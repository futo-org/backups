import AppKit
import BackupsCore
import Foundation
import Observation
import ServiceManagement

enum LoginState: Equatable {
  case idle
  case waiting(userCode: String, url: String)
  case finishing
  case failed(String)
}

enum RecoveryKeyStep: Equatable {
  case save
  case confirm
  case importKey
  case chooseRepository([RemoteRepository])
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
  var signedIn = false
  var restoredFolder: URL?
  var recoveryKeyStep: RecoveryKeyStep?
  var sessionLoaded = false
  var hasSession = false
  var hasMasterKey = false

  private let store = ConfigStore.standard()
  private let vault = SecretVault(store: KeychainSecretStore())
  private let discovery: Discovery
  private let transport: URLSessionTransport
  private let engine: BackupEngine?
  private let missingHelperText: String?
  private var scheduler: Scheduler? = nil
  private var loginTask: Task<Void, Never>?
  private var loginGeneration = 0
  private var operationTask: Task<Void, Never>?
  private var pendingRecoveryKey: String?
  private var sessionToken: String?
  private var sessionGeneration = 0
  private var onboardingGeneration = 0
  private let appVersion: String
  private let configLoadFailure: String?
  private var pendingBootstrapError: String? = nil

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
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
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
          now: { Date() },
          appVersion: appVersion))
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
    self.appVersion = appVersion
    self.configLoadFailure = loadFailure
    if let loadFailure {
      self.pendingBootstrapError =
        missingHelperText.map { "\(loadFailure); \($0)" } ?? loadFailure
    }
    config = loaded
    lastError = loadFailure
    nextRun = loaded.schedule.nextRun(after: loaded.scheduleReference, now: .now, calendar: .current)
    scheduler = Scheduler(model: self)
    scheduler?.start()
    Task { @MainActor in
      if configLoadFailure == nil {
        let storedToken: String? = (try? await vault.get(.accessToken)) ?? nil
        hasSession = storedToken != nil
        sessionToken = storedToken
        if let missingHelperText {
          report("Bootstrap error", ["error": .string(missingHelperText)], force: true)
        }
      }
      hasMasterKey = ((try? await engine?.storedMasterKey()) ?? nil) != nil
      signedIn = hasSession && config.repositoryId != nil && config.recoveryKeyConfirmedAt != nil
      if hasSession && isRecoveringLostKey {
        signedIn = false
        recoveryKeyStep = .importKey
      } else if hasSession && !signedIn {
        continueSetup()
      }
      sessionLoaded = true
      if hasSession {
        await refreshAccount()
      }
    }
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
    guard engine != nil, hasSession, signedIn, config.repositoryId != nil, !config.folders.isEmpty,
      operationTask == nil
    else { return }
    if config.scheduleReference == nil {
      config.scheduleAnchor = Date()
      saveConfig()
      recomputeNextRun()
      return
    }
    if config.schedule.isDue(lastRun: config.scheduleReference, now: .now, calendar: .current) {
      backupNow(scheduled: true)
    }
  }

  func startLogin() {
    guard loginTask == nil else { return }
    guard engine != nil else {
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
        try await self.vault.set(token, for: .accessToken)
        guard generation == self.loginGeneration else {
          _ = try? await self.vault.delete(.accessToken, ifEquals: token)
          return
        }
        self.sessionToken = token
        self.hasSession = true
        self.login = .finishing
        let accountClient = YuccaClient(apiRoot: server.apiRoot, transport: self.transport, accessToken: token)
        self.account = try await accountClient.me()
        guard generation == self.loginGeneration else { return }
        report("Connected FUTO Backups backend")
        if let pendingBootstrapError {
          report("Bootstrap error", ["error": .string(pendingBootstrapError)], force: true)
          self.pendingBootstrapError = nil
        }
        self.loginTask = nil
        self.login = .idle
        self.continueSetup()
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

  var isRecoveringLostKey: Bool {
    config.repositoryId != nil && !hasMasterKey
  }

  var canImportRecoveryKey: Bool {
    config.repositoryId == nil || !hasMasterKey
  }

  func showRecoveryKeyStep(_ step: RecoveryKeyStep) {
    guard step != .importKey || canImportRecoveryKey else { return }
    onboardingGeneration += 1
    pendingRecoveryKey = nil
    recoveryKeyStep = step
  }

  func confirmRecoveryKey(_ input: String) async -> Bool {
    onboardingGeneration += 1
    let generation = onboardingGeneration
    guard let key = await recoveryKey() else { return false }
    guard generation == onboardingGeneration, hasSession else { return false }
    guard RepositoryKeys.matches(input, masterKey: key) else { return false }
    hasMasterKey = true
    markRecoveryKeyConfirmed()
    return true
  }

  func importRecoveryKey(_ input: String) async -> String? {
    onboardingGeneration += 1
    let generation = onboardingGeneration
    guard canImportRecoveryKey else { return "This Mac already has a recovery key." }
    guard let engine else { return missingHelperText ?? "Setup incomplete" }
    guard let normalized = RepositoryKeys.normalizedMasterKey(input) else {
      return "That isn't a valid recovery key."
    }
    if isRecoveringLostKey, let repositoryId = config.repositoryId {
      report("Running repository import", ["repositoryId": .string(repositoryId)])
      do {
        let verified = try await engine.verifyMasterKey(
          normalized, config: config, repositoryId: repositoryId)
        guard generation == onboardingGeneration, hasSession else { return nil }
        guard verified else {
          report(
            "Finished repository import",
            [
              "repositoryId": .string(repositoryId),
              "error": .string("wrong recovery key"),
            ])
          return "That key doesn't open this Mac's backup."
        }
        try await engine.importMasterKey(normalized)
        guard generation == onboardingGeneration, hasSession else { return nil }
      } catch {
        guard generation == onboardingGeneration, hasSession else { return nil }
        report(
          "Finished repository import",
          [
            "repositoryId": .string(repositoryId),
            "error": .string(message(for: error)),
          ])
        return message(for: error)
      }
      report("Finished repository import", ["repositoryId": .string(repositoryId)])
      hasMasterKey = true
      markRecoveryKeyConfirmed()
      return nil
    }
    do {
      let repositories = try await engine.macRepositories(config: config)
      guard generation == onboardingGeneration, hasSession else { return nil }
      if repositories.isEmpty {
        guard config.repositoryId == nil else { return nil }
        try await engine.importMasterKey(normalized)
        guard generation == onboardingGeneration, hasSession else { return nil }
        hasMasterKey = true
        markRecoveryKeyConfirmed()
        return nil
      }
      pendingRecoveryKey = normalized
      recoveryKeyStep = .chooseRepository(repositories)
      return nil
    } catch {
      guard generation == onboardingGeneration, hasSession else { return nil }
      return message(for: error)
    }
  }

  func chooseRepository(_ repository: RemoteRepository) async -> String? {
    onboardingGeneration += 1
    let generation = onboardingGeneration
    guard let engine else { return missingHelperText ?? "Setup incomplete" }
    guard let key = pendingRecoveryKey else { return "No recovery key to use." }
    report("Running repository import", ["repositoryId": .string(repository.id)])
    do {
      let verified = try await engine.verifyMasterKey(key, config: config, repositoryId: repository.id)
      guard generation == onboardingGeneration, hasSession else { return nil }
      guard verified else {
        report(
          "Finished repository import",
          [
            "repositoryId": .string(repository.id),
            "error": .string("wrong recovery key"),
          ])
        return "This backup uses a different recovery key."
      }
      try await engine.importMasterKey(key)
      guard generation == onboardingGeneration, hasSession else { return nil }
    } catch {
      guard generation == onboardingGeneration, hasSession else { return nil }
      report(
        "Finished repository import",
        [
          "repositoryId": .string(repository.id),
          "error": .string(message(for: error)),
        ])
      return message(for: error)
    }
    report("Finished repository import", ["repositoryId": .string(repository.id)])
    hasMasterKey = true
    pendingRecoveryKey = nil
    config.repositoryId = repository.id
    config.recoveryKeyConfirmedAt = Date()
    saveConfig()
    recoveryKeyStep = nil
    signedIn = true
    recomputeNextRun()
    await refreshSnapshots()
    return nil
  }

  func startNewBackupWithPendingKey() async -> String? {
    onboardingGeneration += 1
    let generation = onboardingGeneration
    guard let engine else { return missingHelperText ?? "Setup incomplete" }
    guard let key = pendingRecoveryKey else { return "No recovery key to use." }
    do {
      try await engine.importMasterKey(key)
      guard generation == onboardingGeneration, hasSession else { return nil }
    } catch {
      guard generation == onboardingGeneration, hasSession else { return nil }
      return message(for: error)
    }
    hasMasterKey = true
    pendingRecoveryKey = nil
    markRecoveryKeyConfirmed()
    return nil
  }

  private func markRecoveryKeyConfirmed() {
    config.recoveryKeyConfirmedAt = Date()
    saveConfig()
    continueSetup()
  }

  private func continueSetup() {
    if isRecoveringLostKey {
      recoveryKeyStep = .importKey
      return
    }
    if config.repositoryId == nil && !hasMasterKey {
      config.recoveryKeyConfirmedAt = nil
      saveConfig()
      recoveryKeyStep = .save
      return
    }
    guard config.recoveryKeyConfirmedAt != nil else {
      recoveryKeyStep = .save
      return
    }
    recoveryKeyStep = nil
    guard let engine else {
      login = .failed(missingHelperText ?? "Setup incomplete")
      return
    }
    login = .finishing
    let generation = loginGeneration
    loginTask = Task {
      do {
        let repositoryId = try await engine.ensureRepository(config: self.config)
        guard generation == self.loginGeneration else { return }
        self.config.repositoryId = repositoryId
        self.saveConfig()
        self.loginTask = nil
        self.login = .idle
        self.signedIn = true
        self.recomputeNextRun()
        await self.refreshSnapshots()
      } catch {
        guard generation == self.loginGeneration else { return }
        self.loginTask = nil
        if (error as? EngineError) == .missingMasterKey {
          self.hasMasterKey = false
          self.config.recoveryKeyConfirmedAt = nil
          self.saveConfig()
          self.recoveryKeyStep = .save
          self.login = .idle
          return
        }
        self.login = .failed(self.message(for: error))
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
    let token = sessionToken
    sessionToken = nil
    sessionGeneration += 1
    onboardingGeneration += 1
    operationTask?.cancel()
    account = nil
    snapshots = []
    signedIn = false
    hasSession = false
    restoredFolder = nil
    recoveryKeyStep = nil
    pendingRecoveryKey = nil
    loginGeneration += 1
    loginTask?.cancel()
    loginTask = nil
    login = .idle
    Task {
      if let token {
        _ = try? await self.vault.delete(.accessToken, ifEquals: token)
        guard let server = try? await self.discovery.resolve(serverURL) else { return }
        let client = YuccaClient(apiRoot: server.apiRoot, transport: self.transport, accessToken: token)
        try? await client.logout()
      }
    }
  }

  func addFolders(_ urls: [URL]) {
    for path in urls.map(\.path) where !config.folders.contains(path) {
      config.folders.append(path)
    }
    if config.scheduleAnchor == nil {
      config.scheduleAnchor = Date()
    }
    saveConfig()
    reportRepositoryChange()
  }

  func removeFolder(_ path: String) {
    config.folders.removeAll { $0 == path }
    saveConfig()
    reportRepositoryChange()
  }

  func setSchedule(_ schedule: Schedule) {
    config.schedule = schedule
    config.scheduleAnchor = Date()
    saveConfig()
    recomputeNextRun()
    report("Updated schedule", ["schedule": .string(scheduleDescription(schedule))])
  }

  func grantTelemetryConsent() {
    config.telemetryConsentedAt = Date()
    saveConfig()
    report("Telemetry consent granted")
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

  func backupNow(scheduled: Bool = false) {
    guard activity == nil, operationTask == nil else { return }
    guard engine != nil else {
      lastError = missingHelperText
      return
    }
    guard hasSession else {
      lastError = "Not logged in"
      return
    }
    guard signedIn else {
      lastError = "Finish setting up FUTO Backups first"
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
    let generation = sessionGeneration
    activity = .preparing
    operationTask = Task {
      defer {
        if scheduled {
          report(
            "Finished running schedule for 1 repositories",
            ["lastFinished": .date(Date())],
            generation: generation)
        }
      }
      do {
        let record = try await engine.backup(config: configSnapshot) { activity in
          Task { @MainActor in
            guard self.operationTask != nil, generation == self.sessionGeneration else { return }
            self.activity = activity
          }
        }
        guard generation == self.sessionGeneration else {
          self.finishOperation()
          return
        }
        self.config.lastRun = record
        self.saveConfig()
        self.finishOperation()
        if record.status == .failed || record.status == .warn {
          self.lastError = record.message
        }
        self.recomputeNextRun()
        await self.refreshSnapshots()
      } catch {
        guard generation == self.sessionGeneration else {
          self.finishOperation()
          return
        }
        self.finishOperation()
        self.lastError = self.message(for: error)
      }
    }
    if scheduled, let repositoryId = config.repositoryId {
      report(
        "Running schedule for 1 repositories",
        [
          "lastRun": .date(Date()),
          "repositories": .array([.string(repositoryId)]),
        ])
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
    guard signedIn else {
      lastError = "Finish setting up FUTO Backups first"
      return
    }
    guard config.repositoryId != nil else {
      lastError = "No repository yet"
      return
    }
    let configSnapshot = config
    let generation = sessionGeneration
    activity = .restoring
    restoredFolder = nil
    operationTask = Task {
      do {
        try await engine.restore(config: configSnapshot, snapshotId: snapshot.id, target: url, include: []) {
          activity in
          Task { @MainActor in
            guard self.operationTask != nil, generation == self.sessionGeneration else { return }
            self.activity = activity
          }
        }
        guard generation == self.sessionGeneration else {
          self.finishOperation()
          return
        }
        self.finishOperation()
        self.restoredFolder = snapshot.paths.first.map { url.appendingPathComponent($0) } ?? url
      } catch {
        guard generation == self.sessionGeneration else {
          self.finishOperation()
          return
        }
        self.finishOperation()
        self.lastError = self.message(for: error)
      }
    }
  }

  func refreshSnapshots() async {
    guard let engine, config.repositoryId != nil else { return }
    let generation = sessionGeneration
    do {
      let result = try await engine.snapshots(config: config)
      guard generation == sessionGeneration else { return }
      snapshots = result
    } catch is CancellationError {
      return
    } catch {
      guard generation == sessionGeneration else { return }
      lastError = message(for: error)
    }
  }

  func recoveryKey() async -> String? {
    guard let engine else { return nil }
    if config.repositoryId != nil {
      return try? await engine.storedMasterKey()
    }
    return try? await engine.masterKey()
  }

  private func refreshAccount() async {
    let generation = sessionGeneration
    do {
      let client = try await makeAPIClient()
      let info = try await client.me()
      guard generation == sessionGeneration else { return }
      account = info
    } catch is CancellationError {
      return
    } catch {
      guard generation == sessionGeneration else { return }
      lastError = message(for: error)
    }
  }

  private func makeAPIClient() async throws -> YuccaClient {
    let server = try await discovery.resolve(config.serverURL)
    let token = try? await vault.get(.accessToken)
    return YuccaClient(apiRoot: server.apiRoot, transport: transport, accessToken: token)
  }

  private func report(
    _ summary: String,
    _ data: [String: TelemetryValue] = [:],
    force: Bool = false,
    generation: Int? = nil
  ) {
    if let generation, generation != sessionGeneration { return }
    guard force || config.telemetryConsentedAt != nil, let token = sessionToken else { return }
    let serverURL = config.serverURL
    let capturedGeneration = sessionGeneration
    let version = appVersion
    Task {
      guard let server = try? await discovery.resolve(serverURL) else { return }
      guard capturedGeneration == sessionGeneration else { return }
      let client = YuccaClient(apiRoot: server.apiRoot, transport: transport, accessToken: token)
      try? await client.submitStructuredLog(StructuredLog(summary: summary, data: data, version: version))
    }
  }

  private func reportRepositoryChange() {
    guard let repositoryId = config.repositoryId else { return }
    report(
      "Updated repository",
      [
        "repositoryId": .string(repositoryId),
        "pathCount": .int(Int64(config.folders.count)),
      ])
  }

  private func scheduleDescription(_ schedule: Schedule) -> String {
    switch schedule {
    case .manual: return "manual"
    case .hourly: return "hourly"
    case .daily(let hour, let minute): return String(format: "daily %02d:%02d", hour, minute)
    }
  }

  private func finishOperation() {
    activity = nil
    operationTask = nil
  }

  private func saveConfig() {
    do {
      try store.save(config)
    } catch {
      lastError = String(describing: error)
    }
  }

  private func recomputeNextRun() {
    nextRun = config.schedule.nextRun(after: config.scheduleReference, now: .now, calendar: .current)
  }

  private func message(for error: Error) -> String {
    if let engineError = error as? EngineError {
      switch engineError {
      case .notLoggedIn: return "Not logged in"
      case .noRepository: return "No repository yet"
      case .noFolders: return "No folders selected"
      case .busy: return "Another operation is running"
      case .missingMasterKey: return "This Mac's recovery key is missing"
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
