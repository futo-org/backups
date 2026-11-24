import Darwin
import Foundation

struct DirectoryEntry {
  enum Kind {
    case directory
    case file(bytes: Int64, cloudOnly: Bool)
    case other
  }

  let name: String
  let kind: Kind
}

enum DirectoryWalk {
  static let cloudOnlyFlag = UInt32(0x4000_0000)

  static func entries(of path: String) -> [DirectoryEntry]? {
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr =
      attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
      | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FLAGS)
    request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
    let capacity = 128 * 1024
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    defer { buffer.deallocate() }
    var result: [DirectoryEntry] = []
    while true {
      let count = getattrlistbulk(descriptor, &request, buffer, capacity, 0)
      if count < 0 { return result.isEmpty ? nil : result }
      if count == 0 { return result }
      var record = buffer
      for _ in 0..<count {
        let length = Int(record.load(as: UInt32.self))
        if let entry = parse(record) {
          result.append(entry)
        }
        record += length
      }
    }
  }

  private static func parse(_ record: UnsafeMutableRawPointer) -> DirectoryEntry? {
    var field = record + MemoryLayout<UInt32>.size
    let returned = field.loadUnaligned(as: attribute_set_t.self)
    field += MemoryLayout<attribute_set_t>.size
    if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
      field += MemoryLayout<UInt32>.size
    }
    guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
    let nameReference = field.loadUnaligned(as: attrreference_t.self)
    let name = String(cString: (field + Int(nameReference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
    field += MemoryLayout<attrreference_t>.size
    guard returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 else { return nil }
    let type = field.loadUnaligned(as: fsobj_type_t.self)
    field += MemoryLayout<fsobj_type_t>.size
    var flags: UInt32 = 0
    if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
      flags = field.loadUnaligned(as: UInt32.self)
      field += MemoryLayout<UInt32>.size
    }
    switch type {
    case VDIR.rawValue:
      return DirectoryEntry(name: name, kind: .directory)
    case VREG.rawValue:
      let bytes =
        returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 ? Int64(field.loadUnaligned(as: off_t.self)) : 0
      return DirectoryEntry(name: name, kind: .file(bytes: bytes, cloudOnly: flags & cloudOnlyFlag != 0))
    default:
      return DirectoryEntry(name: name, kind: .other)
    }
  }

  static func size(
    under root: String, workers: Int = ProcessInfo.processInfo.activeProcessorCount,
    isExcluded: (String) -> Bool, isCancelled: () -> Bool
  ) -> FolderSize {
    let base = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    guard let rootEntries = entries(of: base) else { return .unavailable }
    let state = WalkState()
    state.add(rootEntries, in: base, isExcluded: isExcluded)
    DispatchQueue.concurrentPerform(iterations: max(1, workers)) { _ in
      while let directory = state.next() {
        if isCancelled() {
          state.cancel()
          return
        }
        if let found = entries(of: directory) {
          state.add(found, in: directory, isExcluded: isExcluded)
        } else {
          state.markUnreadable()
        }
        state.finish()
      }
    }
    if state.isCancelled || isCancelled() { return .unavailable }
    return state.isComplete ? .bytes(state.total) : .atLeast(state.total)
  }
}

private final class WalkState: @unchecked Sendable {
  private let condition = NSCondition()
  private var pending: [String] = []
  private var active = 0
  private(set) var total: Int64 = 0
  private(set) var isCancelled = false
  private(set) var isComplete = true

  func add(_ found: [DirectoryEntry], in directory: String, isExcluded: (String) -> Bool) {
    var bytes: Int64 = 0
    var directories: [String] = []
    for entry in found {
      let path = directory == "/" ? "/" + entry.name : directory + "/" + entry.name
      switch entry.kind {
      case .directory:
        if !isExcluded(path) { directories.append(path) }
      case .file(let size, let cloudOnly):
        if !cloudOnly, !isExcluded(path) { bytes += size }
      case .other:
        continue
      }
    }
    condition.lock()
    total += bytes
    pending.append(contentsOf: directories)
    condition.broadcast()
    condition.unlock()
  }

  func markUnreadable() {
    condition.lock()
    isComplete = false
    condition.unlock()
  }

  func next() -> String? {
    condition.lock()
    defer { condition.unlock() }
    while pending.isEmpty && active > 0 && !isCancelled {
      condition.wait()
    }
    guard !isCancelled, let directory = pending.popLast() else {
      condition.broadcast()
      return nil
    }
    active += 1
    return directory
  }

  func finish() {
    condition.lock()
    active -= 1
    condition.broadcast()
    condition.unlock()
  }

  func cancel() {
    condition.lock()
    isCancelled = true
    active -= 1
    condition.broadcast()
    condition.unlock()
  }
}
