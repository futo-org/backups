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

    let forget = try await runner.run(ResticCommand.forget(context, host: host, keepWithin: "1h"), onLine: { _ in })
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
}
