import Darwin
import Foundation

public enum DataVolume {
  public static let mountPath = "/System/Volumes/Data"

  public static func relativePath(realPath: String, volumeMountPath: String) -> String? {
    guard volumeMountPath == mountPath else { return nil }
    if realPath == mountPath {
      return "."
    }
    if realPath.hasPrefix(mountPath + "/") {
      return String(realPath.dropFirst(mountPath.count + 1))
    }
    if realPath.hasPrefix("/") && realPath.count > 1 {
      return String(realPath.dropFirst())
    }
    return nil
  }

  public static func relativePath(of path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    let realPath = String(cString: resolved)
    guard realPath == URL(fileURLWithPath: path).standardizedFileURL.path else { return nil }
    var status = statfs()
    guard statfs(realPath, &status) == 0 else { return nil }
    return relativePath(realPath: realPath, volumeMountPath: mountName(of: status))
  }

  public static func resolvedPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  public static func snapshotRelativePath(_ absolutePath: String) -> String? {
    guard absolutePath.hasPrefix("/") else { return nil }
    if absolutePath == mountPath {
      return "."
    }
    if absolutePath.hasPrefix(mountPath + "/") {
      return String(absolutePath.dropFirst(mountPath.count + 1))
    }
    if absolutePath == "/" {
      return nil
    }
    return String(absolutePath.dropFirst())
  }
}

public enum FullDiskAccess {
  public static let probe: URL = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")

  public static func isGranted(probe: URL = FullDiskAccess.probe) -> Bool {
    let descriptor = open(probe.path, O_RDONLY)
    guard descriptor >= 0 else { return false }
    close(descriptor)
    return true
  }
}

private func mountName(of status: statfs) -> String {
  withUnsafePointer(to: status.f_mntonname) { tuple in
    tuple.withMemoryRebound(to: CChar.self, capacity: 1024) { bytes in
      String(cString: bytes)
    }
  }
}
