import Persistence
import Testing

@testable import AppModel

/// Pure result assembly: merge (local + server), dedupe, section, and all search copy. Free of
/// `SearchModel` and persistence I/O so the ordering logic is unit-testable without a database
/// or network.
@Suite struct SearchResultAssemblyTests {

  // MARK: - Fixtures

  private static func row(
    _ kind: SearchResultKind, _ id: String, title: String, reasonField: String? = nil,
    reasonText: String? = nil
  ) -> SearchResultRow {
    SearchResultRow(
      kind: kind, entityID: id, title: title,
      matchReason: reasonField.map { SearchMatchReason(field: $0, text: reasonText) },
      libraryID: "lib1")
  }

  // MARK: - merge

  @Test(
    "server order wins for rows the server returned; local-only rows are appended after, never dropped"
  )
  func mergeKeepsServerOrderThenAppendsLocalOnly() {
    let a = Self.row(.book, "a", title: "Alpha")
    let b = Self.row(.book, "b", title: "Bravo")
    let c = Self.row(.book, "c", title: "Charlie")  // offline-only: the server never indexed it

    let local = [a, b, c]
    let server = [b, a]  // server ranks b above a, a different order than local's

    let merged = SearchResultAssembly.merge(local: local, server: server)

    #expect(merged.map(\.id) == [b.id, a.id, c.id])
  }

  @Test("dedupe keeps the server's matchReason when present")
  func dedupeKeepsServerReasonWhenPresent() {
    let localRow = Self.row(.book, "a", title: "Alpha", reasonField: "author", reasonText: "Jane Doe")
    let serverRow = Self.row(.book, "a", title: "Alpha", reasonField: "narrator", reasonText: "Rob Inglis")

    let merged = SearchResultAssembly.merge(local: [localRow], server: [serverRow])

    #expect(merged.count == 1)
    #expect(merged[0].matchReason == SearchMatchReason(field: "narrator", text: "Rob Inglis"))
  }

  @Test("dedupe falls back to the local matchReason when the server row has none")
  func dedupeFallsBackToLocalReasonWhenServerHasNone() {
    let localRow = Self.row(.book, "a", title: "Alpha", reasonField: "author", reasonText: "Jane Doe")
    let serverRow = Self.row(.book, "a", title: "Alpha")  // server confirms the row but gives no reason

    let merged = SearchResultAssembly.merge(local: [localRow], server: [serverRow])

    #expect(merged.count == 1)
    #expect(merged[0].matchReason == SearchMatchReason(field: "author", text: "Jane Doe"))
  }

  @Test(
    "merging server results into an already-rendered local list only inserts new rows - it never reorders rows already on screen"
  )
  func mergeIsStableUnderInsertion() {
    let a = Self.row(.book, "a", title: "Alpha")
    let b = Self.row(.book, "b", title: "Bravo")
    let c = Self.row(.book, "c", title: "Charlie")  // local-only, never confirmed by the server
    let d = Self.row(.book, "d", title: "Delta")  // brand new, server-only

    let alreadyRendered = SearchResultAssembly.merge(local: [a, b, c], server: [])
    #expect(alreadyRendered.map(\.id) == [a.id, b.id, c.id])

    let merged = SearchResultAssembly.merge(local: [a, b, c], server: [a, b, d])

    // a, b, c keep the relative order they had on screen; d is inserted, not swapped in.
    let visibleOrder = merged.map(\.id).filter { [a.id, b.id, c.id].contains($0) }
    #expect(visibleOrder == [a.id, b.id, c.id])
    #expect(merged.map(\.id) == [a.id, b.id, d.id, c.id])
  }

  @Test(
    "one author in two libraries is one row - Audiobookshelf files authors per library, so the fan-out returns an id per library"
  )
  func mergeCollapsesTheSameEntityAcrossLibraries() {
    let audiobookLibrary = SearchResultRow(
      kind: .author, entityID: "author-audio", title: "Becky Chambers", libraryID: "lib-audio")
    let ebookLibrary = SearchResultRow(
      kind: .author, entityID: "author-ebook", title: "Becky Chambers", libraryID: "lib-ebook")

    let merged = SearchResultAssembly.merge(
      local: [], server: [audiobookLibrary, ebookLibrary])

    // The first library's identity survives: it is enough to navigate, because the destination
    // re-resolves every identity the entity has (`AuthorSeriesModel.loadInitial`).
    #expect(merged.count == 1)
    #expect(merged[0].entityID == "author-audio")
    #expect(merged[0].libraryID == "lib-audio")
  }

