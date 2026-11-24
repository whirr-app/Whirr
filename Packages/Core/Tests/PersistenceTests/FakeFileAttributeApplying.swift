import Foundation

@testable import Persistence

/// Test double for `FileAttributeApplying`. Real `FileProtectionType` enforcement exists only
/// on-device, so this delegates to the same Foundation calls as `POSIXFileAttributeApplier` (they
/// round-trip on macOS without enforcement) while recording call order and targets to assert the
/// sequencing: directory protected before SQLite creates the database file, then the main file and
/// every extant sidecar protected on open and again after writes.
final class FakeFileAttributeApplying: FileAttributeApplying, @unchecked Sendable {
  private let real = POSIXFileAttributeApplier()
  private let lock = NSLock()
  private let downloadedFileProtectionError: Error?

  init(downloadedFileProtectionError: Error? = nil) {
    self.downloadedFileProtectionError = downloadedFileProtectionError
  }

  private(set) var directoryProtectionCalls: [URL] = []
  private(set) var artifactProtectionCalls: [URL] = []
  private(set) var downloadsRootProtectionCalls: [URL] = []
  private(set) var downloadedFileProtectionCalls: [URL] = []

  /// Whether the protected directory was empty (no database file, no sidecars) the first
  /// time it was protected. Proof that protection happened before SQLite created anything.
  private(set) var directoryWasEmptyOnFirstProtection: Bool?

  /// Same proof as `directoryWasEmptyOnFirstProtection`, for the downloads root: the root must
  /// be protected before any file is written into it.
  private(set) var downloadsRootWasEmptyOnFirstProtection: Bool?

  func protectDirectory(at directoryURL: URL) throws {
    try real.protectDirectory(at: directoryURL)
    lock.lock()
    defer { lock.unlock() }
    if directoryWasEmptyOnFirstProtection == nil {
      let contents = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
      directoryWasEmptyOnFirstProtection = contents.isEmpty
    }
    directoryProtectionCalls.append(directoryURL)
  }

  func protectDatabaseArtifacts(at databaseURL: URL) throws {
    try real.protectDatabaseArtifacts(at: databaseURL)
    lock.lock()
    defer { lock.unlock() }
    for candidate in POSIXFileAttributeApplier.artifactURLs(for: databaseURL)
    where FileManager.default.fileExists(atPath: candidate.path) {
      artifactProtectionCalls.append(candidate)
    }
  }

  func protectDownloadsRoot(at directoryURL: URL) throws {
    try real.protectDownloadsRoot(at: directoryURL)
    lock.lock()
    defer { lock.unlock() }
    if downloadsRootWasEmptyOnFirstProtection == nil {
      let contents = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
      downloadsRootWasEmptyOnFirstProtection = contents.isEmpty
    }
    downloadsRootProtectionCalls.append(directoryURL)
  }

  func protectDownloadedFile(at fileURL: URL) throws {
    if let downloadedFileProtectionError {
      throw downloadedFileProtectionError
    }
    try real.protectDownloadedFile(at: fileURL)
    lock.lock()
    defer { lock.unlock() }
    downloadedFileProtectionCalls.append(fileURL)
  }
}
