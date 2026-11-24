import CryptoKit
import Foundation

/// The identity of one stored cover: everything that selects different bytes.
struct CoverStoreKey: Hashable, Sendable {
  let scope: ArtworkAccountScope
  let itemID: String
  let width: Int?
  let revision: ArtworkRevision
  let format: CoverImageFormat

  var scopeDirectory: String { CoverStoreNaming.scopeDirectory(scope) }
  var itemDirectory: String { CoverStoreNaming.itemDirectory(itemID) }
  var fileName: String {
    CoverStoreNaming.fileName(format: format, width: width, revision: revision)
  }
  /// `{item}/{file}`: the form the sweep's keep list uses.
  var relativePath: String { itemDirectory + "/" + fileName }
}

/// Maps cover identities onto path components. Nothing a server or a paired Watch supplies is ever
/// used as a path component unless it is drawn from a fixed safe alphabet: an item ID admits dots
/// and has no length cap, a revision is any string, and the volume is case-insensitive.
enum CoverStoreNaming {
  static let storeDirectory = "store-v1"
  static let temporaryPrefix = "tmp-"
  static let unversionedToken = "unversioned"
  private static let hashedItemPrefix = "h-"
  private static let hashedRevisionPrefix = "r-"

  static func scopeDirectory(_ scope: ArtworkAccountScope) -> String {
    hashPrefix(scope.rawValue)
  }

  /// A lowercase ID is its own directory. Anything else is hashed, including an ID with uppercase
  /// letters: lowercasing it would make two IDs that differ only by case share one directory.
  static func itemDirectory(_ itemID: String) -> String {
    let safe =
      (1...64).contains(itemID.utf8.count) && itemID.hasPrefix(hashedItemPrefix) == false
      && itemID.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
      }
    return safe ? itemID : hashedItemPrefix + hashPrefix(itemID)
  }

  static func revisionToken(_ revision: ArtworkRevision) -> String {
    let raw = revision.rawValue
    if raw == ArtworkRevision.unversioned.rawValue { return unversionedToken }
    if isNumeric(raw) { return raw }
    return hashedRevisionPrefix + hashPrefix(raw)
  }

  static func fileName(format: CoverImageFormat, width: Int?, revision: ArtworkRevision) -> String {
    "\(format.rawValue)-\(width.map(String.init) ?? "full")-\(revisionToken(revision))"
  }

  /// The format and revision token of a stored file, or nil for a temporary or foreign name.
  static func parse(fileName: String) -> (format: CoverImageFormat, revisionToken: String)? {
    let parts = fileName.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, let format = CoverImageFormat(rawValue: String(parts[0])) else {
      return nil
    }
    return (format, String(parts[2]))
  }

  static func isNumeric(_ token: String) -> Bool {
    (1...19).contains(token.utf8.count) && token.utf8.allSatisfy { (48...57).contains($0) }
  }

  /// True when both are numeric and `token` is the older of the two.
  static func isNumeric(_ token: String, lowerThan other: String) -> Bool {
    guard isNumeric(token), isNumeric(other), let lhs = UInt64(token), let rhs = UInt64(other)
    else { return false }
    return lhs < rhs
  }

  private static func hashPrefix(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
}

/// What one sweep removed.
public struct CoverCachePruneSummary: Sendable, Equatable {
  public var removedItemDirectories = 0
  public var removedFiles = 0
  public var removedScopes = 0
  public var removedBytes: Int64 = 0
  /// True when a guard stopped the sweep before it looked at any item.
  public var skipped = false

  public init() {}
}

/// Compressed ABS covers, one file per cover.
///
/// `store-v1/{scope}/{item}/{format}-{width}-{revision}` under a root in Caches. A file per cover
/// makes presence, size, the stale-revision sweep and a clear plain file operations, which a
/// `URLCache` cannot do as it cannot list its contents. Disposable: a deletion costs a refetch.
///
/// Reads take no lock: a write is a rename into place, so a reader sees the old file, the new one,
/// or none. Mutations are serialised by `lock`; the unchecked conformance covers that state and the
/// thread-safe legacy `URLCache`.
final class CoverFileStore: @unchecked Sendable {
  static let defaultMemoryCapacity = 20 * 1024 * 1024
  /// How stale a file's modification date may get before a read refreshes it. The sweep only needs
  /// day precision, so a scroll over covers already read today writes nothing.
  static let lastUseGranularity: TimeInterval = 24 * 60 * 60
  /// Twice `lastUseGranularity`: a file read every day never looks older than this.
  static let recentUseWindow: TimeInterval = 2 * lastUseGranularity
  static let legacyRetirementAge: TimeInterval = 30 * 24 * 60 * 60
  private static let legacyDiskCapacity = 1 * 1024 * 1024 * 1024
  private static let generationPrefix = "generation-"

