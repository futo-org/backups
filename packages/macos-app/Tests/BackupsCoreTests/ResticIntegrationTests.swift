import Darwin
import Foundation
import Testing

@testable import BackupsCore

private let resticExecutable: URL? = {
  guard let path = ProcessInfo.processInfo.environment["FUTO_BACKUPS_RESTIC"],
    FileManager.default.isExecutableFile(atPath: path)
  else { return nil }
  return URL(fileURLWithPath: path)
}()

private func realPath(of path: String) -> String {
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
}

private struct ForgetGroup: Decodable {
  struct Snapshot: Decodable {
    var tags: [String]
  }

  var keep: [Snapshot]
  var remove: [Snapshot]?
}

private func fileNameSet(in directory: URL) throws -> Set<String> {
  let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
  var names = Set<String>()
  while let url = walker?.nextObject() as? URL {
    let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
    if isFile {
      names.insert(url.lastPathComponent)
    }
  }
  return names
}

private final class SummaryCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var value: BackupSummary?

  func set(_ summary: BackupSummary) {
    lock.lock()
    value = summary
    lock.unlock()
  }

  func get() -> BackupSummary? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private struct LocalRepositoryRunner: ResticExecuting {
  let runner: ResticRunner
  let repository: String

  func run(_ invocation: ResticInvocation, onLine: @escaping @Sendable (String) -> Void) async throws
    -> ResticResult
  {
    var local = invocation
    if local.environment["RESTIC_REPOSITORY"] != nil {
      local.environment["RESTIC_REPOSITORY"] = repository
    }
    return try await runner.run(local, onLine: onLine)
  }
}

private struct KeyRotationWorkspace {
  let root: URL
  let repository: String
  let scratch: URL
  let context: ResticContext
  let runner: ResticRunner

  init(executable: URL, password: String) throws {
    let fileManager = FileManager.default
    root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    repository = root.appendingPathComponent("repository").path
    scratch = root.appendingPathComponent("scratch")
    for name in ["cache", "home", "scratch", "source"] {
      try fileManager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try Data("keep me".utf8).write(to: root.appendingPathComponent("source/a.txt"))
    context = ResticContext(
      repository: repository, password: password, cacheDirectory: root.appendingPathComponent("cache"),
      home: root.appendingPathComponent("home").path, connections: 2)
    runner = ResticRunner(executable: executable)
  }

  func engine(secrets: any SecretStore) -> BackupEngine {
    let api = FakeAPI()
    return BackupEngine(
      environment: EngineEnvironment(
        secrets: secrets,
        discover: { _ in ServerInfo(apiRoot: testAPIRoot, resticPackSizeMiB: 16, connectionsMath: "2") },
        makeAPI: { _, _ in api },
        restic: LocalRepositoryRunner(runner: runner, repository: repository),
        proxyLauncher: FakeProxyLauncher(),
        cacheDirectory: context.cacheDirectory,
        home: context.home,
        processorCount: 2,
        now: { Date() },
        temporaryDirectory: scratch))
  }

  func exitCode(_ command: (ResticContext) -> ResticInvocation, password: String) async throws -> Int32 {
    var withPassword = context
    withPassword.password = password
    return try await runner.run(command(withPassword), onLine: { _ in }).exitCode
  }
}

@Suite(.enabled(if: resticExecutable != nil, "set FUTO_BACKUPS_RESTIC to an executable to run"))
struct ResticIntegrationTests {
  @Test func fullRepositoryLifecycle() async throws {
    let executable = try #require(resticExecutable)
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let cacheDirectory = tempRoot.appendingPathComponent("cache")
    let homeDirectory = tempRoot.appendingPathComponent("home")
    let sourceDirectory = tempRoot.appendingPathComponent("source")
    let restoreDirectory = tempRoot.appendingPathComponent("restore")
    try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: restoreDirectory, withIntermediateDirectories: true)
    for name in ["a.txt", "b.txt", "c.txt"] {
      try Data(UUID().uuidString.utf8).write(to: sourceDirectory.appendingPathComponent(name))
    }
    let excluded = sourceDirectory.appendingPathComponent("secret.txt")
    try Data("do not back up".utf8).write(to: excluded)

