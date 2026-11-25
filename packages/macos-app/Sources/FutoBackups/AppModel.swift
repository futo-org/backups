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

enum SnapshotsLoad: Equatable {
  case notLoaded
  case loading
  case loaded
  case failed(String)
}

struct SnapshotBrowserUnavailable: Error, CustomStringConvertible {
  let message: String

  var description: String { message }
}

struct RecoveryKeyChangeFailure: Error {
  let message: String

  init(_ message: String) {
    self.message = message
  }
}

enum RecoveryKeyStep: Equatable {
  case save
  case confirm
  case importKey
  case chooseRepository([RemoteRepository])
  case repositoryKey(RemoteRepository, among: [RemoteRepository], storedKeyFailed: Bool)
  case newBackupKey([RemoteRepository])
}

private enum RepositoryUnlockAttempt {
  case finished(ExistingBackupUnlock)
  case failed(String)
  case superseded
}

@MainActor
@Observable
final class AppModel {
  var config: AppConfig
  var account: AuthInfo?
  var login: LoginState = .idle
  var activity: ActivityPhase?
  var isCancelling = false
  var snapshots: [Snapshot] = []
  var snapshotsLoad: SnapshotsLoad = .notLoaded
  var lastError: String?
  var nextRun: Date?
  var setupError: String?
  var signedIn = false
  var restoredFolders: [URL] = []
  var restoreStoppedEarly = false
  var recoveryKeyStep: RecoveryKeyStep?
  var storedKeyChecks: [String: StoredKeyCheck] = [:]
  var sessionLoaded = false
  var hasSession = false
  var hasMasterKey = false
  var hasFullDiskAccess = FullDiskAccess.isGranted()
  var configLoadFailure: String?
  var backupDeletion: BackupDeletionState = .idle
  var isResetting = false
  let activityProgress = ActivityProgressStore()

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
  private var pendingRecoveryKeyConfirmed = false
  private var storedKeyCheckTask: Task<Void, Never>?
  private var sessionToken: String?
  private var sessionGeneration = 0
  private var onboardingGeneration = 0
  private let appVersion: String
  private let configLoadFailed: Bool
  private var configNeedsMovingAside: Bool
  private var pendingBootstrapError: String? = nil
  private var appActiveObserver: (any NSObjectProtocol)?
  private var backupDeletionTask: Task<Void, Never>?
  private let failureNotifier = FailureNotifier(center: FailureNotifications.shared)

  static let allowsServerSelection =
    Bundle.main.object(forInfoDictionaryKey: "FUTOServerSelection") as? Bool ?? true