  @Test(
    "entity rows collapse on the same normalized name the Library's own author index merges under",
    arguments: [
      ("J. N. Chaney", "JN Chaney"),
      ("Bronte", "Brontë"),
    ])
  func mergeCollapsesEntitySpellingVariants(first: String, second: String) {
    let merged = SearchResultAssembly.merge(
      local: [],
      server: [
        SearchResultRow(kind: .author, entityID: "a1", title: first, libraryID: "lib1"),
        SearchResultRow(kind: .author, entityID: "a2", title: second, libraryID: "lib2"),
      ])

    #expect(merged.map(\.title) == [first])
  }

  @Test("a series collapses across libraries the same way an author does")
  func mergeCollapsesSeriesAcrossLibraries() {
    let merged = SearchResultAssembly.merge(
      local: [],
      server: [
        SearchResultRow(kind: .series, entityID: "s-audio", title: "Wayfarers", libraryID: "lib-audio"),
        SearchResultRow(kind: .series, entityID: "s-ebook", title: "Wayfarers", libraryID: "lib-ebook"),
      ])

    #expect(merged.count == 1)
    #expect(merged[0].entityID == "s-audio")
  }

  @Test("two entities of different kinds sharing one name stay two rows")
  func mergeKeepsDistinctKindsWithTheSameName() {
    let merged = SearchResultAssembly.merge(
      local: [],
      server: [
        SearchResultRow(kind: .author, entityID: "a1", title: "Wayfarers", libraryID: "lib1"),
        SearchResultRow(kind: .series, entityID: "s1", title: "Wayfarers", libraryID: "lib1"),
      ])

    #expect(merged.map(\.kind) == [.author, .series])
  }

  @Test("two items sharing a title are still two rows - only entity kinds collapse by name")
  func mergeKeepsDistinctItemsWithTheSameTitle() {
    let audiobook = SearchResultRow(
      kind: .book, entityID: "item-audio", title: "A Closed and Common Orbit", libraryID: "lib-audio")
    let ebook = SearchResultRow(
      kind: .book, entityID: "item-ebook", title: "A Closed and Common Orbit", libraryID: "lib-ebook")

    let merged = SearchResultAssembly.merge(local: [], server: [audiobook, ebook])

    #expect(merged.map(\.entityID) == ["item-audio", "item-ebook"])
  }

  // MARK: - section

  @Test("rows keep the baseline section order when no entity is promoted")
  func sectionsAreInFixedOrder() {
    let rows = [
      Self.row(.series, "s1", title: "A Series"),
      Self.row(.author, "au1", title: "An Author"),
      Self.row(.episode, "e1", title: "An Episode"),
      Self.row(.podcast, "p1", title: "A Podcast"),
      Self.row(.book, "b1", title: "A Book"),
    ]

    let sections = SearchResultAssembly.section(
      SearchSectionInput(rows: rows, query: "library"))

    #expect(sections.map(\.kind) == [.book, .podcast, .episode, .author, .series])
  }

