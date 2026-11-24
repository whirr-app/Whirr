import Foundation
import Persistence
import Testing
import WatchProtocol

@testable import Whirr

/// One signed-in account's Audiobookshelf send half over an in-memory database, with a sender that
/// records what would cross to the Watch.
@MainActor
final class ABSWatchSendFixture {
  static let install = "0f0e0d0c-0b0a-4908-8706-050403020100"
  static let book = ABSWatchCopyKey(itemId: "book-1", episodeId: nil)
  static let otherBook = ABSWatchCopyKey(itemId: "book-2", episodeId: nil)
  static let episode = ABSWatchCopyKey(itemId: "show-1", episodeId: "episode-1")

  let database: AppDatabase
  let accountId: Int64
  let store: ABSWatchCopyStore
  let stamp: WatchAccountStamp
  let defaults: UserDefaults
  var progress: [ABSWatchCopyKey: StoredAudioProgress] = [:]
  var removesFinished = true
  var isWatchInstalled = true
  var books: [String: ItemSummary] = [:]
  private(set) var sent: [Data] = []

  init() throws {
    database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "abs-watch-send", serverBaseURL: "https://abs-watch-send.invalid",
        serverUserId: "listener", serverVersion: "2.35.1"))
    accountId = try #require(account.id)
    store = ABSWatchCopyStore(database: database, accountId: accountId)
    stamp = try WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")
    defaults = try #require(UserDefaults(suiteName: "abs-watch-send-\(UUID().uuidString)"))
  }

  static func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + seconds)
  }

  func publisher() -> ABSWatchSendPublisher {
    ABSWatchSendPublisher(
      store: store, stamp: stamp,
      progress: { [unowned self] in self.progress[$0] },
      sender: ABSWatchSendPublisher.Sender(
        isWatchInstalled: { [unowned self] in self.isWatchInstalled },
        sendOffer: { [unowned self] data in
          self.sent.append(data)
          return true
        }),
      now: { Self.date(500) }, debounce: .zero,
      removesFinished: { [unowned self] in self.removesFinished })
  }

  var resolver: ABSWatchTitleResolver {
    ABSWatchTitleResolver(book: { [unowned self] in self.books[$0] }, episode: { _, _ in nil })
  }

  var record: ABSWatchInventoryRecord { ABSWatchInventoryRecord(defaults: defaults) }

  func inbox() -> ABSWatchInventoryInbox {
    ABSWatchInventoryInbox(store: store, stamp: stamp, resolver: resolver, record: record)
  }

  func offers() throws -> [WatchABSSendOffer] {
    try sent.map { try WatchWireCodec.decode(WatchABSSendOffer.self, from: $0) }
  }

  @discardableResult
  func request(_ key: ABSWatchCopyKey, at seconds: TimeInterval) async throws -> ABSWatchCopy {
    try await store.request(
      key, title: "Title of \(key.itemId)", subtitle: "Author", declaredBytes: 1_000,
      now: Self.date(seconds))
  }

  /// An inventory already matched to an account, as the inbox hands it to the store.
  @discardableResult
  func applyStoreInventory(
    sequence: UInt64, acknowledged: UInt64, accountIdentityHash: String = "account",
    _ entries: [ABSWatchInventory.Entry] = []
  ) async throws -> ABSWatchCopyInventoryOutcome {
    try await store.applyInventory(
      ABSWatchInventory(
        watchInstallID: Self.install, sequence: sequence, accountIdentityHash: accountIdentityHash,
        acknowledgedGeneration: acknowledged, entries: entries),
      now: Self.date(400))
  }

  func finished(_ key: ABSWatchCopyKey, at seconds: TimeInterval) {
    progress[key] = StoredAudioProgress(position: 600, isFinished: true, changedAt: Self.date(seconds))
  }

  static func selection(_ key: ABSWatchCopyKey) throws -> WatchABSSelection {
    try WatchABSSelection(itemID: key.itemId, episodeID: key.episodeId)
  }

  /// A wire inventory carrying only an Audiobookshelf half, stamped with this account unless
  /// `stamp` names another (or `.some(nil)`, a signed-out Watch).
  func wireInventory(
    sequence: UInt64, acknowledged: UInt64 = 0, stamp: WatchAccountStamp?? = nil,
    _ entries: [WatchABSInventoryEntry]?
  ) throws -> WatchEpisodeInventory {
    try WatchEpisodeInventory(
      watchInstallID: Self.install, sequence: sequence, acknowledgedGeneration: 0, acceptsCopies: true,
      entries: [], budgetTotalBytes: 10_000, budgetUsedBytes: 1_000, observedAt: Self.date(300),
      absEntries: entries, absAcknowledgedGeneration: entries == nil ? nil : acknowledged,
      absAccountStamp: stamp ?? self.stamp)
  }

  static func wireEntry(
    _ key: ABSWatchCopyKey, revision: UInt64?, origin: WatchABSOrigin,
    _ state: WatchABSInventoryEntry.State = .ready, tracks: Int = 1, completed: Int = 1
  ) throws -> WatchABSInventoryEntry {
    // The wire requires a ready group to name the bytes it committed.
    try WatchABSInventoryEntry(
      selection: selection(key), revision: revision, origin: origin, state: state, trackCount: tracks,
      completedTracks: completed, committedBytes: state == .ready ? 1_000 : nil)
  }
}
