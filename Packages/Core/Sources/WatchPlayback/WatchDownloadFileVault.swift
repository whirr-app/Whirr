import Foundation

/// Owns download files only. Manifest transitions and quota reservations stay with the store.
struct WatchDownloadFileVault: Sendable {
  private let filesURL: URL

  init(rootURL: URL) throws {
    try Self.rejectSymlink(at: rootURL)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try Self.rejectSymlink(at: rootURL)
    let filesURL = rootURL.appendingPathComponent("files", isDirectory: true)
    try Self.rejectSymlink(at: filesURL)
    try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
    try Self.rejectSymlink(at: filesURL)
    Self.excludeFromBackup(rootURL)
    Self.excludeFromBackup(filesURL)
    Self.protectPrivateFile(rootURL)
    Self.protectPrivateFile(filesURL)

    self.filesURL = filesURL
  }

  func measuredTemporaryFile(_ temporaryFileURL: URL, expectedBytes: Int64?, responseBytes: Int64?) throws -> Int64 {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: temporaryFileURL.path) else {
      throw WatchDownloadStoreError.temporaryFileMissing
    }
    guard Self.isRegularNonSymlink(temporaryFileURL) else {
      throw WatchDownloadStoreError.temporaryFileIsSymlink
    }
    guard let measured = Self.fileSize(at: temporaryFileURL), measured >= 0 else {
      throw WatchDownloadStoreError.temporaryFileMissing
    }
    if let responseBytes, responseBytes != measured { throw WatchDownloadStoreError.fileSizeMismatch }
    if let expected = expectedBytes, expected != measured {
      throw WatchDownloadStoreError.fileSizeMismatch
    }
    return measured
  }

  func install(_ temporaryFileURL: URL, relativePath: String, measured: Int64) throws {
    let fileManager = FileManager.default
    let destination = try containedDestination(for: relativePath)
    guard Self.hasNoSymlinkComponents(from: filesURL, through: destination, includeLeaf: true) else {
      throw WatchDownloadStoreError.storageFailure
    }
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let staging = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).part")
    do {
      guard Self.fileSize(at: temporaryFileURL) == measured, Self.isRegularNonSymlink(temporaryFileURL) else {
        throw WatchDownloadStoreError.fileSizeMismatch
      }
      // A same-volume rename needs no second copy of the file; copying is the cross-volume fallback.
      do { try fileManager.moveItem(at: temporaryFileURL, to: staging) } catch {
        try fileManager.copyItem(at: temporaryFileURL, to: staging)
      }
      guard Self.fileSize(at: staging) == measured, Self.isRegularNonSymlink(staging) else {
        throw WatchDownloadStoreError.fileSizeMismatch
      }
      if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
      try fileManager.moveItem(at: staging, to: destination)
      try? fileManager.removeItem(at: temporaryFileURL)
      Self.excludeFromBackup(destination)
      Self.protectPrivateFile(destination)
    } catch let error as WatchDownloadStoreError {
      try? fileManager.removeItem(at: staging)
      throw error
    } catch {
      try? fileManager.removeItem(at: staging)
      throw WatchDownloadStoreError.storageFailure
    }
  }

  func completedFile(relativePath: String, expectedBytes: Int64?) throws -> URL {
    let destination = try containedDestination(for: relativePath)
    guard Self.hasNoSymlinkComponents(from: filesURL, through: destination, includeLeaf: false) else {
      throw WatchDownloadStoreError.completedFileIsSymlink
    }
    guard FileManager.default.fileExists(atPath: destination.path) else {
      throw WatchDownloadStoreError.completedFileMissing
    }
    guard Self.isRegularNonSymlink(destination) else {
      throw WatchDownloadStoreError.completedFileIsSymlink
    }
    if let expected = expectedBytes, Self.fileSize(at: destination) != expected {
      throw WatchDownloadStoreError.fileSizeMismatch
    }
    return destination
  }

  func destinationFile(relativePath: String) throws -> URL {
    let destination = try containedDestination(for: relativePath)
    guard Self.hasNoSymlinkComponents(from: filesURL, through: destination, includeLeaf: false) else {
      throw WatchDownloadStoreError.storageFailure
    }
    return destination
  }

  func remove(relativePath: String) throws {
    let destination = try containedDestination(for: relativePath)
    guard Self.hasNoSymlinkComponents(from: filesURL, through: destination, includeLeaf: true) else {
      throw WatchDownloadStoreError.completedFileIsSymlink
    }
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
    } catch let error as WatchDownloadStoreError {
      throw error
    } catch {
      throw WatchDownloadStoreError.storageFailure
    }
  }

  /// Removes every file, for a manifest that can no longer say which of them it owns.
  func removeAllFiles() {
    if let files = try? FileManager.default.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: nil) {
      for file in files { try? FileManager.default.removeItem(at: file) }
    }
  }

  func removeStagingFiles() {
    if let files = try? FileManager.default.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: nil) {
      for file in files where file.lastPathComponent.hasSuffix(".part") {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }

  private func containedDestination(for relativePath: String) throws -> URL {
    guard relativePath.isEmpty == false, relativePath.hasPrefix("/") == false,
      relativePath.contains("..") == false
    else { throw WatchDownloadStoreError.invalidSelection }
    let destination = filesURL.appendingPathComponent(relativePath)
    let rootPath = filesURL.standardizedFileURL.path
    let destinationPath = destination.standardizedFileURL.path
    guard destinationPath.hasPrefix(rootPath + "/") else { throw WatchDownloadStoreError.invalidSelection }
    return destination
  }

  private static func rejectSymlink(at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    guard hasNoSymlink(at: url) else { throw WatchDownloadStoreError.storageFailure }
  }

  // Ancestors above the vault root are trusted because the root is the app's own container.
  // On Apple platforms /var → /private/var is itself a symlink; standardizedFileURL resolves
  // that system alias before the prefix comparison, so only the root and paths below it are checked.
  private static func hasNoSymlinkComponents(
    from root: URL, through destination: URL, includeLeaf: Bool
  ) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let destinationPath = destination.standardizedFileURL.path
    guard destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/") else {
      return false
    }
    var current = destination.standardizedFileURL
    if includeLeaf == false { current.deleteLastPathComponent() }
    while true {
      if FileManager.default.fileExists(atPath: current.path), hasNoSymlink(at: current) == false {
        return false
      }
      if current.path == rootPath { return true }
      let parent = current.deletingLastPathComponent()
      guard parent.path != current.path else { return false }
      current = parent
    }
  }

  /// Fails closed: an existing item whose type cannot be read is treated as untrusted.
  private static func hasNoSymlink(at url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let type = attributes[.type] as? FileAttributeType
    else { return false }
    return type != .typeSymbolicLink
  }

  private static func fileSize(at url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
  }

  private static func isRegularNonSymlink(_ url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let type = attributes[.type] as? FileAttributeType
    else { return false }
    return type == .typeRegular
  }

  private static func excludeFromBackup(_ url: URL) {
    #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableURL = url
      try? mutableURL.setResourceValues(values)
    #endif
  }

  private static func protectPrivateFile(_ url: URL) {
    #if os(iOS) || os(tvOS) || os(watchOS)
      try? FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path)
    #endif
  }
}
