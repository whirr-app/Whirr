import ABSApi
import Foundation
import Persistence
import PodcastFeeds
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

extension RSSPlaybackCoordinatorTests {
  // MARK: - Fixtures

  struct Fixture {
    let database: AppDatabase
    let feedID: Int64
    let itemID: String
    let episodeIDs: [String: Int64]
  }

  static let episodeURL = URL(string: "https://example.com/episode.mp3")!

  static func date(_ time: TimeInterval) -> Date {
    Date(timeIntervalSince1970: time)
  }

  static func episode(
    identityKey: String,
    title: String? = "Episode",
    enclosureURL: URL = Self.episodeURL,
    durationSeconds: Double? = 120
  ) -> RSSEpisodeUpsert {
    RSSEpisodeUpsert(
      identityKey: identityKey, title: title, enclosureURL: enclosureURL,
      enclosureType: "audio/mpeg", durationSeconds: durationSeconds)
  }

  static func makeFixture(
    feedURL: URL? = nil, episodes: [RSSEpisodeUpsert]
  ) async throws -> Fixture {
    let database = try AppDatabase.inMemory()
    let feedURL = feedURL ?? URL(string: "https://example.com/feed-\(UUID().uuidString).xml")!
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: feedURL,
      title: "Feed", author: nil, synopsis: nil, artworkURL: nil, subscribedAt: date(1))
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedID, episodes: episodes)
    let rows = try await database.readAsync { db in
      try RSSEpisodeRecord.fetchAll(
        db, sql: "SELECT * FROM rssEpisode WHERE feedId = ? ORDER BY id", arguments: [feedID])
    }
    let episodeIDs = Dictionary(
      uniqueKeysWithValues: rows.compactMap { row -> (String, Int64)? in
        guard let id = row.id else { return nil }
        return (row.identityKey, id)
      })
    return Fixture(
      database: database,
      feedID: feedID,
      itemID: try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId,
      episodeIDs: episodeIDs)
  }

  static func makeCoordinator(
    fixture: Fixture,
    loader: any EnclosureDurationLoading = NoOpEnclosureDurationLoading(),
    chapterLoader: (any EmbeddedChapterLoading)? = nil,
    fileStore: RSSFileStore? = nil,
    tracker: RSSActivePlaybackTracker? = nil,
    credentialStore: any FeedCredentialStoring = InMemoryFeedCredentialStore(),
    downloadPreferences: any DownloadPreferences = NoOpDownloadPreferences(),
    requestFinishedDownloadDeletion: @escaping @Sendable (String, String?) async -> Void = {
      _, _ in
    },
    requestPodcastAutoDownloadReap: @escaping @Sendable () async -> Void = {},
    settleObserver: (any PodcastPlaybackSettleObserving)? = nil,
    now: @escaping @Sendable () -> Date = { Self.date(100) }
  ) -> RSSPlaybackCoordinator {
    let episodeStore = RSSEpisodeStore(database: fixture.database)
    return RSSPlaybackCoordinator(
      episodeStore: episodeStore,
      stateStore: RSSEpisodeStateStore(database: fixture.database),
      durationResolver: RSSEpisodeDurationResolver(episodeStore: episodeStore, loader: loader),
      chapterResolver: chapterLoader.map {
        RSSEpisodeChapterResolver(
          chapterStore: RSSEpisodeChapterStore(database: fixture.database), loader: $0)
      },
      fileStore: fileStore,
      activePlaybackTracker: tracker,
      feedStore: RSSFeedStore(database: fixture.database),
      credentialStore: credentialStore,
      downloadPreferences: downloadPreferences,
      requestFinishedDownloadDeletion: requestFinishedDownloadDeletion,
      requestPodcastAutoDownloadReap: requestPodcastAutoDownloadReap,
      settleObserver: settleObserver,
      now: now)
  }

  /// Ticks the active stream the way the playback model does after a session has started.
  static func tick(
    _ coordinator: RSSPlaybackCoordinator, fixture: Fixture, episodeID: String,
    currentTime: Double, isFinished: Bool
  ) async {
    await coordinator.recordProgressTick(
      itemID: fixture.itemID, episodeID: episodeID, currentTime: currentTime, listenedDelta: 1,
      isFinished: isFinished, isSeek: false, sleepTimerExpired: false)
  }

  static func insertAccount(_ fixture: Fixture) async throws -> Int64 {
    try await fixture.database.writeAsync { db -> Int64 in
      var account = PersistenceFixtures.account(
        clientUUID: "rss-coordinator-\(UUID().uuidString)", serverBaseURL: "https://example.test",
        serverUserId: "user", serverVersion: "2.26.0")
      try account.insert(db)
      return try #require(account.id)
    }
  }

  /// Starts a stream before any file exists, then completes the download beneath it, so the
  /// coordinator is streaming with a promotable local file.
  static func streamThenCompleteDownload(
    fixture: Fixture, episodeID: Int64, localDuration: Double
  ) async throws -> (RSSPlaybackCoordinator, URL, PreparedPlayback) {
    let downloads = try RSSDownloadStore(database: fixture.database)
    let row = try downloads.claimOrCreate(episodeId: episodeID)
    _ = try downloads.transition(downloadId: try #require(row.id), to: .downloading)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let files = try RSSFileStore(
      rootURL: root, fileAttributes: InertFileAttributes(), downloadStore: downloads)
    let coordinator = makeCoordinator(
      fixture: fixture, loader: RSSPlaybackFixtures.SourceAwareDurationLoader(localResult: localDuration),
      fileStore: files)
    let streamed = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    let temporary = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try Data([1, 2, 3, 4]).write(to: temporary)
    _ = try files.completeTransfer(
      downloadId: try #require(row.id), temporaryFileURL: temporary,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 4))
    return (coordinator, root, streamed)
  }

  static func completeDownload(
    for episodeID: Int64, in fixture: Fixture
  ) throws -> (store: RSSFileStore, root: URL) {
    let downloads = try RSSDownloadStore(database: fixture.database)
    let row = try downloads.claimOrCreate(episodeId: episodeID)
    _ = try downloads.transition(downloadId: try #require(row.id), to: .downloading)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let files = try RSSFileStore(
      rootURL: root, fileAttributes: InertFileAttributes(), downloadStore: downloads)
    let temporary = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try Data([1, 2, 3, 4]).write(to: temporary)
    _ = try files.completeTransfer(
      downloadId: try #require(row.id), temporaryFileURL: temporary,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 4))
    return (files, root)
  }
}

// MARK: - Fakes

enum RSSPlaybackFixtures {
  // Kept for now: RSSPlaybackCoordinator*Tests await this actor's API; migrate them together.
  actor DurationLoaderSpy: EnclosureDurationLoading {
    let result: Double?
    private(set) var callCount = 0

    init(result: Double?) {
      self.result = result
    }

    func loadDuration(for enclosureURL: URL) async throws -> Double? {
      callCount += 1
      return result
    }
  }

  // Kept for now: RSSPlaybackCoordinator*Tests await this actor's API; migrate them together.
  actor BlockingDurationLoader: EnclosureDurationLoading {
    private let result: Double?
    private nonisolated let starts = TestCountRecorder(label: "BlockingDurationLoader loads")
    // Stays parked on task cancellation, as the load it stands in for runs to completion.
    private nonisolated let gate = TestGate<Void>(
      label: "BlockingDurationLoader load", ignoresCancellation: true)

    init(result: Double?) {
      self.result = result
      gate.hold()
    }

    func loadDuration(for enclosureURL: URL) async throws -> Double? {
      _ = enclosureURL
      starts.record()
      await gate.pass()
      try Task.checkCancellation()
      return result
    }

    func waitUntilStarted() async {
      await starts.waitUntil(count: 1)
    }

    func release() {
      gate.release()
    }
  }

  // Kept for now: RSSPlaybackCoordinator*Tests await this actor's API; migrate them together.
  actor SourceAwareDurationLoader: EnclosureDurationLoading {
    let localResult: Double?
    private(set) var remoteURLs: [URL] = []
    private(set) var localURLs: [URL] = []

    init(localResult: Double?) {
      self.localResult = localResult
    }

    func loadDuration(for url: URL) async throws -> Double? {
      if url.isFileURL {
        localURLs.append(url)
        return localResult
      }
      remoteURLs.append(url)
      return nil
    }
  }

  // Kept for now: RSSPlaybackCoordinator*Tests await this actor's API; migrate them together.
  actor OfflineRemoteDurationLoader: EnclosureDurationLoading {
    let localResult: Double?
    private(set) var remoteCallCount = 0
    private(set) var localCallCount = 0

    init(localResult: Double?) {
      self.localResult = localResult
    }

    func loadDuration(for url: URL) async throws -> Double? {
      if url.isFileURL {
        localCallCount += 1
        return localResult
      }
      remoteCallCount += 1
      throw URLError(.notConnectedToInternet)
    }
  }

  struct RSSFinishedDeletionIdentity: Sendable, Equatable {
    let itemID: String
    let episodeID: String?
  }

  actor RSSFinishedDeletionRecorder {
    private(set) var values: [RSSFinishedDeletionIdentity] = []

    func record(itemID: String, episodeID: String?) {
      values.append(RSSFinishedDeletionIdentity(itemID: itemID, episodeID: episodeID))
    }
  }

  actor RSSReapCounter {
    private(set) var count = 0

    func record() { count += 1 }
  }

  final class RSSSettleRecorder: PodcastPlaybackSettleObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var settled = 0

    var count: Int { lock.withLock { settled } }

    func playbackPositionSettled() {
      lock.withLock { settled += 1 }
    }
  }

  /// Reads the stored position at the moment cloud sync is told a listen has settled, which is the
  /// position it will send.
  final class RSSSettlePositionRecorder: PodcastPlaybackSettleObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var database: AppDatabase?
    private var episodeRowID: Int64?
    private var recorded: [Double?] = []

    var positions: [Double?] { lock.withLock { recorded } }

    func watch(database: AppDatabase, episodeRowID: Int64) {
      lock.withLock {
        self.database = database
        self.episodeRowID = episodeRowID
      }
    }

    func playbackPositionSettled() {
      let (database, episodeRowID) = lock.withLock { (self.database, self.episodeRowID) }
      guard let database, let episodeRowID else { return }
      let position = try? database.dbWriter.read { db in
        try Double.fetchOne(
          db, sql: "SELECT position FROM rssEpisodeState WHERE episodeId = ?",
          arguments: [episodeRowID])
      }
      lock.withLock { recorded.append(position ?? nil) }
    }
  }
}