  @Test(
    "entity promotion uses whole canonical words and requires every query word",
    arguments: [
      ("Murakami", "Haruki Murakami", true),
      ("Haruki Murakami", "Haruki Murakami", true),
      ("murakami haruki", "Haruki Murakami", true),
      ("Mur", "Haruki Murakami", false),
      ("Ocean", "Oceana Smith", false),
      ("Kafka on the Shore", "Franz Kafka", false),
      ("S. A. Corey", "SA Corey", true),
    ]
  )
  func entityPromotionWorkedExamples(query: String, title: String, expected: Bool) {
    let author = Self.row(.author, "au1", title: title)

    #expect(
      SearchResultAssembly.promotesEntities(query: query, rows: [author], kind: .author)
        == expected)
  }

  @Test("empty or punctuation-only queries promote nothing")
  func emptyQueriesDoNotPromote() {
    let author = Self.row(.author, "au1", title: "Haruki Murakami")

    #expect(
      SearchResultAssembly.promotesEntities(query: "", rows: [author], kind: .author) == false)
    #expect(
      SearchResultAssembly.promotesEntities(query: "...", rows: [author], kind: .author) == false)
  }

  @Test("a matching series is promoted without promoting authors")
  func seriesPromotion() {
    let rows = [
      Self.row(.book, "b1", title: "The Colour of Magic"),
      Self.row(.series, "s1", title: "Discworld"),
    ]

    let sections = SearchResultAssembly.section(
      SearchSectionInput(rows: rows, query: "Discworld"))

    #expect(sections.map(\.kind) == [.series, .book])
  }

  @Test("authors and series can both be promoted while other kinds keep their order")
  func bothEntityKindsPromote() {
    let rows = [
      Self.row(.episode, "e1", title: "An Episode"),
      Self.row(.series, "s1", title: "Discworld"),
      Self.row(.author, "a1", title: "Discworld"),
      Self.row(.podcast, "p1", title: "A Podcast"),
      Self.row(.book, "b1", title: "A Book"),
    ]

    let sections = SearchResultAssembly.section(
      SearchSectionInput(rows: rows, query: "Discworld"))

    #expect(sections.map(\.kind) == [.author, .series, .book, .podcast, .episode])
  }

  @Test("no author rows means no author promotion")
  func noAuthorRowsDoNotPromote() {
    let rows = [Self.row(.book, "b1", title: "A Book")]

    let sections = SearchResultAssembly.section(
      SearchSectionInput(rows: rows, query: "anything"))

    #expect(sections.map(\.kind) == [.book])
  }

  @Test("empty sections are omitted entirely")
  func emptySectionsAreOmitted() {
    let rows = [Self.row(.book, "b1", title: "A Book")]

    let sections = SearchResultAssembly.section(
      SearchSectionInput(rows: rows, query: "library"))

    #expect(sections.map(\.kind) == [.book])
  }

  @Test("hasMore propagates per section, independently of other sections")
  func hasMorePropagatesPerSection() {
    let rows = [
      Self.row(.book, "b1", title: "A Book"),
      Self.row(.podcast, "p1", title: "A Podcast"),
    ]

    let sections = SearchResultAssembly.section(
      SearchSectionInput(rows: rows, query: "library", hasMore: [.book: true]))

    let byKind = Dictionary(uniqueKeysWithValues: sections.map { ($0.kind, $0.hasMore) })
    #expect(byKind[.book] == true)
    #expect(byKind[.podcast] == false)
  }

  @Test("hasMore stays attached to its kind after entity promotion")
  func hasMorePropagatesAfterPromotion() {
    let rows = [
      Self.row(.book, "b1", title: "A Book"),
      Self.row(.author, "a1", title: "Haruki Murakami"),
    ]

    let sections = SearchResultAssembly.section(
      SearchSectionInput(rows: rows, query: "Murakami", hasMore: [.book: true]))

    let byKind = Dictionary(uniqueKeysWithValues: sections.map { ($0.kind, $0.hasMore) })
    #expect(sections.map(\.kind) == [.author, .book])
    #expect(byKind[.author] == false)
    #expect(byKind[.book] == true)
  }
}

/// `SearchCopy`: all user-facing search copy, so no view or model reaches for a literal string.
@Suite struct SearchCopyTests {

  @Test(
    "section titles per kind",
    arguments: [
      (SearchResultKind.book, "Books"),
      (SearchResultKind.podcast, "Podcasts"),
      (SearchResultKind.episode, "Episodes"),
      (SearchResultKind.author, "Authors"),
      (SearchResultKind.series, "Series"),
    ]
  )
  func sectionTitlePerKind(kind: SearchResultKind, expected: String) {
    #expect(SearchCopy.sectionTitle(for: kind) == expected)
  }

  @Test("a known field with text renders 'Label: text'")
  func matchReasonRendersKnownField() {
    let reason = SearchMatchReason(field: "narrator", text: "Rob Inglis")

    #expect(SearchCopy.matchReasonText(reason, rowTitle: "The Book") == "Narrator: Rob Inglis")
  }

