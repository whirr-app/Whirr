import CryptoKit
import Foundation
import WatchProtocol

/// Disposable compressed thumbnails, bounded by bytes and record count; no decoded images. Each
/// cover is a raw image file named by its key's hash, and one index file describes them all, so
/// opening never reads the covers. Two tiers share the directory: on-demand covers (download
/// covers evicted last, though the hard budget takes precedence) and phone-pushed covers, which
/// have their own budget and are never evicted for on-demand ones.
public actor WatchArtworkCache {
  public struct Key: Codable, Hashable, Sendable {
    public let accountStamp: WatchAccountStamp
    public let reference: WatchArtworkReference
    public let size: WatchArtworkSize
    public init(accountStamp: WatchAccountStamp, reference: WatchArtworkReference, size: WatchArtworkSize) {
      self.accountStamp = accountStamp
      self.reference = reference
      self.size = size
    }
  }
  private struct Entry: Codable {
    let key: Key
    let bytes: Int
    let savedAt: Date
    var usedAt: Date
    var synced: Bool
  }
  private struct Index: Codable {
    static let currentVersion = 2
    let version: Int
    let entries: [Entry]
  }
  /// The index is rewritten at most this often; a crash in between leaves image files with no
  /// entry, which the next open deletes.
  static let indexWriteDelay: Duration = .seconds(1)
  private static let indexName = "index.json"
  private static let imageExtension = "jpg"
  /// An unversioned cover may be replaced on the server; a versioned one changes key instead.
  private static let unversionedRefreshAge: TimeInterval = 24 * 60 * 60

  private let directory: URL
  private let legacyDirectories: [URL]
  private let byteLimit: Int
  private let recordLimit: Int
  private let syncedByteLimit: Int
  private let syncedRecordLimit: Int
  private var entries: [String: Entry] = [:]
  private var allowedAccounts: Set<WatchAccountStamp> = []
  private var pinned: Set<Key> = []
  private var loaded = false
  private var indexWrite: Task<Void, Never>?
  public var storedByteCount: Int { entries.values.reduce(0) { $0 + $1.bytes } }

  public init(
    directory: URL, legacyDirectories: [URL] = [], byteLimit: Int = 16 * 1024 * 1024, recordLimit: Int = 512,
    syncedByteLimit: Int = 48 * 1024 * 1024, syncedRecordLimit: Int = WatchArtworkSyncLimits.maxManifestCovers
  ) {
    self.directory = directory
    self.legacyDirectories = legacyDirectories
    self.byteLimit = max(1, byteLimit)
    self.recordLimit = max(1, recordLimit)
    self.syncedByteLimit = max(1, syncedByteLimit)
    self.syncedRecordLimit = max(1, syncedRecordLimit)
  }

  /// Replaces the admitted accounts and deletes every other account's covers. Only the owner of
  /// the current session calls this.
  public func retainAccounts(_ accounts: Set<WatchAccountStamp>) {
    allowedAccounts = accounts
    openIfNeeded()
    for (id, entry) in entries where !accounts.contains(entry.key.accountStamp) { remove(id) }
    trim()
    flush()
  }

  /// Admits one more account without deleting any other: the sync receiver uses it for the phone's
  /// catalogue stamp, which the next `retainAccounts` keeps or drops.
  public func admit(_ account: WatchAccountStamp) {
    openIfNeeded()
    allowedAccounts.insert(account)
  }

  public func setPinned(_ keys: Set<Key>) { pinned = keys }

  public func data(for key: Key) -> Data? {
    guard allowedAccounts.contains(key.accountStamp) else { return nil }
    let id = identifier(key)
    guard var entry = entries[id], entry.key == key, let data = try? Data(contentsOf: url(id)) else { return nil }
    entry.usedAt = Date()
    entries[id] = entry
    return data
  }

  public func needsRefresh(_ key: Key, now: Date = Date()) -> Bool {
    guard let entry = entries[identifier(key)] else { return true }
    guard key.reference.revision == WatchArtworkReference.unversioned else { return false }
    return now.timeIntervalSince(entry.savedAt) > Self.unversionedRefreshAge
  }

  /// Stores an on-demand cover. A refresh of a cover the phone pushed keeps it in the synced tier.
  @discardableResult
  public func store(_ data: Data, for key: Key, now: Date = Date()) -> Bool {
    write(data, for: key, synced: entries[identifier(key)]?.synced == true, now: now)
  }

  /// Stores a cover the phone pushed, moving it out of the on-demand tier if it was there.
  @discardableResult
  public func storeSynced(_ data: Data, for key: Key, now: Date = Date()) -> Bool {
    write(data, for: key, synced: true, now: now)
  }

  public func syncedKeys(accountStamp: WatchAccountStamp) -> Set<Key> {
    Set(entries.values.lazy.filter { $0.synced && $0.key.accountStamp == accountStamp }.map(\.key))
  }

  /// Removes these keys only where they are synced covers; on-demand covers are left alone.
  public func removeSynced(_ keys: Set<Key>) {
    for key in keys {
      let id = identifier(key)
      if entries[id]?.synced == true { remove(id) }
    }
  }

  private func write(_ data: Data, for key: Key, synced: Bool, now: Date) -> Bool {
    guard allowedAccounts.contains(key.accountStamp), !data.isEmpty,
      data.count <= min(synced ? syncedByteLimit : byteLimit, WatchArtworkReply.maxImageBytes),
      (try? key.accountStamp.validate()) != nil, (try? key.reference.validate()) != nil
    else { return false }
    let id = identifier(key)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url(id), options: .atomic)
    } catch { return false }
    entries[id] = Entry(key: key, bytes: data.count, savedAt: now, usedAt: now, synced: synced)
    trim()
    scheduleIndexWrite()
    return entries[id] != nil
  }

  /// Writes the index now rather than at the next scheduled write.
  public func flush() {
    indexWrite?.cancel()
    indexWrite = nil
    guard loaded else { return }
    let index = Index(version: Index.currentVersion, entries: Array(entries.values))
    guard let encoded = try? JSONEncoder().encode(index) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? encoded.write(to: directory.appendingPathComponent(Self.indexName), options: .atomic)
  }

  func fileURL(for key: Key) -> URL { url(identifier(key)) }

  private func openIfNeeded() {
    guard !loaded else { return }
    loaded = true
    open()
  }

  private func open() {
    for legacy in legacyDirectories { try? FileManager.default.removeItem(at: legacy) }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let index = (try? Data(contentsOf: directory.appendingPathComponent(Self.indexName)))
      .flatMap { try? JSONDecoder().decode(Index.self, from: $0) }
      .flatMap { $0.version == Index.currentVersion ? $0 : nil }
    let files =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]))
      ?? []
    var sizes: [String: Int] = [:]
    for file in files where file.lastPathComponent != Self.indexName {
      let id = file.deletingPathExtension().lastPathComponent
      if file.pathExtension == Self.imageExtension,
        let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
      {
        sizes[id] = size
      } else {
        try? FileManager.default.removeItem(at: file)
      }
    }
    for entry in index?.entries ?? [] {
      let id = identifier(entry.key)
      guard sizes[id] == entry.bytes, entry.bytes <= WatchArtworkReply.maxImageBytes,
        (try? entry.key.accountStamp.validate()) != nil, (try? entry.key.reference.validate()) != nil,
        entry.savedAt.timeIntervalSinceReferenceDate.isFinite
      else { continue }
      entries[id] = entry
    }
    for id in sizes.keys where entries[id] == nil { try? FileManager.default.removeItem(at: url(id)) }
  }

  private func scheduleIndexWrite() {
    guard indexWrite == nil else { return }
    indexWrite = Task { [weak self] in
      try? await Task.sleep(for: Self.indexWriteDelay)
      guard !Task.isCancelled else { return }
      await self?.flush()
    }
  }

  private func trim() {
    trim(synced: false, byteLimit: byteLimit, recordLimit: recordLimit)
    trim(synced: true, byteLimit: syncedByteLimit, recordLimit: syncedRecordLimit)
  }

  private func trim(synced: Bool, byteLimit: Int, recordLimit: Int) {
    var tier = entries.filter { $0.value.synced == synced }
    var bytes = tier.values.reduce(0) { $0 + $1.bytes }
    while bytes > byteLimit || tier.count > recordLimit {
      let candidate = tier.min { lhs, rhs in
        let lp = pinned.contains(lhs.value.key)
        let rp = pinned.contains(rhs.value.key)
        if lp != rp { return !lp }
        return lhs.value.usedAt < rhs.value.usedAt
      }
      guard let candidate else { return }
      tier.removeValue(forKey: candidate.key)
      bytes -= candidate.value.bytes
      remove(candidate.key)
    }
  }

  private func remove(_ id: String) {
    entries.removeValue(forKey: id)
    try? FileManager.default.removeItem(at: url(id))
    scheduleIndexWrite()
  }
  private func url(_ id: String) -> URL {
    directory.appendingPathComponent(id).appendingPathExtension(Self.imageExtension)
  }
  private func identifier(_ key: Key) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = (try? encoder.encode(key)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
