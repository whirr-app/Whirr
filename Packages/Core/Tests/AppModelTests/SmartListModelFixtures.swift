import Foundation
import GRDB
import Persistence
import TestSupport

@testable import AppModel

final class SmartListExpansionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var ids: [Int64] = []

  var listIDs: [Int64] {
    lock.lock()
    defer { lock.unlock() }
    return ids
  }

  func record(_ id: Int64) {
    lock.lock()
    ids.append(id)
    lock.unlock()
  }
}

struct SmartListCatalogStub: SmartListShowCatalogReading {
  let shows: [SmartListCatalogShow]

  func observeShows() -> AsyncStream<[SmartListCatalogShow]> {
    AsyncStream { continuation in
      continuation.yield(shows)
      continuation.finish()
    }
  }
}

@MainActor
final class SmartListPlaybackSpy: SmartListPlaybackStarting {
  struct Call: Equatable {
    let listID: Int64
    let itemID: String
    let episodeID: String
  }

  var calls: [Call] = []
  var succeeds = true
  /// What the run store holds when the start returns, as playback composition would leave it.
  var onStart: (() async -> Void)?

  func startFromList(listID: Int64, itemID: String, episodeID: String) async -> Bool {
    calls.append(Call(listID: listID, itemID: itemID, episodeID: episodeID))
    await onStart?()
    return succeeds
  }
}

/// A real in-memory database with the smart list services over it.
struct SmartListFixture: Sendable {
  static let epoch = Date(timeIntervalSince1970: 1_900_000_000)

  let database: AppDatabase
  let preference: NativePodcastSubscriptionsPreference
  let expansions = SmartListExpansionRecorder()
  let services: SmartListServices

  init(
    nativeEnabled: Bool = true, catalog: [SmartListCatalogShow] = []
  ) throws {
    let database = try AppDatabase.inMemory()
    let defaults = FakeNativePodcastSubscriptionsDefaults()
    defaults.setBoolValue(nativeEnabled, forKey: NativePodcastSubscriptionsPreference.storageKey)
    let preference = NativePodcastSubscriptionsPreference(defaults: defaults)
    let expansions = expansions
    self.database = database
    self.preference = preference
    services = SmartListServices(
      database: database, subscriptions: preference,
      accountIdentity: DefaultAccountIdentityReading(database: database),
      showCatalog: SmartListCatalogStub(shows: catalog),
      expand: { expansions.record($0) }, now: { Self.epoch })
  }

  @discardableResult
  func signIn(userID: String = "user-1") async throws -> Int64 {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: userID, serverVersion: "2.35.1")
      try account.insert(db)
      guard let id = account.id else { throw FixtureError.noRowID }
      return id
    }
  }

  /// A podcast show in a new included library of `accountID`, keyed by the account's `serverUserId`.
  @discardableResult
  func serverShow(
    _ accountID: Int64, _ serverItemID: String, title: String = "Server Show",
    fingerprint: String? = nil
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "lib-\(serverItemID)", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      guard let libraryID = library.id else { throw FixtureError.noRowID }
      var item = ItemRecord(
        accountId: accountID, libraryId: libraryID, serverItemId: serverItemID,
        mediaKind: "podcast", title: title, sortTitle: title,
        podcastFeedFingerprint: fingerprint)
      try item.insert(db)
      guard let id = item.id else { throw FixtureError.noRowID }
      return id
    }
  }

  func signOut() async throws {
    try await database.writeAsync { db in try db.execute(sql: "DELETE FROM account") }
  }

  @discardableResult
  func feed(_ url: String, title: String = "Feed", fingerprint: String? = nil) async throws
    -> Int64
  {
    try await database.writeAsync { db in
      var feed = RSSFeedRecord(
        feedURL: url, title: title, subscribedAt: Self.epoch, refreshGeneration: 1,
        podcastFeedFingerprint: fingerprint)
      try feed.insert(db)
      guard let id = feed.id else { throw FixtureError.noRowID }
      return id
    }
  }

  @discardableResult
  func episode(feed: Int64, _ key: String, ageSeconds: TimeInterval = 0, duration: Double = 1_800)
    async throws -> Int64
  {
    try await database.writeAsync { db in
      var episode = RSSEpisodeRecord(
        feedId: feed, identityKey: key, title: "T-\(key)",
        enclosureURL: "https://audio.example/\(key).mp3",
        publishedAt: Self.epoch.addingTimeInterval(-ageSeconds), durationSeconds: duration,
        lastSeenGeneration: 1)
      try episode.insert(db)
      guard let id = episode.id else { throw FixtureError.noRowID }
      return id
    }
  }

  func finish(_ episode: Int64) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO rssEpisodeState (episodeId, position, finished, localSequence, updatedAt)
          VALUES (?, 0, 1, 1, ?)
          """,
        arguments: [episode, Self.epoch])
    }
  }

  func nativeItemID(_ feed: Int64) -> String { "rss:\(feed)" }

  enum FixtureError: Error { case noRowID }
}