  @Test("the field names local search actually emits render their label")
  func matchReasonRendersLocalFieldNames() {
    // `DefaultSearchReading`'s SQL reports the column names, so labels must cover them as well as
    // the server's `matchKey` vocabulary, or a series or narrator hit renders nothing.
    #expect(
      SearchCopy.matchReasonText(
        SearchMatchReason(field: "seriesName", text: "Dungeon Crawler Carl #6"),
        rowTitle: "The Gate of the Feral Gods") == "Series: Dungeon Crawler Carl #6")
    #expect(
      SearchCopy.matchReasonText(
        SearchMatchReason(field: "narratorName", text: "Jeff Hays"), rowTitle: "The Book")
        == "Narrator: Jeff Hays")
  }

  @Test("the plural matchKeys the server actually emits render their label")
  func matchReasonRendersServerMatchKeys() {
    // The server's `matchKey` is `authors`/`narrators`/`series`/`tags` (plural), so the plural
    // forms must map or a server author or narrator hit is blank.
    #expect(
      SearchCopy.matchReasonText(
        SearchMatchReason(field: "authors", text: "Matt Dinniman"), rowTitle: "The Book")
        == "Author: Matt Dinniman")
    #expect(
      SearchCopy.matchReasonText(
        SearchMatchReason(field: "narrators", text: "Jeff Hays"), rowTitle: "The Book")
        == "Narrator: Jeff Hays")
    #expect(
      SearchCopy.matchReasonText(SearchMatchReason(field: "tags", text: "LitRPG"), rowTitle: "The Book")
        == "Tag: LitRPG")
  }

  @Test("an unknown field renders nothing rather than a raw key")
  func matchReasonSuppressesUnknownField() {
    let reason = SearchMatchReason(field: "someInternalColumn", text: "whatever")

    #expect(SearchCopy.matchReasonText(reason, rowTitle: "The Book") == nil)
  }

  @Test("a reason whose text equals the row title is suppressed as noise")
  func matchReasonSuppressesTextEqualToTitle() {
    let reason = SearchMatchReason(field: "narrator", text: "The Book")

    #expect(SearchCopy.matchReasonText(reason, rowTitle: "The Book") == nil)
  }

  @Test("a nil matchReason renders nothing")
  func matchReasonNilRendersNothing() {
    #expect(SearchCopy.matchReasonText(nil, rowTitle: "The Book") == nil)
  }

  @Test("a matchReason with no text renders nothing")
  func matchReasonWithNoTextRendersNothing() {
    let reason = SearchMatchReason(field: "narrator")

    #expect(SearchCopy.matchReasonText(reason, rowTitle: "The Book") == nil)
  }

  @Test("the empty-results message names the query")
  func emptyResultsMessageNamesTheQuery() {
    #expect(SearchCopy.emptyResultsMessage(for: "gaiman").contains("gaiman"))
  }

  // MARK: - Media category

  @Test("dedupe keeps the server row's media category when it has one")
  func dedupeKeepsServerMediaCategoryWhenPresent() {
    let localRow = SearchResultRow(
      kind: .book, entityID: "a", title: "Alpha", mediaCategory: .audiobook, libraryID: "lib1")
    let serverRow = SearchResultRow(
      kind: .book, entityID: "a", title: "Alpha", mediaCategory: .ebook, libraryID: "lib1")

    let merged = SearchResultAssembly.merge(local: [localRow], server: [serverRow])

    #expect(merged.count == 1)
    #expect(merged[0].mediaCategory == .ebook)
  }

  @Test("dedupe backfills the media category from the local row when the server row has none")
  func dedupeBackfillsMediaCategoryFromLocalWhenServerHasNone() {
    let localRow = SearchResultRow(
      kind: .book, entityID: "a", title: "Alpha",
      matchReason: SearchMatchReason(field: "author", text: "Jane Doe"),
      mediaCategory: .ebook, libraryID: "lib1")
    let serverRow = SearchResultRow(kind: .book, entityID: "a", title: "Alpha", libraryID: "lib1")

    let merged = SearchResultAssembly.merge(local: [localRow], server: [serverRow])

    #expect(merged.count == 1)
    #expect(merged[0].matchReason == SearchMatchReason(field: "author", text: "Jane Doe"))
    #expect(merged[0].mediaCategory == .ebook)
  }

  @Test("dedupe backfills the series name from the local row when the server row has none")
  func dedupeBackfillsSeriesNameFromLocalWhenServerHasNone() {
    let localRow = SearchResultRow(
      kind: .book, entityID: "a", title: "Alpha", seriesName: "Alpha Saga #2", libraryID: "lib1")
    let serverRow = SearchResultRow(kind: .book, entityID: "a", title: "Alpha", libraryID: "lib1")

    let merged = SearchResultAssembly.merge(local: [localRow], server: [serverRow])

    #expect(merged.count == 1)
    #expect(merged[0].seriesName == "Alpha Saga #2")
  }
}
