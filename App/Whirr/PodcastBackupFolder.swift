import AppModel
import Foundation
import SyncEngine

/// Files access for the automatic backup folder: a retained bookmark, security-scoped access held
/// for each whole operation, and coordinated file work so iCloud Drive and other providers see
/// consistent writes. The coordinated calls block, so both entry points run off the main actor.
nonisolated struct PodcastBackupFolder: PodcastBackupFolderWriting {
  var startAccess: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
  var stopAccess: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }

  @concurrent func choose(pickedFolder url: URL) async throws -> PodcastBackupFolderChoice {
    try scoped(url) {
      guard let bookmark = try? Self.makeBookmark(url) else { throw PodcastBackupFolderError.folderUnavailable }
      let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
      return PodcastBackupFolderChoice(bookmark: bookmark, name: name)
    }
  }

  @concurrent func write(
    _ data: Data, named filename: String, toFolder bookmark: Data, keepingExistingBackups: Bool
  ) async throws -> Data? {
    var stale = false
    guard
      let folder = try? URL(
        resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
    else { throw PodcastBackupFolderError.folderUnavailable }
    return try scoped(folder) {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
      else { throw PodcastBackupFolderError.folderUnavailable }
      // A failed refresh keeps the old bookmark, which still resolved this time.
      let refreshed = stale ? try? Self.makeBookmark(folder) : nil

      if keepingExistingBackups {
        // An unreadable listing is no evidence that the folder is empty.
        guard let existing = try? Self.backups(in: folder) else { throw PodcastBackupFolderError.writeFailed }
        guard existing.isEmpty else { throw PodcastBackupFolderError.existingBackupsKept }
      }

      let file = folder.appendingPathComponent(filename, isDirectory: false)
      do {
        try Self.coordinatedWrite(data, to: file)
        guard try Self.coordinatedRead(file) == data else { throw PodcastBackupFolderError.writeFailed }
      } catch {
        throw PodcastBackupFolderError.writeFailed
      }
      // Pruning only follows a verified write, and a failure to prune never fails the backup.
      let backups = (try? Self.backups(in: folder)) ?? [:]
      for name in PodcastAutoBackupPolicy.filesToDelete(among: Array(backups.keys), justWritten: filename) {
        if let url = backups[name] { try? Self.coordinatedDelete(url) }
      }
      return refreshed
    }
  }

  // MARK: - Helpers

  private func scoped<T>(_ url: URL, body: () throws -> T) throws -> T {
    guard startAccess(url) else { throw PodcastBackupFolderError.folderUnavailable }
    defer { stopAccess(url) }
    return try body()
  }

  private static func makeBookmark(_ folder: URL) throws -> Data {
    try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  /// Backup files by name. A provider may list a file not yet downloaded as a hidden
  /// `.<name>.icloud` placeholder, which still counts as that backup.
  private static func backups(in folder: URL) throws -> [String: URL] {
    var listing: Result<[URL], Error> = .failure(PodcastBackupFolderError.writeFailed)
    try coordinate(reading: folder, options: .immediatelyAvailableMetadataOnly) { url in
      listing = Result { try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
    }
    var result: [String: URL] = [:]
    for entry in try listing.get() {
      var name = entry.lastPathComponent
      if name.hasPrefix("."), name.hasSuffix(".icloud") {
        name = String(name.dropFirst().dropLast(".icloud".count))
      }
      if PodcastAutoBackupPolicy.isBackupFilename(name) { result[name] = entry }
    }
    return result
  }

  private static func coordinatedWrite(_ data: Data, to file: URL) throws {
    var coordinationError: NSError?
    var result: Result<Void, Error> = .failure(PodcastBackupFolderError.writeFailed)
    NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
      result = Result { try data.write(to: url, options: .atomic) }
    }
    if let coordinationError { throw coordinationError }
    try result.get()
  }

  private static func coordinatedRead(_ file: URL) throws -> Data {
    var result: Result<Data, Error> = .failure(PodcastBackupFolderError.writeFailed)
    try coordinate(reading: file, options: []) { url in
      result = Result {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= PodcastStateSnapshotCodec.maxBytes else { throw CocoaError(.fileReadTooLarge) }
        return try Data(contentsOf: url)
      }
    }
    return try result.get()
  }

  private static func coordinatedDelete(_ file: URL) throws {
    var coordinationError: NSError?
    var result: Result<Void, Error> = .success(())
    NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: &coordinationError) { url in
      result = Result { try FileManager.default.removeItem(at: url) }
    }
    if let coordinationError { throw coordinationError }
    try result.get()
  }

  private static func coordinate(
    reading url: URL, options: NSFileCoordinator.ReadingOptions, body: (URL) -> Void
  ) throws {
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(readingItemAt: url, options: options, error: &coordinationError, byAccessor: body)
    if let coordinationError { throw coordinationError }
  }
}

/// The automatic backup setting in `UserDefaults`, as one encoded value. It is not
/// in `ICloudSettingsSync`'s allowlist: a folder bookmark means nothing on another device.
nonisolated final class UserDefaultsPodcastAutoBackupStore: PodcastAutoBackupStoring, @unchecked Sendable {
  static let key = "com.remoteconcern.whirr.podcastAutoBackup"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> PodcastAutoBackupState {
    guard let data = defaults.data(forKey: Self.key),
      let state = try? JSONDecoder().decode(PodcastAutoBackupState.self, from: data)
    else { return PodcastAutoBackupState() }
    return state
  }

  func save(_ state: PodcastAutoBackupState) {
    defaults.set(try? JSONEncoder().encode(state), forKey: Self.key)
  }
}
