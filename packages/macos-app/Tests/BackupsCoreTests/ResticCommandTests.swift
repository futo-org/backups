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

private let backupEnvironment = standardEnvironment.merging(["RESTIC_PROGRESS_FPS": "2"]) { $1 }

struct CommandCase: Sendable {
  var name: String
  var invocation: ResticInvocation
  var arguments: [String]
  var environment = standardEnvironment
  var retainsStdout = true
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
    name: "key list",
    invocation: ResticCommand.keyList(plainContext),
    arguments: ["key", "list", "--json"] + common),
  CommandCase(
    name: "key add",
    invocation: ResticCommand.keyAdd(plainContext, newPasswordFile: "/private/tmp/k/password"),
    arguments: ["key", "add", "--json"] + common + ["--new-password-file", "/private/tmp/k/password"]),
  CommandCase(
    name: "key remove",
    invocation: ResticCommand.keyRemove(plainContext, id: "-abc123"),
    arguments: ["key", "remove", "--json"] + common + ["--", "-abc123"]),
  CommandCase(
    name: "backup minimal",
    invocation: ResticCommand.backup(plainContext, paths: ["/p/one", "/p/two"], excludes: [], host: "host-a"),
    arguments: ["backup", "--json"] + common
      + [
        "--host", "host-a", "--group-by", "host", "--exclude-caches", "--exclude-cloud-files", "--", "/p/one",
        "/p/two",
      ],
    environment: backupEnvironment, retainsStdout: false),
  CommandCase(
    name: "backup full",
    invocation: ResticCommand.backup(
      packedContext,
      paths: ["/p/one"],
      excludes: ["/p/skip-a", "/p/skip-b"],
      host: "host-a"),
    arguments: ["backup", "--json"] + common
      + [
        "--host", "host-a", "--group-by", "host", "--exclude-caches", "--exclude-cloud-files", "--exclude",
        "/p/skip-a", "--exclude", "/p/skip-b", "--pack-size", "4", "--walk-concurrency", "2", "--", "/p/one",
      ],
    environment: backupEnvironment, retainsStdout: false),
  CommandCase(
    name: "forget without pack size",
    invocation: ResticCommand.forget(
      plainContext, host: "host-a", retention: .policy(RetentionPolicy(keepWithin: "1h")))!,
    arguments: ["forget", "--json"] + common
      + ["--host", "host-a", "--group-by", "host", "--keep-within", "1h", "--prune"]),
  CommandCase(
    name: "forget with pack size",
    invocation: ResticCommand.forget(
      packedContext, host: "host-a", retention: .policy(RetentionPolicy(keepWithin: "30d")))!,
    arguments: ["forget", "--json"] + common
      + ["--host", "host-a", "--group-by", "host", "--keep-within", "30d", "--prune", "--pack-size", "4"]),
  CommandCase(
    name: "restore whole snapshot",
    invocation: ResticCommand.restore(plainContext, snapshotId: "abc123", target: "/target"),
    arguments: ["restore", "--json"] + common + ["--target", "/target", "--overwrite", "never", "--", "abc123"],
    retainsStdout: false),
  CommandCase(
    name: "restore subfolder",
    invocation: ResticCommand.restore(
      plainContext, snapshotId: "abc123", subfolder: "/Users/x/My Docs", target: "/target/My Docs"),
    arguments: ["restore", "--json"] + common + [
      "--target", "/target/My Docs", "--overwrite", "never", "--", "abc123:/Users/x/My Docs",
    ],
    retainsStdout: false),
]

@Test(arguments: commandCases)
func argumentsMatch(_ testCase: CommandCase) {
  #expect(testCase.invocation.arguments == testCase.arguments, "\(testCase.name)")
}

@Test(arguments: commandCases)
func environmentIsReplacedWithExactlyTheExpectedVariables(_ testCase: CommandCase) {
  #expect(testCase.invocation.environment == testCase.environment, "\(testCase.name)")
}

@Test(arguments: commandCases)
func onlyCommandsWhoseOutputIsReadRetainStdout(_ testCase: CommandCase) {
  #expect(testCase.invocation.retainsStdout == testCase.retainsStdout, "\(testCase.name)")
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

@Test func backupTagsFollowTheExcludeFlagsAndDefaultToNone() {
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
    Array(tagged.arguments[cachesIndex...].prefix(8))
      == [
        "--exclude-caches", "--exclude-cloud-files", "--tag", "disk-snapshot", "--tag", "beta", "--exclude", "/skip",
      ])
}

