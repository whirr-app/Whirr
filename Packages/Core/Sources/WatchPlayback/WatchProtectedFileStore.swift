import Foundation

public enum WatchProtectedFileStoreError: Error, Equatable, Sendable {
  /// The key is not a plain file name; no path was built from it.
  case invalidKey
  /// The root directory or the key's file is a symbolic link.
  case symlink
  /// The file exists but could not be read, as before the first unlock after a restart.
  case unreadable
  case writeFailed
}

/// Watch state that names the account, the server or the user's titles. One file per key under a
/// single directory, written atomically, protected until first unlock and excluded from backup, so
/// none of it rides the Watch backup to the paired iPhone.
///
/// A read that fails is `unreadable`, never `nil`: before first unlock a protected file exists but
/// cannot be read, and a caller that took that for "nothing saved" would delete or overwrite it.
public final class WatchProtectedFileStore: @unchecked Sendable {
  public static let production = WatchProtectedFileStore(
    rootURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WatchProtected", isDirectory: true))

  public let rootURL: URL
  private let lock = NSLock()

  /// Does not touch the disk; the directory is created on the first save.
  public init(rootURL: URL) {
    self.rootURL = rootURL
  }

  public func settings(forKey key: String) throws -> any WatchSettingsStoring {
    try Self.validate(key)
    return KeySettings(store: self, key: key)
  }

  /// Reads and decodes one key, telling absent, unreadable and undecodable apart.
  public func read<Value>(key: String, decode: (Data) throws -> Value) -> WatchProtectedRead<Value> {
    WatchProtectedRead({ try self.load(key: key) }, decode: decode)
  }

  public func load(key: String) throws -> Data? {
    try Self.validate(key)
    return try lock.withLock {
      guard try Self.itemType(at: rootURL) != nil else { return nil }
      try Self.refuseSymlink(at: rootURL)
      let file = fileURL(key)
      guard try Self.itemType(at: file) != nil else { return nil }
      try Self.refuseSymlink(at: file)
      do {
        return try Data(contentsOf: file)
      } catch {
        throw WatchProtectedFileStoreError.unreadable
      }
    }
  }

  public func save(_ data: Data, key: String) throws {
    try Self.validate(key)
    try lock.withLock {
      try prepareRoot()
      let file = fileURL(key)
      if try Self.itemType(at: file) != nil { try Self.refuseSymlink(at: file) }
      do {
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try Self.excludeFromBackup(file)
      } catch {
        throw WatchProtectedFileStoreError.writeFailed
      }
    }
  }

  public func clear(key: String) throws {
    try Self.validate(key)
    try lock.withLock {
      guard try Self.itemType(at: rootURL) != nil else { return }
      try Self.refuseSymlink(at: rootURL)
      try remove(fileURL(key))
    }
  }

  /// Removes every key that starts with `prefix`, such as each account's download labels.
  public func clear(keysWithPrefix prefix: String) throws {
    guard Self.isValidPrefix(prefix) else { throw WatchProtectedFileStoreError.invalidKey }
    try lock.withLock {
      guard try Self.itemType(at: rootURL) != nil else { return }
      try Self.refuseSymlink(at: rootURL)
      let names: [String]
      do {
        names = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
      } catch {
        throw WatchProtectedFileStoreError.unreadable
      }
      for name in names where name.hasPrefix(prefix) && Self.isValidKey(name) {
        try remove(fileURL(name))
      }
    }
  }

  // MARK: Private

  private func fileURL(_ key: String) -> URL {
    rootURL.appendingPathComponent(key, isDirectory: false)
  }

  private func prepareRoot() throws {
    if try Self.itemType(at: rootURL) != nil {
      try Self.refuseSymlink(at: rootURL)
    } else {
      do {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
      } catch {
        throw WatchProtectedFileStoreError.writeFailed
      }
      try Self.refuseSymlink(at: rootURL)
    }
    do { try Self.excludeFromBackup(rootURL) } catch { throw WatchProtectedFileStoreError.writeFailed }
  }

  private func remove(_ file: URL) throws {
    guard try Self.itemType(at: file) != nil else { return }
    do {
      // Removing a link removes the link, not its target, so a symlinked file needs no refusal here.
      try FileManager.default.removeItem(at: file)
    } catch {
      throw WatchProtectedFileStoreError.writeFailed
    }
  }

  private static func excludeFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = url
    try mutable.setResourceValues(values)
  }

  /// The item's own type without following a final link; `nil` when nothing is there.
  private static func itemType(at url: URL) throws -> FileAttributeType? {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return attributes[.type] as? FileAttributeType ?? .typeUnknown
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
      return nil
    } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
      return nil
    } catch {
      throw WatchProtectedFileStoreError.unreadable
    }
  }

  private static func refuseSymlink(at url: URL) throws {
    if try itemType(at: url) == .typeSymbolicLink { throw WatchProtectedFileStoreError.symlink }
  }

  private static func validate(_ key: String) throws {
    guard isValidKey(key) else { throw WatchProtectedFileStoreError.invalidKey }
  }

  /// `^[a-z0-9][a-z0-9._-]{0,127}$`: a plain file name that cannot climb, hide or nest.
  static func isValidKey(_ key: String) -> Bool {
    guard (1...128).contains(key.utf8.count), let first = key.utf8.first, isLowerAlphanumeric(first) else {
      return false
    }
    return key.utf8.allSatisfy {
      isLowerAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
    }
  }

  private static func isValidPrefix(_ prefix: String) -> Bool { isValidKey(prefix) }

  private static func isLowerAlphanumeric(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
  }
}

/// What a protected read found. Callers decide per outcome what to keep and what to delete; the
/// one rule they share is that `unreadable` deletes nothing and overwrites nothing it has not read.
public enum WatchProtectedRead<Value> {
  case absent
  /// The file exists and could not be read, as before first unlock. Nothing may delete it.
  case unreadable
  /// Bytes were read and did not decode; the file is safe to replace or clear.
  case undecodable
  case value(Value)

  public init(_ load: () throws -> Data?, decode: (Data) throws -> Value) {
    let data: Data?
    do { data = try load() } catch {
      self = .unreadable
      return
    }
    guard let data else {
      self = .absent
      return
    }
    do { self = .value(try decode(data)) } catch { self = .undecodable }
  }

  public var value: Value? {
    if case .value(let value) = self { return value }
    return nil
  }

  /// A write may replace the file: either nothing is there or what is there was read.
  public var isSettled: Bool {
    if case .unreadable = self { return false }
    return true
  }
}

extension WatchProtectedRead: Sendable where Value: Sendable {}

private struct KeySettings: WatchSettingsStoring {
  let store: WatchProtectedFileStore
  let key: String

  func load() throws -> Data? { try store.load(key: key) }
  func save(_ data: Data) throws { try store.save(data, key: key) }
  func clear() throws { try store.clear(key: key) }
}
