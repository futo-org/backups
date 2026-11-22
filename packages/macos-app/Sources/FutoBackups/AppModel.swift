import AppKit
import BackupsCore
import Foundation
import Observation
import ServiceManagement

enum LoginState: Equatable {
  case idle
  case waiting(userCode: String, url: String)
  case failed(String)
}

@MainActor
@Observable
final class AppModel {
  var config: AppConfig
  var account: AuthInfo?
  var login: LoginState = .idle
  var activity: EngineActivity?
  var snapshots: [Snapshot] = []
  var lastError: String?
  var nextRun: Date?
  var setupError: String?

  private let store = ConfigStore.standard()
  private let secrets = KeychainSecretStore()
  private let discovery: Discovery
  private let transport: URLSessionTransport
  private let engine: BackupEngine?
  private let missingHelperText: String?
  private var scheduler: Scheduler? = nil
  private var loginTask: Task<Void, Never>?
  private var loginGeneration = 0
  private var operationTask: Task<Void, Never>?

  init() {
    let home = NSHomeDirectory()
    let host = Host.current().localizedName ?? "Mac"
    var loaded = AppConfig.defaults(host: host, home: home)
    var loadFailure: String?
    do {
      loaded = try ConfigStore.standard().load(defaultHost: host, home: home)
    } catch {
      loadFailure = "Could not load config: \(error)"
    }
    let cacheDirectory = URL(fileURLWithPath: home)
      .appendingPathComponent("Library")
      .appendingPathComponent("Caches")
      .appendingPathComponent("FUTO Backups")
      .appendingPathComponent("restic")
    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let discovery = Discovery(transport: URLSessionTransport(timeout: 8))
    let transport = URLSessionTransport()
    let resticURL = HelperLocator.locate(.restic)
    let proxyURL = HelperLocator.locate(.resticProxy)
    let engine: BackupEngine?
    let missingHelperText: String?
    if let resticURL, let proxyURL {
      engine = BackupEngine(
        environment: EngineEnvironment(
          secrets: KeychainSecretStore(),
          discover: { try await discovery.resolve($0) },
          makeAPI: { YuccaClient(apiRoot: $0, transport: transport, accessToken: $1) },
          restic: ResticRunner(executable: resticURL),
          proxyLauncher: ResticProxyLauncher(executable: proxyURL),
          cacheDirectory: cacheDirectory,
          home: home,
          processorCount: ProcessInfo.processInfo.activeProcessorCount,
          now: { Date() }))
      missingHelperText = nil
    } else {
      engine = nil
      let missing = resticURL == nil ? Helper.restic : Helper.resticProxy
      missingHelperText =
        "Missing bundled helper: \(missing.rawValue). Run the bundled app or set "
        + "\(Helper.restic.environmentKey) / \(Helper.resticProxy.environmentKey)."
    }
    self.discovery = discovery
    self.transport = transport
    self.engine = engine
    self.missingHelperText = missingHelperText
    config = loaded
    lastError = loadFailure
    nextRun = loaded.schedule.nextRun(after: loaded.lastRun?.startedAt, now: .now, calendar: .current)
    scheduler = Scheduler(model: self)
    scheduler?.start()
    if isLoggedIn {
      Task {
        await self.refreshAccount()
      }
    }
  }

  var isLoggedIn: Bool {
    ((try? secrets.get(.accessToken)) ?? nil) != nil
  }

