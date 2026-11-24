import Foundation
import GRDB
import Testing

@testable import Persistence

/// The recent-episodes shelf is a partial view: the newest N across a whole library, never any one
/// show's complete list. These tests keep that partiality from being mistaken for authority,
/// above all by the generation-based soft-delete sweep.
@Suite("Recent episode store")
struct RecentEpisodeStoreTests {
  @Test("episodes land against the show named by their library item id")
  func episodesLandAgainstTheirShow() async throws {
    let harness = try await Harness()
    let first = try await harness.insertShow("show-1")
    let second = try await harness.insertShow("show-2")

    let applied = try await harness.store.apply(
      accountId: harness.accountID,
      episodes: [
        Self.upsert(show: "show-1", episode: "ep-a", title: "A"),
        Self.upsert(show: "show-2", episode: "ep-b", title: "B"),
      ])

    #expect(applied == 2)
    #expect(try harness.episodeIDs(ofLocalItem: first) == ["ep-a"])
    #expect(try harness.episodeIDs(ofLocalItem: second) == ["ep-b"])
    #expect(try harness.liveEpisode("ep-a")?.title == "A")
  }

  /// One payload spanning many shows must not become a per-show write storm.
  @Test("a payload spanning several shows is written in a single transaction")
  func multiShowPayloadIsOneTransaction() async throws {
    let harness = try await Harness()
    for index in 1...5 { _ = try await harness.insertShow("show-\(index)") }

    let before = harness.transactionCount
    _ = try await harness.store.apply(
      accountId: harness.accountID,
      episodes: (1...5).map { Self.upsert(show: "show-\($0)", episode: "ep-\($0)", title: "E") })

    #expect(harness.transactionCount - before == 1)
  }

  @Test("re-applying an episode updates it in place rather than duplicating it")
  func reapplyingAnEpisodeUpdatesInPlace() async throws {
    let harness = try await Harness()
    let show = try await harness.insertShow("show-1")
    _ = try await harness.store.apply(
      accountId: harness.accountID,
      episodes: [Self.upsert(show: "show-1", episode: "ep-a", title: "First title")])

    _ = try await harness.store.apply(
      accountId: harness.accountID,
      episodes: [Self.upsert(show: "show-1", episode: "ep-a", title: "Corrected title")])

    #expect(try harness.episodeIDs(ofLocalItem: show) == ["ep-a"])
    #expect(try harness.liveEpisode("ep-a")?.title == "Corrected title")
  }

