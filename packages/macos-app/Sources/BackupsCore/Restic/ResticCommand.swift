import Foundation

public struct ResticContext: Sendable, Equatable {
  public var repository: String
  public var password: String
  public var cacheDirectory: URL
  public var home: String
  public var connections: Int
  public var packSizeMiB: Int?
  public var walkConcurrency: Int?

  public init(
    repository: String, password: String, cacheDirectory: URL, home: String, connections: Int,
    packSizeMiB: Int? = nil, walkConcurrency: Int? = nil
  ) {
    self.repository = repository
    self.password = password
    self.cacheDirectory = cacheDirectory
    self.home = home
    self.connections = connections
    self.packSizeMiB = packSizeMiB
    self.walkConcurrency = walkConcurrency
  }
}

public struct ResticInvocation: Sendable, Equatable {
  public var arguments: [String]
  public var environment: [String: String]
  public var currentDirectory: String? = nil
}

public enum ResticCommand {
  public static func version(home: String) -> ResticInvocation {
    ResticInvocation(arguments: ["version", "--json"], environment: ["HOME": home, "PATH": standardPath])
  }

  public static func initialize(_ context: ResticContext) -> ResticInvocation {
    invocation(context, ["init"], [])
  }

  public static func unlock(_ context: ResticContext) -> ResticInvocation {
    invocation(context, ["unlock"], ["--remove-all"])
  }

  public static func backup(
    _ context: ResticContext, paths: [String], excludes: [String], host: String,
    currentDirectory: String? = nil, tags: [String] = []
  ) -> ResticInvocation {
    var flags = ["--host", host, "--group-by", "host", "--exclude-caches"]
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
    var result = invocation(context, ["backup"], flags, positional: paths)
    result.currentDirectory = currentDirectory
    return result
  }

  public static func snapshots(_ context: ResticContext) -> ResticInvocation {
    invocation(context, ["snapshots"], ["--no-lock"])
  }

  public static func forget(_ context: ResticContext, host: String, keepWithin: String) -> ResticInvocation {
    var flags = ["--host", host, "--group-by", "host", "--keep-within", keepWithin, "--prune"]
    if let packSizeMiB = context.packSizeMiB {
      flags += ["--pack-size", "\(packSizeMiB)"]
    }
    return invocation(context, ["forget"], flags)
  }

  public static func restore(_ context: ResticContext, snapshotId: String, target: String, include: [String])
    -> ResticInvocation
  {
    var flags = ["--target", target]
    for path in include {
      flags += ["--include", path]
    }
    return invocation(context, ["restore"], flags, positional: [snapshotId])
  }

  public static func stats(_ context: ResticContext) -> ResticInvocation {
    invocation(context, ["stats"], ["--mode", "raw-data"])
  }

  public static func catConfig(_ context: ResticContext) -> ResticInvocation {
    invocation(context, ["cat", "config"], [])
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
    arguments += positional
    return ResticInvocation(arguments: arguments, environment: environment(context))
  }
}