  var launchAtLogin: Bool {
    get { SMAppService.mainApp.status == .enabled }
    set {
      do {
        if newValue {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
      } catch {
        lastError = String(describing: error)
      }
    }
  }

  func tick() {
    recomputeNextRun()
    guard engine != nil, isLoggedIn, config.repositoryId != nil, !config.folders.isEmpty, operationTask == nil
    else { return }
    if config.schedule.isDue(lastRun: config.lastRun?.startedAt, now: .now, calendar: .current) {
      backupNow()
    }
  }

  func startLogin() {
    guard loginTask == nil else { return }
    guard let engine else {
      login = .failed(missingHelperText ?? "Setup incomplete")
      return
    }
    loginGeneration += 1
    let generation = loginGeneration
    loginTask = Task {
      do {
        let server = try await self.discovery.resolve(self.config.serverURL)
        let client = YuccaClient(apiRoot: server.apiRoot, transport: self.transport)
        let authorization = try await client.startDeviceAuthorization()
        guard generation == self.loginGeneration else { return }
        let urlString = authorization.verificationUriComplete ?? authorization.verificationUri
        self.login = .waiting(userCode: authorization.userCode, url: urlString)
        if let url = URL(string: urlString) {
          NSWorkspace.shared.open(url)
        }
        let deviceLogin = DeviceLogin(client: client)
        let token = try await deviceLogin.waitForToken(
          authorization, connectionType: "macos", connectionName: self.config.host)
        guard generation == self.loginGeneration else { return }
        try self.secrets.set(token, for: .accessToken)
        let accountClient = YuccaClient(apiRoot: server.apiRoot, transport: self.transport, accessToken: token)
        self.account = try await accountClient.me()
        let repositoryId = try await engine.ensureRepository(config: self.config)
        guard generation == self.loginGeneration else { return }
        self.config.repositoryId = repositoryId
        self.saveConfig()
        self.login = .idle
        self.recomputeNextRun()
        self.loginTask = nil
        await self.refreshSnapshots()
      } catch {
        guard generation == self.loginGeneration else { return }
        self.loginTask = nil
        if error is CancellationError {
          self.login = .idle
        } else {
          self.login = .failed(self.message(for: error))
        }
      }
    }
  }

  func cancelLogin() {
    guard let task = loginTask else { return }
    loginGeneration += 1
    loginTask = nil
    task.cancel()
    login = .idle
  }

  func logout() {
    let serverURL = config.serverURL
    let token = (try? secrets.get(.accessToken)) ?? nil
    account = nil
    snapshots = []
    try? secrets.delete(.accessToken)
    guard let token else { return }
    Task {
      guard let server = try? await self.discovery.resolve(serverURL) else { return }
      let client = YuccaClient(apiRoot: server.apiRoot, transport: self.transport, accessToken: token)
      try? await client.logout()
    }
  }

  func addFolders(_ urls: [URL]) {
    for path in urls.map(\.path) where !config.folders.contains(path) {
      config.folders.append(path)
    }
    saveConfig()
  }

  func removeFolder(_ path: String) {
    config.folders.removeAll { $0 == path }
    saveConfig()
  }

  func setSchedule(_ schedule: Schedule) {
    config.schedule = schedule
    saveConfig()
    recomputeNextRun()
  }

  func setThrottle(_ throttle: Throttle) {
    config.throttle = throttle
    saveConfig()
  }

  func setServerURL(_ url: URL) {
    logout()
    config.serverURL = url
    config.repositoryId = nil
    saveConfig()
  }

  func backupNow() {
    guard activity == nil, operationTask == nil else { return }
    guard engine != nil else {
      lastError = missingHelperText
      return
    }
    guard isLoggedIn else {
      lastError = "Not logged in"
      return
    }
    guard config.repositoryId != nil else {
      lastError = "No repository yet"
      return
    }
    guard !config.folders.isEmpty else {
      lastError = "No folders selected"
      return
    }
    guard let engine else { return }
    let configSnapshot = config
    activity = .preparing
    operationTask = Task {
      do {
        let record = try await engine.backup(config: configSnapshot) { activity in
          Task { @MainActor in
            self.activity = activity
          }
        }
        self.config.lastRun = record
        self.saveConfig()
        self.activity = nil
        if record.status == .failed || record.status == .warn {
          self.lastError = record.message
        }
        self.recomputeNextRun()
        await self.refreshSnapshots()
      } catch {
        self.activity = nil
        self.lastError = self.message(for: error)
      }
      self.operationTask = nil
    }
  }

  func cancelBackup() {
    operationTask?.cancel()
  }

  func restore(snapshot: Snapshot, to url: URL) {
    guard activity == nil, operationTask == nil else {
      lastError = "Another operation is running"
      return
    }
    guard let engine else {
      lastError = missingHelperText
      return
    }
    guard config.repositoryId != nil else {
      lastError = "No repository yet"
      return
    }
    let configSnapshot = config
    activity = .restoring
    operationTask = Task {
      do {
        try await engine.restore(config: configSnapshot, snapshotId: snapshot.id, target: url, include: []) {
          activity in
          Task { @MainActor in
            self.activity = activity
          }
        }
        self.activity = nil
      } catch {
        self.activity = nil
        self.lastError = self.message(for: error)
      }
      self.operationTask = nil
    }
  }

  func refreshSnapshots() async {
    guard let engine, config.repositoryId != nil else { return }
    do {
      snapshots = try await engine.snapshots(config: config)
    } catch is CancellationError {
      return
    } catch {
      lastError = message(for: error)
    }
  }

  func recoveryKey() async -> String? {
    guard let engine else { return nil }
    return try? await engine.masterKey()
  }

  private func refreshAccount() async {
    do {
      let client = try await makeAPIClient()
      account = try await client.me()
    } catch is CancellationError {
      return
    } catch {
      lastError = message(for: error)
    }
  }

  private func makeAPIClient() async throws -> YuccaClient {
    let server = try await discovery.resolve(config.serverURL)
    return YuccaClient(
      apiRoot: server.apiRoot, transport: transport, accessToken: (try? secrets.get(.accessToken)) ?? nil)
  }

  private func saveConfig() {
    do {
      try store.save(config)
    } catch {
      lastError = String(describing: error)
    }
  }

  private func recomputeNextRun() {
    nextRun = config.schedule.nextRun(after: config.lastRun?.startedAt, now: .now, calendar: .current)
  }

  private func message(for error: Error) -> String {
    if let engineError = error as? EngineError {
      switch engineError {
      case .notLoggedIn: return "Not logged in"
      case .noRepository: return "No repository yet"
      case .noFolders: return "No folders selected"
      case .busy: return "Another operation is running"
      case .restic(_, let message): return message
      }
    }
    if let yuccaError = error as? YuccaError, yuccaError == .unauthorized {
      logout()
      return "Session expired, log in again"
    }
    if let loginError = error as? DeviceLoginError {
      switch loginError {
      case .expired: return "Login code expired"
      case .failed(let reason): return "Login failed: \(reason)"
      }
    }
    return String(describing: error)
  }
}
