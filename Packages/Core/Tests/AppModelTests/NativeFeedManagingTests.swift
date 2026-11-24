import ABSApi
import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite("Native feed managing")
struct NativeFeedManagingTests {
  @Test("saving a Basic credential releases only that feed through the update boundary")
  func saveCredentialNotifiesUpdateHandler() async throws {
    let database = try AppDatabase.inMemory()
    let feeds = RSSFeedStore(database: database)
    let feedID = try await feeds.subscribe(
      feedURL: URL(string: "https://example.test/private.xml")!, title: "Private",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let credentials = InMemoryFeedCredentialStore()
    let updates = RecordingCredentialUpdateHandler()
    let managing = RSSFeedManaging(
      store: feeds, credentialStore: credentials, credentialUpdateHandler: updates)

    try await managing.saveBasicCredential(
      username: "listener", password: "secret", feedId: feedID)

    #expect(
      try credentials.load(forFeedID: feedID)
        == FeedCredential.basic(username: "listener", password: "secret"))
    #expect(await updates.feedIDs == [feedID])
  }

  @Test("a successful password retry clears recovery before refreshing only that feed")
  func retryCredentialClearsRecoveryThenRefreshes() async throws {
    let database = try AppDatabase.inMemory()
    let feeds = RSSFeedStore(database: database)
    let feedID = try await feeds.subscribe(
      feedURL: URL(string: "https://example.test/private.xml")!, title: "Private",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date(),
      recoveryReason: .credentialStorageFailed)
    let credentials = InMemoryFeedCredentialStore()
    let refreshing = RecoveryRecordingPodcastRefreshing(recovery: feeds)
    let managing = RSSFeedManaging(
      store: feeds, credentialStore: credentials, refreshing: refreshing)

    try await managing.saveBasicCredential(
      username: "fixture-user", password: "fixture-password", feedId: feedID)

    #expect(try await feeds.recoveryRequired(feedID: feedID) == false)
    #expect(await refreshing.itemIDs == ["rss:\(feedID)"])
    #expect(await refreshing.observedRecoveryStates == [false])
  }