  private let root: URL?
  private let memoryCapacity: Int
  private let lock = NSLock()
  private var memory: [CoverStoreKey: Data] = [:]
  private var memoryOrder: [CoverStoreKey] = []
  private var memoryBytes = 0
  private var legacy: URLCache?

  // MARK: Construction

  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var registry: [String: CoverFileStore] = [:]

  /// One store per root for the life of the process, so two clients over the same directory share
  /// one lock and a clear by either is seen by both.
  static func shared(root: URL) -> CoverFileStore {
    let key = root.standardizedFileURL.path
    return registryLock.withLock {
      if let existing = registry[key] { return existing }
      let store = CoverFileStore(root: root)
      registry[key] = store
      return store
    }
  }

  /// Directory-backed. `legacy` overrides the old `URLCache` that would otherwise be opened over
  /// the root when one is found there.
  init(root: URL, legacy: URLCache? = nil, now: Date = Date()) {
    self.root = root
    memoryCapacity = 0
    try? FileManager.default.createDirectory(at: storeURL(root), withIntermediateDirectories: true)
    self.legacy = legacy ?? Self.openLegacyCache(under: root)
    let created =
      (try? storeURL(root).resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
    if now.timeIntervalSince(created) > Self.legacyRetirementAge { retireLegacyCache() }
  }

  /// Memory-only: nothing touches the disk. Used by the Watch, the UI harness and tests.
  init(memoryCapacity: Int) {
    root = nil
    self.memoryCapacity = max(0, memoryCapacity)
  }

  private func storeURL(_ root: URL) -> URL {
    root.appendingPathComponent(CoverStoreNaming.storeDirectory, isDirectory: true)
  }

  private func fileURL(for key: CoverStoreKey) -> URL? {
    root.map {
      storeURL($0)
        .appendingPathComponent(key.scopeDirectory, isDirectory: true)
        .appendingPathComponent(key.itemDirectory, isDirectory: true)
        .appendingPathComponent(key.fileName, isDirectory: false)
    }
  }

  // MARK: Read

  func contains(_ key: CoverStoreKey) -> Bool {
    guard let url = fileURL(for: key) else {
      return lock.withLock { memory[key] != nil }
    }
    return FileManager.default.fileExists(atPath: url.path)
  }

  func data(for key: CoverStoreKey, now: Date = Date()) -> Data? {
    guard let url = fileURL(for: key) else {
      return lock.withLock { memory[key] }
    }
    guard
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
      let size = values.fileSize
    else { return nil }
    guard size <= CoverImageAdmission.maximumResponseBytes else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    if let modified = values.contentModificationDate,
      now.timeIntervalSince(modified) > Self.lastUseGranularity
    {
      try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }
    return data
  }

  // MARK: Write

  /// Stores already-admitted bytes. A numeric revision removes the item's older numeric revisions
  /// at every width; other stale files are left to the sweep.
  func write(_ data: Data, for key: CoverStoreKey) {
    guard let url = fileURL(for: key) else {
      lock.withLock { writeToMemory(data, for: key) }
      return
    }
    let directory = url.deletingLastPathComponent()
    let fileManager = FileManager.default
    lock.withLock {
      try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let temporary = directory.appendingPathComponent(
        CoverStoreNaming.temporaryPrefix + UUID().uuidString, isDirectory: false)
      // `rename(2)` replaces the destination atomically, so a reader never sees a partial file.
      guard (try? data.write(to: temporary)) != nil, rename(temporary.path, url.path) == 0 else {
        try? fileManager.removeItem(at: temporary)
        return
      }
      let token = CoverStoreNaming.revisionToken(key.revision)
      guard CoverStoreNaming.isNumeric(token) else { return }
      for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
        guard let parsed = CoverStoreNaming.parse(fileName: name),
          CoverStoreNaming.isNumeric(parsed.revisionToken, lowerThan: token)
        else { continue }
        try? fileManager.removeItem(at: directory.appendingPathComponent(name))
      }
    }
  }