    let context = ResticContext(
      repository: tempRoot.appendingPathComponent("repository").path,
      password: "pw-\(UUID().uuidString)",
      cacheDirectory: cacheDirectory,
      home: homeDirectory.path,
      connections: 2)
    let runner = ResticRunner(executable: executable)
    let host = "integration-host"

    let initialized = try await runner.run(ResticCommand.initialize(context), onLine: { _ in })
    #expect(initialized.exitCode == ResticExitCode.success)

    let summaries = SummaryCollector()
    let backup = try await runner.run(
      ResticCommand.backup(context, paths: [sourceDirectory.path], excludes: [excluded.path], host: host)
    ) { line in
      if case .summary(let summary) = ResticOutput.parseLine(line) {
        summaries.set(summary)
      }
    }
    #expect(backup.exitCode == ResticExitCode.success)
    let snapshotId = try #require(summaries.get()?.snapshotId)

    let snapshotsResult = try await runner.run(ResticCommand.snapshots(context), onLine: { _ in })
    #expect(snapshotsResult.exitCode == ResticExitCode.success)
    let snapshots = try ResticOutput.parseSnapshots(snapshotsResult.stdout)
    try #require(snapshots.count == 1)
    #expect(snapshots[0].paths == [sourceDirectory.path])

    let statsResult = try await runner.run(ResticCommand.stats(context), onLine: { _ in })
    #expect(statsResult.exitCode == ResticExitCode.success)
    #expect(try ResticOutput.parseStatsTotalSize(statsResult.stdout) > 0)

    let item = try #require(RestorePlan.items(paths: snapshots[0].paths, into: restoreDirectory).first)
    let target = try RestorePlan.claimTarget(
      for: item, avoiding: [], createDirectory: RestorePlan.createDirectoryExclusively)
    #expect(target.path == restoreDirectory.appendingPathComponent("source").path)
    let restore = try await runner.run(
      ResticCommand.restore(context, snapshotId: snapshotId, subfolder: item.snapshotPath, target: target.path),
      onLine: { _ in })
    #expect(restore.exitCode == ResticExitCode.success)
    let restored = try fileManager.contentsOfDirectory(atPath: target.path)
    #expect(Set(restored) == ["a.txt", "b.txt", "c.txt"])
    for name in ["a.txt", "b.txt", "c.txt"] {
      #expect(
        try Data(contentsOf: target.appendingPathComponent(name))
          == Data(contentsOf: sourceDirectory.appendingPathComponent(name)), "\(name)")
    }

