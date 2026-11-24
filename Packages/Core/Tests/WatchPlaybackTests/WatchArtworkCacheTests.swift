import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

struct WatchArtworkCacheTests {
  @Test func accountSourceAndSizeAreIsolatedAndDiskSurvivesRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try WatchAccountStamp(accountIdentityHash: "a", serverIdentityHash: "s")
    let b = try WatchAccountStamp(accountIdentityHash: "b", serverIdentityHash: "s")
    let art = WatchArtworkReference(selection: .audiobookshelf(itemID: "42", episodeID: nil))
    let key = WatchArtworkCache.Key(accountStamp: a, reference: art, size: .row)
    let cache = WatchArtworkCache(directory: root, byteLimit: 1024)
    await cache.retainAccounts([a, b])
    await cache.store(Data([1, 2, 3]), for: key)
    await cache.flush()
    #expect(await cache.data(for: .init(accountStamp: b, reference: art, size: .row)) == nil)
    #expect(await cache.data(for: .init(accountStamp: a, reference: art, size: .player)) == nil)
    let restarted = WatchArtworkCache(directory: root, byteLimit: 1024)
    await restarted.retainAccounts([a])
    #expect(await restarted.data(for: key) == Data([1, 2, 3]))
    await restarted.retainAccounts([b])
    await restarted.store(Data([4]), for: key)
    #expect(await restarted.data(for: key) == nil)
  }

  @Test func budgetEvictsOldestUnpinnedCoverFirst() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try WatchAccountStamp(accountIdentityHash: "a", serverIdentityHash: "s")
    func key(_ id: String) -> WatchArtworkCache.Key {
      .init(accountStamp: stamp, reference: .init(selection: .audiobookshelf(itemID: id, episodeID: nil)), size: .row)
    }
    let cache = WatchArtworkCache(directory: root, byteLimit: 2500)
    await cache.retainAccounts([stamp])
    await cache.setPinned([key("download")])
    await cache.store(Data(repeating: 1, count: 1000), for: key("download"))
    await cache.store(Data(repeating: 2, count: 1000), for: key("old"))
    await cache.store(Data(repeating: 3, count: 1000), for: key("new"))
    #expect(await cache.data(for: key("download")) != nil)
    #expect(await cache.data(for: key("old")) == nil)
    #expect(await cache.data(for: key("new")) != nil)
    #expect(await cache.storedByteCount <= 2500)
  }

  @Test func syncedCoversAreNeverEvictedByOnDemandCovers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try Self.stamp()
    let cache = WatchArtworkCache(directory: root, byteLimit: 2500, recordLimit: 2, syncedByteLimit: 10_000)
    await cache.retainAccounts([stamp])
    #expect(await cache.storeSynced(Data(repeating: 1, count: 1000), for: Self.key("synced", stamp)))
    for id in ["a", "b", "c", "d"] { await cache.store(Data(repeating: 2, count: 1000), for: Self.key(id, stamp)) }
    #expect(await cache.data(for: Self.key("synced", stamp)) != nil)
    #expect(await cache.data(for: Self.key("a", stamp)) == nil)
    #expect(await cache.data(for: Self.key("d", stamp)) != nil)
    #expect(await cache.syncedKeys(accountStamp: stamp) == [Self.key("synced", stamp)])
  }

  @Test func syncedTierHasItsOwnBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try Self.stamp()
    let cache = WatchArtworkCache(directory: root, syncedByteLimit: 1_000_000, syncedRecordLimit: 2)
    await cache.retainAccounts([stamp])
    for id in ["a", "b", "c"] { await cache.storeSynced(Data([1]), for: Self.key(id, stamp)) }
    #expect(await cache.syncedKeys(accountStamp: stamp).count == 2)
    #expect(await cache.data(for: Self.key("a", stamp)) == nil)
  }

  @Test func anOnDemandCoverMovesToTheSyncedTierAndARefreshKeepsItThere() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try Self.stamp()
    let cache = WatchArtworkCache(directory: root)
    await cache.retainAccounts([stamp])
    let key = Self.key("a", stamp)
    await cache.store(Data([1]), for: key)
    #expect(await cache.syncedKeys(accountStamp: stamp).isEmpty)
    await cache.storeSynced(Data([2]), for: key)
    await cache.store(Data([3]), for: key)
    #expect(await cache.syncedKeys(accountStamp: stamp) == [key])
    #expect(await cache.data(for: key) == Data([3]))
    await cache.flush()
    let reopened = WatchArtworkCache(directory: root)
    await reopened.retainAccounts([stamp])
    #expect(await reopened.syncedKeys(accountStamp: stamp) == [key])
  }

  @Test func removingSyncedCoversLeavesOnDemandOnes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try Self.stamp()
    let cache = WatchArtworkCache(directory: root)
    await cache.retainAccounts([stamp])
    await cache.storeSynced(Data([1]), for: Self.key("gone", stamp))
    await cache.storeSynced(Data([1]), for: Self.key("kept", stamp))
    await cache.store(Data([1]), for: Self.key("demand", stamp))
    await cache.removeSynced([Self.key("gone", stamp), Self.key("demand", stamp)])
    #expect(await cache.data(for: Self.key("gone", stamp)) == nil)
    #expect(await cache.data(for: Self.key("kept", stamp)) != nil)
    #expect(await cache.data(for: Self.key("demand", stamp)) != nil)
  }

  @Test func admittingAnAccountKeepsTheOthers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try Self.stamp()
    let b = try WatchAccountStamp(accountIdentityHash: "b", serverIdentityHash: "s")
    let cache = WatchArtworkCache(directory: root)
    await cache.retainAccounts([a])
    await cache.store(Data([1]), for: Self.key("x", a))
    #expect(!(await cache.storeSynced(Data([1]), for: Self.key("y", b))))
    await cache.admit(b)
    #expect(await cache.storeSynced(Data([1]), for: Self.key("y", b)))
    #expect(await cache.data(for: Self.key("x", a)) != nil)
    #expect(await cache.data(for: Self.key("y", b)) != nil)
  }

  private static func stamp() throws -> WatchAccountStamp {
    try WatchAccountStamp(accountIdentityHash: "a", serverIdentityHash: "s")
  }

  private static func key(_ id: String, _ stamp: WatchAccountStamp, revision: String = "unversioned")
    -> WatchArtworkCache.Key
  {
    .init(
      accountStamp: stamp,
      reference: .init(selection: .audiobookshelf(itemID: id, episodeID: nil), revision: revision), size: .row)
  }

  private static func files(in directory: URL, extension ext: String) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == ext }
  }

  @Test func coversAreStoredAsRawImageFilesBesideOneIndex() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try Self.stamp()
    let cache = WatchArtworkCache(directory: root)
    await cache.retainAccounts([stamp])
    await cache.store(Data([9, 8, 7]), for: Self.key("1", stamp))
    await cache.store(Data([6, 5]), for: Self.key("2", stamp))
    await cache.flush()
    let images = Self.files(in: root, extension: "jpg")
    #expect(images.count == 2)
    #expect(Set(images.compactMap { try? Data(contentsOf: $0) }) == [Data([9, 8, 7]), Data([6, 5])])
    #expect(Self.files(in: root, extension: "json").map(\.lastPathComponent) == ["index.json"])
    #expect(await cache.storedByteCount == 5)
  }

  @Test func reopeningDropsEntriesWithoutFilesAndFilesWithoutEntries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try Self.stamp()
    let cache = WatchArtworkCache(directory: root)
    await cache.retainAccounts([stamp])
    await cache.store(Data([1]), for: Self.key("kept", stamp))
    await cache.store(Data([2]), for: Self.key("lost", stamp))
    await cache.flush()
    try FileManager.default.removeItem(at: await cache.fileURL(for: Self.key("lost", stamp)))
    let stray = root.appendingPathComponent(String(repeating: "f", count: 64)).appendingPathExtension("jpg")
    try Data([3]).write(to: stray)

    let reopened = WatchArtworkCache(directory: root)
    await reopened.retainAccounts([stamp])
    #expect(await reopened.data(for: Self.key("kept", stamp)) == Data([1]))
    #expect(await reopened.data(for: Self.key("lost", stamp)) == nil)
    #expect(await reopened.storedByteCount == 1)
    #expect(!FileManager.default.fileExists(atPath: stray.path))
  }

  @Test func anUnreadableIndexStartsEmptyAndClearsImages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try Self.stamp()
    let cache = WatchArtworkCache(directory: root)
    await cache.retainAccounts([stamp])
    await cache.store(Data([1]), for: Self.key("1", stamp))
    await cache.flush()
    try Data("not json".utf8).write(to: root.appendingPathComponent("index.json"))

    let reopened = WatchArtworkCache(directory: root)
    await reopened.retainAccounts([stamp])
    #expect(await reopened.data(for: Self.key("1", stamp)) == nil)
    #expect(Self.files(in: root, extension: "jpg").isEmpty)
  }

  @Test func openingRemovesTheLegacyDirectories() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: parent) }
    let legacy = parent.appendingPathComponent("WatchThumbnails-v1", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data([1]).write(to: legacy.appendingPathComponent("old.json"))
    let cache = WatchArtworkCache(
      directory: parent.appendingPathComponent("WatchThumbnails-v2", isDirectory: true),
      legacyDirectories: [legacy])
    await cache.retainAccounts([try Self.stamp()])
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
  }

  @Test func recordLimitEvictsTheLeastRecentlyUsedCover() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try Self.stamp()
    let cache = WatchArtworkCache(directory: root, recordLimit: 2)
    await cache.retainAccounts([stamp])
    await cache.store(Data([1]), for: Self.key("1", stamp))
    await cache.store(Data([2]), for: Self.key("2", stamp))
    await cache.store(Data([3]), for: Self.key("3", stamp))
    #expect(await cache.data(for: Self.key("1", stamp)) == nil)
    #expect(await cache.data(for: Self.key("3", stamp)) == Data([3]))
  }

  @Test func onlyUnversionedCoversAgeIntoRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try Self.stamp()
    let cache = WatchArtworkCache(directory: root)
    await cache.retainAccounts([stamp])
    let saved = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let later = saved.addingTimeInterval(2 * 24 * 60 * 60)
    let unversioned = Self.key("1", stamp)
    let versioned = Self.key("2", stamp, revision: "abs-1700000000")
    await cache.store(Data([1]), for: unversioned, now: saved)
    await cache.store(Data([2]), for: versioned, now: saved)
    #expect(await cache.needsRefresh(unversioned, now: later))
    #expect(!(await cache.needsRefresh(versioned, now: later)))
    #expect(await cache.needsRefresh(Self.key("absent", stamp, revision: "abs-1"), now: saved))
  }
}