  private func writeToMemory(_ data: Data, for key: CoverStoreKey) {
    guard data.count <= memoryCapacity else { return }
    if let existing = memory.removeValue(forKey: key) {
      memoryBytes -= existing.count
      memoryOrder.removeAll { $0 == key }
    }
    memory[key] = data
    memoryOrder.append(key)
    memoryBytes += data.count
    while memoryBytes > memoryCapacity, memoryOrder.isEmpty == false {
      let evicted = memoryOrder.removeFirst()
      memoryBytes -= memory.removeValue(forKey: evicted)?.count ?? 0
    }
  }

  // MARK: Clear

  /// Removes every cover under the root, the old `URLCache` files included, and stops consulting
  /// the old cache: it would otherwise hand back covers the user just cleared.
  func clear() {
    lock.withLock {
      memory.removeAll()
      memoryOrder.removeAll()
      memoryBytes = 0
      legacy?.removeAllCachedResponses()
      legacy = nil
      guard let root else { return }
      let fileManager = FileManager.default
      for entry in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
        ?? []
      {
        try? fileManager.removeItem(at: entry)
      }
      try? fileManager.createDirectory(at: storeURL(root), withIntermediateDirectories: true)
    }
  }

  // MARK: Legacy URLCache

  /// The cover stored by a build that kept covers in a `URLCache`, under the first of `requests`
  /// that has one. An entry that fails admission is evicted rather than returned.
  func takeLegacyCover(for requests: [URLRequest]) -> CoverImageResult? {
    lock.withLock {
      guard let legacy else { return nil }
      for request in requests {
        guard let cached = legacy.cachedResponse(for: request) else { continue }
        legacy.removeCachedResponse(for: request)
        if let admitted = try? CoverImageAdmission.admit(
          data: cached.data, contentType: cached.response.mimeType)
        {
          return admitted
        }
      }
      return nil
    }
  }

  /// Deletes the old cache's files. Called once a bulk pass has moved everything it wants into the
  /// store, and at open once the store is 30 days old.
  func retireLegacyCache() {
    lock.withLock {
      legacy?.removeAllCachedResponses()
      legacy = nil
      guard let root else { return }
      let fileManager = FileManager.default
      for entry in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
        ?? []
      where entry.lastPathComponent != CoverStoreNaming.storeDirectory {
        try? fileManager.removeItem(at: entry)
      }
    }
  }

  var hasLegacyCacheForTesting: Bool { lock.withLock { legacy != nil } }

