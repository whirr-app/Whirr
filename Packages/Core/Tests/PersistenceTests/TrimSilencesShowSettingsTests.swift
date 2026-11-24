import Foundation
import GRDB
import Testing

@testable import Persistence

/// The per-show Trim Silences override: one column on each spine,
/// added by v92 beside the Voice Boost one. Every writer that touches a show's settings row must
/// leave the override alone, or saving any other show setting would reset trimming to Default.
@Suite struct TrimSilencesShowSettingsTests {

  // MARK: - Migration

  @Test func existingRowsOnBothSpinesInheritAfterV92() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v91")
    let (feedId, itemRowId) = try queue.write { db in
      #expect(try db.columns(in: "rssFeedSettings").contains { $0.name == "trimSilencesOverride" } == false)
      let feedId = try Self.insertFeed(db, name: "existing")
      try db.execute(
        sql: "INSERT INTO rssFeedSettings (feedId, rateStep, includeInLatest) VALUES (?, 30, 0)",
        arguments: [feedId])
      let show = try Self.insertShow(db, suffix: "existing")
      try db.execute(
        sql: """
          INSERT INTO podcastShowSettings (itemId, accountId, keepLatestOverride) VALUES (?, ?, 5)
          """,
        arguments: [show.itemRowId, show.accountId])
      return (feedId, show.itemRowId)
    }

    try SchemaV1.migrator().migrate(queue)

