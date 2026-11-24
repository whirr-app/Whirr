import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite struct ContinueSeriesReadingTests {

  @Test("fractional successor is selected without integer successor arithmetic")
  func fractionalSuccessor() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    let finishedID = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-1",
      seriesName: "S #1")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: finishedID, currentTime: 100,
      isFinished: true, localSequence: 1)
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-1.5",
      seriesName: "S #1.5")

    #expect(try await Self.ids(from: reading, limit: 10) == ["s-1.5"])
  }

  @Test("the library setting restricts selection to books after finished sequences")
  func librarySettingOnlyOffersLaterBooks() async throws {
    let (
      restrictedDatabase, restrictedReading, restrictedItemDAO, restrictedAccountId,
      restrictedLibraryId
    ) = try await Self.context(onlyShowLaterBooksInContinueSeries: true)
    try await Self.seedFinishedAndUnstarted(
      restrictedDatabase, itemDAO: restrictedItemDAO, accountId: restrictedAccountId,
      libraryId: restrictedLibraryId,
      finished: [("s-1", "1"), ("s-3", "3")], unfinished: [("s-2", "2"), ("s-4", "4")])

    let (
      unrestrictedDatabase, unrestrictedReading, unrestrictedItemDAO, unrestrictedAccountId,
      unrestrictedLibraryId
    ) = try await Self.context()
    try await Self.seedFinishedAndUnstarted(
      unrestrictedDatabase, itemDAO: unrestrictedItemDAO, accountId: unrestrictedAccountId,
      libraryId: unrestrictedLibraryId,
      finished: [("s-1", "1"), ("s-3", "3")], unfinished: [("s-2", "2"), ("s-4", "4")])

    #expect(try await Self.ids(from: restrictedReading, limit: 10) == ["s-4"])
    #expect(try await Self.ids(from: unrestrictedReading, limit: 10) == ["s-2"])
  }

  @Test("a restricted series with no unfinished book after the threshold offers nothing")
  func restrictedSeriesBelowFinishedThresholdOffersNothing() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context(
      onlyShowLaterBooksInContinueSeries: true)
    try await Self.seedFinishedAndUnstarted(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      finished: [("s-1", "1"), ("s-3", "3")], unfinished: [("s-2", "2")])

    #expect(try await Self.ids(from: reading, limit: 10).isEmpty)
  }

  @Test("a restricted series with absent finished sequences behaves as unrestricted")
  func restrictedSeriesWithAbsentFinishedSequencesIsUnrestricted() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context(
      onlyShowLaterBooksInContinueSeries: true)

    for (serverItemId, localSequence) in [("s-finished-a", 1), ("s-finished-b", 2)] {
      let itemID = try Self.insertBook(
        itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
        seriesName: "S")
      try await HomeReadingFixtures.writeProgress(
        database, accountId: accountId, itemId: itemID, currentTime: 100,
        isFinished: true, localSequence: Int64(localSequence))
    }
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-2",
      seriesName: "S #2")

    #expect(try await Self.ids(from: reading, limit: 10) == ["s-2"])
  }

  @Test("one opted-in library restricts a series folded across libraries")
  func oneRestrictedLibraryRestrictsTheWholeFoldedSeries() async throws {
    let (database, reading, itemDAO, accountId, openLibraryId) = try await Self.context()
    let restrictedLibraryId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: "restricted", mediaType: "book",
        name: "Restricted", onlyShowLaterBooksInContinueSeries: true)
      try library.insert(db)
      return library.id!
    }

    for (libraryId, serverItemId, sequence) in [
      (openLibraryId, "s-1", "1"), (restrictedLibraryId, "s-3", "3"),
    ] {
      let itemID = try Self.insertBook(
        itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
        seriesName: "S #\(sequence)")
      try await HomeReadingFixtures.writeProgress(
        database, accountId: accountId, itemId: itemID, currentTime: 100,
        isFinished: true, localSequence: 1)
    }
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: openLibraryId, serverItemId: "s-2",
      seriesName: "S #2")
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: restrictedLibraryId, serverItemId: "s-4",
      seriesName: "S #4")

    // The unrestricted library's #2 would win on sequence alone; the restriction is what withholds
    // it, and it has to reach the whole folded group or the setting is silently half-applied.
    #expect(try await Self.ids(from: reading, limit: 10) == ["s-4"])
  }

  @Test("gap selects the first unfinished book rather than an absent immediate successor")
  func gapSelectsFirstUnfinishedBook() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    for (serverItemId, sequence, localSequence) in [("s-1", "1", 1), ("s-2", "2", 2)] {
      let itemID = try Self.insertBook(
        itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
        seriesName: "S #\(sequence)")
      try await HomeReadingFixtures.writeProgress(
        database, accountId: accountId, itemId: itemID, currentTime: 100,
        isFinished: true, localSequence: Int64(localSequence))
    }
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-4",
      seriesName: "S #4")

    #expect(try await Self.ids(from: reading, limit: 10) == ["s-4"])
  }

  @Test("first unfinished book is selected even when it is not the immediate successor")
  func firstUnfinishedIsNotImmediateSuccessor() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    for (serverItemId, sequence, localSequence) in [("s-1", "1", 1), ("s-2", "2", 2)] {
      let itemID = try Self.insertBook(
        itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
        seriesName: "S #\(sequence)")
      try await HomeReadingFixtures.writeProgress(
        database, accountId: accountId, itemId: itemID, currentTime: 100,
        isFinished: true, localSequence: Int64(localSequence))
    }
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-3",
      seriesName: "S #3")

    #expect(try await Self.ids(from: reading, limit: 10) == ["s-3"])
  }

  @Test("non-numeric sequence orders like CAST AS FLOAT and therefore sorts before #4")
  func nonNumericSequenceUsesServerCastOrdering() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    let finishedID = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-3",
      seriesName: "S #3")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: finishedID, currentTime: 100,
      isFinished: true, localSequence: 1)
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-4",
      seriesName: "S #4")
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-three",
      seriesName: "S #three")

    #expect(try await Self.ids(from: reading, limit: 10) == ["s-three"])
  }

  @Test("absent sequence sorts last")
  func absentSequenceSortsLast() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    let finishedID = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-1",
      seriesName: "S #1")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: finishedID, currentTime: 100,
      isFinished: true, localSequence: 1)
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-unnumbered",
      seriesName: "S")
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-2",
      seriesName: "S #2")

    #expect(try await Self.ids(from: reading, limit: 10) == ["s-2"])
  }

  @Test("a flattened multi-series item contributes one offered entry to each series")
  func flattenedMultiSeriesValueExpandsIntoBothSeries() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    let finishedID = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "multi-1",
      seriesName: "Foo #1, Bar #1")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: finishedID, currentTime: 100,
      isFinished: true, localSequence: 1)
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "foo-2",
      seriesName: "Foo #2")
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "bar-2",
      seriesName: "Bar #2")

    let result = try await Self.ids(from: reading, limit: 10)
    #expect(result.count == 2)
    #expect(Set(result) == Set(["foo-2", "bar-2"]))
  }

  @Test("an in-progress book suppresses the whole series")
  func inProgressBookSuppressesWholeSeries() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    let finishedID = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-1",
      seriesName: "S #1")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: finishedID, currentTime: 100,
      isFinished: true, localSequence: 1)
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-2",
      seriesName: "S #2")
    let inProgressID = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-5",
      seriesName: "S #5")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: inProgressID, currentTime: 1,
      isFinished: false, localSequence: 2)

    #expect(try await Self.ids(from: reading, limit: 10).isEmpty)
  }

  @Test("ebook position also suppresses the whole series")
  func ebookPositionSuppressesWholeSeries() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    let finishedID = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-1",
      seriesName: "S #1")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: finishedID, currentTime: 100,
      isFinished: true, localSequence: 1)
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-2",
      seriesName: "S #2")
    let inProgressID = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-5",
      seriesName: "S #5")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: inProgressID, currentTime: 0,
      ebookProgress: 0.25, isFinished: false, localSequence: 2)

    #expect(try await Self.ids(from: reading, limit: 10).isEmpty)
  }

  @Test("one series contributes exactly one entry")
  func oneEntryPerSeries() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    for (serverItemId, sequence, localSequence) in [("s-1", "1", 1), ("s-3", "3", 2)] {
      let itemID = try Self.insertBook(
        itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
        seriesName: "S #\(sequence)")
      try await HomeReadingFixtures.writeProgress(
        database, accountId: accountId, itemId: itemID, currentTime: 100,
        isFinished: true, localSequence: Int64(localSequence))
    }
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-2",
      seriesName: "S #2")
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-4",
      seriesName: "S #4")

    #expect(try await Self.ids(from: reading, limit: 10) == ["s-2"])
  }

  @Test("a resolved dismissed series is excluded while other series remain")
  func resolvedHiddenSeriesIsExcluded() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Hidden", finishedID: "hidden-1", nextID: "hidden-2", localSequence: 1,
      lastActivityAt: Date(timeIntervalSince1970: 1_000))
    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Visible", finishedID: "visible-1", nextID: "visible-2", localSequence: 2,
      lastActivityAt: Date(timeIntervalSince1970: 2_000))
    try await Self.seedSeriesIndex(
      database, accountId: accountId, libraryId: "lib1",
      entries: [AuthorSeriesSnapshotEntry(kind: .series, entityID: "hidden-series", name: "Hidden")])
    try await HiddenContinueSeriesStore(database: database).replace(
      accountId: accountId, serverSeriesIDs: ["hidden-series"])

    #expect(try await Self.ids(from: reading, limit: 10) == ["visible-2"])
  }

  @Test("an unresolved dismissed series does not change the shelf")
  func unresolvedHiddenSeriesDoesNotChangeShelf() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Visible", finishedID: "visible-1", nextID: "visible-2", localSequence: 1,
      lastActivityAt: Date(timeIntervalSince1970: 1_000))
    try await HiddenContinueSeriesStore(database: database).replace(
      accountId: accountId, serverSeriesIDs: ["not-cached-yet"])

    #expect(try await Self.ids(from: reading, limit: 10) == ["visible-2"])
  }

  @Test("a hidden series does not consume a Continue Series limit slot")
  func hiddenSeriesDoesNotConsumeLimitSlot() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Old", finishedID: "old-1", nextID: "old-2", localSequence: 1,
      lastActivityAt: Date(timeIntervalSince1970: 1_000))
    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Middle", finishedID: "middle-1", nextID: "middle-2", localSequence: 2,
      lastActivityAt: Date(timeIntervalSince1970: 2_000))
    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Recent", finishedID: "recent-1", nextID: "recent-2", localSequence: 3,
      lastActivityAt: Date(timeIntervalSince1970: 3_000))
    try await Self.seedSeriesIndex(
      database, accountId: accountId, libraryId: "lib1",
      entries: [AuthorSeriesSnapshotEntry(kind: .series, entityID: "recent-series", name: "Recent")])
    try await HiddenContinueSeriesStore(database: database).replace(
      accountId: accountId, serverSeriesIDs: ["recent-series"])

    #expect(
      try await Self.ids(from: reading, limit: 2) == ["middle-2", "old-2"])
  }

  @Test("dismissing a series on the server removes it from a live shelf")
  func dismissalReachesALiveObservation() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Hidden", finishedID: "hidden-1", nextID: "hidden-2", localSequence: 1,
      lastActivityAt: Date(timeIntervalSince1970: 1_000))
    try await Self.seedSeriesIndex(
      database, accountId: accountId, libraryId: "lib1",
      entries: [AuthorSeriesSnapshotEntry(kind: .series, entityID: "hidden-series", name: "Hidden")])

    let observations = PersistenceObservationCollector(
      reading.observeContinueSeries(category: nil, limit: 10))
    #expect(
      await TestSupport.waitUntil {
        observations.values.last?.map(\.serverItemId) == ["hidden-2"]
      })

    // The dismissal arrives on a later refresh, so the shelf has to be inside the observed region
    // rather than only correct on the next cold read.
    try await HiddenContinueSeriesStore(database: database).replace(
      accountId: accountId, serverSeriesIDs: ["hidden-series"])

    #expect(await TestSupport.waitUntil { observations.values.last?.isEmpty == true })
  }

  @Test("series order uses the most recent progress row, not local sequence")
  func seriesOrderUsesProgressRecency() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Alpha", finishedID: "alpha-1", nextID: "alpha-2", localSequence: 99,
      lastActivityAt: Date(timeIntervalSince1970: 1_000))
    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Beta", finishedID: "beta-1", nextID: "beta-2", localSequence: 1,
      lastActivityAt: Date(timeIntervalSince1970: 2_000))

    #expect(try await Self.ids(from: reading, limit: 10) == ["beta-2", "alpha-2"])
  }

  @Test("limit counts series and keeps the two most recent series")
  func limitCountsSeries() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Alpha", finishedID: "alpha-1", nextID: "alpha-2", localSequence: 3,
      lastActivityAt: Date(timeIntervalSince1970: 1_000))
    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Beta", finishedID: "beta-1", nextID: "beta-2", localSequence: 1,
      lastActivityAt: Date(timeIntervalSince1970: 3_000))
    try await Self.seedFinishedAndNext(
      database, itemDAO: itemDAO, accountId: accountId, libraryId: libraryId,
      seriesName: "Gamma", finishedID: "gamma-1", nextID: "gamma-2", localSequence: 2,
      lastActivityAt: Date(timeIntervalSince1970: 2_000))

    #expect(try await Self.ids(from: reading, limit: 2) == ["beta-2", "gamma-2"])
  }

  @Test("podcasts never qualify even with a series-shaped name")
  func podcastsNeverQualify() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    let finishedID = try Self.insertPodcast(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "podcast-1",
      seriesName: "Podcast Series #1")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: finishedID, currentTime: 100,
      isFinished: true, localSequence: 1)
    _ = try Self.insertPodcast(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "podcast-2",
      seriesName: "Podcast Series #2")

    #expect(try await Self.ids(from: reading, limit: 10).isEmpty)
  }

  @Test("an EPUB-only series follows the requested media category")
  func ebookOnlySeriesFollowsCategoryFilter() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    var finished = HomeReadingFixtures.ebook(
      accountId: accountId, libraryId: libraryId, serverItemId: "ebook-1")
    finished.seriesName = "Ebook Series #1"
    let finishedID = try #require(try itemDAO.upsert(finished).id)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: finishedID, currentTime: 100,
      isFinished: true, localSequence: 1)

    var next = HomeReadingFixtures.ebook(
      accountId: accountId, libraryId: libraryId, serverItemId: "ebook-2")
    next.seriesName = "Ebook Series #2"
    _ = try itemDAO.upsert(next)

    #expect(
      try await Self.ids(from: reading, category: .ebook, limit: 10) == ["ebook-2"])
    #expect(
      try await Self.ids(from: reading, category: nil, limit: 10) == ["ebook-2"])
    #expect(
      try await Self.ids(from: reading, category: .audiobook, limit: 10).isEmpty)
  }

  @Test("opted-out libraries stay excluded from Continue Series")
  func optedOutLibrariesStayExcluded() async throws {
    let (database, reading, itemDAO, accountId, _) = try await Self.context()
    let excludedLibraryId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: "excluded", mediaType: "book", name: "Excluded",
        isIncluded: false)
      try library.insert(db)
      return library.id!
    }

    let finishedID = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: excludedLibraryId, serverItemId: "excluded-1",
      seriesName: "Excluded Series #1")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: finishedID, currentTime: 100,
      isFinished: true, localSequence: 1)
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: excludedLibraryId, serverItemId: "excluded-2",
      seriesName: "Excluded Series #2")

    #expect(try await Self.ids(from: reading, limit: 10).isEmpty)
  }

  @Test("an unfinished book with no progress row is eligible")
  func unfinishedBookWithoutProgressRowIsEligible() async throws {
    let (database, reading, itemDAO, accountId, libraryId) = try await Self.context()

    let finishedID = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-1",
      seriesName: "S #1")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: finishedID, currentTime: 100,
      isFinished: true, localSequence: 1)
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: "s-2",
      seriesName: "S #2")

    #expect(try await Self.ids(from: reading, limit: 10) == ["s-2"])
  }

  private static func context() async throws -> (
    AppDatabase, DefaultHomeReading, ItemDAO, Int64, Int64
  ) {
    try await context(onlyShowLaterBooksInContinueSeries: false)
  }

  private static func context(
    onlyShowLaterBooksInContinueSeries: Bool
  ) async throws -> (
    AppDatabase, DefaultHomeReading, ItemDAO, Int64, Int64
  ) {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1",
      onlyShowLaterBooksInContinueSeries: onlyShowLaterBooksInContinueSeries)
    return (database, reading, itemDAO, accountId, libraryId)
  }

  private static func seedFinishedAndUnstarted(
    _ database: AppDatabase,
    itemDAO: ItemDAO,
    accountId: Int64,
    libraryId: Int64,
    finished: [(serverItemId: String, sequence: String)],
    unfinished: [(serverItemId: String, sequence: String)]
  ) async throws {
    for (index, entry) in finished.enumerated() {
      let itemID = try Self.insertBook(
        itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: entry.serverItemId,
        seriesName: "S #\(entry.sequence)")
      try await HomeReadingFixtures.writeProgress(
        database, accountId: accountId, itemId: itemID, currentTime: 100,
        isFinished: true, localSequence: Int64(index + 1))
    }
    for entry in unfinished {
      _ = try Self.insertBook(
        itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: entry.serverItemId,
        seriesName: "S #\(entry.sequence)")
    }
  }

  private static func ids(
    from reading: DefaultHomeReading, limit: Int
  ) async throws -> [String] {
    try await ids(from: reading, category: nil, limit: limit)
  }

  private static func ids(
    from reading: DefaultHomeReading, category: ItemMediaCategory?, limit: Int
  ) async throws -> [String] {
    var iterator = reading.observeContinueSeries(category: category, limit: limit).makeAsyncIterator()
    return try #require(await iterator.next()).map(\.serverItemId)
  }

  private static func insertBook(
    _ itemDAO: ItemDAO,
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String,
    seriesName: String,
    title: String? = nil,
    sortTitle: String? = nil
  ) throws -> Int64 {
    var item = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryId, serverItemId: serverItemId)
    item.seriesName = seriesName
    if let title { item.title = title }
    if let sortTitle { item.sortTitle = sortTitle }
    return try #require(try itemDAO.upsert(item).id)
  }

  private static func insertPodcast(
    _ itemDAO: ItemDAO,
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String,
    seriesName: String
  ) throws -> Int64 {
    var item = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryId, serverItemId: serverItemId)
    item.seriesName = seriesName
    return try #require(try itemDAO.upsert(item).id)
  }

  private static func seedFinishedAndNext(
    _ database: AppDatabase,
    itemDAO: ItemDAO,
    accountId: Int64,
    libraryId: Int64,
    seriesName: String,
    finishedID: String,
    nextID: String,
    localSequence: Int64,
    lastActivityAt: Date
  ) async throws {
    let finishedItemID = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: finishedID,
      seriesName: "\(seriesName) #1")
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: finishedItemID, currentTime: 100,
      isFinished: true, localSequence: localSequence, lastActivityAt: lastActivityAt)
    _ = try Self.insertBook(
      itemDAO, accountId: accountId, libraryId: libraryId, serverItemId: nextID,
      seriesName: "\(seriesName) #2")
  }

  private static func seedSeriesIndex(
    _ database: AppDatabase,
    accountId: Int64,
    libraryId: String,
    entries: [AuthorSeriesSnapshotEntry]
  ) async throws {
    try await AuthorSeriesEntityStore(database: database).replaceSnapshot(
      accountID: accountId, libraryID: libraryId, entries: entries)
  }
}