  @Test("a failed marker clear stays visible and a later retry is idempotent")
  func failedRecoveryClearCanBeRetried() async throws {
    let database = try AppDatabase.inMemory()
    let feeds = RSSFeedStore(database: database)
    let feedID = try await feeds.subscribe(
      feedURL: URL(string: "https://example.test/private.xml")!, title: "Private",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date(),
      recoveryReason: .credentialStorageFailed)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          CREATE TRIGGER failRecoveryClear
          BEFORE DELETE ON rssFeedRecovery
          BEGIN SELECT RAISE(ABORT, 'fixture clear failure'); END
          """)
    }
    let credentials = InMemoryFeedCredentialStore()
    let refreshing = RecoveryRecordingPodcastRefreshing(recovery: feeds)
    let managing = RSSFeedManaging(
      store: feeds, credentialStore: credentials, refreshing: refreshing)

    await #expect(throws: (any Error).self) {
      try await managing.saveBasicCredential(
        username: "fixture-user", password: "fixture-password", feedId: feedID)
    }
    #expect(try await feeds.recoveryRequired(feedID: feedID))
    #expect(await refreshing.itemIDs.isEmpty)

    try await database.writeAsync { db in try db.execute(sql: "DROP TRIGGER failRecoveryClear") }
    try await managing.saveBasicCredential(
      username: "fixture-user", password: "fixture-password", feedId: feedID)
    #expect(try await feeds.recoveryRequired(feedID: feedID) == false)
    #expect(await refreshing.itemIDs == ["rss:\(feedID)"])
  }

  @Test("unsubscribe deletes the feed credential with the subscription")
  func unsubscribeClearsCredential() async throws {
    let database = try AppDatabase.inMemory()
    let feeds = RSSFeedStore(database: database)
    let feedID = try await feeds.subscribe(
      feedURL: URL(string: "https://example.test/private.xml")!, title: "Private",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let credentials = InMemoryFeedCredentialStore()
    try credentials.save(
      try FeedCredential.basic(username: "user", password: "pass"), forFeedID: feedID)
    let managing = RSSFeedManaging(store: feeds, credentialStore: credentials)

    try await managing.unsubscribe(feedId: feedID)

    #expect(try await feeds.fetchFeed(feedId: feedID) == nil)
    #expect(try credentials.load(forFeedID: feedID) == nil)
  }

  @Test("unsubscribe disarms only that feed before deleting it")
  func unsubscribeDisarmsNotifications() async throws {
    let database = try AppDatabase.inMemory()
    let feeds = RSSFeedStore(database: database)
    let feedID = try await feeds.subscribe(
      feedURL: URL(string: "https://example.test/feed.xml")!, title: "Feed",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let lifecycle = FakeRSSNotificationLifecycleHandling()
    let managing = RSSFeedManaging(store: feeds, notificationLifecycle: lifecycle)

    try await managing.unsubscribe(feedId: feedID)

    #expect(await lifecycle.feedIDs == [feedID])
    #expect(try await feeds.fetchFeed(feedId: feedID) == nil)
  }

  @Test("a Keychain clear failure leaves the subscription intact")
  func clearFailureKeepsSubscription() async throws {
    let database = try AppDatabase.inMemory()
    let feeds = RSSFeedStore(database: database)
    let feedID = try await feeds.subscribe(
      feedURL: URL(string: "https://example.test/private.xml")!, title: "Private",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let credentials = FakeFeedCredentialStoring()
    credentials.stubClearFailure(TestCredentialStoreError())
    let managing = RSSFeedManaging(store: feeds, credentialStore: credentials)

    await #expect(throws: TestCredentialStoreError.self) {
      try await managing.unsubscribe(feedId: feedID)
    }

    #expect(try await feeds.fetchFeed(feedId: feedID) != nil)
  }

  @Test("unsubscribe removes downloaded enclosure files after the feed delete")
  func unsubscribeRemovesDownloadedEnclosureFiles() async throws {
    let fixture = try await makeDownloadedFeedFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let cleaner = RecordingRSSDownloadFileCleaner(
      records: [fixture.feedID: [fixture.download]], rootURL: fixture.rootURL)
    let managing = RSSFeedManaging(
      store: fixture.feeds, downloadFileCleaner: cleaner)

    try await managing.unsubscribe(feedId: fixture.feedID)

    #expect(try await fixture.feeds.fetchFeed(feedId: fixture.feedID) == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path) == false)
    #expect(await cleaner.removedRecords == [[fixture.download]])
  }

  @Test("a failed unsubscribe leaves downloaded enclosure files intact")
  func failedUnsubscribeLeavesDownloadedEnclosureFiles() async throws {
    let fixture = try await makeDownloadedFeedFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let cleaner = RecordingRSSDownloadFileCleaner(
      records: [fixture.feedID: [fixture.download]], rootURL: fixture.rootURL)
    let lifecycle = FakeRSSNotificationLifecycleHandling()
    let feeds = fixture.feeds
    lifecycle.setDisarmHook { feedID in
      guard let feedID else { return }
      try? await feeds.unsubscribe(feedId: feedID)
    }
    let managing = RSSFeedManaging(
      store: fixture.feeds, notificationLifecycle: lifecycle, downloadFileCleaner: cleaner)

    await #expect(throws: RSSFeedStoreError.feedNotFound) {
      try await managing.unsubscribe(feedId: fixture.feedID)
    }

    #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    #expect(await cleaner.removedRecords.isEmpty)
  }
}

private struct DownloadedFeedFixture {
  let feeds: RSSFeedStore
  let feedID: Int64
  let download: RSSDownloadRecord
  let rootURL: URL
  let fileURL: URL
}

private func makeDownloadedFeedFixture() async throws -> DownloadedFeedFixture {
  let database = try AppDatabase.inMemory()
  let feeds = RSSFeedStore(database: database)
  let feedID = try await feeds.subscribe(
    feedURL: URL(string: "https://example.test/downloaded-feed.xml")!, title: "Downloaded",
    author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
  let episodeStore = RSSEpisodeStore(database: database)
  _ = try await episodeStore.applyRefresh(
    feedId: feedID,
    episodes: [
      RSSEpisodeUpsert(
        identityKey: "episode-1", title: "Episode",
        enclosureURL: URL(string: "https://example.test/episode.mp3")!,
        enclosureType: "audio/mpeg", declaredBytes: 5)
    ])
  let episode = try #require(
    await episodeStore.fetchEpisode(feedId: feedID, identityKey: "episode-1"))
  let downloads = try RSSDownloadStore(database: database)
  let download = try await downloads.claimOrCreateAsync(episodeId: try #require(episode.id))
  _ = try await downloads.transitionAsync(downloadId: try #require(download.id), to: .downloading)
  let completed = try await downloads.completeAsync(
    downloadId: try #require(download.id), actualBytes: 5)

  let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "NativeFeedManagingTests-" + UUID().uuidString, isDirectory: true)
  let fileURL = rootURL.appendingPathComponent(completed.relativePath)
  try FileManager.default.createDirectory(
    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(repeating: 0x42, count: 5).write(to: fileURL)
  return DownloadedFeedFixture(
    feeds: feeds, feedID: feedID, download: completed, rootURL: rootURL, fileURL: fileURL)
}

private actor RecordingCredentialUpdateHandler: FeedCredentialUpdateHandling {
  private(set) var feedIDs: [Int64] = []
  func handleFeedCredentialUpdate(feedId: Int64) { feedIDs.append(feedId) }
}

// Kept: it reads the feed's recovery state inside `refresh`, a per-call hook that
// `FakePodcastRefreshing` (read-only here) does not have.
private actor RecoveryRecordingPodcastRefreshing: PodcastRefreshing {
  let recovery: any NativeFeedRecoveryReading
  private(set) var itemIDs: [String] = []
  private(set) var observedRecoveryStates: [Bool] = []

  init(recovery: any NativeFeedRecoveryReading) { self.recovery = recovery }

  func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    itemIDs.append(itemID)
    let feedID = try #require(PodcastSourceIdentity(itemId: itemID)?.rssFeedId)
    observedRecoveryStates.append(try await recovery.recoveryRequired(feedID: feedID))
    return .complete
  }
}

private struct TestCredentialStoreError: Error {}

private actor RecordingRSSDownloadFileCleaner: RSSDownloadFileCleaning, FeedCredentialUpdateHandling {
  let records: [Int64: [RSSDownloadRecord]]
  let rootURL: URL
  private(set) var removedRecords: [[RSSDownloadRecord]] = []

  init(records: [Int64: [RSSDownloadRecord]], rootURL: URL) {
    self.records = records
    self.rootURL = rootURL
  }

  func rssDownloadFiles(forFeedID feedID: Int64) async throws -> [RSSDownloadRecord] {
    records[feedID] ?? []
  }

  func removeRSSDownloadFiles(_ records: [RSSDownloadRecord]) async throws {
    removedRecords.append(records)
    for record in records {
      let fileURL = rootURL.appendingPathComponent(record.relativePath)
      if FileManager.default.fileExists(atPath: fileURL.path) {
        try FileManager.default.removeItem(at: fileURL)
      }
    }
  }

  func handleFeedCredentialUpdate(feedId: Int64) {}
}