  /// Opens the old cache only where one exists: `URLCache` creates its database on open, and a
  /// fresh install has nothing to migrate. The old layout is the root itself, or its newest
  /// `generation-*` subdirectory once a clear had run.
  private static func openLegacyCache(under root: URL) -> URLCache? {
    let fileManager = FileManager.default
    let generations =
      ((try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix(generationPrefix) }
    let live = generations.max { $0.lastPathComponent < $1.lastPathComponent } ?? root
    guard fileManager.fileExists(atPath: live.appendingPathComponent("Cache.db").path) else {
      return nil
    }
    return URLCache(memoryCapacity: 0, diskCapacity: legacyDiskCapacity, directory: live)
  }

  // MARK: Sweep

  /// Removes what nothing will ask for again.
  ///
  /// - `live`: item directory → current revision token, for every item the account still has.
  /// - `keep`: `{item}/{file}` paths that are never removed for being unread.
  ///
  /// Within `scopeDirectory`: an item directory not in `live` goes unless it changed within
  /// `recentUseWindow` (inserted after the snapshot); a file of another revision goes at once if an
  /// older numeric revision, else once unread for `recentUseWindow`; a file outside `keep` goes
  /// once unread for `unlistedOlderThan`. Any other scope goes once nothing in it has been used for
  /// `unlistedOlderThan`. Last, while over `byteCeiling`, the least recently read files outside
  /// `keep` go.
  ///
  /// Does nothing when `live` is empty or names fewer than half the directories present, which is
  /// what a reset or half-synced database looks like.
  func prune(
    scopeDirectory: String,
    live: [String: String],
    keep: Set<String>,
    unlistedOlderThan: TimeInterval,
    byteCeiling: Int64,
    now: Date = Date()
  ) -> CoverCachePruneSummary {
    var summary = CoverCachePruneSummary()
    guard let root else { return summary }
    let fileManager = FileManager.default
    let scopeURL = storeURL(root).appendingPathComponent(scopeDirectory, isDirectory: true)
    let itemDirectories = (try? fileManager.contentsOfDirectory(atPath: scopeURL.path)) ?? []
    let known = itemDirectories.filter { live[$0] != nil }.count
    guard live.isEmpty == false, known * 2 >= itemDirectories.count else {
      summary.skipped = true
      return summary
    }

    var survivors: [(url: URL, bytes: Int64, lastUse: Date)] = []
    for item in itemDirectories {
      let itemURL = scopeURL.appendingPathComponent(item, isDirectory: true)
      lock.withLock {
        guard let current = live[item] else {
          guard age(of: itemURL, now: now) > Self.recentUseWindow else { return }
          summary.removedBytes += allocatedBytes(under: itemURL)
          if (try? fileManager.removeItem(at: itemURL)) != nil { summary.removedItemDirectories += 1 }
          return
        }
        for name in (try? fileManager.contentsOfDirectory(atPath: itemURL.path)) ?? [] {
          let url = itemURL.appendingPathComponent(name, isDirectory: false)
          let unread = age(of: url, now: now)
          let stale: Bool
          if let parsed = CoverStoreNaming.parse(fileName: name) {
            if parsed.revisionToken != current {
              stale =
                CoverStoreNaming.isNumeric(parsed.revisionToken, lowerThan: current)
                || unread > Self.recentUseWindow
            } else {
              stale = keep.contains(item + "/" + name) == false && unread > unlistedOlderThan
            }
          } else {
            // A temporary file whose write never finished.
            stale = unread > Self.recentUseWindow
          }
          let bytes = allocatedBytes(of: url)
          if stale {
            if (try? fileManager.removeItem(at: url)) != nil {
              summary.removedFiles += 1
              summary.removedBytes += bytes
            }
          } else if keep.contains(item + "/" + name) == false {
            survivors.append((url, bytes, now.addingTimeInterval(-unread)))
          }
        }
      }
    }

    for scope in (try? fileManager.contentsOfDirectory(atPath: storeURL(root).path)) ?? []
    where scope != scopeDirectory {
      let url = storeURL(root).appendingPathComponent(scope, isDirectory: true)
      lock.withLock {
        guard newestUse(under: url, now: now) > unlistedOlderThan else { return }
        summary.removedBytes += allocatedBytes(under: url)
        if (try? fileManager.removeItem(at: url)) != nil { summary.removedScopes += 1 }
      }
    }

    var total = allocatedBytes(under: storeURL(root))
    if total > byteCeiling {
      for candidate in survivors.sorted(by: { $0.lastUse < $1.lastUse }) where total > byteCeiling {
        lock.withLock {
          guard (try? fileManager.removeItem(at: candidate.url)) != nil else { return }
          total -= candidate.bytes
          summary.removedFiles += 1
          summary.removedBytes += candidate.bytes
        }
      }
    }
    return summary
  }

  /// Seconds since the entry was last written or, for a cover, last read.
  private func age(of url: URL, now: Date) -> TimeInterval {
    let modified =
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    return modified.map { now.timeIntervalSince($0) } ?? .infinity
  }

  /// The age of the most recently used entry in a scope, counting its directories too.
  private func newestUse(under url: URL, now: Date) -> TimeInterval {
    var newest = age(of: url, now: now)
    let enumerator = FileManager.default.enumerator(
      at: url, includingPropertiesForKeys: [.contentModificationDateKey])
    while let entry = enumerator?.nextObject() as? URL {
      newest = min(newest, age(of: entry, now: now))
    }
    return newest
  }

  private func allocatedBytes(of url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
    return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
  }

  private func allocatedBytes(under url: URL) -> Int64 {
    var total: Int64 = 0
    let enumerator = FileManager.default.enumerator(
      at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
    while let entry = enumerator?.nextObject() as? URL {
      guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
        continue
      }
      total += allocatedBytes(of: entry)
    }
    return total
  }
}
