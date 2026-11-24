import Foundation
import Testing

@testable import BackupsCore

private let plainContext = ResticContext(
  repository: "rest:http://repo-id:token@127.0.0.1:54321",
  password: "secret",
  cacheDirectory: URL(fileURLWithPath: "/cache"),
  home: "/home/user",
  connections: 3)

private let packedContext = ResticContext(
  repository: "rest:http://repo-id:token@127.0.0.1:54321",
  password: "secret",
  cacheDirectory: URL(fileURLWithPath: "/cache"),
  home: "/home/user",
  connections: 3,
  packSizeMiB: 4,
  walkConcurrency: 2)

private let common = ["--option", "rest.connections=3", "--cache-dir", "/cache"]

private let standardEnvironment = [
  "RESTIC_REPOSITORY": "rest:http://repo-id:token@127.0.0.1:54321",
  "RESTIC_PASSWORD": "secret",
  "HOME": "/home/user",
  "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
]

struct CommandCase: Sendable {
  var name: String
  var invocation: ResticInvocation
  var arguments: [String]
}

private let commandCases: [CommandCase] = [
  CommandCase(
    name: "init",
    invocation: ResticCommand.initialize(plainContext),
    arguments: ["init", "--json"] + common),
  CommandCase(
    name: "unlock",
    invocation: ResticCommand.unlock(plainContext),
    arguments: ["unlock", "--json"] + common),
  CommandCase(
    name: "snapshots",
    invocation: ResticCommand.snapshots(plainContext),
    arguments: ["snapshots", "--json"] + common + ["--no-lock"]),
  CommandCase(
    name: "stats",
    invocation: ResticCommand.stats(plainContext),
    arguments: ["stats", "--json"] + common + ["--mode", "raw-data"]),
  CommandCase(
    name: "cat config",
    invocation: ResticCommand.catConfig(plainContext),
    arguments: ["cat", "config", "--json"] + common),
  CommandCase(
    name: "backup minimal",
    invocation: ResticCommand.backup(plainContext, paths: ["/p/one", "/p/two"], excludes: [], host: "host-a"),
    arguments: ["backup", "--json"] + common
      + ["--host", "host-a", "--group-by", "host", "--exclude-caches", "--", "/p/one", "/p/two"]),
  CommandCase(
    name: "backup full",
    invocation: ResticCommand.backup(
      packedContext,
      paths: ["/p/one"],
      excludes: ["/p/skip-a", "/p/skip-b"],
      host: "host-a"),
    arguments: ["backup", "--json"] + common
      + [
        "--host", "host-a", "--group-by", "host", "--exclude-caches", "--exclude", "/p/skip-a",
        "--exclude", "/p/skip-b", "--pack-size", "4", "--walk-concurrency", "2", "--", "/p/one",
      ]),
  CommandCase(
    name: "forget without pack size",
    invocation: ResticCommand.forget(plainContext, host: "host-a", keepWithin: "1h"),
    arguments: ["forget", "--json"] + common
      + ["--host", "host-a", "--group-by", "host", "--keep-within", "1h", "--prune"]),
  CommandCase(
    name: "forget with pack size",
    invocation: ResticCommand.forget(packedContext, host: "host-a", keepWithin: "30d"),
    arguments: ["forget", "--json"] + common
      + ["--host", "host-a", "--group-by", "host", "--keep-within", "30d", "--prune", "--pack-size", "4"]),
  CommandCase(
    name: "restore whole snapshot",
    invocation: ResticCommand.restore(plainContext, snapshotId: "abc123", target: "/target"),
    arguments: ["restore", "--json"] + common + ["--target", "/target", "--overwrite", "never", "--", "abc123"]),
  CommandCase(
    name: "restore subfolder",
    invocation: ResticCommand.restore(
      plainContext, snapshotId: "abc123", subfolder: "/Users/x/My Docs", target: "/target/My Docs"),
    arguments: ["restore", "--json"] + common + [
      "--target", "/target/My Docs", "--overwrite", "never", "--", "abc123:/Users/x/My Docs",
    ]),
]

@Test(arguments: commandCases)
func argumentsMatch(_ testCase: CommandCase) {
  #expect(testCase.invocation.arguments == testCase.arguments, "\(testCase.name)")
}

@Test(arguments: commandCases)
func environmentIsReplacedWithExactlyFourVariables(_ testCase: CommandCase) {
  #expect(testCase.invocation.environment == standardEnvironment, "\(testCase.name)")
}

@Test func versionInvocation() {
  let invocation = ResticCommand.version(home: "/version-home")
  #expect(invocation.arguments == ["version", "--json"])
  #expect(invocation.environment == ["HOME": "/version-home", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
}

@Test func backupGroupsByHostAfterHostAndCarriesCurrentDirectory() {
  let minimal = ResticCommand.backup(plainContext, paths: ["/p"], excludes: [], host: "host-a")
  #expect(minimal.currentDirectory == nil)
  guard let hostIndex = minimal.arguments.firstIndex(of: "--host") else {
    Issue.record("missing --host in \(minimal.arguments)")
    return
  }
  #expect(
    Array(minimal.arguments[hostIndex...].prefix(5))
      == ["--host", "host-a", "--group-by", "host", "--exclude-caches"])
  let mounted = ResticCommand.backup(
    plainContext, paths: ["/p"], excludes: [], host: "host-a", currentDirectory: "/mnt")
  #expect(mounted.currentDirectory == "/mnt")
  #expect(mounted.arguments == minimal.arguments)
}

@Test func backupTagsFollowExcludeCachesAndDefaultToNone() {
  let plain = ResticCommand.backup(plainContext, paths: ["/p"], excludes: [], host: "host-a")
  #expect(!plain.arguments.contains("--tag"))
  let tagged = ResticCommand.backup(
    plainContext, paths: ["/p"], excludes: ["/skip"], host: "host-a",
    tags: ["disk-snapshot", "beta"])
  guard let cachesIndex = tagged.arguments.firstIndex(of: "--exclude-caches") else {
    Issue.record("missing --exclude-caches in \(tagged.arguments)")
    return
  }
  #expect(
    Array(tagged.arguments[cachesIndex...].prefix(7))
      == ["--exclude-caches", "--tag", "disk-snapshot", "--tag", "beta", "--exclude", "/skip"])
}

@Test func positionalsThatLookLikeFlagsFollowEndOfOptions() {
  let backup = ResticCommand.backup(plainContext, paths: ["--dry-run", "-x"], excludes: [], host: "host-a")
  #expect(Array(backup.arguments.suffix(3)) == ["--", "--dry-run", "-x"])
  let restore = ResticCommand.restore(
    plainContext, snapshotId: "abc123", subfolder: "--verify", target: "/target")
  #expect(Array(restore.arguments.suffix(2)) == ["--", "abc123:--verify"])
  #expect(!ResticCommand.snapshots(plainContext).arguments.contains("--"))
}

@Test func forgetGroupsByHostNotPaths() {
  let arguments = ResticCommand.forget(plainContext, host: "host-a", keepWithin: "60d").arguments
  #expect(argumentAfter(arguments, "--group-by") == "host")
  #expect(!arguments.contains("paths"))
}