@Test func positionalsThatLookLikeFlagsFollowEndOfOptions() {
  let backup = ResticCommand.backup(plainContext, paths: ["--dry-run", "-x"], excludes: [], host: "host-a")
  #expect(Array(backup.arguments.suffix(3)) == ["--", "--dry-run", "-x"])
  let restore = ResticCommand.restore(
    plainContext, snapshotId: "abc123", subfolder: "--verify", target: "/target")
  #expect(Array(restore.arguments.suffix(2)) == ["--", "abc123:--verify"])
  #expect(!ResticCommand.snapshots(plainContext).arguments.contains("--"))
}

@Test func forgetGroupsByHostNotPaths() throws {
  let arguments = try #require(ResticCommand.forget(plainContext, host: "host-a", retention: .standard)).arguments
  #expect(argumentAfter(arguments, "--group-by") == "host")
  #expect(!arguments.contains("paths"))
}

@Test func keyCommandsKeepPasswordsOutOfArguments() {
  let invocations = [
    ResticCommand.keyList(plainContext),
    ResticCommand.keyAdd(plainContext, newPasswordFile: "/private/tmp/k/password"),
    ResticCommand.keyRemove(plainContext, id: "abc123"),
  ]
  for invocation in invocations {
    #expect(!invocation.arguments.contains { $0.contains("secret") })
    #expect(invocation.environment["RESTIC_PASSWORD"] == "secret")
  }
}

@Test func everyBackupSkipsCloudOnlyFiles() throws {
  let live = ResticCommand.backup(plainContext, paths: ["/p"], excludes: [], host: "host-a")
  let mounted = ResticCommand.backup(
    packedContext, paths: ["p"], excludes: ["/skip"], host: "host-a", currentDirectory: "/mnt",
    tags: ["disk-snapshot"])
  #expect(live.arguments.filter { $0 == "--exclude-cloud-files" }.count == 1)
  #expect(mounted.arguments.filter { $0 == "--exclude-cloud-files" }.count == 1)
  let forget = try #require(ResticCommand.forget(plainContext, host: "host-a", retention: .standard))
  #expect(!forget.arguments.contains("--exclude-cloud-files"))
}

@Test(
  "forget emits the flags of each retention preset",
  arguments: [
    (RetentionPreset.days15, ["--keep-within", "15d"]),
    (.days30, ["--keep-within", "30d"]),
    (.days60, ["--keep-within", "60d"]),
    (.days90, ["--keep-within", "90d"]),
    (.latestTwo, ["--keep-last", "2"]),
  ])
func forgetFlagsForPresets(preset: RetentionPreset, flags: [String]) throws {
  let invocation = try #require(ResticCommand.forget(plainContext, host: "host-a", retention: preset.retention))
  #expect(
    invocation.arguments == ["forget", "--json"] + common + ["--host", "host-a", "--group-by", "host"] + flags + [
      "--prune"
    ])
}

@Test func forgetEmitsEveryCustomRuleInRestOrder() throws {
  let policy = RetentionPolicy(
    keepLast: 3, keepWithin: "7d", keepWithinHourly: "2d", keepWithinDaily: "1m", keepWithinWeekly: "6m",
    keepWithinMonthly: "2y", keepWithinYearly: "10y")
  let invocation = try #require(ResticCommand.forget(packedContext, host: "host-a", retention: .policy(policy)))
  #expect(
    invocation.arguments == ["forget", "--json"] + common
      + [
        "--host", "host-a", "--group-by", "host", "--keep-last", "3", "--keep-within", "7d", "--keep-within-hourly",
        "2d", "--keep-within-daily", "1m", "--keep-within-weekly", "6m", "--keep-within-monthly", "2y",
        "--keep-within-yearly", "10y", "--prune", "--pack-size", "4",
      ])
}

@Test(
  "forget refuses retention that would not prune or that restic would reject",
  arguments: [
    SnapshotRetention.keepAll,
    .policy(RetentionPolicy()),
    .policy(RetentionPolicy(keepLast: 0)),
    .policy(RetentionPolicy(keepWithin: "0d")),
    .policy(RetentionPolicy(keepWithin: "")),
    .policy(RetentionPolicy(keepWithin: "60")),
    .policy(RetentionPolicy(keepLast: 2, keepWithinDaily: "1w")),
  ])
func forgetRefusesUnprunableRetention(retention: SnapshotRetention) {
  #expect(ResticCommand.forget(plainContext, host: "host-a", retention: retention) == nil)
}
