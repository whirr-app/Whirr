import Foundation
import GRDB
import Synchronization
import TestSupport
import Testing

@testable import Persistence

/// The mixed Saved for Later projection and its account-scoped observations.
@Suite struct SavedShelfReadingTests {

  @Test("saved rows are newest first with an id tie-break")
  func savedRowsAreOrderedBySavedAtThenID() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = Mutex(firstDate)
    let writer = SavedShelfStore(
      database: database, accountId: fixture.accountId, now: { clock.withLock { $0 } })
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    var iterator = reading.observeSaved(filter: nil, limit: nil).makeAsyncIterator()

    let initial = try #require(await iterator.next())
    #expect(initial.isEmpty)

    _ = try await writer.save(fixture.audiobook)
    _ = try #require(await iterator.next())

    clock.withLock { $0 = firstDate.addingTimeInterval(1) }
    _ = try await writer.save(fixture.ebook)
    _ = try #require(await iterator.next())

    // Equal timestamps are ordered by the later savedShelfEntry row id.
    _ = try await writer.save(fixture.episode)
    let rows = try #require(await iterator.next())
    #expect(rows.map(\.identity) == [fixture.episode, fixture.ebook, fixture.audiobook])
    #expect(
      rows.map(\.savedAt) == [
        firstDate.addingTimeInterval(1),
        firstDate.addingTimeInterval(1), firstDate,
      ])
  }

  @Test("whole-item saves project audiobook and ebook summaries")
  func wholeItemProjectionUsesItemTitleAndCategory() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    var iterator = reading.observeSaved(filter: nil, limit: nil).makeAsyncIterator()
    _ = try #require(await iterator.next())

    _ = try await writer.save(fixture.audiobook)
    _ = try #require(await iterator.next())
    _ = try await writer.save(fixture.ebook)
    let rows = try #require(await iterator.next())

    let audiobook = try #require(rows.first { $0.identity == fixture.audiobook })
    #expect(audiobook.subjectTitle == "Primary Audiobook")
    #expect(audiobook.contextTitle == nil)
    #expect(audiobook.category == .audiobook)
    #expect(audiobook.itemSummary?.title == "Primary Audiobook")
    #expect(audiobook.itemSummary?.serverUpdatedAt == Self.audiobookServerUpdatedAt)
    #expect(audiobook.episode == nil)

    let ebook = try #require(rows.first { $0.identity == fixture.ebook })
    #expect(ebook.subjectTitle == "Primary Ebook")
    #expect(ebook.category == .ebook)
    #expect(ebook.itemSummary?.title == "Primary Ebook")
    #expect(ebook.episode == nil)
  }

  @Test("episode saves project episode subject and show context")
  func episodeProjectionUsesEpisodeAndShowTitles() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    var iterator = reading.observeSaved(filter: nil, limit: nil).makeAsyncIterator()
    _ = try #require(await iterator.next())

    _ = try await writer.save(fixture.episode)
    let rows = try #require(await iterator.next())
    let row = try #require(rows.first)

    #expect(row.identity == fixture.episode)
    #expect(row.subjectTitle == "Primary Episode One")
    #expect(row.contextTitle == "Primary Podcast")
    #expect(row.category == .podcast)
    #expect(row.itemSummary == nil)
    #expect(row.episode?.title == "Primary Episode One")
    #expect(row.episode?.showTitle == "Primary Podcast")
    #expect(row.episode?.episodeID == "primary-episode-1")
  }

  @Test("category filtering happens before the limit")
  func categoryFilterIsAppliedBeforeLimit() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = Mutex(firstDate)
    let writer = SavedShelfStore(
      database: database, accountId: fixture.accountId, now: { clock.withLock { $0 } })
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    var iterator = reading.observeSaved(filter: .podcast, limit: 2).makeAsyncIterator()
    _ = try #require(await iterator.next())

    // These newer non-podcast rows must not consume the podcast limit.
    _ = try await writer.save(fixture.audiobook)
    _ = try await writer.save(fixture.ebook)
    clock.withLock { $0 = firstDate.addingTimeInterval(-1) }
    _ = try await writer.save(fixture.episode)
    _ = try #require(await iterator.next())
    clock.withLock { $0 = firstDate.addingTimeInterval(-2) }
    _ = try await writer.save(fixture.secondEpisode)
    let rows = try #require(await iterator.next())

    #expect(rows.count == 2)
    #expect(rows.map(\.identity) == [fixture.episode, fixture.secondEpisode])
    #expect(rows.allSatisfy { $0.category == .podcast })
  }

  @Test("nil limit returns all rows and a numeric limit truncates after ordering")
  func nilAndNumericLimits() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    for identity in [fixture.audiobook, fixture.ebook, fixture.episode] {
      _ = try await writer.save(identity)
    }
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)

    var allIterator = reading.observeSaved(filter: nil, limit: nil).makeAsyncIterator()
    let allRows = try #require(await allIterator.next())
    #expect(allRows.count == 3)

    var limitedIterator = reading.observeSaved(filter: nil, limit: 2).makeAsyncIterator()
    let limitedRows = try #require(await limitedIterator.next())
    #expect(limitedRows.count == 2)
    #expect(limitedRows.map(\.identity) == [fixture.episode, fixture.ebook])
  }

  @Test("hard-tombstoned saved rows use denormalized titles and live renames win")
  func hardTombstonedRowsUseDenormalizedTitlesAndLiveRenamesWin() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    _ = try await writer.save(fixture.audiobook)
    _ = try await writer.save(fixture.episode)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    var iterator = reading.observeSaved(filter: nil, limit: nil).makeAsyncIterator()
    let initial = try #require(await iterator.next())
    #expect(initial.allSatisfy { $0.isUnavailable == false })

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET title = '', softDeleted = 1 WHERE id IN (?, ?)",
        arguments: [fixture.audiobookItemRowID, fixture.showItemRowID])
      try db.execute(
        sql: "UPDATE podcastEpisode SET title = '', softDeleted = 1 WHERE id = ?",
        arguments: [fixture.episodeRowID])
    }

    let rows = try #require(await iterator.next())
    let audiobook = try #require(rows.first { $0.identity == fixture.audiobook })
    #expect(audiobook.isUnavailable)
    #expect(audiobook.subjectTitle == "Primary Audiobook")
    #expect(audiobook.itemSummary?.title == "Primary Audiobook")
    let episode = try #require(rows.first { $0.identity == fixture.episode })
    #expect(episode.isUnavailable)
    #expect(episode.subjectTitle == "Primary Episode One")
    #expect(episode.contextTitle == "Primary Podcast")
    #expect(episode.episode?.title == "Primary Episode One")
    #expect(episode.episode?.showTitle == "Primary Podcast")

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET title = ?, softDeleted = 0 WHERE id = ?",
        arguments: ["Renamed Audiobook", fixture.audiobookItemRowID])
    }

    let renamedRows = try #require(await iterator.next())
    let renamed = try #require(renamedRows.first { $0.identity == fixture.audiobook })
    #expect(renamed.isUnavailable == false)
    #expect(renamed.subjectTitle == "Renamed Audiobook")
    #expect(renamed.itemSummary?.title == "Renamed Audiobook")
  }

  @Test("unsaved items and another account's saves are excluded")
  func savedRowsAreAccountScoped() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let other = try await Self.seed(database, suffix: "other")
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    let otherWriter = SavedShelfStore(database: database, accountId: other.accountId)
    _ = try await writer.save(fixture.audiobook)
    _ = try await otherWriter.save(other.audiobook)

    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    var iterator = reading.observeSaved(filter: nil, limit: nil).makeAsyncIterator()
    let rows = try #require(await iterator.next())
    #expect(rows.map(\.identity) == [fixture.audiobook])
    #expect(rows.contains { $0.identity == other.audiobook } == false)
    #expect(rows.contains { $0.subjectTitle == "Primary Unsaved" } == false)
  }

  @Test("saved identities reflect save and remove")
  func savedIdentityObservationReflectsMutations() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    var iterator = reading.observeSavedIdentities().makeAsyncIterator()

    let initial = try #require(await iterator.next())
    #expect(initial.isEmpty)
    _ = try await writer.save(fixture.episode)
    let afterSave = try #require(await iterator.next())
    #expect(afterSave == [fixture.episode])

    try await writer.remove(fixture.episode)
    let afterRemove = try #require(await iterator.next())
    #expect(afterRemove.isEmpty)
  }

  @Test("unrelated writes do not emit an identical saved projection")
  func unrelatedWritesAreDeduplicated() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    _ = try await writer.save(fixture.audiobook)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    let observations = PersistenceObservationCollector(
      reading.observeSaved(filter: nil, limit: nil))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let before = observations.values

    // The observation tracks item because the projection joins it; removeDuplicates must drop the
    // re-run because this unsaved item's changed title cannot change the saved result.
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET title = ? WHERE id = ?",
        arguments: ["Primary Unsaved Changed", fixture.unsavedItemRowID])
    }
    // A real change written afterwards is the barrier: GRDB delivers in commit order, so a
    // duplicate of the unrelated write would arrive before the sentinel's emission.
    _ = try await writer.save(fixture.episode)
    #expect(await TestSupport.waitUntil { observations.values.count > before.count })
    #expect(Array(observations.values.prefix(before.count)) == before)
    #expect(observations.values.count == before.count + 1)
  }

  @Test("starting a saved item removes it from the observed shelf")
  func startedItemLeavesObservedShelf() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    var iterator = reading.observeSaved(filter: nil, limit: nil).makeAsyncIterator()
    _ = try #require(await iterator.next())

    _ = try await writer.save(fixture.audiobook)
    #expect(try #require(await iterator.next()).map(\.identity) == [fixture.audiobook])

    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: fixture.accountId, itemId: fixture.audiobookItemRowID,
        currentTime: 15, isFinished: false, localSequence: 1,
        origin: .local, originKey: "test")
      try progress.insert(db)
    }

    #expect(try #require(await iterator.next()).isEmpty)
  }

  @Test("explicitly saving a partially started item survives unchanged sync until progress moves")
  func partiallyStartedItemCanBeSavedAgain() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: fixture.accountId, itemId: fixture.audiobookItemRowID,
        currentTime: 15, isFinished: false, localSequence: 1,
        origin: .local, originKey: "test")
      try progress.insert(db)
    }

    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    var iterator = reading.observeSaved(filter: nil, limit: nil).makeAsyncIterator()
    _ = try #require(await iterator.next())
    _ = try await writer.save(fixture.audiobook)
    #expect(try #require(await iterator.next()).map(\.identity) == [fixture.audiobook])

    // A refresh may write the same positive value again. That is not evidence the user resumed.
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE mediaProgress SET currentTime = currentTime WHERE accountId = ? AND itemId = ?",
        arguments: [fixture.accountId, fixture.audiobookItemRowID])
    }
    let countAfterUnchangedSync = try database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM savedShelfEntry WHERE accountId = ?",
        arguments: [fixture.accountId])
    }
    #expect(countAfterUnchangedSync == 1)

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE mediaProgress SET currentTime = currentTime + 1 WHERE accountId = ? AND itemId = ?",
        arguments: [fixture.accountId, fixture.audiobookItemRowID])
    }
    #expect(try #require(await iterator.next()).isEmpty)
  }

  @Test("a saved partially started item lists its position floored to the minute")
  func savedItemFloorsPlaybackPosition() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: fixture.accountId, itemId: fixture.audiobookItemRowID,
        currentTime: 754.3, isFinished: false, localSequence: 1,
        origin: .local, originKey: "test")
      try progress.insert(db)
    }
    _ = try await SavedShelfStore(database: database, accountId: fixture.accountId)
      .save(fixture.audiobook)

    var iterator = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
      .observeSaved(filter: nil, limit: nil).makeAsyncIterator()
    let row = try #require(await iterator.next()).first
    #expect(row?.identity == fixture.audiobook)
    #expect(row?.itemSummary?.progressSeconds == 720)
  }

  @Test("a native RSS episode save appears in the saved identity projection")
  func nativeEpisodeAppearsInSavedIdentities() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let native = try await Self.seedNative(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    let observations = PersistenceObservationCollector(reading.observeSavedIdentities())
    #expect(await waitUntil("initial emission") { observations.contains { $0.isEmpty } })

    _ = try await writer.save(native.identity)
    #expect(
      await waitUntil("native identity projected") {
        observations.contains { $0 == [native.identity] }
      })

    _ = try await writer.save(fixture.episode)
    #expect(
      await waitUntil("both identities projected") {
        observations.contains { $0 == [native.identity, fixture.episode] }
      })

    try await writer.remove(native.identity)
    #expect(
      await waitUntil("native identity removed") {
        observations.contains { $0 == [fixture.episode] }
      })
  }

  @Test("a native RSS episode save projects a podcast episode row from the feed")
  func nativeEpisodeProjectsAPodcastRow() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let native = try await Self.seedNative(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    _ = try await writer.save(native.identity)

    let observations = PersistenceObservationCollector(reading.observeSaved(filter: nil, limit: nil))
    #expect(await waitUntil("native row projected") { observations.contains { $0.isEmpty == false } })
    let rows = try #require(observations.last { $0.isEmpty == false })
    let row = try #require(rows.first)

    #expect(rows.count == 1)
    #expect(row.identity == native.identity)
    #expect(row.subjectTitle == "Native Episode")
    #expect(row.contextTitle == "Native Feed")
    #expect(row.category == .podcast)
    #expect(row.itemSummary == nil)
    #expect(row.isUnavailable == false)
    let episode = try #require(row.episode)
    #expect(episode.itemID == native.itemID)
    #expect(episode.episodeID == native.identityKey)
    #expect(episode.title == "Native Episode")
    #expect(episode.showTitle == "Native Feed")
    #expect(episode.showAuthor == "Native Author")
    #expect(episode.durationSeconds == 60)
    #expect(episode.publishedAt == Date(timeIntervalSince1970: 1_650_000_000))
    #expect(episode.progressSeconds == 0)
    #expect(episode.isFinished == false)
    #expect(episode.artworkURL == URL(string: "https://example.com/native.jpg"))
    #expect(episode.artworkFeedURL == native.feedURL)
  }

  @Test("a native RSS episode belongs to the podcast filter only")
  func nativeEpisodeHonoursTheCategoryFilter() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let native = try await Self.seedNative(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    _ = try await writer.save(native.identity)
    _ = try await writer.save(fixture.audiobook)

    let podcasts = PersistenceObservationCollector(
      reading.observeSaved(filter: .podcast, limit: nil), stopAfter: 1)
    #expect(
      await waitUntil("podcast filter keeps the native row") {
        podcasts.contains { $0.map(\.identity) == [native.identity] }
      })

    let audiobooks = PersistenceObservationCollector(
      reading.observeSaved(filter: .audiobook, limit: nil), stopAfter: 1)
    #expect(
      await waitUntil("audiobook filter drops the native row") {
        audiobooks.contains { $0.map(\.identity) == [fixture.audiobook] }
      })

    let ebooks = PersistenceObservationCollector(
      reading.observeSaved(filter: .ebook, limit: nil), stopAfter: 1)
    #expect(await waitUntil("ebook filter is empty") { ebooks.contains { $0.isEmpty } })
  }

  @Test("a native RSS episode dropped by a feed refresh projects as unavailable")
  func nativeEpisodeDroppedFromTheFeedIsUnavailable() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let native = try await Self.seedNative(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    _ = try await writer.save(native.identity)
    let observations = PersistenceObservationCollector(reading.observeSaved(filter: nil, limit: nil))
    #expect(
      await waitUntil("available row projected") {
        observations.contains { $0.first?.isUnavailable == false }
      })

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssFeed SET refreshGeneration = refreshGeneration + 1 WHERE id = ?",
        arguments: [native.feedId])
    }
    #expect(
      await waitUntil("dropped row projected as unavailable") {
        observations.contains { $0.first?.isUnavailable == true }
      })
    let rows = try #require(observations.last { $0.first?.isUnavailable == true })
    #expect(rows.map(\.identity) == [native.identity])
    #expect(rows.first?.subjectTitle == "Native Episode")
  }

  @Test("a native RSS episode's progress reads from the device-owned state row")
  func nativeEpisodeProgressComesFromEpisodeState() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let native = try await Self.seedNative(database)
    let writer = SavedShelfStore(database: database, accountId: fixture.accountId)
    let reading = DefaultSavedShelfReading(database: database, accountId: fixture.accountId)
    try await database.writeAsync { db in
      // Finished before it was saved: a save made after completion is an explicit intent the
      // shelf keeps, and the row's zero position is what the projection must report.
      try RSSEpisodeStateRecord(
        episodeId: native.episodeId, position: 0, finished: true, localSequence: 1,
        updatedAt: Date()
      ).insert(db)
    }
    _ = try await writer.save(native.identity)

    let observations = PersistenceObservationCollector(
      reading.observeSaved(filter: nil, limit: nil), stopAfter: 1)
    #expect(
      await waitUntil("finished state projected") {
        observations.contains { $0.first?.episode?.isFinished == true }
      })
    #expect(observations.last { $0.isEmpty == false }?.first?.episode?.progressSeconds == 0)
  }

  // MARK: - Fixtures

  private struct NativeFixture: Sendable {
    let feedId: Int64
    let feedURL: URL
    let episodeId: Int64
    let itemID: String
    let identityKey: String
    let identity: SavedShelfIdentity
  }

  /// One device-owned feed with one episode. RSS rows have no account ownership, so this seeds
  /// alongside `seed` rather than inside it.
  private static func seedNative(_ database: AppDatabase) async throws -> NativeFixture {
    let feedURL = URL(string: "https://example.com/native-\(UUID().uuidString).xml")!
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: feedURL, title: "Native Feed", author: "Native Author", synopsis: nil,
      artworkURL: URL(string: "https://example.com/native.jpg"), subscribedAt: Date())
    let identityKey = "native-episode"
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: identityKey, title: "Native Episode",
          enclosureURL: URL(string: "https://example.com/native.mp3")!,
          publishedAt: Date(timeIntervalSince1970: 1_650_000_000), durationSeconds: 60)
      ])
    let episodeId = try await database.readAsync { db in
      let fetched = try Int64.fetchOne(
        db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
        arguments: [feedId, identityKey])
      return try #require(fetched)
    }
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: feedId)?.itemId)
    return NativeFixture(
      feedId: feedId, feedURL: feedURL, episodeId: episodeId, itemID: itemID,
      identityKey: identityKey,
      identity: .rssEpisode(itemID: itemID, episodeID: identityKey))
  }

  private struct Fixture: Sendable {
    let accountId: Int64
    let audiobookItemRowID: Int64
    let showItemRowID: Int64
    let audiobook: SavedShelfIdentity
    let ebook: SavedShelfIdentity
    let unsavedItemRowID: Int64
    let episode: SavedShelfIdentity
    let secondEpisode: SavedShelfIdentity
    let episodeRowID: Int64
  }

  private static let audiobookServerUpdatedAt = Date(timeIntervalSince1970: 1_790_000_000)

  private static func seed(
    _ database: AppDatabase, suffix: String = "primary"
  ) async throws -> Fixture {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-\(suffix)-\(UUID().uuidString)",
        serverBaseURL: "server-\(suffix)",
        serverUserId: "user-\(suffix)",
        serverVersion: "2.35.1")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!,
        serverLibraryId: "library-\(suffix)",
        mediaType: "book",
        name: "Library")
      try library.insert(db)

      let audiobookID = "\(suffix)-audiobook"
      var audiobook = ItemRecord(
        accountId: account.id!,
        libraryId: library.id!,
        serverItemId: audiobookID,
        mediaKind: "book",
        title: "\(suffix.capitalized) Audiobook",
        sortTitle: "\(suffix)-audiobook",
        author: "Author",
        durationSeconds: 3_600,
        numAudioFiles: 4,
        serverUpdatedAt: Self.audiobookServerUpdatedAt)
      try audiobook.insert(db)

      let ebookID = "\(suffix)-ebook"
      var ebook = ItemRecord(
        accountId: account.id!,
        libraryId: library.id!,
        serverItemId: ebookID,
        mediaKind: "book",
        title: "\(suffix.capitalized) Ebook",
        sortTitle: "\(suffix)-ebook",
        ebookFormat: "epub")
      try ebook.insert(db)

      var unsaved = ItemRecord(
        accountId: account.id!,
        libraryId: library.id!,
        serverItemId: "\(suffix)-unsaved",
        mediaKind: "book",
        title: "\(suffix.capitalized) Unsaved",
        sortTitle: "\(suffix)-unsaved",
        numAudioFiles: 1)
      try unsaved.insert(db)

      let showID = "\(suffix)-podcast"
      var show = ItemRecord(
        accountId: account.id!,
        libraryId: library.id!,
        serverItemId: showID,
        mediaKind: "podcast",
        title: "\(suffix.capitalized) Podcast",
        sortTitle: "\(suffix)-podcast",
        author: "Publisher")
      try show.insert(db)

      let episodeID = "\(suffix)-episode-1"
      var episode = PodcastEpisodeRecord(
        accountId: account.id!,
        itemId: show.id!,
        serverEpisodeId: episodeID,
        title: "\(suffix.capitalized) Episode One",
        subtitle: "Subtitle",
        durationSeconds: 1_800,
        publishedAt: Date(timeIntervalSince1970: 1_600_000_000),
        lastSeenGeneration: 1)
      try episode.insert(db)

      let secondEpisodeID = "\(suffix)-episode-2"
      var secondEpisode = PodcastEpisodeRecord(
        accountId: account.id!,
        itemId: show.id!,
        serverEpisodeId: secondEpisodeID,
        title: "\(suffix.capitalized) Episode Two",
        durationSeconds: 1_500,
        publishedAt: Date(timeIntervalSince1970: 1_600_000_100),
        lastSeenGeneration: 1)
      try secondEpisode.insert(db)

      return Fixture(
        accountId: account.id!,
        audiobookItemRowID: audiobook.id!,
        showItemRowID: show.id!,
        audiobook: .item(itemID: audiobookID),
        ebook: .item(itemID: ebookID),
        unsavedItemRowID: unsaved.id!,
        episode: .podcastEpisode(itemID: showID, episodeID: episodeID),
        secondEpisode: .podcastEpisode(itemID: showID, episodeID: secondEpisodeID),
        episodeRowID: episode.id!)
    }
  }
}
