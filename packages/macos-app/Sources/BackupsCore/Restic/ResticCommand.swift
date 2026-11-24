import Foundation

public struct ResticContext: Sendable, Equatable {
  public static let packSizeRangeMiB = 4...128

  public var repository: String
  public var password: String
  public var cacheDirectory: URL
  public var home: String
  public var connections: Int
  public var packSizeMiB: Int?
  public var walkConcurrency: Int?
  public var readConcurrency: Int?

  public init(
    repository: String, password: String, cacheDirectory: URL, home: String, connections: Int,
    packSizeMiB: Int? = nil, walkConcurrency: Int? = nil, readConcurrency: Int? = nil
  ) {
    self.repository = repository
    self.password = password
    self.cacheDirectory = cacheDirectory
    self.home = home
    self.connections = connections
    self.packSizeMiB = packSizeMiB
    self.walkConcurrency = walkConcurrency
    self.readConcurrency = readConcurrency
  }
}

public struct ResticInvocation: Sendable, Equatable {
  public var arguments: [String]
  public var environment: [String: String]
  public var currentDirectory: String? = nil
  public var retainsStdout = true
}

public enum ResticCommand {
  public static func version(home: String) -> ResticInvocation {
    ResticInvocation(arguments: ["version", "--json"], environment: ["HOME": home, "PATH": standardPath])
  }

  public static func initialize(_ context: ResticContext) -> ResticInvocation {
    invocation(context, ["init"], [])
  }

  public static func unlock(_ context: ResticContext) -> ResticInvocation {
    invocation(context, ["unlock"], [])
  }

  public static func backup(
    _ context: ResticContext, paths: [String], excludes: [String], host: String,
    currentDirectory: String? = nil, tags: [String] = []
  ) -> ResticInvocation {
    var flags = ["--host", host, "--group-by", "host", "--exclude-caches", "--exclude-cloud-files"]
    for tag in tags {
      flags += ["--tag", tag]
    }
    for exclude in excludes {
      flags += ["--exclude", exclude]
    }
    if let packSizeMiB = context.packSizeMiB {
      flags += ["--pack-size", "\(packSizeMiB)"]
    }
    if let walkConcurrency = context.walkConcurrency {
      flags += ["--walk-concurrency", "\(walkConcurrency)"]
    }
    if let readConcurrency = context.readConcurrency {
      flags += ["--read-concurrency", "\(readConcurrency)"]
    }
    var result = invocation(context, ["backup"], flags, positional: paths)
    result.currentDirectory = currentDirectory
    result.retainsStdout = false
    result.environment["RESTIC_PROGRESS_FPS"] = "2"
    return result
  }

  public static func snapshots(_ context: ResticContext) -> ResticInvocation {
    invocation(context, ["snapshots"], ["--no-lock"])
  }

  public static func forget(_ context: ResticContext, host: String, retention: SnapshotRetention) -> ResticInvocation? {
    guard let policy = retention.prunablePolicy else { return nil }
    var flags = ["--host", host, "--group-by", "host"] + policy.resticArguments + ["--prune"]
    if let packSizeMiB = context.packSizeMiB {
      flags += ["--pack-size", "\(packSizeMiB)"]
    }
    return invocation(context, ["forget"], flags)
  }

  public static func restore(
    _ context: ResticContext, snapshotId: String, subfolder: String? = nil, target: String
  ) -> ResticInvocation {
    let source = subfolder.map { "\(snapshotId):\($0)" } ?? snapshotId
    var result = invocation(
      context, ["restore"], ["--target", target, "--overwrite", "never"], positional: [source])
    result.retainsStdout = false
    return result
  }

  public static func stats(_ context: ResticContext) -> ResticInvocation {
    invocation(context, ["stats"], ["--mode", "raw-data"])
  }

  public static func catConfig(_ context: ResticContext) -> ResticInvocation {
    invocation(context, ["cat", "config"], [])
  }

  public static func keyList(_ context: ResticContext) -> ResticInvocation {
    invocation(context, ["key", "list"], [])
  }

  public static func keyAdd(_ context: ResticContext, newPasswordFile: String) -> ResticInvocation {
    invocation(context, ["key", "add"], ["--new-password-file", newPasswordFile])
  }

  public static func keyRemove(_ context: ResticContext, id: String) -> ResticInvocation {
    invocation(context, ["key", "remove"], [], positional: [id])
  }

  private static let standardPath = "/usr/bin:/bin:/usr/sbin:/sbin"

  private static func environment(_ context: ResticContext) -> [String: String] {
    [
      "RESTIC_REPOSITORY": context.repository,
      "RESTIC_PASSWORD": context.password,
      "HOME": context.home,
      "PATH": standardPath,
    ]
  }

  private static func invocation(
    _ context: ResticContext, _ command: [String], _ flags: [String],
    positional: [String] = []
  ) -> ResticInvocation {
    var arguments = command + ["--json"]
    arguments += ["--option", "rest.connections=\(context.connections)", "--cache-dir", context.cacheDirectory.path]
    arguments += flags
    if !positional.isEmpty {
      arguments += ["--"] + positional
    }
    return ResticInvocation(arguments: arguments, environment: environment(context))
  }
}
