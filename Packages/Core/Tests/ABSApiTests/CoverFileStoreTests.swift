import Foundation
import Testing

@testable import ABSApi

@Suite("CoverFileStore")
struct CoverFileStoreTests {
  private static let scope = ArtworkAccountScope("abs:namespace-1#account=1")
  private static let day: TimeInterval = 24 * 60 * 60

  // MARK: Storage

  @Test("bytes round-trip and presence needs no read")
  func roundTripAndPresence() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let key = Self.key("0b3f1c2a-item", width: 420, revision: "1700000000000")

    #expect(store.contains(key) == false)
    #expect(store.data(for: key) == nil)
    store.write(Data("cover".utf8), for: key)

    #expect(store.contains(key))
    #expect(store.data(for: key) == Data("cover".utf8))
    #expect(CoverFileStore(root: root.url).data(for: key) == Data("cover".utf8))
  }

  @Test("a full-size cover with no width is stored and found")
  func nilWidth() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let key = Self.key("item-1", width: nil, revision: "5")
    store.write(Data("full".utf8), for: key)

    #expect(store.data(for: key) == Data("full".utf8))
    #expect(key.fileName == "webp-full-5")
  }

  @Test("a newer numeric revision removes older ones at every width, never the reverse")
  func newerNumericRevisionEvictsOlder() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let oldThumb = Self.key("item-1", width: 132, revision: "100")
    let oldCard = Self.key("item-1", width: 420, revision: "100")
    let newCard = Self.key("item-1", width: 420, revision: "200")
    store.write(Data("a".utf8), for: oldThumb)
    store.write(Data("b".utf8), for: oldCard)

    store.write(Data("c".utf8), for: newCard)
    #expect(store.contains(oldThumb) == false)
    #expect(store.contains(oldCard) == false)
    #expect(store.contains(newCard))

    // A late write of the older revision neither survives a later newer write nor removes it now.
    store.write(Data("d".utf8), for: oldThumb)
    #expect(store.contains(newCard))
  }

  @Test("a non-numeric revision neither evicts nor is evicted on write")
  func nonNumericRevisionsAreLeftToTheSweep() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let unversioned = Self.key("item-1", width: 132, revision: ArtworkRevision.unversioned.rawValue)
    let opaque = Self.key("item-1", width: 132, revision: "etag-abc")
    let numeric = Self.key("item-1", width: 132, revision: "200")
    store.write(Data("u".utf8), for: unversioned)
    store.write(Data("o".utf8), for: opaque)
    store.write(Data("n".utf8), for: numeric)
    store.write(Data("o".utf8), for: opaque)

    #expect(store.contains(unversioned))
    #expect(store.contains(opaque))
    #expect(store.contains(numeric))
  }

  @Test(
    "a hostile revision never becomes a path component",
    arguments: ["..", "../../escape", "a/b", ".hidden", String(repeating: "9", count: 400), ""])
  func hostileRevisionStaysInsideTheItemDirectory(_ raw: String) throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let key = Self.key("item-1", width: 132, revision: raw)
    store.write(Data("x".utf8), for: key)

    #expect(store.data(for: key) == Data("x".utf8))
    #expect(key.fileName.contains("/") == false)
    #expect(key.fileName.contains("..") == false)
    #expect(key.fileName.utf8.count < 80)
    let itemDirectory = root.url.appendingPathComponent(
      "store-v1/\(key.scopeDirectory)/\(key.itemDirectory)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: itemDirectory.path).count == 1)
  }

  @Test(
    "an awkward item ID is stored and found under a safe directory name",
    arguments: [".leading-dot", String(repeating: "a", count: 300), "Item-1", "h-0123", "a_b~c"])
  func awkwardItemIDs(_ itemID: String) throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let key = Self.key(itemID, width: 132, revision: "1")
    store.write(Data(itemID.utf8), for: key)

    #expect(store.data(for: key) == Data(itemID.utf8))
    #expect(key.itemDirectory.hasPrefix("h-"))
    #expect(key.itemDirectory.utf8.count == 34)
  }

  @Test("item IDs that differ only by case do not share a directory")
  func caseDistinctItemIDs() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let lower = Self.key("item-1", width: 132, revision: "1")
    let upper = Self.key("ITEM-1", width: 132, revision: "1")
    store.write(Data("lower".utf8), for: lower)
    store.write(Data("upper".utf8), for: upper)

    #expect(store.data(for: lower) == Data("lower".utf8))
    #expect(store.data(for: upper) == Data("upper".utf8))
    #expect(lower.itemDirectory.lowercased() != upper.itemDirectory.lowercased())
  }

  @Test("a temporary file from an interrupted write is never served")
  func interruptedTemporaryFileIsNotServed() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let key = Self.key("item-1", width: 132, revision: "1")
    let directory = root.url.appendingPathComponent(
      "store-v1/\(key.scopeDirectory)/\(key.itemDirectory)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: directory.appendingPathComponent("tmp-interrupted"))

    #expect(store.contains(key) == false)
    #expect(store.data(for: key) == nil)
  }

  @Test("memory-only mode writes nothing to disk and evicts oldest first")
  func memoryOnly() throws {
    let store = CoverFileStore(memoryCapacity: 10)
    let first = Self.key("item-1", width: 132, revision: "1")
    let second = Self.key("item-2", width: 132, revision: "1")
    store.write(Data(repeating: 1, count: 6), for: first)
    store.write(Data(repeating: 2, count: 6), for: second)

    #expect(store.contains(first) == false)
    #expect(store.data(for: second) == Data(repeating: 2, count: 6))
    store.write(Data(repeating: 3, count: 11), for: first)
    #expect(store.contains(first) == false)
    store.clear()
    #expect(store.contains(second) == false)
  }

  @Test("a read refreshes the last-use date at most once a day")
  func lastUseIsRefreshedDaily() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let key = Self.key("item-1", width: 132, revision: "1")
    store.write(Data("x".utf8), for: key)
    let url = root.fileURL(for: key)
    let now = Date()
    try Self.setModified(url, now.addingTimeInterval(-3 * Self.day))

    _ = store.data(for: key, now: now)
    let refreshed = try #require(Self.modified(url))
    #expect(abs(refreshed.timeIntervalSince(now)) < 5)

    let recent = now.addingTimeInterval(-3600)
    try Self.setModified(url, recent)
    _ = store.data(for: key, now: now)
    #expect(abs(try #require(Self.modified(url)).timeIntervalSince(recent)) < 5)
  }

  // MARK: Clear and the old cache

  @Test("a clear removes the store, the old cache's files and generation directories")
  func clearRemovesEverythingUnderTheRoot() throws {
    let root = try TemporaryRoot()
    let fileManager = FileManager.default
    try Data("db".utf8).write(to: root.url.appendingPathComponent("Cache.db-wal"))
    try fileManager.createDirectory(
      at: root.url.appendingPathComponent("fsCachedData"), withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: root.url.appendingPathComponent("generation-000000000000001-x"),
      withIntermediateDirectories: true)
    let store = CoverFileStore(root: root.url)
    let key = Self.key("item-1", width: 132, revision: "1")
    store.write(Data("x".utf8), for: key)

    store.clear()

    #expect(try fileManager.contentsOfDirectory(atPath: root.url.path) == ["store-v1"])
    #expect(store.contains(key) == false)
    store.write(Data("y".utf8), for: key)
    #expect(store.data(for: key) == Data("y".utf8))
  }

  @Test("retiring the old cache removes its files and keeps the store")
  func retireLegacyKeepsTheStore() throws {
    let root = try TemporaryRoot()
    try Data("db".utf8).write(to: root.url.appendingPathComponent("Cache.db-shm"))
    let store = CoverFileStore(
      root: root.url, legacy: URLCache(memoryCapacity: 1024, diskCapacity: 0, directory: nil))
    let key = Self.key("item-1", width: 132, revision: "1")
    store.write(Data("x".utf8), for: key)

    store.retireLegacyCache()

    #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path) == ["store-v1"])
    #expect(store.hasLegacyCacheForTesting == false)
    #expect(store.contains(key))
  }

  @Test("no old cache is opened, or created, where none exists")
  func noLegacyCacheOnAFreshInstall() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)

    #expect(store.hasLegacyCacheForTesting == false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path) == ["store-v1"])
  }

  @Test("the old cache is retired once the store is thirty days old")
  func legacyRetiredAfterThirtyDays() throws {
    let root = try TemporaryRoot()
    try Data("db".utf8).write(to: root.url.appendingPathComponent("Cache.db-shm"))
    let legacy = URLCache(memoryCapacity: 1024, diskCapacity: 0, directory: nil)
    #expect(CoverFileStore(root: root.url, legacy: legacy).hasLegacyCacheForTesting)

    let later = CoverFileStore(
      root: root.url, legacy: legacy, now: Date().addingTimeInterval(31 * Self.day))
    #expect(later.hasLegacyCacheForTesting == false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path) == ["store-v1"])
  }

  // MARK: Sweep

  @Test("the sweep removes an unknown item, an old revision and an unread unlisted file")
  func pruneRemovesStaleEntries() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let now = Date()
    let kept = Self.key("item-1", width: 132, revision: "200")
    let unlistedOld = Self.key("item-1", width: 96, revision: "200")
    let unlistedRecent = Self.key("item-1", width: 168, revision: "200")
    let listedOld = Self.key("item-1", width: 420, revision: "200")
    let gone = Self.key("item-deleted", width: 132, revision: "200")
    for key in [kept, unlistedOld, unlistedRecent, listedOld, gone] {
      store.write(Data(repeating: 7, count: 100), for: key)
    }
    // An older revision that write-time eviction never saw, as after a crash or a clock change.
    let oldRevisionURL = root.fileURL(for: Self.key("item-1", width: 132, revision: "100"))
    try Data("old".utf8).write(to: oldRevisionURL)
    try Self.setModified(root.fileURL(for: unlistedOld), now.addingTimeInterval(-40 * Self.day))
    try Self.setModified(root.fileURL(for: listedOld), now.addingTimeInterval(-40 * Self.day))
    try Self.setModified(
      root.fileURL(for: gone).deletingLastPathComponent(), now.addingTimeInterval(-3 * Self.day))

    let summary = store.prune(
      scopeDirectory: kept.scopeDirectory, live: [kept.itemDirectory: "200"],
      keep: [kept.relativePath, listedOld.relativePath], unlistedOlderThan: 30 * Self.day,
      byteCeiling: .max, now: now)

    #expect(summary.skipped == false)
    #expect(summary.removedItemDirectories == 1)
    #expect(summary.removedFiles == 2)
    #expect(store.contains(kept))
    #expect(store.contains(listedOld))
    #expect(store.contains(unlistedRecent))
    #expect(store.contains(unlistedOld) == false)
    #expect(store.contains(gone) == false)
    #expect(FileManager.default.fileExists(atPath: oldRevisionURL.path) == false)
  }

  @Test("a file of an unrecognised revision survives while it is still being read")
  func pruneSparesRecentlyReadForeignRevisions() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let now = Date()
    let current = Self.key("item-1", width: 132, revision: "200")
    let unversionedRecent = Self.key("item-1", width: 420, revision: "unversioned")
    let newerThanSnapshot = Self.key("item-1", width: 132, revision: "300")
    let unversionedOld = Self.key("item-1", width: 96, revision: "unversioned")
    for key in [current, unversionedRecent, unversionedOld] {
      store.write(Data("x".utf8), for: key)
    }
    try Data("x".utf8).write(to: root.fileURL(for: newerThanSnapshot))
    try Self.setModified(root.fileURL(for: unversionedOld), now.addingTimeInterval(-3 * Self.day))

    _ = store.prune(
      scopeDirectory: current.scopeDirectory, live: [current.itemDirectory: "200"],
      keep: [], unlistedOlderThan: 30 * Self.day, byteCeiling: .max, now: now)

    #expect(store.contains(unversionedRecent))
    #expect(store.contains(newerThanSnapshot))
    #expect(store.contains(unversionedOld) == false)
  }

  @Test("an empty item list deletes nothing")
  func pruneWithEmptyLiveDoesNothing() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let key = Self.key("item-1", width: 132, revision: "1")
    store.write(Data("x".utf8), for: key)
    try Self.setModified(
      root.fileURL(for: key).deletingLastPathComponent(), Date().addingTimeInterval(-9 * Self.day))

    let summary = store.prune(
      scopeDirectory: key.scopeDirectory, live: [:], keep: [], unlistedOlderThan: 0,
      byteCeiling: 0)

    #expect(summary.skipped)
    #expect(store.contains(key))
  }

  @Test("an item list covering under half of the directories deletes nothing")
  func pruneWithHalfSyncedLiveDoesNothing() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let keys = (1...5).map { Self.key("item-\($0)", width: 132, revision: "1") }
    for key in keys {
      store.write(Data("x".utf8), for: key)
      try Self.setModified(
        root.fileURL(for: key).deletingLastPathComponent(),
        Date().addingTimeInterval(-9 * Self.day))
    }

    let summary = store.prune(
      scopeDirectory: keys[0].scopeDirectory,
      live: [keys[0].itemDirectory: "1", keys[1].itemDirectory: "1"], keep: [],
      unlistedOlderThan: 30 * Self.day, byteCeiling: .max)

    #expect(summary.skipped)
    #expect(keys.allSatisfy(store.contains))
  }

  @Test("an unknown item written since the snapshot survives")
  func pruneSparesAFreshUnknownDirectory() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let known = Self.key("item-1", width: 132, revision: "1")
    let fresh = Self.key("item-new", width: 132, revision: "1")
    store.write(Data("x".utf8), for: known)
    store.write(Data("x".utf8), for: fresh)

    let summary = store.prune(
      scopeDirectory: known.scopeDirectory, live: [known.itemDirectory: "1"],
      keep: [known.relativePath], unlistedOlderThan: 30 * Self.day, byteCeiling: .max)

    #expect(summary.removedItemDirectories == 0)
    #expect(store.contains(fresh))
  }

  @Test("another login's scope is removed once nothing in it has been used for the window")
  func pruneRemovesAStaleSiblingScope() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let now = Date()
    let mine = Self.key("item-1", width: 132, revision: "1")
    let stale = Self.key(
      "item-1", width: 132, revision: "1", scope: ArtworkAccountScope("previous-login"))
    let recent = Self.key(
      "item-1", width: 132, revision: "1", scope: ArtworkAccountScope("other-recent"))
    for key in [mine, stale, recent] { store.write(Data("x".utf8), for: key) }
    var url = root.fileURL(for: stale)
    for _ in 0..<3 {
      try Self.setModified(url, now.addingTimeInterval(-40 * Self.day))
      url = url.deletingLastPathComponent()
    }

    let summary = store.prune(
      scopeDirectory: mine.scopeDirectory, live: [mine.itemDirectory: "1"],
      keep: [mine.relativePath], unlistedOlderThan: 30 * Self.day, byteCeiling: .max, now: now)

    #expect(summary.removedScopes == 1)
    #expect(store.contains(stale) == false)
    #expect(store.contains(recent))
    #expect(store.contains(mine))
  }

  @Test("the backstop removes least-recently-read unlisted files and never a listed one")
  func pruneBackstop() throws {
    let root = try TemporaryRoot()
    let store = CoverFileStore(root: root.url)
    let now = Date()
    let listed = Self.key("item-1", width: 420, revision: "1")
    let older = Self.key("item-1", width: 96, revision: "1")
    let newer = Self.key("item-1", width: 168, revision: "1")
    for key in [listed, older, newer] {
      store.write(Data(repeating: 7, count: 64 * 1024), for: key)
    }
    try Self.setModified(root.fileURL(for: listed), now.addingTimeInterval(-20 * Self.day))
    try Self.setModified(root.fileURL(for: older), now.addingTimeInterval(-10 * Self.day))
    try Self.setModified(root.fileURL(for: newer), now.addingTimeInterval(-5 * Self.day))

    let summary = store.prune(
      scopeDirectory: listed.scopeDirectory, live: [listed.itemDirectory: "1"],
      keep: [listed.relativePath], unlistedOlderThan: 30 * Self.day, byteCeiling: 140 * 1024,
      now: now)

    #expect(summary.removedFiles == 1)
    #expect(store.contains(older) == false)
    #expect(store.contains(newer))
    #expect(store.contains(listed))
  }

  // MARK: Helpers

  private static func key(
    _ itemID: String, width: Int?, revision: String, scope: ArtworkAccountScope = scope
  ) -> CoverStoreKey {
    CoverStoreKey(
      scope: scope, itemID: itemID, width: width, revision: ArtworkRevision(revision),
      format: .webp)
  }

  private static func setModified(_ url: URL, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }

  private static func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }
}

/// A root directory removed when the test ends.
private final class TemporaryRoot {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CoverFileStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  func fileURL(for key: CoverStoreKey) -> URL {
    url.appendingPathComponent("store-v1/\(key.scopeDirectory)/\(key.itemDirectory)/\(key.fileName)")
  }
}
