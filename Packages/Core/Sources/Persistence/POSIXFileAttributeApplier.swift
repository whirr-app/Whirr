import Foundation

/// Production `FileAttributeApplying` conformance. `FileProtectionType`/`.protectionKey` are
/// plain Foundation APIs available on every Darwin platform, but their protection is only
/// meaningfully enforced by iOS Data Protection; on macOS the calls succeed and round-trip
/// without any real enforcement. Hence the attributes are applied through the
/// `FileAttributeApplying` seam rather than inlined into `AppDatabase`.
public struct POSIXFileAttributeApplier: FileAttributeApplying {
  public init() {}

  public func protectDirectory(at directoryURL: URL) throws {
    try Self.applyAndVerify(at: directoryURL, excludedFromBackup: false)
  }

  public func protectDatabaseArtifacts(at databaseURL: URL) throws {
    for url in Self.artifactURLs(for: databaseURL) where FileManager.default.fileExists(atPath: url.path) {
      try Self.applyAndVerify(at: url, excludedFromBackup: false)
    }
  }

  public func protectDownloadsRoot(at directoryURL: URL) throws {
    try Self.applyAndVerify(at: directoryURL, excludedFromBackup: true)
  }

  public func protectDownloadedFile(at fileURL: URL) throws {
    try Self.applyAndVerify(at: fileURL, excludedFromBackup: true)
  }

  /// Any other file or folder the app keeps out of backups and readable after first unlock, such
  /// as the widget snapshot and its covers, which another process reads.
  public func protectExcludedFromBackup(at url: URL) throws {
    try Self.applyAndVerify(at: url, excludedFromBackup: true)
  }

  /// The main database file plus its WAL-mode sidecars, whether or not they currently exist.
  public static func artifactURLs(for databaseURL: URL) -> [URL] {
    DatabaseArtifacts.urls(for: databaseURL)
  }

  private static func applyAndVerify(at url: URL, excludedFromBackup: Bool) throws {
    // The iOS simulator's filesystem does not implement Data Protection: the attribute does not
    // round-trip there, so applying and verifying it only produces false failures (a fresh
    // install crashed opening its database on first launch). Not host-unit-testable, because
    // the macOS host round-trips the attribute.
    #if !targetEnvironment(simulator)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path
      )
    #endif
    var mutableURL = url
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = excludedFromBackup
    try mutableURL.setResourceValues(resourceValues)
    try verify(url, excludedFromBackup: excludedFromBackup)
  }

  private static func verify(_ url: URL, excludedFromBackup: Bool) throws {
    #if !targetEnvironment(simulator)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication
      else {
        throw FileAttributeError.protectionNotApplied(path: url.path)
      }
    #endif
    let resourceValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
    if excludedFromBackup {
      guard resourceValues.isExcludedFromBackup == true else {
        throw FileAttributeError.notExcludedFromBackup(path: url.path)
      }
    } else {
      guard resourceValues.isExcludedFromBackup != true else {
        throw FileAttributeError.excludedFromBackup(path: url.path)
      }
    }
  }
}