  init() {
    let home = NSHomeDirectory()
    let host = Host.current().localizedName ?? "Mac"
    var loaded = AppConfig.defaults(host: host, home: home)
    var loadFailure: String?
    var pinnedToProduction = false
    do {
      loaded = try ConfigStore.standard().load(defaultHost: host, home: home)
      if loaded.addNewDefaultExcludes(home: home) {
        try? ConfigStore.standard().save(loaded)
      }
      if !Self.allowsServerSelection, loaded.pinToProductionServer() {
        try? ConfigStore.standard().save(loaded)
        pinnedToProduction = true
      }
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
    let snapshotDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("FUTO Backups")
      .appendingPathComponent("Snapshot")
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
          appVersion: appVersion,
          diskSnapshots: TimeMachineSnapshots.live(),
          snapshotDirectory: snapshotDirectory,
          dataVolumePath: { DataVolume.relativePath(of: $0) },
          cloudOnlyScanner: CloudOnlyScanner()))
      missingHelperText = nil
    } else {
      engine = nil
      let missing = resticURL == nil ? Helper.restic : Helper.resticProxy
      missingHelperText =
        "Missing bundled helper: \(missing.rawValue). Run the bundled app or set "
        + "\(Helper.restic.environmentKey) / \(Helper.resticProxy.environmentKey)."
    }
    if let engine {
      Task {
        await engine.cleanUpStaleDiskSnapshots()
      }
    }
    self.discovery = discovery
    self.transport = transport
    self.engine = engine
    self.missingHelperText = missingHelperText
    self.appVersion = appVersion
    self.configLoadFailure = loadFailure
    self.configLoadFailed = loadFailure != nil
    self.configNeedsMovingAside = loadFailure != nil
    if let loadFailure {
      self.pendingBootstrapError =
        missingHelperText.map { "\(loadFailure); \($0)" } ?? loadFailure
    }
    config = loaded
    lastError = loadFailure
    nextRun = loaded.schedule.nextRun(after: loaded.scheduleReference, now: .now, calendar: .current)
    if loadFailure == nil, config.treatExistingFoldersAsOnboarded(at: Date()) {
      saveConfig()
    }
    failureNotifier.host = self
    scheduler = Scheduler(model: self)
    scheduler?.start()
    let clearsSession = pinnedToProduction
    Task { @MainActor in
      if clearsSession {
        try? await vault.delete(.accessToken)
      }
      if !configLoadFailed {
        let storedToken: String? = (try? await vault.get(.accessToken)) ?? nil
        hasSession = storedToken != nil
        sessionToken = storedToken
        if let missingHelperText {
          report("Bootstrap error", ["error": .string(missingHelperText)], force: true)
        }
      }
      hasMasterKey = ((try? await engine?.storedMasterKey()) ?? nil) != nil
      signedIn = hasSession && config.repositoryId != nil && config.recoveryKeyConfirmedAt != nil
      if hasSession && !signedIn {
        continueSetup()
      }
      sessionLoaded = true
      if hasSession {
        await refreshAccount()
      }
      if signedIn {
        await finishPendingKeyRotation()
        await refreshSnapshots()
      }
    }
    appActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshFullDiskAccess()
        self?.refreshNotificationAuthorization()
      }
    }
    refreshNotificationAuthorization()
  }

  func refreshFullDiskAccess() {
    hasFullDiskAccess = FullDiskAccess.isGranted()
  }

  var failureNotificationToggle: FailureNotificationToggle { failureNotifier.toggle }

  var isRequestingNotificationPermission: Bool { failureNotifier.isRequestingAuthorization }

  var showsFailureNotificationHint: Bool { failureNotifier.showsHint }

  var isMissingRecoveryKey: Bool { signedIn && isRecoveringLostKey }

  func refreshNotificationAuthorization() {
    Task { await failureNotifier.refreshAuthorization() }
  }

  func setFailureNotifications(_ enabled: Bool) {
    Task { await failureNotifier.setEnabled(enabled) }
  }

  func dismissFailureNotificationHint() {
    failureNotifier.dismissHint()
  }

  func openNotificationSettings() {
    guard let url = FailureNotifications.systemSettingsURL else { return }
    NSWorkspace.shared.open(url)
  }

  var hasSnapshotFolders: Bool {
    config.folders.contains { DataVolume.relativePath(of: $0) != nil }
  }

  var launchAtLogin: Bool {
    get { SMAppService.mainApp.status == .enabled }
    set { setLaunchAtLogin(newValue) }
  }

  func setLaunchAtLogin(_ wanted: Bool) {
    let service = SMAppService.mainApp
    do {
      switch LoginItemChange.toward(openAtLogin: wanted, from: service.loginItemStatus) {
      case .none, .askForApproval: break
      case .register: try service.register()
      case .unregister: try service.unregister()
      }
    } catch {
      lastError = String(describing: error)
      return
    }
    if wanted, service.loginItemStatus == .requiresApproval {
      lastError = "To open FUTO Backups at login, turn it on under Login Items in System Settings."
      SMAppService.openSystemSettingsLoginItems()
    }
  }

  func tick() {
    recomputeNextRun()
    guard engine != nil, hasSession, signedIn, !isMissingRecoveryKey, config.repositoryId != nil,
      !config.folders.isEmpty, operationTask == nil
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
        if self.config.repositoryId != nil {
          let repositories = try await accountClient.listRepositories()
          guard generation == self.loginGeneration else { return }
          if self.config.forgetRepository(unlessListedIn: repositories) {
            self.saveConfig()
            self.failureNotifier.endStreak()
          }
        }
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
    guard step != .importKey || isRecoveringLostKey else { return }
    onboardingGeneration += 1
    switch step {
    case .chooseRepository(let repositories):
      startStoredKeyChecks(repositories)
    case .repositoryKey, .newBackupKey:
      break
    case .save, .confirm, .importKey:
      holdRecoveryKey(nil)
    }
    recoveryKeyStep = step
  }

  func showExistingBackups() async -> String? {
    onboardingGeneration += 1
    let generation = onboardingGeneration
    guard canImportRecoveryKey else { return "This Mac already has a recovery key." }
    guard let engine else { return missingHelperText ?? "Setup incomplete" }
    do {
      let repositories = try await engine.macRepositories(config: config)
      let storedKey = hasMasterKey ? ((try? await engine.storedMasterKey()) ?? nil) : nil
      guard generation == onboardingGeneration, hasSession else { return nil }
      guard !repositories.isEmpty else {
        holdRecoveryKey(nil)
        showRecoveryKeyStep(.newBackupKey([]))
        return nil
      }
      holdRecoveryKey(storedKey, confirmed: false)
      showRecoveryKeyStep(.chooseRepository(repositories))
      return nil
    } catch {
      guard generation == onboardingGeneration, hasSession else { return nil }
      return message(for: error)
    }
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
    guard isRecoveringLostKey, let repositoryId = config.repositoryId else {
      return "This Mac already has a recovery key."
    }
    guard let normalized = RepositoryKeys.normalizedMasterKey(input) else {
      return "That isn't a valid recovery key."
    }
    switch await unlockRepository(repositoryId, with: .entered(normalized)) {
    case .superseded: return nil
    case .failed(let message): return message
    case .finished(.unlocked):
      hasMasterKey = true
      if signedIn {
        lastError = nil
        Task { await refreshSnapshots() }
      } else {
        markRecoveryKeyConfirmed()
      }
      return nil
    case .finished: return "That key doesn't open this Mac's backup."
    }
  }

  func chooseRepository(_ repository: RemoteRepository, among repositories: [RemoteRepository]) async -> String? {
    guard let storedKey = pendingRecoveryKey else {
      showRecoveryKeyStep(.repositoryKey(repository, among: repositories, storedKeyFailed: false))
      return nil
    }
    switch await unlockRepository(repository.id, with: .stored(storedKey)) {
    case .superseded: return nil
    case .failed(let message):
      startStoredKeyChecks(repositories)
      return message
    case .finished(.unlocked):
      await continueRepository(repository)
      return nil
    case .finished:
      showRecoveryKeyStep(.repositoryKey(repository, among: repositories, storedKeyFailed: true))
      return nil
    }
  }

  func enterRepositoryKey(_ input: String, for repository: RemoteRepository) async -> String? {
    guard RepositoryKeys.normalizedMasterKey(input) != nil else { return "That isn't a valid recovery key." }
    switch await unlockRepository(repository.id, with: .entered(input)) {
    case .superseded: return nil
    case .failed(let message): return message
    case .finished(.unlocked):
      await continueRepository(repository)
      return nil
    case .finished: return "That key doesn't open \(repository.name)."
    }
  }

  func startNewBackup(insteadOf repositories: [RemoteRepository]) async -> String? {
    onboardingGeneration += 1
    let generation = onboardingGeneration
    guard let engine else { return missingHelperText ?? "Setup incomplete" }
    guard let key = pendingRecoveryKey, pendingRecoveryKeyConfirmed else {
      showRecoveryKeyStep(.newBackupKey(repositories))
      return nil
    }
    await stopStoredKeyChecks()
    guard generation == onboardingGeneration, hasSession else { return nil }
    do {
      try await engine.importMasterKey(key)
      guard generation == onboardingGeneration, hasSession else { return nil }
    } catch {
      guard generation == onboardingGeneration, hasSession else { return nil }
      return message(for: error)
    }
    hasMasterKey = true
    holdRecoveryKey(nil)
    markRecoveryKeyConfirmed(offeringExistingRepositories: false)
    return nil
  }

  func startNewBackup(withKey input: String) async -> String? {
    onboardingGeneration += 1
    let generation = onboardingGeneration
    guard config.repositoryId == nil else { return "This Mac already has a backup." }
    guard let engine else { return missingHelperText ?? "Setup incomplete" }
    await stopStoredKeyChecks()
    guard generation == onboardingGeneration, hasSession else { return nil }
    do {
      try await engine.importMasterKey(input)
      guard generation == onboardingGeneration, hasSession else { return nil }
    } catch {
      guard generation == onboardingGeneration, hasSession else { return nil }
      return message(for: error)
    }
    hasMasterKey = true
    holdRecoveryKey(nil)
    markRecoveryKeyConfirmed(offeringExistingRepositories: false)
    return nil
  }

  private func unlockRepository(_ repositoryId: String, with key: ExistingBackupKey) async -> RepositoryUnlockAttempt {
    onboardingGeneration += 1
    let generation = onboardingGeneration
    guard let engine else { return .failed(missingHelperText ?? "Setup incomplete") }
    await stopStoredKeyChecks()
    guard generation == onboardingGeneration, hasSession else { return .superseded }
    report("Running repository import", ["repositoryId": .string(repositoryId)])
    do {
      let unlock = try await engine.unlockExistingRepository(repositoryId, with: key, config: config)
      guard generation == onboardingGeneration, hasSession else { return .superseded }
      if case .stored = key {
        storedKeyChecks[repositoryId] = unlock == .unlocked ? .opens : .doesNotOpen
      }
      if unlock == .unlocked {
        report("Finished repository import", ["repositoryId": .string(repositoryId)])
      } else {
        report(
          "Finished repository import",
          ["repositoryId": .string(repositoryId), "error": .string("wrong recovery key")])
      }
      return .finished(unlock)
    } catch {
      guard generation == onboardingGeneration, hasSession else { return .superseded }
      report(
        "Finished repository import",
        ["repositoryId": .string(repositoryId), "error": .string(message(for: error))])
      return .failed(message(for: error))
    }
  }

  private func continueRepository(_ repository: RemoteRepository) async {
    hasMasterKey = true
    holdRecoveryKey(nil)
    config.repositoryId = repository.id
    config.recoveryKeyConfirmedAt = Date()
    saveConfig()
    recoveryKeyStep = nil
    signedIn = true
    recomputeNextRun()
    await refreshSnapshots()
  }

  private func holdRecoveryKey(_ key: String?, confirmed: Bool = false) {
    pendingRecoveryKeyConfirmed = key != nil && confirmed
    guard key == nil || key != pendingRecoveryKey else { return }
    storedKeyCheckTask?.cancel()
    storedKeyCheckTask = nil
    storedKeyChecks = [:]
    pendingRecoveryKey = key
  }

  private func startStoredKeyChecks(_ repositories: [RemoteRepository]) {
    guard let engine, let storedKey = pendingRecoveryKey, storedKeyCheckTask == nil else { return }
    let unchecked = repositories.map(\.id).filter { storedKeyChecks[$0] == nil || storedKeyChecks[$0] == .unknown }
    guard !unchecked.isEmpty else { return }
    let config = config
    storedKeyCheckTask = Task { [weak self] in
      await engine.checkStoredKey(storedKey, against: unchecked, config: config) { repositoryId, check in
        await MainActor.run {
          guard !Task.isCancelled else { return }
          self?.storedKeyChecks[repositoryId] = check
        }
      }
      guard !Task.isCancelled else { return }
      self?.storedKeyCheckTask = nil
    }
  }

  private func stopStoredKeyChecks() async {
    guard let task = storedKeyCheckTask else { return }
    storedKeyCheckTask = nil
    task.cancel()
    await task.value
    storedKeyChecks = storedKeyChecks.filter { $0.value != .checking }
  }

  private func markRecoveryKeyConfirmed(offeringExistingRepositories: Bool = true) {
    config.recoveryKeyConfirmedAt = Date()
    saveConfig()
    continueSetup(offeringExistingRepositories: offeringExistingRepositories)
  }

  private func continueSetup(offeringExistingRepositories: Bool = true) {
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
        let setup = try await engine.setUpRepository(
          config: self.config, offeringExisting: offeringExistingRepositories)
        guard generation == self.loginGeneration else { return }
        self.loginTask = nil
        self.login = .idle
        switch setup {
        case .chooseExisting(let existing, let key):
          self.holdRecoveryKey(key, confirmed: true)
          self.showRecoveryKeyStep(.chooseRepository(existing))
        case .ready(let repositoryId):
          self.config.repositoryId = repositoryId
          self.saveConfig()
          self.signedIn = true
          self.recomputeNextRun()
          await self.refreshSnapshots()
        }
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
    snapshotsLoad = .notLoaded
    signedIn = false
    hasSession = false
    restoredFolders = []
    recoveryKeyStep = nil
    holdRecoveryKey(nil)
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

  var needsOnboarding: Bool {
    config.needsOnboarding
  }

  func finishOnboarding(folders: [String], retention: RetentionPreset, backUpNow startBackup: Bool) {
    config.retention = retention.retention
    config.completeOnboarding(folders: folders, at: Date())
    saveConfig()
    recomputeNextRun()
    reportRepositoryChange()
    Task { await failureNotifier.requestPermissionIfNeeded() }
    if startBackup {
      backupNow()
    }
  }

  func removeFolder(_ path: String) {
    config.folders.removeAll { $0 == path }
    saveConfig()
    reportRepositoryChange()
  }

  var hasAllDefaultExclusions: Bool {
    Exclusions.defaults(home: NSHomeDirectory()).allSatisfy(config.excludes.contains)
  }

  func isDefaultExclusion(_ pattern: String) -> Bool {
    Exclusions.isDefault(pattern, home: NSHomeDirectory())
  }

  func addExclusions(_ urls: [URL]) {
    addExcludedPaths(urls.map(\.path))
  }

  func addExcludedPaths(_ paths: [String]) {
    updateExclusions(Exclusions.excluding(paths, in: config.excludes))
  }

  func isExcludedPath(_ path: String) -> Bool {
    Exclusions.isExcluded(path, by: config.excludes)
  }

  func canExcludePath(_ path: String) -> Bool {
    !Exclusions.wouldExcludeAnyFolder(path, folders: config.folders)
  }

  func addExclusionPattern(_ input: String) -> String? {
    guard let pattern = Exclusions.normalizedPattern(input, home: NSHomeDirectory()) else {
      return "Enter a folder, file or pattern."
    }
    do {
      try updateExclusions(Exclusions.adding([pattern], to: config.excludes))
      return nil
    } catch {
      return "That's already excluded."
    }
  }

  func removeExclusion(_ pattern: String) {
    updateExclusions(config.excludes.filter { $0 != pattern })
  }

  func restoreDefaultExclusions() {
    updateExclusions(Exclusions.restoringDefaults(in: config.excludes, home: NSHomeDirectory()))
  }

  private func updateExclusions(_ excludes: [String]) {
    guard excludes != config.excludes else { return }
    config.excludes = excludes
    saveConfig()
    report("Updated exclusions", ["count": .int(Int64(excludes.count))])
  }

  func setSchedule(_ schedule: Schedule) {
    let previous = config.schedule
    config.schedule = schedule
    config.scheduleAnchor = Date()
    saveConfig()
    recomputeNextRun()
    report("Updated schedule", ["schedule": .string(scheduleDescription(schedule))])
    Task { await failureNotifier.scheduleChanged(from: previous) }
  }

  func setUploadConnections(_ connections: Int?) {
    guard connections != config.uploadConnections else { return }
    config.uploadConnections = connections
    saveConfig()
    report("Updated parallelism", ["uploadConnections": .string(connections.map(String.init) ?? "auto")])
  }

  func setReadConcurrency(_ concurrency: Int?) {
    guard concurrency != config.readConcurrency else { return }
    config.readConcurrency = concurrency
    saveConfig()
    report("Updated parallelism", ["readConcurrency": .string(concurrency.map(String.init) ?? "auto")])
  }

  func setRetention(_ retention: SnapshotRetention) {
    guard retention != config.retention else { return }
    config.retention = retention
    saveConfig()
    report("Updated snapshot retention", ["retentionPolicy": .string(retention.telemetryValue)])
  }

  func setDiskSnapshots(_ enabled: Bool) {
    config.diskSnapshots = enabled
    saveConfig()
    report("Updated disk snapshots", ["enabled": .bool(enabled)])
    if !enabled, let engine {
      Task {
        await engine.cleanUpStaleDiskSnapshots()
      }
    }
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
    guard url != config.serverURL else { return }
    logout()
    failureNotifier.cancelPendingNotice()
    config.switchServer(to: url)
    saveConfig()
  }

  func backupNow(scheduled: Bool = false) {
    guard activity == nil, operationTask == nil, !isResetting, backupDeletionTask == nil else { return }
    guard engine != nil else {
      lastError = missingHelperText
      return
    }
    guard hasSession else {
      lastError = "Not signed in"
      return
    }
    guard signedIn else {
      lastError = "Finish setting up FUTO Backups first"
      return
    }
    guard !isMissingRecoveryKey else {
      lastError = message(for: EngineError.missingMasterKey)
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
        _ = try? await engine.finishPendingKeyRotation(config: configSnapshot)
        let record = try await engine.backup(config: configSnapshot) { activity in
          Task { @MainActor in
            guard self.operationTask != nil, generation == self.sessionGeneration else { return }
            self.show(activity)
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
        self.failureNotifier.backupFinished(BackupRunOutcome(record: record), scheduled: scheduled)
        await self.refreshSnapshots()
      } catch {
        guard generation == self.sessionGeneration else {
          self.finishOperation()
          return
        }
        self.finishOperation()
        if (error as? EngineError) == .missingMasterKey {
          self.hasMasterKey = false
        }
        self.lastError = self.message(for: error)
        self.failureNotifier.backupFinished(BackupRunOutcome(error: error), scheduled: scheduled)
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

  var canBackUpNow: Bool {
    signedIn && !config.folders.isEmpty && activity == nil && operationTask == nil && !isResetting
      && backupDeletionTask == nil
  }

  var canCancelActivity: Bool {
    operationTask != nil && !isCancelling && activity?.isCancellable == true
  }

  func cancelBackup() {
    guard let operationTask, activity?.isCancellable ?? true else { return }
    isCancelling = true
    operationTask.cancel()
  }

  func resetThisMac() async {
    guard !isResetting, backupDeletionTask == nil else { return }
    await resetLocally(signingOut: true)
  }

  func startBackupDeletion() {
    guard backupDeletionTask == nil, !isResetting, let repositoryId = config.repositoryId else { return }
    backupDeletion = .starting
    let telemetryVersion = config.telemetryConsentedAt != nil ? appVersion : nil
    backupDeletionTask = Task {
      await stopRunningWork()
      do {
        let deletion = BackupDeletion(
          api: try await makeAPIClient(),
          openBrowser: { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } },
          telemetryVersion: telemetryVersion)
        let result = try await deletion.run(repositoryId: repositoryId) { step in
          await self.showBackupDeletionStep(step)
        }
        backupDeletionTask = nil
        switch result {
        case .deleted:
          await resetLocally(signingOut: false)
        case .connectionKeepsRepositories(let repositories):
          backupDeletion = .macStillLinked(otherRepositories: repositories, detail: nil)
        }
      } catch {
        backupDeletionTask = nil
        backupDeletion = BackupDeletionState(error: error)
      }
    }
  }

  func cancelBackupDeletion() {
    backupDeletionTask?.cancel()
  }

  func dismissBackupDeletion() {
    guard backupDeletionTask == nil else { return }
    backupDeletion = .idle
  }

  func resetAfterBackupDeletion() async {
    guard backupDeletionTask == nil, !isResetting else { return }
    await resetLocally(signingOut: true)
  }

  private func showBackupDeletionStep(_ step: BackupDeletionStep) {
    guard backupDeletionTask != nil else { return }
    switch step {
    case .confirmingInBrowser(let url): backupDeletion = .confirmingInBrowser(url)
    case .removingThisMac: backupDeletion = .removingThisMac
    }
  }

  private func stopRunningWork() async {
    loginGeneration += 1
    loginTask?.cancel()
    loginTask = nil
    let running = operationTask
    running?.cancel()
    await running?.value
  }

  private func resetLocally(signingOut: Bool) async {
    failureNotifier.invalidate()
    isResetting = true
    await stopRunningWork()
    let token = signingOut ? sessionToken : nil
    let server = token == nil ? nil : try? await discovery.resolve(config.serverURL)
    let api = server.flatMap { server in
      token.map { YuccaClient(apiRoot: server.apiRoot, transport: transport, accessToken: $0) }
    }
    var log: StructuredLog?
    if config.telemetryConsentedAt != nil {
      var data: [String: TelemetryValue] = [:]
      data["repositoryId"] = config.repositoryId.map { .string($0) }
      log = StructuredLog(summary: "Unlink this Mac", data: data, version: appVersion)
    }
    let engine = engine
    let reset = MacReset(
      files: .standard(home: URL(fileURLWithPath: NSHomeDirectory())),
      secrets: KeychainSecretStore(),
      cleanUpDiskSnapshots: { await engine?.cleanUpStaleDiskSnapshots() })
    let failed = await reset.run(signingOut: api, log: log)
    returnToFirstScreen()
    if !failed.isEmpty {
      configLoadFailure =
        "FUTO Backups couldn't remove everything from this Mac: "
        + failed.map(\.title).joined(separator: ", ") + "."
    }
    isResetting = false
  }

  private func returnToFirstScreen() {
    sessionToken = nil
    sessionGeneration += 1
    onboardingGeneration += 1
    loginGeneration += 1
    config = AppConfig.defaults(host: Host.current().localizedName ?? "Mac", home: NSHomeDirectory())
    account = nil
    login = .idle
    activity = nil
    activityProgress.clear()
    operationTask = nil
    isCancelling = false
    snapshots = []
    snapshotsLoad = .notLoaded
    lastError = nil
    setupError = nil
    signedIn = false
    hasSession = false
    hasMasterKey = false
    restoredFolders = []
    recoveryKeyStep = nil
    holdRecoveryKey(nil)
    configLoadFailure = nil
    configNeedsMovingAside = false
    pendingBootstrapError = nil
    backupDeletion = .idle
    UserDefaults.standard.removeObject(forKey: SidebarItem.storageKey)
    recomputeNextRun()
    failureNotifier.endStreak()
  }

  func restore(snapshot: Snapshot, to url: URL) {
    let items = RestorePlan.items(paths: snapshot.paths, into: url)
    startRestore { engine, config, onActivity in
      try await engine.restore(config: config, snapshotId: snapshot.id, items: items, onActivity: onActivity)
    }
  }

  func restore(snapshot: Snapshot, selection: [SnapshotEntry], to url: URL) {
    startRestore { engine, config, onActivity in
      try await engine.restore(
        config: config, snapshotId: snapshot.id, selection: selection, into: url, onActivity: onActivity)
    }
  }

  private func startRestore(
    _ run: @escaping (BackupEngine, AppConfig, @escaping @Sendable (EngineActivity) -> Void) async throws -> [URL]
  ) {
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
    guard !isMissingRecoveryKey else {
      lastError = message(for: EngineError.missingMasterKey)
      return
    }
    guard config.repositoryId != nil else {
      lastError = "No repository yet"
      return
    }
    let configSnapshot = config
    let generation = sessionGeneration
    activity = .restoring
    restoredFolders = []
    operationTask = Task {
      do {
        let restored = try await run(engine, configSnapshot) { activity in
          Task { @MainActor in
            guard self.operationTask != nil, generation == self.sessionGeneration else { return }
            self.show(activity)
          }
        }
        guard generation == self.sessionGeneration else {
          self.finishOperation()
          return
        }
        self.finishOperation()
        self.restoreStoppedEarly = false
        self.restoredFolders = restored
      } catch let incomplete as RestoreIncomplete {
        self.finishOperation()
        guard generation == self.sessionGeneration else { return }
        self.restoreStoppedEarly = true
        self.restoredFolders = incomplete.restored
        self.lastError = self.message(for: incomplete)
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

  var canRestore: Bool {
    activity == nil && operationTask == nil
  }

  func snapshotBrowser(for snapshot: Snapshot) -> SnapshotBrowser {
    let engine = engine
    let config = config
    let missingHelperText = missingHelperText
    return SnapshotBrowser(
      snapshot: snapshot,
      describe: { [weak self] error in
        self?.message(for: error) ?? String(describing: error)
      }
    ) { path in
      guard let engine else { throw SnapshotBrowserUnavailable(message: missingHelperText ?? "Setup incomplete") }
      return try await engine.listDirectory(config: config, snapshotId: snapshot.id, path: path)
    }
  }

  func refreshSnapshots() async {
    guard config.repositoryId != nil else { return }
    guard let engine else {
      snapshotsLoad = .failed(missingHelperText ?? "Setup incomplete")
      return
    }
    let generation = sessionGeneration
    let previousLoad = snapshotsLoad
    snapshotsLoad = .loading
    do {
      let result = try await engine.snapshots(config: config)
      guard generation == sessionGeneration else { return }
      snapshots = result
      snapshotsLoad = .loaded
    } catch is CancellationError {
      guard generation == sessionGeneration else { return }
      snapshotsLoad = previousLoad
    } catch {
      guard generation == sessionGeneration else { return }
      let text = message(for: error)
      snapshotsLoad = .failed(text)
      lastError = text
    }
  }

  func revealRecoveryKey() async -> String? {
    switch await OwnerAuthentication.confirm(reason: "show your recovery key") {
    case .confirmed:
      return await recoveryKey()
    case .declined:
      return nil
    case .unavailable:
      lastError = OwnerAuthentication.unavailableMessage
      return nil
    }
  }

  func recoveryKey() async -> String? {
    guard let engine else { return nil }
    if config.repositoryId != nil {
      return try? await engine.storedMasterKey()
    }
    return try? await engine.masterKey()
  }

  var canChangeRecoveryKey: Bool {
    engine != nil && signedIn && hasMasterKey && config.repositoryId != nil && activity == nil
      && operationTask == nil
  }

  func changeRecoveryKey(to newKey: String) async -> Result<KeyRotationOutcome, RecoveryKeyChangeFailure> {
    guard let engine else { return .failure(RecoveryKeyChangeFailure(missingHelperText ?? "Setup incomplete")) }
    guard canChangeRecoveryKey else { return .failure(RecoveryKeyChangeFailure("Another operation is running")) }
    let configSnapshot = config
    let generation = sessionGeneration
    activity = .changingRecoveryKey
    // Unstructured so Cancel or logout never interrupts a half-applied key change.
    let change = Task { try await engine.changeMasterKey(to: newKey, config: configSnapshot) }
    operationTask = Task { _ = await change.result }
    let result = await change.result
    finishOperation()
    switch result {
    case .success(let outcome):
      if generation == sessionGeneration {
        hasMasterKey = true
        config.recoveryKeyConfirmedAt = Date()
        saveConfig()
      }
      return .success(outcome)
    case .failure(let error):
      return .failure(RecoveryKeyChangeFailure(keyChangeMessage(for: error)))
    }
  }

  private func keyChangeMessage(for error: Error) -> String {
    switch error as? KeyRotationError {
    case .currentKeyNotFound: return "Couldn't find this Mac's current key in the backup."
    case .newKeyRejected: return "The backup didn't accept the new key."
    case .passwordFileFailed: return "Couldn't prepare the new key on this Mac."
    case .pendingRotationUnreadable: return "An earlier key change couldn't be finished."
    case nil: return message(for: error)
    }
  }

  private func finishPendingKeyRotation() async {
    guard let engine, operationTask == nil else { return }
    _ = try? await engine.finishPendingKeyRotation(config: config)
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
    case .weekly(let weekday, let hour, let minute):
      var calendar = Calendar(identifier: .gregorian)
      calendar.locale = Locale(identifier: "en_US")
      let day = Schedule.weekdayName(weekday, calendar: calendar).lowercased()
      return String(format: "weekly %@ %02d:%02d", day, hour, minute)
    }
  }

  private func finishOperation() {
    activity = nil
    activityProgress.clear()
    operationTask = nil
    isCancelling = false
  }

  private func show(_ engineActivity: EngineActivity) {
    let phase = engineActivity.phase
    if activity != phase { activity = phase }
    if let sample = engineActivity.sample {
      activityProgress.receive(sample)
    } else {
      activityProgress.clear()
    }
  }

  private func saveConfig() {
    do {
      if configNeedsMovingAside {
        if let moved = try store.moveAside(at: Date()) {
          configLoadFailure = [configLoadFailure, "The unreadable file was kept as \(moved.lastPathComponent)."]
            .compactMap { $0 }.joined(separator: ". ")
        }
        configNeedsMovingAside = false
      }
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
      case .notLoggedIn: return "Not signed in"
      case .noRepository: return "No repository yet"
      case .noFolders: return "No folders selected"
      case .busy: return "Another operation is running"
      case .missingMasterKey: return "This Mac's recovery key is missing"
      case .restic(_, let message): return message
      }
    }
    if let yuccaError = error as? YuccaError, yuccaError == .unauthorized {
      logout()
      return "Session expired, sign in again"
    }
    if let loginError = error as? DeviceLoginError {
      return loginError.message(server: config.serverDisplayName)
    }
    if let incomplete = error as? RestoreIncomplete {
      return restoreIncompleteMessage(incomplete)
    }
    return String(describing: error)
  }

  private func restoreIncompleteMessage(_ incomplete: RestoreIncomplete) -> String {
    var parts = [incomplete.cause is CancellationError ? "Restore cancelled" : message(for: incomplete.cause)]
    let count = incomplete.restored.count
    if count > 0 {
      parts.append(
        count == 1 ? "1 item was restored before it stopped" : "\(count) items were restored before it stopped")
    }
    if let leftover = incomplete.leftoverStaging {
      parts.append("The temporary folder \(leftover.path) couldn't be removed")
    }
    return parts.joined(separator: ". ")
  }
}

extension AppModel: FailureNotificationHost {
  func updateConfig(_ change: (inout AppConfig) -> Void) {
    change(&config)
    saveConfig()
  }

  func failureNotice(for reason: BackupFailureReason) -> FailureNotice {
    FailureNotice(
      reason: reason, server: config.serverName, retryAt: nextRun, now: Date(), calendar: .current, locale: .current)
  }
}

extension SMAppService {
  fileprivate var loginItemStatus: LoginItemStatus {
    switch status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notFound: .notFound
    case .notRegistered: .notRegistered
    @unknown default: .notRegistered
    }
  }
}