    try queue.read { db in
      let rss = try #require(
        try Row.fetchOne(db, sql: "SELECT * FROM rssFeedSettings WHERE feedId = ?", arguments: [feedId]))
      #expect((rss["trimSilencesOverride"] as String) == "inherit")
      #expect((rss["voiceBoostOverride"] as String) == "inherit")
      #expect((rss["rateStep"] as Int) == 30)
      let abs = try #require(
        try Row.fetchOne(
          db, sql: "SELECT * FROM podcastShowSettings WHERE itemId = ?", arguments: [itemRowId]))
      #expect((abs["trimSilencesOverride"] as String) == "inherit")
      #expect((abs["voiceBoostOverride"] as String) == "inherit")
      #expect((abs["keepLatestOverride"] as Int) == 5)
      #expect(try db.tableExists("pauseTrimEpisode"))
    }
  }

  @Test func bothTablesRejectAnUnknownOverride() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await Self.subscribeFeed(database, name: "checked")
    let show = try await database.writeAsync { db in try Self.insertShow(db, suffix: "checked") }
    let statements: [(String, StatementArguments)] = [
      ("INSERT INTO rssFeedSettings (feedId, trimSilencesOverride) VALUES (?, 'always')", [feedId]),
      ("INSERT INTO rssFeedSettings (feedId, voiceBoostOverride) VALUES (?, 'maximum')", [feedId]),
      (
        "INSERT INTO podcastShowSettings (itemId, accountId, trimSilencesOverride) VALUES (?, ?, 'on')",
        [show.itemRowId, show.accountId]
      ),
      (
        "INSERT INTO podcastShowSettings (itemId, accountId, voiceBoostOverride) VALUES (?, ?, 'moderate')",
        [show.itemRowId, show.accountId]
      ),
    ]
    for (sql, arguments) in statements {
      await #expect(throws: DatabaseError.self) {
        try await database.writeAsync { db in try db.execute(sql: sql, arguments: arguments) }
      }
    }
  }

  @Test func parsingFailsClosedToInherit() {
    #expect(TrimSilencesShowOverride.parse("maximum") == .maximum)
    #expect(TrimSilencesShowOverride.parse("always") == .inherit)
    #expect(TrimSilencesShowOverride.parse(nil) == .inherit)
    #expect(VoiceBoostShowOverride.parse("on") == .on)
    #expect(VoiceBoostShowOverride.parse("loud") == .inherit)
  }

  // MARK: - RSS

  @Test func anRSSOverrideRoundTripsAndInheritIsNotListed() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await Self.subscribeFeed(database, name: "first")
    let second = try await Self.subscribeFeed(database, name: "second")
    let store = RSSFeedSettingsStore(database: database)
    #expect(try await store.fetchTrimSilencesOverrides().isEmpty)

    try await store.setTrimSilencesOverride(feedId: first, override: .maximum)
    try await store.setTrimSilencesOverride(feedId: second, override: .off)
    #expect(try await store.fetchTrimSilencesOverrides() == [first: .maximum, second: .off])

    try await store.setTrimSilencesOverride(feedId: second, override: .inherit)
    #expect(try await store.fetchTrimSilencesOverrides() == [first: .maximum])
  }

  @Test func anRSSOverrideForAMissingFeedIsNotFound() async throws {
    let store = RSSFeedSettingsStore(database: try AppDatabase.inMemory())
    await #expect(throws: RSSFeedSettingsStoreError.feedNotFound) {
      try await store.setTrimSilencesOverride(feedId: 404, override: .moderate)
    }
  }

  @Test func everyRSSWriterKeepsTheOverride() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await Self.subscribeFeed(database, name: "writers")
    let store = RSSFeedSettingsStore(database: database)
    try await store.setTrimSilencesOverride(feedId: feedId, override: .moderate)
    try await Self.setVoiceBoost(database, table: "rssFeedSettings", key: "feedId", id: feedId, to: "on")

    try await store.updateSettings(
      feedId: feedId, autoDownload: .enabled, keepLatest: 2, deleteAfterPlayed: true, rateStep: 30,
      includeInLatest: false)
    try await store.setAutoDownloadOverride(feedId: feedId, override: .disabled)
    try await store.setKeepLatestOverride(feedId: feedId, count: 4)
    try await store.setDeleteAfterPlayedOverride(feedId: feedId, enabled: nil)
    try await store.setIncludeInLatest(feedId: feedId, enabled: true)
    try await store.setNotificationOverride(feedId: feedId, override: .enabled)
    try await store.setRateOverride(feedId: feedId, rateStep: 36)
    try await store.clearRateOverride(feedId: feedId)
    try await store.clearAllRateOverrides()

    #expect(try await store.fetchTrimSilencesOverrides() == [feedId: .moderate])
    #expect(
      try await Self.voiceBoost(database, table: "rssFeedSettings", key: "feedId", id: feedId) == "on")
    #expect(try await store.settings(feedId: feedId)?.keepLatest == 4)
  }

  @Test(.timeLimit(.minutes(1))) func theRSSStreamFollowsChanges() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await Self.subscribeFeed(database, name: "stream")
    let store = RSSFeedSettingsStore(database: database)
    let stream = store.observeTrimSilencesOverrides()

    try await store.setTrimSilencesOverride(feedId: feedId, override: .off)

    #expect(try await Self.first(stream, where: { $0 == [feedId: .off] }) == [feedId: .off])
  }

  // MARK: - ABS

  @Test func anABSOverrideRoundTripsByServerItemID() async throws {
    let database = try AppDatabase.inMemory()
    let show = try await database.writeAsync { db in try Self.insertShow(db, suffix: "abs") }
    let store = PodcastSettingsStore(database: database, accountId: show.accountId)
    #expect(try await store.fetchTrimSilencesOverrides().isEmpty)

    try await store.setTrimSilencesOverride(itemID: show.serverItemID, override: .off)
    #expect(try await store.fetchTrimSilencesOverrides() == [show.serverItemID: .off])

    try await store.setTrimSilencesOverride(itemID: show.serverItemID, override: .inherit)
    #expect(try await store.fetchTrimSilencesOverrides().isEmpty)
  }

  @Test func anABSOverrideForAnUnknownShowIsNotFound() async throws {
    let database = try AppDatabase.inMemory()
    let show = try await database.writeAsync { db in try Self.insertShow(db, suffix: "known") }
    let store = PodcastSettingsStore(database: database, accountId: show.accountId)
    await #expect(throws: PodcastSettingsStoreError.itemNotFound) {
      try await store.setTrimSilencesOverride(itemID: "show-missing", override: .maximum)
    }
  }

  @Test func everyABSShowWriterKeepsTheOverride() async throws {
    let database = try AppDatabase.inMemory()
    let show = try await database.writeAsync { db in try Self.insertShow(db, suffix: "writers") }
    let store = PodcastSettingsStore(database: database, accountId: show.accountId)
    try await store.setTrimSilencesOverride(itemID: show.serverItemID, override: .maximum)
    try await Self.setVoiceBoost(
      database, table: "podcastShowSettings", key: "itemId", id: show.itemRowId, to: "off")

    try await store.setGlobalAutoDownloadEnabled(true)
    try await store.setShowAutoDownloadOverride(itemID: show.serverItemID, override: .enabled)
    try await store.setShowKeepLatestOverride(itemID: show.serverItemID, count: 2)
    try await store.setShowDeleteAfterPlayedOverride(itemID: show.serverItemID, enabled: true)

    #expect(try await store.fetchTrimSilencesOverrides() == [show.serverItemID: .maximum])
    #expect(
      try await Self.voiceBoost(database, table: "podcastShowSettings", key: "itemId", id: show.itemRowId)
        == "off")
  }

  @Test func anotherAccountsOverridesAreNotListed() async throws {
    let database = try AppDatabase.inMemory()
    let mine = try await database.writeAsync { db in try Self.insertShow(db, suffix: "mine") }
    let theirs = try await database.writeAsync { db in try Self.insertShow(db, suffix: "theirs") }
    try await PodcastSettingsStore(database: database, accountId: theirs.accountId)
      .setTrimSilencesOverride(itemID: theirs.serverItemID, override: .off)

    let store = PodcastSettingsStore(database: database, accountId: mine.accountId)
    #expect(try await store.fetchTrimSilencesOverrides().isEmpty)
  }

  // MARK: - Routing

  @Test(.timeLimit(.minutes(1))) func theFacadeRoutesEachIDAndMergesBothSpines() async throws {
    let database = try AppDatabase.inMemory()
    let show = try await database.writeAsync { db in try Self.insertShow(db, suffix: "routed") }
    let feedId = try await Self.subscribeFeed(database, name: "routed")
    let rssItemID = try #require(PodcastSourceIdentity.rss(feedId: feedId)?.itemId)
    let facade = RoutingTrimSilencesShowSettingsAccess(
      abs: PodcastSettingsStore(database: database, accountId: show.accountId),
      rss: RSSFeedSettingsStore(database: database))
    let stream = facade.observeTrimSilencesOverrides()

    try await facade.setTrimSilencesOverride(itemID: show.serverItemID, override: .moderate)
    try await facade.setTrimSilencesOverride(itemID: rssItemID, override: .off)

    let expected: [String: TrimSilencesShowOverride] = [show.serverItemID: .moderate, rssItemID: .off]
    #expect(try await facade.fetchTrimSilencesOverrides() == expected)
    #expect(try await RSSFeedSettingsStore(database: database).fetchTrimSilencesOverrides() == [feedId: .off])
    #expect(try await Self.first(stream, where: { $0 == expected }) == expected)
  }

  /// Two spines that emit at once must publish their merges in the order they were merged:
  /// the stream keeps only its newest value, so a stale merge yielded last would stand until the
  /// next change. One trial cannot force the interleaving, so many race it.
  @Test(.timeLimit(.minutes(1))) func theLastPublishedMergeHoldsBothSpinesLatest() async throws {
    let feedId: Int64 = 7
    let rssItemID = try #require(PodcastSourceIdentity.rss(feedId: feedId)?.itemId)
    let expected: [String: TrimSilencesShowOverride] = ["show-abs": .off, rssItemID: .maximum]

    for _ in 0..<20_000 {
      let (absStream, absInput) = AsyncStream<[String: TrimSilencesShowOverride]>.makeStream()
      let (rssStream, rssInput) = AsyncStream<[Int64: TrimSilencesShowOverride]>.makeStream()
      absInput.yield(["show-abs": .off])
      absInput.finish()
      rssInput.yield([feedId: .maximum])
      rssInput.finish()

      var last: [String: TrimSilencesShowOverride]?
      for await merged in mergedShowOverrideStream(abs: absStream, rss: rssStream) {
        last = merged
      }
      #expect(last == expected)
      if last != expected { return }
    }
  }

  @Test func theFacadeRefusesAnUnroutableID() async throws {
    let database = try AppDatabase.inMemory()
    let show = try await database.writeAsync { db in try Self.insertShow(db, suffix: "unroutable") }
    let facade = RoutingTrimSilencesShowSettingsAccess(
      abs: PodcastSettingsStore(database: database, accountId: show.accountId),
      rss: RSSFeedSettingsStore(database: database))
    await #expect(throws: PodcastSettingsStoreError.itemNotFound) {
      try await facade.setTrimSilencesOverride(itemID: "", override: .off)
    }
  }

  // MARK: - Voice Boost

  @Test func anRSSVoiceBoostOverrideRoundTripsWithoutTouchingTrim() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await Self.subscribeFeed(database, name: "boost")
    let store = RSSFeedSettingsStore(database: database)
    try await store.setTrimSilencesOverride(feedId: feedId, override: .maximum)
    #expect(try await store.fetchVoiceBoostOverrides().isEmpty)

    try await store.setVoiceBoostOverride(feedId: feedId, override: .off)
    #expect(try await store.fetchVoiceBoostOverrides() == [feedId: .off])
    #expect(try await store.fetchTrimSilencesOverrides() == [feedId: .maximum])

    try await store.setVoiceBoostOverride(feedId: feedId, override: .inherit)
    #expect(try await store.fetchVoiceBoostOverrides().isEmpty)
    await #expect(throws: RSSFeedSettingsStoreError.feedNotFound) {
      try await store.setVoiceBoostOverride(feedId: 404, override: .on)
    }
  }

  @Test func anABSVoiceBoostOverrideRoundTripsWithoutTouchingTrim() async throws {
    let database = try AppDatabase.inMemory()
    let show = try await database.writeAsync { db in try Self.insertShow(db, suffix: "boost") }
    let store = PodcastSettingsStore(database: database, accountId: show.accountId)
    try await store.setTrimSilencesOverride(itemID: show.serverItemID, override: .off)

    try await store.setVoiceBoostOverride(itemID: show.serverItemID, override: .on)
    #expect(try await store.fetchVoiceBoostOverrides() == [show.serverItemID: .on])
    #expect(try await store.fetchTrimSilencesOverrides() == [show.serverItemID: .off])
    await #expect(throws: PodcastSettingsStoreError.itemNotFound) {
      try await store.setVoiceBoostOverride(itemID: "show-missing", override: .on)
    }
  }

  @Test(.timeLimit(.minutes(1))) func theVoiceBoostFacadeRoutesEachIDAndMergesBothSpines()
    async throws
  {
    let database = try AppDatabase.inMemory()
    let show = try await database.writeAsync { db in try Self.insertShow(db, suffix: "boosted") }
    let feedId = try await Self.subscribeFeed(database, name: "boosted")
    let rssItemID = try #require(PodcastSourceIdentity.rss(feedId: feedId)?.itemId)
    let facade = RoutingVoiceBoostShowSettingsAccess(
      abs: PodcastSettingsStore(database: database, accountId: show.accountId),
      rss: RSSFeedSettingsStore(database: database))
    let stream = facade.observeVoiceBoostOverrides()

    try await facade.setVoiceBoostOverride(itemID: show.serverItemID, override: .off)
    try await facade.setVoiceBoostOverride(itemID: rssItemID, override: .on)

    let expected: [String: VoiceBoostShowOverride] = [show.serverItemID: .off, rssItemID: .on]
    #expect(try await facade.fetchVoiceBoostOverrides() == expected)
    #expect(try await Self.first(stream, where: { $0 == expected }) == expected)
    await #expect(throws: PodcastSettingsStoreError.itemNotFound) {
      try await facade.setVoiceBoostOverride(itemID: "", override: .on)
    }
  }

  // MARK: - Fixtures

  private struct Show {
    var accountId: Int64
    var itemRowId: Int64
    var serverItemID: String
  }

  private static func insertShow(_ db: Database, suffix: String) throws -> Show {
    var account = AccountRecord(
      clientUUID: "client-\(suffix)", serverBaseURL: "server-\(suffix)",
      serverUserId: "user-\(suffix)", serverVersion: "2.35.1")
    try account.insert(db)
    var library = LibraryRecord(
      accountId: account.id!, serverLibraryId: "library-\(suffix)", mediaType: "podcast",
      name: "Podcasts")
    try library.insert(db)
    var item = ItemRecord(
      accountId: account.id!, libraryId: library.id!, serverItemId: "show-\(suffix)",
      mediaKind: "podcast", title: "Show \(suffix)", sortTitle: "show \(suffix)")
    try item.insert(db)
    return Show(accountId: account.id!, itemRowId: item.id!, serverItemID: "show-\(suffix)")
  }

  private static func insertFeed(_ db: Database, name: String) throws -> Int64 {
    var record = RSSFeedRecord(
      feedURL: "https://example.com/\(name).xml", title: name, author: nil, subscribedAt: Date())
    try record.insert(db)
    return db.lastInsertedRowID
  }

  private static func subscribeFeed(_ database: AppDatabase, name: String) async throws -> Int64 {
    try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/\(name).xml")!, title: name, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
  }

  /// The column written directly, to prove every whole-row writer leaves it alone.
  private static func setVoiceBoost(
    _ database: AppDatabase, table: String, key: String, id: Int64, to value: String
  ) async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE \(table) SET voiceBoostOverride = ? WHERE \(key) = ?", arguments: [value, id])
    }
  }

  private static func voiceBoost(
    _ database: AppDatabase, table: String, key: String, id: Int64
  ) async throws -> String? {
    try await database.readAsync { db in
      try String.fetchOne(db, sql: "SELECT voiceBoostOverride FROM \(table) WHERE \(key) = ?", arguments: [id])
    }
  }

  /// The first value `stream` yields that satisfies `predicate`, or nil if it finishes first.
  private static func first<Value: Sendable>(
    _ stream: AsyncStream<Value>, where predicate: @Sendable (Value) -> Bool
  ) async throws -> Value? {
    for await value in stream where predicate(value) { return value }
    return nil
  }
}