  /// The sweep in `PodcastRefreshStore.apply` soft-deletes every episode of a show that a
  /// complete response did not mention. A shelf payload mentions a handful of a show's episodes,
  /// so running that rule here would delete almost the entire local catalogue.
  @Test("a partial payload never soft-deletes the episodes it omits")
  func partialPayloadNeverSoftDeletes() async throws {
    let harness = try await Harness()
    let show = try await harness.insertShow("show-1")
    try await harness.seedEpisode(itemID: show, serverEpisodeID: "old-1", generation: 4)
    try await harness.seedEpisode(itemID: show, serverEpisodeID: "old-2", generation: 4)
    try await harness.seedEpisode(itemID: show, serverEpisodeID: "old-3", generation: 4)

    _ = try await harness.store.apply(
      accountId: harness.accountID,
      episodes: [Self.upsert(show: "show-1", episode: "brand-new", title: "New")])

    #expect(
      try harness.episodeIDs(ofLocalItem: show) == ["brand-new", "old-1", "old-2", "old-3"])
  }

  /// A later complete refresh computes its generation as `MAX(lastSeenGeneration) + 1` and sweeps
  /// anything it does not re-see. If the shelf raised that ceiling, the refresh's own generation
  /// would collide with rows it never visited and the sweep would start missing real deletions.
  @Test("a shelf write does not raise the show's generation ceiling")
  func shelfWriteDoesNotRaiseTheGenerationCeiling() async throws {
    let harness = try await Harness()
    let show = try await harness.insertShow("show-1")
    try await harness.seedEpisode(itemID: show, serverEpisodeID: "existing", generation: 7)

    _ = try await harness.store.apply(
      accountId: harness.accountID,
      episodes: [Self.upsert(show: "show-1", episode: "brand-new", title: "New")])

    #expect(try harness.maximumGeneration(ofLocalItem: show) == 7)
    #expect(try harness.liveEpisode("existing")?.lastSeenGeneration == 7)
  }

  @Test("an episode naming a show this account does not hold is skipped, not thrown on")
  func unknownShowIsSkipped() async throws {
    let harness = try await Harness()
    let show = try await harness.insertShow("show-1")

    let applied = try await harness.store.apply(
      accountId: harness.accountID,
      episodes: [
        Self.upsert(show: "not-mine", episode: "ep-x", title: "X"),
        Self.upsert(show: "show-1", episode: "ep-a", title: "A"),
      ])

    #expect(applied == 1)
    #expect(try harness.episodeIDs(ofLocalItem: show) == ["ep-a"])
  }

  @Test("a shelf payload cannot update a show in an excluded library")
  func excludedShowIsSkipped() async throws {
    let harness = try await Harness()
    let included = try await harness.insertShow("included-show")
    let excluded = try await harness.insertExcludedShow("excluded-show")

    let applied = try await harness.store.apply(
      accountId: harness.accountID,
      episodes: [
        Self.upsert(show: "included-show", episode: "included-episode", title: "Included"),
        Self.upsert(show: "excluded-show", episode: "excluded-episode", title: "Excluded"),
      ])

    #expect(applied == 1)
    #expect(try harness.episodeIDs(ofLocalItem: included) == ["included-episode"])
    #expect(try harness.episodeIDs(ofLocalItem: excluded).isEmpty)
  }

  private static func upsert(
    show: String, episode: String, title: String
  ) -> RecentEpisodeUpsert {
    RecentEpisodeUpsert(
      serverItemID: show,
      serverEpisodeID: episode,
      title: title,
      subtitle: nil,
      episodeDescription: nil,
      seasonNumber: nil,
      episodeNumber: nil,
      episodeType: nil,
      mimeType: nil,
      durationSeconds: 1_200,
      sizeBytes: nil,
      publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
      storedAudio: nil)
  }

  /// Counts committed write transactions via GRDB's observer hook. `PRAGMA data_version` only moves
  /// for commits made on other connections, so it never ticks for an in-memory database.
  private final class CommitCounter: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var commits = 0

    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return commits
    }

    func observes(eventsOfKind kind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseDidRollback(_ db: Database) {}
    func databaseDidCommit(_ db: Database) {
      lock.lock()
      commits += 1
      lock.unlock()
    }
  }

  private struct Harness {
    let database: AppDatabase
    let store: RecentEpisodeStore
    let accountID: Int64
    private let libraryID: Int64
    private let commits = CommitCounter()

    init() async throws {
      let database = try AppDatabase.inMemory()
      self.database = database
      store = RecentEpisodeStore(database: database)
      let ids = try await database.writeAsync { db -> (Int64, Int64) in
        var account = AccountRecord(
          clientUUID: "recent-client", serverBaseURL: "https://recent.example.test",
          serverUserId: "user_fixture", serverVersion: "2.35.1")
        try account.insert(db)
        var library = LibraryRecord(
          accountId: account.id!, serverLibraryId: "podcasts", mediaType: "podcast",
          name: "Podcasts")
        try library.insert(db)
        return (account.id!, library.id!)
      }
      accountID = ids.0
      libraryID = ids.1
      database.dbWriter.add(transactionObserver: commits)
    }

    var transactionCount: Int { commits.count }

    func insertShow(_ serverItemID: String) async throws -> Int64 {
      try await database.writeAsync { db in
        var item = ItemRecord(
          accountId: accountID, libraryId: libraryID, serverItemId: serverItemID,
          mediaKind: "podcast", title: serverItemID, sortTitle: serverItemID)
        try item.insert(db)
        return item.id!
      }
    }

    func insertExcludedShow(_ serverItemID: String) async throws -> Int64 {
      try await database.writeAsync { db in
        var library = LibraryRecord(
          accountId: accountID, serverLibraryId: "excluded-podcasts", mediaType: "podcast",
          name: "Excluded Podcasts", isIncluded: false)
        try library.insert(db)
        var item = ItemRecord(
          accountId: accountID, libraryId: library.id!, serverItemId: serverItemID,
          mediaKind: "podcast", title: serverItemID, sortTitle: serverItemID)
        try item.insert(db)
        return item.id!
      }
    }

    func seedEpisode(itemID: Int64, serverEpisodeID: String, generation: Int) async throws {
      try await database.writeAsync { db in
        var episode = PodcastEpisodeRecord(
          accountId: accountID, itemId: itemID, serverEpisodeId: serverEpisodeID,
          title: serverEpisodeID, lastSeenGeneration: generation)
        try episode.insert(db)
      }
    }

    func episodeIDs(ofLocalItem itemID: Int64) throws -> [String] {
      try database.read { db in
        try String.fetchAll(
          db,
          sql: """
            SELECT serverEpisodeId FROM podcastEpisode
            WHERE itemId = ? AND softDeleted = 0 ORDER BY serverEpisodeId
            """,
          arguments: [itemID])
      }
    }

    func maximumGeneration(ofLocalItem itemID: Int64) throws -> Int {
      try database.read { db in
        try Int.fetchOne(
          db, sql: "SELECT MAX(lastSeenGeneration) FROM podcastEpisode WHERE itemId = ?",
          arguments: [itemID]) ?? 0
      }
    }

    func liveEpisode(_ serverEpisodeID: String) throws -> PodcastEpisodeRecord? {
      try database.read { db in
        try PodcastEpisodeRecord
          .filter(Column("serverEpisodeId") == serverEpisodeID)
          .fetchOne(db)
      }
    }
  }
}
