import Foundation
import GRDB
import Testing

@testable import Persistence

/// `DefaultSearchReading`'s cross-library, five-field, ranked local item search. Assertions
/// describe behaviour, not the `LIKE` or FTS5 implementation underneath, so either must pass.
@Suite struct SearchReadingTests {

  // MARK: - Cross-library

  @Test("libraryIDs: nil searches every library on the account; a set restricts to it")
  func crossLibrarySearch() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryA = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-a")
    let libraryB = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-b")

    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryA, serverItemId: "item-a", title: "Match Item A"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryB, serverItemId: "item-b", title: "Match Item B"))

    let both = try await reading.searchItems(
      query: "match", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(Set(both.rows.map(\.entityID)) == ["item-a", "item-b"])

    let onlyA = try await reading.searchItems(
      query: "match", libraryIDs: ["lib-a"], filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(onlyA.rows.map(\.entityID) == ["item-a"])
  }

  // MARK: - Fields

  @Test("a match on title, author, seriesName, or narratorName each return the row and report the field")
  func fieldMatchesReportTheirField() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "title-hit",
        title: "The Zephyr Chronicles"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "author-hit", title: "Unrelated",
        author: "Zephyr Winters"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "series-hit", title: "Unrelated",
        seriesName: "Zephyr Saga"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "narrator-hit", title: "Unrelated",
        narratorName: "Zephyr Reads"))

    let page = try await reading.searchItems(
      query: "zephyr", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    let byId = Dictionary(uniqueKeysWithValues: page.rows.map { ($0.entityID, $0) })

    #expect(byId["title-hit"]?.matchReason?.field == "title")
    #expect(byId["author-hit"]?.matchReason?.field == "author")
    #expect(byId["series-hit"]?.matchReason?.field == "seriesName")
    #expect(byId["narrator-hit"]?.matchReason?.field == "narratorName")
  }

  @Test("a book row carries its series name even when the query matched another field")
  func bookRowCarriesItsSeriesName() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "in-series",
        title: "The Gate of the Feral Gods", author: "Zephyr Winters",
        seriesName: "Zephyr Saga #6"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "standalone", title: "Unrelated",
        author: "Zephyr Winters"))

    let page = try await reading.searchItems(
      query: "zephyr winters", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    let byId = Dictionary(uniqueKeysWithValues: page.rows.map { ($0.entityID, $0) })

    #expect(byId["in-series"]?.seriesName == "Zephyr Saga #6")
    // Never an empty string standing in for "no series": the renderer distinguishes the two.
    #expect(byId["standalone"]?.seriesName == nil)
  }

  @Test("a mixed item search row stays audiobook while exposing ebook capability")
  func mixedItemRowCarriesEbookCapability() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "mixed-item",
        title: "Mixed Format Item", numAudioFiles: 2, ebookFormat: "epub")
    )

    let page = try await reading.searchItems(
      query: "mixed format", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    let row = try #require(page.rows.first { $0.entityID == "mixed-item" })

    #expect(row.mediaCategory == .audiobook)
    #expect(row.hasReadableEbook)
  }

  // MARK: - Folding

  @Test("case- and diacritic-folded queries match a diacritic-bearing title")
  func foldingMatchesDiacritics() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "emile", title: "Émile"))

    let lower = try await reading.searchItems(
      query: "emile", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(lower.rows.map(\.entityID) == ["emile"])

    let upper = try await reading.searchItems(
      query: "ÉMILE", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(upper.rows.map(\.entityID) == ["emile"])
  }

  @Test("canonical initials match and rank below a literal spelling")
  func canonicalInitialsMatchBelowLiteralSpelling() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "canonical",
        title: "Canonical Initials", author: "James S. A. Corey"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "literal",
        title: "Literal Initials", author: "James SA Corey"))

    let page = try await reading.searchItems(
      query: "James SA Corey", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)

    #expect(page.rows.map(\.entityID) == ["literal", "canonical"])
    #expect(page.rows.map(\.matchReason?.field) == ["author", "author"])
  }

  @Test("canonical tokens may span fields before ranking and pagination")
  func canonicalTokensMaySpanFields() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "cross-field",
        title: "Corey Collection", author: "James S. A."))

    let page = try await reading.searchItems(
      query: "James SA Corey", libraryIDs: nil, filters: BrowseFilters(), limit: 1, offset: 0)

    #expect(page.rows.map(\.entityID) == ["cross-field"])
    #expect(page.rows.first?.matchReason?.field == "title")
  }

  @Test("apostrophe and hyphen variants match canonically")
  func canonicalPunctuationVariantsMatch() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "apostrophe",
        title: "A Book", author: "Flannery O'Brien"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "hyphen",
        title: "Another Book", author: "Jean Luc Picard"))

    let apostrophe = try await reading.searchItems(
      query: "obrien", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    let hyphen = try await reading.searchItems(
      query: "jean-luc", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)

    #expect(apostrophe.rows.map(\.entityID) == ["apostrophe"])
    #expect(hyphen.rows.map(\.entityID) == ["hyphen"])
  }

  // MARK: - Token AND, order-independent

  @Test("multi-token queries AND within a field, independent of token order")
  func tokenANDIsOrderIndependent() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "gaiman", title: "Norse Mythology",
        author: "Neil Gaiman"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "pratchett", title: "Discworld",
        author: "Terry Pratchett"))

    let forward = try await reading.searchItems(
      query: "gaiman neil", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(forward.rows.map(\.entityID) == ["gaiman"])

    let reversed = try await reading.searchItems(
      query: "neil gaiman", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(reversed.rows.map(\.entityID) == ["gaiman"])

    let neither = try await reading.searchItems(
      query: "gaiman pratchett", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(neither.rows.isEmpty)
  }

  // MARK: - Ranking

  @Test(
    "ranks exact title above title prefix above title word-start above a title substring above an other-field substring"
  )
  func rankingOrdersByMatchQuality() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    // Five items, one per tier, all found by the single query "ocean":
    _ = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "exact", title: "Ocean"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "prefix",
        title: "Ocean Adventures"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "word-start",
        title: "The Story of the Ocean"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "mid-word-title",
        title: "Subocean Mysteries"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "other-field", title: "Mystery Series",
        author: "Ocean View Press"))

    let page = try await reading.searchItems(
      query: "ocean", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(
      page.rows.map(\.entityID) == [
        "exact", "prefix", "word-start", "mid-word-title", "other-field",
      ])
  }

  // MARK: - Paging

  @Test("limit/offset apply after filtering and ranking; hasMore reflects rows beyond the window")
  func pagingAppliesAfterRanking() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    for index in 1...5 {
      _ = try itemDAO.upsert(
        Self.book(
          accountId: accountId, libraryId: libraryId, serverItemId: "page-\(index)",
          title: "Page Item \(index)"))
    }

    let first = try await reading.searchItems(
      query: "item", libraryIDs: nil, filters: BrowseFilters(), limit: 2, offset: 0)
    #expect(first.rows.map(\.entityID) == ["page-1", "page-2"])
    #expect(first.hasMore == true)

    let middle = try await reading.searchItems(
      query: "item", libraryIDs: nil, filters: BrowseFilters(), limit: 2, offset: 2)
    #expect(middle.rows.map(\.entityID) == ["page-3", "page-4"])
    #expect(middle.hasMore == true)

    let last = try await reading.searchItems(
      query: "item", libraryIDs: nil, filters: BrowseFilters(), limit: 2, offset: 4)
    #expect(last.rows.map(\.entityID) == ["page-5"])
    #expect(last.hasMore == false)
  }

  // MARK: - Exclusions

  @Test("soft-deleted rows are excluded")
  func softDeletedRowsExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "gone", title: "Removed Book",
        softDeleted: true))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "present", title: "Present Book"))

    let page = try await reading.searchItems(
      query: "book", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(page.rows.map(\.entityID) == ["present"])
  }

  @Test("an empty, whitespace-only, or punctuation-only query returns an empty page without a match")
  func emptyNormalizedQueryReturnsEmptyPage() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    // A row that a naive `LIKE '%%'` implementation would wrongly return for an empty pattern.
    _ = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "any", title: "Any Book"))

    for query in ["", "   ", "...", "  --  "] {
      let page = try await reading.searchItems(
        query: query, libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
      #expect(page.rows.isEmpty, "query \(String(reflecting: query)) should match nothing")
      #expect(page.hasMore == false)
    }
  }

  // MARK: - Episodes

  @Test("an episode matches on title, subtitle, or episodeDescription and carries its show as parentItemID")
  func episodeFieldMatchesReportTheirField() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    let showId = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1", title: "A Show")

    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "title-hit",
      title: "Zephyr Winds")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "subtitle-hit",
      title: "Unrelated", subtitle: "Zephyr Notes")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "description-hit",
      title: "Unrelated", episodeDescription: "All about the Zephyr project")

    let page = try await reading.searchEpisodes(
      query: "zephyr", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    let byId = Dictionary(uniqueKeysWithValues: page.rows.map { ($0.entityID, $0) })

    #expect(byId.count == 3)
    #expect(byId["title-hit"]?.kind == .episode)
    #expect(byId["title-hit"]?.parentItemID == "show-1")
    #expect(byId["title-hit"]?.matchReason?.field == "title")
    #expect(byId["subtitle-hit"]?.matchReason?.field == "subtitle")
    #expect(byId["description-hit"]?.matchReason?.field == "episodeDescription")
  }

  /// The stored description is HTML, so the FTS index and the `LIKE` fallback must not see its
  /// markup, or `href` or a link's host would return episodes.
  @Test("an episode's description matches on its text, never on its markup, through insert and update")
  func episodeDescriptionMarkupIsNotSearchable() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    let showId = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1", title: "A Show")
    let episodeId = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "markup",
      title: "Unrelated",
      episodeDescription:
        "<div class=\"notes\"><p>Interview with <a href=\"https://linkhost.example/div\">Mara Quill</a> &amp; friends.</p></div>"
    )

    func rows(_ query: String) async throws -> [SearchResultRow] {
      try await reading.searchEpisodes(
        query: query, libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0
      ).rows
    }

    for markup in ["href", "div", "class", "notes", "linkhost", "https", "amp"] {
      #expect(try await rows(markup).isEmpty, "\(markup) matched the description's markup")
    }
    let hit = try #require(try await rows("quill").first)
    #expect(hit.entityID == "markup")
    #expect(hit.matchReason?.field == "episodeDescription")
    #expect(hit.matchReason?.text == "Interview with Mara Quill & friends.")
    #expect(try await rows("mara quill").count == 1)
    #expect(try await rows("friends").count == 1)

    // The update trigger re-indexes the new plain text and forgets the old.
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET episodeDescription = ? WHERE id = ?",
        arguments: ["<p>New guest: <em>Ola Vance</em></p>", episodeId])
    }
    #expect(try await rows("vance").count == 1)
    #expect(try await rows("quill").isEmpty)
    #expect(try await rows("em").isEmpty)
  }

  @Test("item and episode rows carry the backing item's serverUpdatedAt, an episode its show's")
  func rowsCarryBackingItemServerUpdatedAt() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    let bookUpdatedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let showUpdatedAt = Date(timeIntervalSince1970: 1_790_000_500)
    let showId = try await database.writeAsync { db in
      var book = Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "book-1", title: "Zephyr Book")
      book.serverUpdatedAt = bookUpdatedAt
      try book.insert(db)
      var show = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "show-1", mediaKind: "podcast",
        title: "A Show", sortTitle: "show-1", serverUpdatedAt: showUpdatedAt)
      try show.insert(db)
      return show.id!
    }
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "ep-1", title: "Zephyr Winds")

    let items = try await reading.searchItems(
      query: "zephyr", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    let episodes = try await reading.searchEpisodes(
      query: "zephyr", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)

    #expect(items.rows.map(\.serverUpdatedAt) == [bookUpdatedAt])
    #expect(episodes.rows.map(\.serverUpdatedAt) == [showUpdatedAt])
  }

  @Test("episodes of a soft-deleted show are excluded")
  func episodesOfSoftDeletedShowExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    let goneShowId = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "gone-show",
      title: "Gone Show", softDeleted: true)
    let presentShowId = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "present-show",
      title: "Present Show")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: goneShowId, serverEpisodeId: "gone-episode",
      title: "Widget Episode")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: presentShowId, serverEpisodeId: "present-episode",
      title: "Widget Episode")

    let page = try await reading.searchEpisodes(
      query: "widget", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(page.rows.map(\.entityID) == ["present-episode"])
  }

  // MARK: - Downloaded filter

  @Test(
    "downloadedOnly returns only items whose download rollup is complete, filtering before limit"
  )
  func downloadedOnlyFiltersItemsInSQLBeforeLimit() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    // sortTitle order (undownloaded first) puts it earlier than the two complete items,
    // so a naive "LIMIT then filter in Swift" implementation would return zero or the wrong rows
    // at limit 1. Only a WHERE-clause predicate applied before ORDER BY/LIMIT gets this right.
    let partialId = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "aaa-partial", title: "Book Partial")
    )
    .id!
    let pausedId = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "bbb-paused", title: "Book Paused")
    )
    .id!
    let deletingId = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "ccc-deleting", title: "Book Deleting")
    )
    .id!
    _ = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "ddd-none", title: "Book None"))
    let complete1Id = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "xxx-complete1", title: "Book Complete 1")
    )
    .id!
    let complete2Id = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "yyy-complete2", title: "Book Complete 2")
    )
    .id!

    try await Self.seedDownload(database, accountId: accountId, itemId: partialId, state: .downloading)
    try await Self.seedDownload(database, accountId: accountId, itemId: pausedId, state: .paused)
    try await Self.seedDownload(database, accountId: accountId, itemId: deletingId, state: .deleting)
    try await Self.seedDownload(database, accountId: accountId, itemId: complete1Id, state: .completed)
    try await Self.seedDownload(database, accountId: accountId, itemId: complete2Id, state: .completed)

    let firstPage = try await reading.searchItems(
      query: "book", libraryIDs: nil, filters: BrowseFilters(downloadedOnly: true), limit: 1,
      offset: 0)
    #expect(firstPage.rows.map(\.entityID) == ["xxx-complete1"])
    #expect(firstPage.hasMore == true)

    let bothPage = try await reading.searchItems(
      query: "book", libraryIDs: nil, filters: BrowseFilters(downloadedOnly: true), limit: 2,
      offset: 0)
    #expect(bothPage.rows.map(\.entityID) == ["xxx-complete1", "yyy-complete2"])
    #expect(bothPage.hasMore == false)
  }

  @Test("downloadedOnly returns only episodes whose download rollup is complete")
  func downloadedOnlyFiltersEpisodes() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    let showId = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1", title: "Show")

    let partialEpisodeId = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "episode-partial",
      title: "Gadget Partial")
    let completeEpisodeId = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "episode-complete",
      title: "Gadget Complete")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "episode-none",
      title: "Gadget None")

    try await Self.seedDownload(
      database, accountId: accountId, itemId: showId, podcastEpisodeId: partialEpisodeId,
      state: .downloading)
    try await Self.seedDownload(
      database, accountId: accountId, itemId: showId, podcastEpisodeId: completeEpisodeId,
      state: .completed)

    let page = try await reading.searchEpisodes(
      query: "gadget", libraryIDs: nil, filters: BrowseFilters(downloadedOnly: true), limit: 20,
      offset: 0)
    #expect(page.rows.map(\.entityID) == ["episode-complete"])
  }

  // MARK: - Playback filter

  @Test("playback: .unfinished is never started, and .inProgress is everything part-way through")
  func unfinishedIsNeverStartedAndInProgressIsPartWayThrough() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    let showId = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1", title: "Show")

    let finishedId = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "finished", title: "Quest Finished")
    )
    .id!
    let inProgressId = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "in-progress", title: "Quest In Progress")
    )
    .id!
    let neverStartedId = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "never-started", title: "Quest Never Started")
    )
    .id!
    _ = neverStartedId

    try await Self.seedProgress(database, accountId: accountId, itemId: finishedId, isFinished: true)
    try await Self.seedProgress(database, accountId: accountId, itemId: inProgressId, isFinished: false)
    // No progress row at all for `neverStartedId`, the only item "Unplayed" admits. The
    // part-listened one belongs to `.inProgress`, so "Unplayed" means what it says.

    let finishedEpisodeId = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "quest-episode-finished",
      title: "Quest Episode Finished")
    let neverStartedEpisodeId = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId,
      serverEpisodeId: "quest-episode-never-started", title: "Quest Episode Never Started")
    _ = neverStartedEpisodeId
    try await Self.seedProgress(
      database, accountId: accountId, itemId: showId, podcastEpisodeId: finishedEpisodeId,
      isFinished: true)

    let itemsPage = try await reading.searchItems(
      query: "quest", libraryIDs: nil, filters: BrowseFilters(playback: .unfinished), limit: 20,
      offset: 0)
    #expect(itemsPage.rows.map(\.entityID) == ["never-started"])

    let inProgressPage = try await reading.searchItems(
      query: "quest", libraryIDs: nil, filters: BrowseFilters(playback: .inProgress), limit: 20,
      offset: 0)
    #expect(inProgressPage.rows.map(\.entityID) == ["in-progress"])

    let episodesPage = try await reading.searchEpisodes(
      query: "quest", libraryIDs: nil, filters: BrowseFilters(playback: .unfinished), limit: 20,
      offset: 0)
    #expect(episodesPage.rows.map(\.entityID) == ["quest-episode-never-started"])

    // Episode scope is where a podcast playback question is answerable at all: the show itself is
    // excluded from the item scope above, and its episodes answer for themselves.
    let startedEpisodeId = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "quest-episode-started",
      title: "Quest Episode Started")
    try await Self.seedProgress(
      database, accountId: accountId, itemId: showId, podcastEpisodeId: startedEpisodeId,
      isFinished: false)
    let inProgressEpisodes = try await reading.searchEpisodes(
      query: "quest", libraryIDs: nil, filters: BrowseFilters(playback: .inProgress), limit: 20,
      offset: 0)
    #expect(inProgressEpisodes.rows.map(\.entityID) == ["quest-episode-started"])
  }

  /// A podcast show is excluded from every engaged playback state on both surfaces, not only the
  /// Library: one funnel row must mean one thing. `ItemFilterPredicate.itemPlayback` carries the
  /// exclusion precisely so this cannot drift.
  @Test("playback: a podcast show never appears in item results under an engaged state")
  func engagedPlaybackExcludesPodcastShowsFromItemResults() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "quest-show",
      title: "Quest Show")
    _ = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "quest-book", title: "Quest Book")
    )

    for state in [PlaybackFilter.unfinished, .inProgress, .finished] {
      let page = try await reading.searchItems(
        query: "quest", libraryIDs: nil, filters: BrowseFilters(playback: state), limit: 20,
        offset: 0)
      #expect(page.rows.map(\.entityID).contains("quest-show") == false)
    }

    let unfiltered = try await reading.searchItems(
      query: "quest", libraryIDs: nil, filters: .unfiltered, limit: 20, offset: 0)
    #expect(Set(unfiltered.rows.map(\.entityID)) == ["quest-show", "quest-book"])
  }

  /// "What have I finished?" is a state `BrowseFilters` can express and a `Bool` could not.
  /// `ItemFilterPredicate` is multi-state capable; this pins that Search reaches this case too,
  /// and that it is disjoint from both states above: a never-started item and a part-listened one
  /// are each excluded.
  @Test("playback: .finished returns only finished items/episodes")
  func finishedPlaybackReturnsOnlyFinished() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    let showId = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1", title: "Show")

    let finishedId = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "finished", title: "Quest Finished")
    )
    .id!
    let inProgressId = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "in-progress", title: "Quest In Progress")
    )
    .id!
    _ = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "never-started", title: "Quest Never Started")
    )

    try await Self.seedProgress(database, accountId: accountId, itemId: finishedId, isFinished: true)
    try await Self.seedProgress(database, accountId: accountId, itemId: inProgressId, isFinished: false)

    let finishedEpisodeId = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "quest-episode-finished",
      title: "Quest Episode Finished")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId,
      serverEpisodeId: "quest-episode-never-started", title: "Quest Episode Never Started")
    try await Self.seedProgress(
      database, accountId: accountId, itemId: showId, podcastEpisodeId: finishedEpisodeId,
      isFinished: true)

    let itemsPage = try await reading.searchItems(
      query: "quest", libraryIDs: nil, filters: BrowseFilters(playback: .finished), limit: 20,
      offset: 0)
    #expect(itemsPage.rows.map(\.entityID) == ["finished"])

    let episodesPage = try await reading.searchEpisodes(
      query: "quest", libraryIDs: nil, filters: BrowseFilters(playback: .finished), limit: 20,
      offset: 0)
    #expect(episodesPage.rows.map(\.entityID) == ["quest-episode-finished"])
  }

  // MARK: - Server row admission

  @Test("an inactive filter admits every seeded item id")
  func inactiveFilterAdmitsEverySeededItemID() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    _ = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryId, serverItemId: "book", title: "Book"))
    _ = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show", title: "Show")

    let ids = ["book", "show"]
    let admitted = try await reading.admittedItemIDs(ids, filters: BrowseFilters())

    #expect(admitted == Set(ids))
  }

  @Test("downloadedOnly admits only the completed-download item")
  func downloadedOnlyAdmitsOnlyCompletedDownloadItem() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    let partialId = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "partial", title: "Partial")
    ).id!
    let completeId = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "complete", title: "Complete")
    ).id!
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "none", title: "None"))

    try await Self.seedDownload(database, accountId: accountId, itemId: partialId, state: .downloading)
    try await Self.seedDownload(database, accountId: accountId, itemId: completeId, state: .completed)

    let admitted = try await reading.admittedItemIDs(
      ["partial", "complete", "none"], filters: BrowseFilters(downloadedOnly: true))

    #expect(admitted == ["complete"])
  }

  @Test("inProgress admits a started-but-unfinished item, not a never-started item")
  func inProgressAdmitsStartedButUnfinishedItem() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    let finishedId = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "finished", title: "Finished")
    ).id!
    let inProgressId = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "in-progress",
        title: "In Progress")
    ).id!
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "never-started",
        title: "Never Started"))

    try await Self.seedProgress(database, accountId: accountId, itemId: finishedId, isFinished: true)
    try await Self.seedProgress(database, accountId: accountId, itemId: inProgressId, isFinished: false)

    let admitted = try await reading.admittedItemIDs(
      ["finished", "in-progress", "never-started"],
      filters: BrowseFilters(playback: .inProgress))

    #expect(admitted == ["in-progress"])
  }

  @Test("a podcast show is not admitted under any engaged playback state")
  func podcastShowIsNotAdmittedUnderEngagedPlaybackState() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show", title: "Show")

    for playback in [PlaybackFilter.unfinished, .inProgress, .finished] {
      let admitted = try await reading.admittedItemIDs(
        ["show"], filters: BrowseFilters(playback: playback))
      #expect(admitted.isEmpty)
    }
  }

  @Test("soft-deleted items and excluded-library items are not admitted")
  func softDeletedAndExcludedLibraryItemsAreNotAdmitted() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let includedLibraryId = try await Self.seedLibrary(
      database, accountId: accountId, serverLibraryId: "included")
    let excludedLibraryId = try await Self.seedLibrary(
      database, accountId: accountId, serverLibraryId: "excluded")

    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: includedLibraryId, serverItemId: "soft-deleted",
        title: "Soft Deleted", softDeleted: true))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: excludedLibraryId, serverItemId: "excluded",
        title: "Excluded"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: includedLibraryId, serverItemId: "present",
        title: "Present"))
    try await database.writeAsync { db in
      try LibraryRecord
        .filter(Column("id") == excludedLibraryId)
        .updateAll(db, Column("isIncluded").set(to: false))
    }

    let admitted = try await reading.admittedItemIDs(
      ["soft-deleted", "excluded", "present"], filters: .unfiltered)

    #expect(admitted == ["present"])
  }

  @Test("an empty id list returns an empty admission set")
  func emptyIDListReturnsEmptyAdmissionSet() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)

    let admitted = try await reading.admittedItemIDs(
      [], filters: BrowseFilters(downloadedOnly: true, playback: .inProgress))

    #expect(admitted.isEmpty)
  }

  // MARK: - Categories filter

  @Test("categories restricts item search to matching categories; a podcast item matching the query is excluded")
  func categoriesRestrictsItemSearchToMatchingCategory() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "audiobook-hit",
        title: "Vortex Audiobook"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "ebook-hit",
        title: "Vortex Ebook", ebookFormat: "epub"))
    _ = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "podcast-hit",
      title: "Vortex Podcast")

    let page = try await reading.searchItems(
      query: "vortex", libraryIDs: nil, filters: BrowseFilters(categories: [.audiobook]),
      limit: 20, offset: 0)
    #expect(page.rows.map(\.entityID) == ["audiobook-hit"])
  }

  @Test("the ebook search filter includes mixed EPUB but excludes a PDF sidecar")
  func ebookCategoryFilterIncludesMixedEPUBOnly() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "audiobook-hit",
        title: "Vortex Audiobook", numAudioFiles: 2))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "ebook-hit",
        title: "Vortex Ebook", ebookFormat: "epub"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "mixed-hit",
        title: "Vortex Mixed", numAudioFiles: 2, ebookFormat: "epub"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "mixed-pdf-hit",
        title: "Vortex Mixed PDF", numAudioFiles: 2, ebookFormat: "pdf"))

    let page = try await reading.searchItems(
      query: "vortex", libraryIDs: nil, filters: BrowseFilters(categories: [.ebook]), limit: 20,
      offset: 0)
    #expect(Set(page.rows.map(\.entityID)) == ["ebook-hit", "mixed-hit"])
  }

  @Test("nil and empty-set categories both mean unfiltered")
  func nilAndEmptyCategoriesAreUnfiltered() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "audiobook-hit",
        title: "Nebula Audiobook"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "ebook-hit",
        title: "Nebula Ebook", ebookFormat: "epub"))
    _ = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "podcast-hit",
      title: "Nebula Podcast")

    let nilFiltered = try await reading.searchItems(
      query: "nebula", libraryIDs: nil, filters: BrowseFilters(categories: nil), limit: 20,
      offset: 0)
    #expect(
      Set(nilFiltered.rows.map(\.entityID)) == ["audiobook-hit", "ebook-hit", "podcast-hit"])

    let emptyFiltered = try await reading.searchItems(
      query: "nebula", libraryIDs: nil, filters: BrowseFilters(categories: []), limit: 20,
      offset: 0)
    #expect(
      Set(emptyFiltered.rows.map(\.entityID)) == ["audiobook-hit", "ebook-hit", "podcast-hit"])
  }

  @Test(
    "categories excluding the podcast category short-circuits episode search to an empty page without touching the database"
  )
  func categoriesExcludingPodcastShortCircuitsEpisodeSearch() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    let showId = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1", title: "Show")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "episode-1",
      title: "Vortex Episode")

    // If the implementation queried the database despite `.audiobook` excluding all episode
    // content, this dropped table would make the read throw instead of quietly returning
    // nothing, proving the short circuit happens before any SQL runs.
    try await database.writeAsync { db in
      try db.execute(sql: "DROP TABLE podcastEpisode")
    }

    let page = try await reading.searchEpisodes(
      query: "vortex", libraryIDs: nil, filters: BrowseFilters(categories: [.audiobook]),
      limit: 20, offset: 0)
    #expect(page.rows.isEmpty)
    #expect(page.hasMore == false)
  }

  @Test("a categories set including podcasts leaves episode search unaffected")
  func categoriesIncludingPodcastLeaveEpisodeSearchUnaffected() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    let showId = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1", title: "Show")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "episode-1",
      title: "Vortex Episode")

    let page = try await reading.searchEpisodes(
      query: "vortex", libraryIDs: nil, filters: BrowseFilters(categories: [.audiobook, .podcast]),
      limit: 20, offset: 0)
    #expect(page.rows.map(\.entityID) == ["episode-1"])
  }

  @Test("categories compose with downloadedOnly, playback, and libraryIDs, applied before limit")
  func categoriesComposeWithOtherFiltersAndLibraryIDs() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryA = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-a")
    let libraryB = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-b")

    let matchId = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryA, serverItemId: "match",
        title: "Comet Audiobook")
    ).id!
    let ebookId = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryA, serverItemId: "wrong-category",
        title: "Comet Ebook", ebookFormat: "epub")
    ).id!
    let finishedId = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryA, serverItemId: "wrong-finished",
        title: "Comet Finished")
    ).id!
    let notDownloadedId = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryA, serverItemId: "wrong-not-downloaded",
        title: "Comet Not Downloaded")
    ).id!
    _ = notDownloadedId
    let otherLibraryId = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryB, serverItemId: "wrong-library",
        title: "Comet Other Library")
    ).id!

    try await Self.seedDownload(database, accountId: accountId, itemId: matchId, state: .completed)
    try await Self.seedProgress(database, accountId: accountId, itemId: matchId, isFinished: false)
    try await Self.seedDownload(database, accountId: accountId, itemId: ebookId, state: .completed)
    try await Self.seedProgress(database, accountId: accountId, itemId: ebookId, isFinished: false)
    try await Self.seedDownload(database, accountId: accountId, itemId: finishedId, state: .completed)
    try await Self.seedProgress(database, accountId: accountId, itemId: finishedId, isFinished: true)
    try await Self.seedDownload(database, accountId: accountId, itemId: otherLibraryId, state: .completed)
    try await Self.seedProgress(database, accountId: accountId, itemId: otherLibraryId, isFinished: false)

    let page = try await reading.searchItems(
      query: "comet", libraryIDs: ["lib-a"],
      filters: BrowseFilters(
        categories: [.audiobook], downloadedOnly: true, playback: .inProgress), limit: 20,
      offset: 0)
    #expect(page.rows.map(\.entityID) == ["match"])
  }

  // MARK: - Composition

  @Test("filters compose with each other and with libraryIDs, applied before limit")
  func filtersComposeWithEachOtherAndLibraryIDs() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryA = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-a")
    let libraryB = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-b")

    // In library A: one item is downloaded+part-listened (should match), one is
    // downloaded+finished (excluded by playback: .inProgress), one is part-listened but not
    // downloaded (excluded by downloadedOnly).
    let matchId = try itemDAO.upsert(
      Self.book(accountId: accountId, libraryId: libraryA, serverItemId: "match", title: "Combo Match")
    )
    .id!
    let downloadedFinishedId = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryA, serverItemId: "downloaded-finished",
        title: "Combo Downloaded Finished")
    ).id!
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryA, serverItemId: "not-downloaded",
        title: "Combo Not Downloaded"))
    // In library B: an otherwise-identical downloaded+part-listened item, excluded only by
    // `libraryIDs: ["lib-a"]`.
    let otherLibraryId = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryB, serverItemId: "other-library",
        title: "Combo Other Library")
    ).id!

    try await Self.seedDownload(database, accountId: accountId, itemId: matchId, state: .completed)
    try await Self.seedProgress(database, accountId: accountId, itemId: matchId, isFinished: false)
    try await Self.seedDownload(
      database, accountId: accountId, itemId: downloadedFinishedId, state: .completed)
    try await Self.seedProgress(
      database, accountId: accountId, itemId: downloadedFinishedId, isFinished: true)
    try await Self.seedDownload(database, accountId: accountId, itemId: otherLibraryId, state: .completed)
    try await Self.seedProgress(database, accountId: accountId, itemId: otherLibraryId, isFinished: false)

    let page = try await reading.searchItems(
      query: "combo", libraryIDs: ["lib-a"],
      filters: BrowseFilters(downloadedOnly: true, playback: .inProgress), limit: 20, offset: 0)
    #expect(page.rows.map(\.entityID) == ["match"])
  }

  // MARK: - FTS5

  @Test("two prefix tokens each matching a different word within the same field")
  func twoPrefixTokensMatchWithinAField() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "gaiman", title: "Norse Mythology",
        author: "Neil Gaiman"))

    // "nei"/"gai" are prefixes of "Neil"/"Gaiman" respectively, not whole words. This pins the
    // FTS5 prefix-query path rather than a whole-token match.
    let page = try await reading.searchItems(
      query: "nei gai", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(page.rows.map(\.entityID) == ["gaiman"])
  }

  @Test("tokens spanning two different columns match, order-independently")
  func tokensSpanningTwoColumnsMatch() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    // The cross-column item has "gaiman" only in author and "ocean" only in title, so no single
    // column contains both tokens. Two decoys each contain only one of the two tokens, in a
    // column that does not pair with the other token, so they must not match either query.
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "cross-column",
        title: "Ocean Tales", author: "Neil Gaiman"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "title-only-decoy",
        title: "Ocean Voyage", author: "Someone Else"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "author-only-decoy",
        title: "Unrelated Book", author: "Neil Gaiman Junior"))

    let forward = try await reading.searchItems(
      query: "gaiman ocean", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(forward.rows.map(\.entityID) == ["cross-column"])

    let reversed = try await reading.searchItems(
      query: "ocean gaiman", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(reversed.rows.map(\.entityID) == ["cross-column"])
  }

  @Test(
    "a title-prefix episode hit outranks a description-substring hit from a more recently added episode"
  )
  func titlePrefixOutranksDescriptionSubstringRegardlessOfRecency() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    let showId = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1", title: "Show")

    // Added first (older, lower rowid): matches only via a description substring.
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "description-hit",
      title: "Unrelated Episode", episodeDescription: "A story that mentions vortex in passing")
    // Added second (more recent, higher rowid): matches via a title prefix, the stronger tier.
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "prefix-hit",
      title: "Vortex Adventures")

    let page = try await reading.searchEpisodes(
      query: "vortex", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(page.rows.map(\.entityID) == ["prefix-hit", "description-hit"])
  }

  @Test("FTS5 metacharacters in the query are treated as literal text, never as MATCH syntax")
  func ftsMetacharactersAreTreatedAsLiteralText() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "foo-item",
        title: "Foo Adventures"))

    // "foo*" normalizes to the single token "foo". The literal asterisk must never reach SQL as
    // an FTS prefix operator on its own.
    let starQuery = try await reading.searchItems(
      query: "foo*", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(starQuery.rows.map(\.entityID) == ["foo-item"])

    // "a OR b" must never be interpreted as FTS boolean syntax. "or" is a literal
    // token like any other, and since "Foo Adventures" contains no separate "b" token, this must
    // match nothing (an FTS boolean OR reading would instead match on "a" alone) and must not
    // throw.
    let booleanLookingQuery = try await reading.searchItems(
      query: "a OR b", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(booleanLookingQuery.rows.isEmpty)

    // An unbalanced quote must not crash the query. The quote character is stripped by
    // `SearchQueryNormalizer.tokens` before it reaches SQL, so this behaves like the plain query
    // "foo".
    let unbalancedQuoteQuery = try await reading.searchItems(
      query: "\"foo", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(unbalancedQuoteQuery.rows.map(\.entityID) == ["foo-item"])
  }

  @Test("local item and episode search excludes opted-out libraries")
  func localSearchExcludesOptedOutLibraries() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountID = try await Self.seedAccount(database)
    let includedLibraryID = try await Self.seedLibrary(
      database, accountId: accountID, serverLibraryId: "included")
    let excludedLibraryID = try await Self.seedLibrary(
      database, accountId: accountID, serverLibraryId: "excluded")
    _ = try await Self.seedShow(
      database, accountId: accountID, libraryId: includedLibraryID, serverItemId: "included-show",
      title: "Signal Included")
    let excludedShowID = try await Self.seedShow(
      database, accountId: accountID, libraryId: excludedLibraryID, serverItemId: "excluded-show",
      title: "Signal Excluded")
    _ = try await Self.seedEpisode(
      database, accountId: accountID, itemId: excludedShowID, serverEpisodeId: "excluded-episode",
      title: "Signal Episode")
    try await database.writeAsync { db in
      try LibraryRecord
        .filter(Column("id") == excludedLibraryID)
        .updateAll(db, Column("isIncluded").set(to: false))
    }

    let items = try await reading.searchItems(
      query: "signal", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(items.rows.map(\.entityID) == ["included-show"])
    let episodes = try await reading.searchEpisodes(
      query: "signal", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    #expect(episodes.rows.isEmpty)
  }

  // MARK: - Close-match fallback

  /// Worked examples, row for row, against two items. The fallback is
  /// asked directly: whether the model would reach it is `SearchModelTests`' concern.
  @Test("the close-match fallback reproduces the plan's worked examples")
  func closeMatchWorkedExamples() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "ocean",
        title: "The Ocean at the End of the Lane", author: "Neil Gaiman"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "leviathan",
        title: "Leviathan Wakes", author: "James S. A. Corey"))

    let examples: [(query: String, expected: [String])] = [
      ("gaimn", ["ocean"]),
      ("gaimna", ["ocean"]),
      ("neil gaimn", ["ocean"]),
      ("oceen lane", ["ocean"]),
      ("s.a. corei", ["leviathan"]),
      // Below the budget: a three-character token must be a whole word, so nothing.
      ("oce", []),
      // Tokens are ANDed: one plausible token does not carry an unrelated one.
      ("gaimn tchaikovsky", []),
      // `teh` has budget 0 and sinks the whole query.
      ("teh ocean", []),
    ]
    for example in examples {
      let page = try await reading.closeMatchItems(
        query: example.query, libraryIDs: nil, filters: BrowseFilters(), limit: 20)
      #expect(page.rows.map(\.entityID) == example.expected, "query \(example.query)")
      #expect(page.hasMore == false)
    }
  }

  /// SQLite's scalar `min()` is `NULL` if any argument is, and the distance function is `NULL` for
  /// every column without a close word. Without `COALESCE` around each call, a row whose only close
  /// word is in its last column vanishes.
  @Test("a close match found only in the last column is still returned, reporting that column")
  func closeMatchInLastColumnOnly() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "narrator-only",
        title: "Unrelated", narratorName: "Zephyrine Walsh"))

    let page = try await reading.closeMatchItems(
      query: "zephyrnie", libraryIDs: nil, filters: BrowseFilters(), limit: 20)

    #expect(page.rows.map(\.entityID) == ["narrator-only"])
    // Neither a literal nor a canonical token is in the row, so only the third pass can name the
    // field (the first field, `title`, would be wrong).
    #expect(page.rows.first?.matchReason?.field == "narratorName")
    #expect(page.rows.first?.matchReason?.text == "Zephyrine Walsh")
  }

  @Test("close matches order by total distance before sort title")
  func closeMatchesOrderByDistance() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    // `book` sets `sortTitle` to the server id, so sort title alone would put the farther first.
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "a-distance-one",
        title: "The Hobbit"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "z-distance-zero",
        title: "Hobit Tales"))

    let page = try await reading.closeMatchItems(
      query: "hobit", libraryIDs: nil, filters: BrowseFilters(), limit: 20)

    #expect(page.rows.map(\.entityID) == ["z-distance-zero", "a-distance-one"])
  }

  @Test("the close-match fallback obeys category filters and library scope")
  func closeMatchesObeyFiltersAndLibraryScope() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryA = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-a")
    let libraryB = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-b")
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryA, serverItemId: "audiobook",
        title: "Coraline", author: "Neil Gaiman"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryB, serverItemId: "ebook",
        title: "Stardust", author: "Neil Gaiman", ebookFormat: "epub"))

    let ebooks = try await reading.closeMatchItems(
      query: "gaimn", libraryIDs: nil, filters: BrowseFilters(categories: [.ebook]), limit: 20)
    #expect(ebooks.rows.map(\.entityID) == ["ebook"])

    let libraryAOnly = try await reading.closeMatchItems(
      query: "gaimn", libraryIDs: ["lib-a"], filters: BrowseFilters(), limit: 20)
    #expect(libraryAOnly.rows.map(\.entityID) == ["audiobook"])
  }

  @Test("a podcast hidden from the catalogue for having no server episodes is never a close match")
  func hiddenPodcastIsNeverACloseMatch() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    try await database.writeAsync { db in
      var hidden = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "hidden", mediaKind: "podcast",
        title: "Quasar Weekly", sortTitle: "hidden")
      hidden.podcastServerEpisodeCount = 0
      try hidden.insert(db)
      var visible = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "visible", mediaKind: "podcast",
        title: "Quasar Daily", sortTitle: "visible")
      visible.podcastServerEpisodeCount = 3
      try visible.insert(db)
    }

    let page = try await reading.closeMatchItems(
      query: "quasr", libraryIDs: nil, filters: BrowseFilters(), limit: 20)

    #expect(page.rows.map(\.entityID) == ["visible"])
  }

  @Test("episode close matches use title and subtitle only, tie-breaking on title")
  func episodeCloseMatchesUseTitleAndSubtitle() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")
    let showId = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1", title: "A Show")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "title-beta",
      title: "Zephyr Beta")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "title-alpha",
      title: "Zephyr Alpha")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "subtitle",
      title: "Unrelated", subtitle: "Zephyr notes")
    _ = try await Self.seedEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "description-only",
      title: "Elsewhere", episodeDescription: "All about the zephyr project")

    let page = try await reading.closeMatchEpisodes(
      query: "zepyhr", libraryIDs: nil, filters: BrowseFilters(), limit: 20)

    // Every match is one transposition away, so `title` alone orders them.
    #expect(page.rows.map(\.entityID) == ["subtitle", "title-alpha", "title-beta"])
    #expect(page.rows.allSatisfy { $0.parentItemID == "show-1" && $0.kind == .episode })
    #expect(page.rows.first?.matchReason?.field == "subtitle")
    #expect(page.hasMore == false)

    let audiobooksOnly = try await reading.closeMatchEpisodes(
      query: "zepyhr", libraryIDs: nil, filters: BrowseFilters(categories: [.audiobook]),
      limit: 20)
    #expect(audiobooksOnly.rows.isEmpty)
  }

  // MARK: - Fixtures

  private static func seedAccount(_ database: AppDatabase) async throws -> Int64 {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)
      return account.id!
    }
  }

  private static func seedLibrary(
    _ database: AppDatabase, accountId: Int64, serverLibraryId: String
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: serverLibraryId, mediaType: "book",
        name: serverLibraryId)
      try library.insert(db)
      return library.id!
    }
  }

  private static func book(
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String,
    title: String,
    author: String? = nil,
    seriesName: String? = nil,
    narratorName: String? = nil,
    numAudioFiles: Int? = nil,
    ebookFormat: String? = nil,
    softDeleted: Bool = false
  ) -> ItemRecord {
    ItemRecord(
      accountId: accountId, libraryId: libraryId, serverItemId: serverItemId, mediaKind: "book",
      title: title, sortTitle: serverItemId, author: author, numAudioFiles: numAudioFiles,
      ebookFormat: ebookFormat,
      seriesName: seriesName, narratorName: narratorName, softDeleted: softDeleted)
  }

  private static func seedShow(
    _ database: AppDatabase, accountId: Int64, libraryId: Int64, serverItemId: String, title: String,
    softDeleted: Bool = false
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemId, mediaKind: "podcast",
        title: title, sortTitle: serverItemId, softDeleted: softDeleted)
      try item.insert(db)
      return item.id!
    }
  }

  private static func seedEpisode(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, serverEpisodeId: String, title: String,
    subtitle: String? = nil, episodeDescription: String? = nil, softDeleted: Bool = false
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: itemId, serverEpisodeId: serverEpisodeId, title: title,
        subtitle: subtitle, episodeDescription: episodeDescription, lastSeenGeneration: 1,
        softDeleted: softDeleted)
      try episode.insert(db)
      return episode.id!
    }
  }

  private static func seedDownload(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, podcastEpisodeId: Int64? = nil,
    state: DownloadState
  ) async throws {
    try await database.writeAsync { db in
      var download = DownloadRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId,
        serverFileIno: UUID().uuidString, orderIndex: 0,
        destinationRelativePath: "downloads/\(UUID().uuidString)", expectedBytes: 100,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60,
        receivedBytes: state == .completed ? 100 : 0, state: state)
      try download.insert(db)
    }
  }

  private static func seedProgress(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, podcastEpisodeId: Int64? = nil,
    isFinished: Bool
  ) async throws {
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId,
        currentTime: isFinished ? 100 : 30, isFinished: isFinished, localSequence: 1,
        origin: .local, originKey: "client-uuid")
      try progress.insert(db)
    }
  }

  // MARK: - Media category

  @Test("item rows carry the derived media category - audiobook, ebook, and podcast")
  func itemRowsCarryTheDerivedMediaCategory() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultSearchReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let accountId = try await Self.seedAccount(database)
    let libraryId = try await Self.seedLibrary(database, accountId: accountId, serverLibraryId: "lib-1")

    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "audiobook-hit",
        title: "Quasar Audiobook"))
    _ = try itemDAO.upsert(
      Self.book(
        accountId: accountId, libraryId: libraryId, serverItemId: "ebook-hit",
        title: "Quasar Ebook", ebookFormat: "epub"))
    _ = try await Self.seedShow(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "podcast-hit",
      title: "Quasar Podcast")

    let page = try await reading.searchItems(
      query: "quasar", libraryIDs: nil, filters: BrowseFilters(), limit: 20, offset: 0)
    let categories = Dictionary(
      uniqueKeysWithValues: page.rows.map { ($0.entityID, $0.mediaCategory) })
    #expect(categories["audiobook-hit"] == .audiobook)
    #expect(categories["ebook-hit"] == .ebook)
    #expect(categories["podcast-hit"] == .podcast)
  }
}
