import Foundation
import Persistence
import WidgetProtocol

/// Every widget file the app writes: the App Group's `Widgets/` folder (read by the extension) and
/// an app-private token-map folder. Account removal deletes both (`removalRootURLs`).
///
/// Folders and files are readable after first unlock and excluded from backup. Before the first
/// unlock after a restart the extension cannot read them and draws its placeholder.
nonisolated struct WidgetFileStore: Sendable {
  static let tokenMapDirectoryName = "WidgetTokens"
  static let tokenMapFileName = "token-map.json"

  /// The App Group container, or `nil` when the entitlement is missing (an unsigned build). With
  /// no container nothing is written for the extension; the token map is still kept.
  let containerURL: URL?
  let privateRootURL: URL
  private let protect: @Sendable (URL) throws -> Void

  init(containerURL: URL?, privateRootURL: URL, protect: @escaping @Sendable (URL) throws -> Void) {
    self.containerURL = containerURL
    self.privateRootURL = privateRootURL
    self.protect = protect
  }

  /// An injected application-support directory (a composed test graph) also stands in for the
  /// App Group container, so a test that runs logout or account removal never touches the real
  /// container the installed extension reads.
  static func production(applicationSupportDirectory: URL? = nil) -> WidgetFileStore {
    let container =
      applicationSupportDirectory.map {
        $0.appendingPathComponent("AppGroupContainer", isDirectory: true)
      }
      ?? FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: WidgetStorageLayout.appGroupIdentifier)
    return WidgetFileStore(
      containerURL: container,
      privateRootURL: privateRoot(
        applicationSupportDirectory: applicationSupportDirectory
          ?? AppEnvironment.applicationSupportDirectory()),
      protect: { try POSIXFileAttributeApplier().protectExcludedFromBackup(at: $0) })
  }

  static func privateRoot(applicationSupportDirectory: URL) -> URL {
    applicationSupportDirectory.appendingPathComponent(tokenMapDirectoryName, isDirectory: true)
  }

  /// What account removal deletes, including after a relaunch into the removal-only graph.
  var removalRootURLs: [URL] {
    [containerURL.map(WidgetStorageLayout.rootDirectory(inContainer:)), privateRootURL].compactMap { $0 }
  }

  private var tokenMapURL: URL {
    privateRootURL.appendingPathComponent(Self.tokenMapFileName, isDirectory: false)
  }

  // MARK: Snapshot

  func readSnapshot() -> WidgetSnapshot? {
    guard let containerURL,
      let data = try? Data(contentsOf: WidgetStorageLayout.snapshotFile(inContainer: containerURL))
    else { return nil }
    return try? WidgetSnapshotCodec.decode(data)
  }

  func writeSnapshot(_ data: Data) throws {
    guard let containerURL else { return }
    try ensureDirectory(WidgetStorageLayout.rootDirectory(inContainer: containerURL))
    try write(data, to: WidgetStorageLayout.snapshotFile(inContainer: containerURL))
  }

  // MARK: Smart lists

  func readSmartLists() -> WidgetSmartLists? {
    WidgetSmartListsReader(containerURL: containerURL).read()
  }

  func writeSmartLists(_ data: Data) throws {
    guard let containerURL else { return }
    try ensureDirectory(WidgetStorageLayout.rootDirectory(inContainer: containerURL))
    try write(data, to: WidgetStorageLayout.smartListsFile(inContainer: containerURL))
  }

  // MARK: Token map

  func readTokenMap() -> WidgetTokenMap? {
    (try? Data(contentsOf: tokenMapURL)).flatMap(WidgetTokenMap.decode)
  }

  func writeTokenMap(_ map: WidgetTokenMap) throws {
    try ensureDirectory(privateRootURL)
    try write(try map.encoded(), to: tokenMapURL)
  }

  // MARK: Covers

  func existingCoverNames() -> Set<String> {
    guard let directory = coversDirectory,
      let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    return Set(names.filter { (try? WidgetStorageLayout.validateCoverFileName($0)) != nil })
  }

  func writeCover(_ data: Data, named fileName: String) throws {
    guard let containerURL, let directory = coversDirectory else { return }
    try ensureDirectory(WidgetStorageLayout.rootDirectory(inContainer: containerURL))
    try ensureDirectory(directory)
    try write(data, to: try WidgetStorageLayout.coverFile(named: fileName, inContainer: containerURL))
  }

  /// Deletes every cover not in `names`, and anything in the folder that is not a cover.
  func pruneCovers(keeping names: Set<String>) {
    guard let directory = coversDirectory,
      let present = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return }
    for name in present where !names.contains(name) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  /// Logout: covers, the smart list file and the token map go; the snapshot is replaced, not
  /// deleted, so the extension reads a signed-out file rather than a missing one. The smart list
  /// widget reads its signed-out state from that snapshot, and a missing list file can never draw
  /// the previous account's lists.
  func removeCoversAndTokenMap() {
    if let coversDirectory { try? FileManager.default.removeItem(at: coversDirectory) }
    if let containerURL {
      try? FileManager.default.removeItem(at: WidgetStorageLayout.smartListsFile(inContainer: containerURL))
    }
    try? FileManager.default.removeItem(at: privateRootURL)
  }

  private var coversDirectory: URL? {
    containerURL.map(WidgetStorageLayout.coversDirectory(inContainer:))
  }

  private func ensureDirectory(_ url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try protect(url)
  }

  private func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    try protect(url)
  }
}