    let edited = target.appendingPathComponent("a.txt")
    try Data("edited after restore".utf8).write(to: edited)
    let repeated = try await runner.run(
      ResticCommand.restore(context, snapshotId: snapshotId, subfolder: item.snapshotPath, target: target.path),
      onLine: { _ in })
    #expect(repeated.exitCode == ResticExitCode.success)
    #expect(try Data(contentsOf: edited) == Data("edited after restore".utf8))
    #expect(
      try RestorePlan.claimTarget(for: item, avoiding: [], createDirectory: RestorePlan.createDirectoryExclusively)
        .path == restoreDirectory.appendingPathComponent("source 2").path)

    try Data("more".utf8).write(
      to: sourceDirectory.appendingPathComponent("d.txt"))
    let secondBackup = try await runner.run(
      ResticCommand.backup(context, paths: [sourceDirectory.path], excludes: [excluded.path], host: host),
      onLine: { _ in })
    #expect(secondBackup.exitCode == ResticExitCode.success)

    let forgetInvocation = try #require(
      ResticCommand.forget(context, host: host, retention: .policy(RetentionPolicy(keepWithin: "1h"))))
    let forget = try await runner.run(forgetInvocation, onLine: { _ in })
    #expect(forget.exitCode == ResticExitCode.success)

    let versionResult = try await runner.run(ResticCommand.version(home: homeDirectory.path), onLine: { _ in })
    #expect(versionResult.exitCode == ResticExitCode.success)
    #expect(try ResticOutput.parseVersion(versionResult.stdout).contains("+futo."))
  }

  @Test func backupRunsFromCurrentDirectoryAndStoresTreeAsAbsolute() async throws {
    let executable = try #require(resticExecutable)
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let resolvedRoot = URL(fileURLWithPath: realPath(of: tempRoot.path))
    defer { try? fileManager.removeItem(at: resolvedRoot) }
    let cacheDirectory = resolvedRoot.appendingPathComponent("cache")
    let homeDirectory = resolvedRoot.appendingPathComponent("home")
    let mount = resolvedRoot.appendingPathComponent("mount")
    let docs = mount.appendingPathComponent("Users/x/Docs")
    let caches = docs.appendingPathComponent("Caches")
    let restoreDirectory = resolvedRoot.appendingPathComponent("restore")
    try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: caches, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: restoreDirectory, withIntermediateDirectories: true)
    let original = Data(UUID().uuidString.utf8)
    try original.write(to: docs.appendingPathComponent("a.txt"))
    try Data("do not back up".utf8).write(to: caches.appendingPathComponent("c.txt"))

    let context = ResticContext(
      repository: resolvedRoot.appendingPathComponent("repository").path,
      password: "pw-\(UUID().uuidString)",
      cacheDirectory: cacheDirectory,
      home: homeDirectory.path,
      connections: 2)
    let runner = ResticRunner(executable: executable)

    let initialized = try await runner.run(ResticCommand.initialize(context), onLine: { _ in })
    #expect(initialized.exitCode == ResticExitCode.success)

    let summaries = SummaryCollector()
    let backup = try await runner.run(
      ResticCommand.backup(
        context,
        paths: ["Users/x/Docs"],
        excludes: [caches.path],
        host: "h",
        currentDirectory: mount.path)
    ) { line in
      if case .summary(let summary) = ResticOutput.parseLine(line) {
        summaries.set(summary)
      }
    }
    #expect(backup.exitCode == ResticExitCode.success)
    let snapshotId = try #require(summaries.get()?.snapshotId)

    let restore = try await runner.run(
      ResticCommand.restore(
        context, snapshotId: snapshotId, subfolder: "/Users/x/Docs",
        target: restoreDirectory.appendingPathComponent("Docs").path),
      onLine: { _ in })
    #expect(restore.exitCode == ResticExitCode.success)
    let restoredDocs = restoreDirectory.appendingPathComponent("Docs")
    #expect(try Data(contentsOf: restoredDocs.appendingPathComponent("a.txt")) == original)
    #expect(try fileNameSet(in: restoreDirectory) == ["a.txt"])

    let snapshotsResult = try await runner.run(ResticCommand.snapshots(context), onLine: { _ in })
    #expect(snapshotsResult.exitCode == ResticExitCode.success)
    let snapshots = try ResticOutput.parseSnapshots(snapshotsResult.stdout)
    try #require(snapshots.count == 1)
    #expect(snapshots[0].paths == [realPath(of: mount.path) + "/Users/x/Docs"])
  }

  @Test func browsingAndRestoringPickedItemsPutsEachDirectlyInTheDestination() async throws {
    let executable = try #require(resticExecutable)
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let resolvedRoot = URL(fileURLWithPath: realPath(of: tempRoot.path))
    defer { try? fileManager.removeItem(at: resolvedRoot) }
    let snapshotDirectory = resolvedRoot.appendingPathComponent("Snapshot")
    let mount = snapshotDirectory.appendingPathComponent("Volume")
    let docs = mount.appendingPathComponent("Users/x/Docs")
    let project = docs.appendingPathComponent("Projects/Site")
    let destination = resolvedRoot.appendingPathComponent("destination")
    for directory in [
      resolvedRoot.appendingPathComponent("cache"), project.appendingPathComponent("assets"), destination,
    ] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let notes = Data("nested notes".utf8)
    try notes.write(to: docs.appendingPathComponent("Projects/notes[1].txt"))
    try Data("sibling".utf8).write(to: docs.appendingPathComponent("Projects/notes1.txt"))
    try Data("index".utf8).write(to: project.appendingPathComponent("index.html"))
    try Data("logo".utf8).write(to: project.appendingPathComponent("assets/logo.svg"))
    try Data("top".utf8).write(to: docs.appendingPathComponent("top.txt"))
    try Data("already here".utf8).write(to: destination.appendingPathComponent("notes[1].txt"))

    let repository = resolvedRoot.appendingPathComponent("repository").path
    let context = ResticContext(
      repository: repository,
      password: try RepositoryKeys.password(masterKey: testMasterKey, repositoryId: "repo-1"),
      cacheDirectory: resolvedRoot.appendingPathComponent("cache"), home: resolvedRoot.path, connections: 2)
    let runner = ResticRunner(executable: executable)
    #expect(try await runner.run(ResticCommand.initialize(context), onLine: { _ in }).exitCode == 0)
    let summaries = SummaryCollector()
    let backup = try await runner.run(
      ResticCommand.backup(
        context, paths: ["Users/x/Docs"], excludes: [], host: "h", currentDirectory: mount.path,
        tags: ["disk-snapshot"])
    ) { line in
      if case .summary(let summary) = ResticOutput.parseLine(line) {
        summaries.set(summary)
      }
    }
    #expect(backup.exitCode == ResticExitCode.success)
    let snapshotId = try #require(summaries.get()?.snapshotId)

    let secrets = InMemorySecretStore([.accessToken: "tok", .masterKey: testMasterKey])
    let config = testConfig(folders: ["/Users/x/Docs"])
    let engine = BackupEngine(
      environment: EngineEnvironment(
        secrets: secrets,
        discover: { _ in ServerInfo(apiRoot: testAPIRoot, resticPackSizeMiB: 16, connectionsMath: "2") },
        makeAPI: { _, _ in FakeAPI() },
        restic: LocalRepositoryRunner(runner: runner, repository: repository),
        proxyLauncher: FakeProxyLauncher(),
        cacheDirectory: context.cacheDirectory,
        home: context.home,
        processorCount: 2,
        now: { Date() },
        snapshotDirectory: snapshotDirectory))

    let snapshots = try await engine.snapshots(config: config)
    let roots = SnapshotListing.roots(of: try #require(snapshots.first).paths)
    #expect(roots == [SnapshotEntry(name: "Docs", path: "/Users/x/Docs", kind: .directory)])
    let top = try await engine.listDirectory(config: config, snapshotId: snapshotId, path: roots[0].path)
    #expect(top.map(\.name) == ["Projects", "top.txt"])
    let projects = try await engine.listDirectory(config: config, snapshotId: snapshotId, path: top[0].path)
    #expect(projects.map(\.name) == ["Site", "notes[1].txt", "notes1.txt"])
    #expect(projects.map(\.path) == ["Site", "notes[1].txt", "notes1.txt"].map { "/Users/x/Docs/Projects/" + $0 })
    #expect(projects.map(\.kind) == [.directory, .file, .file])
    #expect(projects[1].size == Int64(notes.count))

    let picked = [projects[1], projects[0]]
    let restored = try await engine.restore(
      config: config, snapshotId: snapshotId, selection: picked, into: destination
    ) { _ in }
    #expect(restored.map(\.lastPathComponent) == ["notes[1] 2.txt", "Site"])
    #expect(
      Set(try fileManager.contentsOfDirectory(atPath: destination.path))
        == ["notes[1].txt", "notes[1] 2.txt", "Site"])
    #expect(try Data(contentsOf: destination.appendingPathComponent("notes[1] 2.txt")) == notes)
    #expect(try Data(contentsOf: destination.appendingPathComponent("notes[1].txt")) == Data("already here".utf8))
    #expect(try fileNameSet(in: destination.appendingPathComponent("Site")) == ["index.html", "logo.svg"])
    #expect(
      try Data(contentsOf: destination.appendingPathComponent("Site/assets/logo.svg")) == Data("logo".utf8))
  }

  @Test func unreadableFilesAreReportedOnStderrAndStdoutIsNotRetained() async throws {
    let executable = try #require(resticExecutable)
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sourceDirectory = tempRoot.appendingPathComponent("source")
    let unreadable = sourceDirectory.appendingPathComponent("locked.txt")
    defer {
      chmod(unreadable.path, 0o600)
      try? fileManager.removeItem(at: tempRoot)
    }
    try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try Data("readable".utf8).write(to: sourceDirectory.appendingPathComponent("open.txt"))
    try Data("secret".utf8).write(to: unreadable)
    chmod(unreadable.path, 0)
    let context = ResticContext(
      repository: tempRoot.appendingPathComponent("repository").path,
      password: "pw-\(UUID().uuidString)",
      cacheDirectory: tempRoot.appendingPathComponent("cache"),
      home: tempRoot.path,
      connections: 2)
    let runner = ResticRunner(executable: executable)
    #expect(try await runner.run(ResticCommand.initialize(context), onLine: { _ in }).exitCode == 0)

    let stdoutErrors = Counter()
    let backup = try await runner.run(
      ResticCommand.backup(context, paths: [sourceDirectory.path], excludes: [], host: "h")
    ) { line in
      if case .error = ResticOutput.parseLine(line) {
        stdoutErrors.increment()
      }
    }
    #expect(backup.exitCode == ResticExitCode.couldNotReadSource)
    #expect(backup.stdout.isEmpty)
    #expect(stdoutErrors.value == 0)
    let message = try #require(ResticOutput.lastItemError(stderr: backup.stderr))
    #expect(message.hasPrefix(unreadable.path + ": "))
    #expect(message.contains("permission denied"))
  }

  @Test func catConfigVerifiesRepositoryPassword() async throws {
    let executable = try #require(resticExecutable)
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let cacheDirectory = tempRoot.appendingPathComponent("cache")
    let homeDirectory = tempRoot.appendingPathComponent("home")
    try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    let repositoryId = "repo-1"
    let keyA = RepositoryKeys.generateMasterKey()
    let keyB = RepositoryKeys.generateMasterKey()
    let context = ResticContext(
      repository: tempRoot.appendingPathComponent("repository").path,
      password: try RepositoryKeys.password(masterKey: keyA, repositoryId: repositoryId),
      cacheDirectory: cacheDirectory,
      home: homeDirectory.path,
      connections: 2)
    let runner = ResticRunner(executable: executable)

    let initialized = try await runner.run(ResticCommand.initialize(context), onLine: { _ in })
    #expect(initialized.exitCode == ResticExitCode.success)

    let withKeyA = try await runner.run(ResticCommand.catConfig(context), onLine: { _ in })
    #expect(withKeyA.exitCode == ResticExitCode.success)

    var wrongContext = context
    wrongContext.password = try RepositoryKeys.password(masterKey: keyB, repositoryId: repositoryId)
    let withKeyB = try await runner.run(ResticCommand.catConfig(wrongContext), onLine: { _ in })
    #expect(withKeyB.exitCode == ResticExitCode.wrongPassword)
  }

  @Test func customRetentionFlagsAreAcceptedByRestic() async throws {
    let executable = try #require(resticExecutable)
    let workspace = try KeyRotationWorkspace(executable: executable, password: "pw-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: workspace.root) }
    let context = workspace.context
    let runner = workspace.runner
    #expect(
      try await runner.run(ResticCommand.initialize(context), onLine: { _ in }).exitCode == ResticExitCode.success)
    for _ in 0..<2 {
      let backup = try await runner.run(
        ResticCommand.backup(
          context, paths: [workspace.root.appendingPathComponent("source").path], excludes: [], host: "h"),
        onLine: { _ in })
      #expect(backup.exitCode == ResticExitCode.success)
    }
    let policy = RetentionPolicy(
      keepLast: 1, keepWithin: "1y6m", keepWithinHourly: "2d", keepWithinDaily: "1m", keepWithinWeekly: "6m",
      keepWithinMonthly: "2y", keepWithinYearly: "10y")
    var dryRun = try #require(ResticCommand.forget(context, host: "h", retention: .policy(policy)))
    dryRun.arguments.append("--dry-run")
    let forget = try await runner.run(dryRun, onLine: { _ in })
    #expect(forget.exitCode == ResticExitCode.success, "\(forget.stderr)")

    var withoutRules = try #require(ResticCommand.forget(context, host: "h", retention: .standard))
    withoutRules.arguments.removeAll { $0 == "--keep-within" || $0 == "60d" }
    let refused = try await runner.run(withoutRules, onLine: { _ in })
    #expect(refused.exitCode != ResticExitCode.success)

    let snapshots = try await runner.run(ResticCommand.snapshots(context), onLine: { _ in })
    #expect(try ResticOutput.parseSnapshots(snapshots.stdout).count == 2)
  }

  @Test func customRetentionKeepsWhatEachRuleMatches() async throws {
    let executable = try #require(resticExecutable)
    let workspace = try KeyRotationWorkspace(executable: executable, password: "pw-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: workspace.root) }
    let context = workspace.context
    let runner = workspace.runner
    #expect(
      try await runner.run(ResticCommand.initialize(context), onLine: { _ in }).exitCode == ResticExitCode.success)
    let snapshotTimes = [
      "ancient": "2024-01-10 12:00:00",
      "may-early": "2026-05-10 12:00:00",
      "may-last": "2026-05-20 12:00:00",
      "june-early": "2026-06-01 12:00:00",
      "recent": "2026-06-13 12:00:00",
      "latest": "2026-06-15 12:00:00",
    ]
    for (tag, time) in snapshotTimes {
      var backup = ResticCommand.backup(
        context, paths: [workspace.root.appendingPathComponent("source").path], excludes: [], host: "h", tags: [tag])
      let separator = try #require(backup.arguments.firstIndex(of: "--"))
      backup.arguments.insert(contentsOf: ["--time", time], at: separator)
      #expect(try await runner.run(backup, onLine: { _ in }).exitCode == ResticExitCode.success)
    }
    let policy = RetentionPolicy(keepLast: 1, keepWithin: "3d", keepWithinMonthly: "1y")
    var dryRun = try #require(ResticCommand.forget(context, host: "h", retention: .policy(policy)))
    dryRun.arguments.append("--dry-run")
    let forget = try await runner.run(dryRun, onLine: { _ in })
    #expect(forget.exitCode == ResticExitCode.success, "\(forget.stderr)")
    let groupsLine = try #require(forget.stdout.split(separator: UInt8(ascii: "\n")).first)
    let groups = try JSONDecoder().decode([ForgetGroup].self, from: Data(groupsLine))
    let group = try #require(groups.first)
    #expect(groups.count == 1)
    #expect(Set(group.keep.flatMap(\.tags)) == ["latest", "recent", "may-last"])
    #expect(Set((group.remove ?? []).flatMap(\.tags)) == ["june-early", "may-early", "ancient"])
  }

  @Test func changeMasterKeyRotatesTheRepositoryPassword() async throws {
    let executable = try #require(resticExecutable)
    let repositoryId = "repo-1"
    let oldKey = RepositoryKeys.generateMasterKey()
    let newKey = RepositoryKeys.generateMasterKey()
    let oldPassword = try RepositoryKeys.password(masterKey: oldKey, repositoryId: repositoryId)
    let newPassword = try RepositoryKeys.password(masterKey: newKey, repositoryId: repositoryId)
    let workspace = try KeyRotationWorkspace(executable: executable, password: oldPassword)
    defer { try? FileManager.default.removeItem(at: workspace.root) }
    #expect(try await workspace.exitCode(ResticCommand.initialize, password: oldPassword) == ResticExitCode.success)
    let backup = try await workspace.runner.run(
      ResticCommand.backup(
        workspace.context, paths: [workspace.root.appendingPathComponent("source").path], excludes: [], host: "h"),
      onLine: { _ in })
    #expect(backup.exitCode == ResticExitCode.success)
    let secrets = InMemorySecretStore([.accessToken: "tok", .masterKey: oldKey])

    let outcome = try await workspace.engine(secrets: secrets).changeMasterKey(
      to: newKey, config: testConfig(repositoryId: repositoryId))

    #expect(outcome == .complete)
    #expect(try secrets.get(.masterKey) == newKey)
    #expect(try secrets.get(.pendingKeyRotation) == nil)
    #expect(
      try await workspace.exitCode(ResticCommand.catConfig, password: oldPassword) == ResticExitCode.wrongPassword)
    #expect(try await workspace.exitCode(ResticCommand.catConfig, password: newPassword) == ResticExitCode.success)
    var newContext = workspace.context
    newContext.password = newPassword
    let keys = try ResticOutput.parseKeys(
      try await workspace.runner.run(ResticCommand.keyList(newContext), onLine: { _ in }).stdout)
    #expect(keys.count == 1)
    #expect(keys.first?.current == true)
    let snapshots = try await workspace.runner.run(ResticCommand.snapshots(newContext), onLine: { _ in })
    #expect(try ResticOutput.parseSnapshots(snapshots.stdout).count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.scratch.path).isEmpty)
  }

  @Test func finishPendingKeyRotationRemovesTheOldKeyAfterACrash() async throws {
    let executable = try #require(resticExecutable)
    let repositoryId = "repo-1"
    let oldKey = RepositoryKeys.generateMasterKey()
    let newKey = RepositoryKeys.generateMasterKey()
    let oldPassword = try RepositoryKeys.password(masterKey: oldKey, repositoryId: repositoryId)
    let newPassword = try RepositoryKeys.password(masterKey: newKey, repositoryId: repositoryId)
    let workspace = try KeyRotationWorkspace(executable: executable, password: oldPassword)
    defer { try? FileManager.default.removeItem(at: workspace.root) }
    #expect(try await workspace.exitCode(ResticCommand.initialize, password: oldPassword) == ResticExitCode.success)
    let listed = try await workspace.runner.run(ResticCommand.keyList(workspace.context), onLine: { _ in })
    let oldKeyId = try #require(try ResticOutput.parseKeys(listed.stdout).first(where: \.current)?.id)
    let passwordFile = workspace.root.appendingPathComponent("new-password")
    try Data(newPassword.utf8).write(to: passwordFile)
    let added = try await workspace.runner.run(
      ResticCommand.keyAdd(workspace.context, newPasswordFile: passwordFile.path), onLine: { _ in })
    #expect(added.exitCode == ResticExitCode.success)
    let pending = PendingKeyRotation(
      repositoryId: repositoryId, oldKeyId: oldKeyId, previousMasterKey: oldKey, newMasterKey: newKey)
    let secrets = InMemorySecretStore([
      .accessToken: "tok", .masterKey: oldKey,
      .pendingKeyRotation: String(decoding: try JSONEncoder().encode(pending), as: UTF8.self),
    ])

    let finished = try await workspace.engine(secrets: secrets).finishPendingKeyRotation(
      config: testConfig(repositoryId: repositoryId))

    #expect(finished)
    #expect(try secrets.get(.masterKey) == newKey)
    #expect(try secrets.get(.pendingKeyRotation) == nil)
    #expect(
      try await workspace.exitCode(ResticCommand.catConfig, password: oldPassword) == ResticExitCode.wrongPassword)
    #expect(try await workspace.exitCode(ResticCommand.catConfig, password: newPassword) == ResticExitCode.success)
  }
}
