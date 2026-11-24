import Foundation
import Persistence
import Testing

@testable import AppModel

@Suite("Library quick filter")
struct LibraryQuickFilterTests {

  @Test("the worked examples use canonical whitespace fragments")
  func d5WorkedExamples() {
    let item = Self.item(
      id: "children-of-time", title: "Children of Time", author: "Adrian Tchaikovsky")
    let examples = [
      WorkedExample(query: "tchaik", fragments: ["tchaik"], effective: true, expectedIDs: [item.id]),
      WorkedExample(
        query: "children time", fragments: ["children", "time"], effective: true,
        expectedIDs: [item.id]),
      WorkedExample(
        query: "tchaikovsky children", fragments: ["tchaikovsky", "children"], effective: true,
        expectedIDs: [item.id]),
      WorkedExample(
        query: "TCHAÏKOVSKY", fragments: ["tchaikovsky"], effective: true, expectedIDs: [item.id]),
      WorkedExample(query: "  ", fragments: [], effective: false, expectedIDs: [item.id]),
      WorkedExample(query: ".", fragments: [], effective: false, expectedIDs: [item.id]),
      WorkedExample(
        query: "time children", fragments: ["time", "children"], effective: true,
        expectedIDs: [item.id]),
      WorkedExample(query: "childrenof", fragments: ["childrenof"], effective: true, expectedIDs: []),
    ]

    for example in examples {
      #expect(LibraryQuickFilter.fragments(example.query) == example.fragments)
      #expect(LibraryQuickFilter.isEffective(example.query) == example.effective)
      #expect(
        LibraryQuickFilter.filter(items: [item], query: example.query).map(\.id)
          == example.expectedIDs)
    }
  }

  @Test("effectiveness is exactly whether canonical fragments are present")
  func effectiveness() {
    #expect(LibraryQuickFilter.fragments("") == [])
    #expect(LibraryQuickFilter.fragments("   \t\n") == [])
    #expect(LibraryQuickFilter.fragments("S. A.") == ["sa"])
    #expect(LibraryQuickFilter.isEffective("") == false)
    #expect(LibraryQuickFilter.isEffective("   ") == false)
    #expect(LibraryQuickFilter.isEffective("\t\n") == false)
    #expect(LibraryQuickFilter.isEffective("a"))
    #expect(LibraryQuickFilter.isEffective(".") == false)
  }

  @Test("matching allows fragments to span normalized fields and skips empty fields")
  func matchesFragmentsAcrossFields() {
    #expect(LibraryQuickFilter.matches(fragments: [], fields: [nil, ""]))
    #expect(
      LibraryQuickFilter.matches(
        fragments: ["tchaikovsky", "children"],
        fields: ["Children of Time", "Adrian Tchaikovsky"]))
    #expect(
      LibraryQuickFilter.matches(fragments: ["childrenof"], fields: ["Children of Time"]) == false)
    #expect(!LibraryQuickFilter.matches(fragments: ["anything"], fields: [nil, ""]))
  }

  @Test("item filtering matches title and optional author fields")
  func itemFilterUsesTitleAndAuthor() {
    let titleMatch = Self.item(id: "title", title: "Book of Maps", author: nil)
    let authorMatch = Self.item(id: "author", title: "Unrelated", author: "Book Author")
    let noMatch = Self.item(id: "none", title: "Unrelated", author: "Another Author")

    let filtered = LibraryQuickFilter.filter(
      items: [titleMatch, authorMatch, noMatch], query: "book")

    #expect(filtered.map(\.id) == ["title", "author"])
  }

  @Test("canonical presentation variants match without changing source order")
  func canonicalPresentationVariantsMatchInSourceOrder() {
    let items = [
      Self.item(id: "second", title: "Caliban's War", author: "James S. A. Corey"),
      Self.item(id: "skip", title: "Unrelated", author: "Another Author"),
      Self.item(id: "first", title: "Leviathan Wakes", author: "James SA Corey"),
    ]

    for query in ["James S.A. Corey", "James S. A. Corey", "James SA Corey"] {
      #expect(
        LibraryQuickFilter.filter(items: items, query: query).map(\.id) == ["second", "first"])
    }
  }

  @Test("apostrophe and hyphen variants match canonically")
  func apostropheAndHyphenVariantsMatchCanonically() {
    let items = [
      Self.item(id: "apostrophe", title: "A Book", author: "Flannery O'Brien"),
      Self.item(id: "hyphen", title: "Another Book", author: "Jean Luc Picard"),
    ]

    #expect(LibraryQuickFilter.filter(items: items, query: "obrien").map(\.id) == ["apostrophe"])
    #expect(LibraryQuickFilter.filter(items: items, query: "jean-luc").map(\.id) == ["hyphen"])
  }

  @Test("a non-effective item query returns the exact input sequence")
  func nonEffectiveItemQueryPreservesInput() {
    let items = [
      Self.item(id: "zulu", title: "Z", author: "Author"),
      Self.item(id: "alpha", title: "A", author: nil),
      Self.item(id: "zulu", title: "Z", author: "Author"),
    ]

    let filtered = LibraryQuickFilter.filter(items: items, query: " \t ")

    #expect(filtered.map(\.id) == ["zulu", "alpha", "zulu"])
    #expect(filtered == items)
  }

  @Test("effective item filtering preserves the source order")
  func itemFilterPreservesOrder() {
    let items = [
      Self.item(id: "last", title: "Match at the end", author: nil),
      Self.item(id: "skip", title: "No result", author: nil),
      Self.item(id: "first", title: "Match at the start", author: nil),
    ]

    #expect(LibraryQuickFilter.filter(items: items, query: "match").map(\.id) == ["last", "first"])
  }

  @Test("episode filtering searches the title and description text in source order")
  func episodeFilterUsesVisibleAndFullDescriptionText() {
    let episodes = [
      Self.episode(id: "title", title: "Islam and the West"),
      Self.episode(id: "skip", title: "Plate Tectonics", description: "Earth science"),
      Self.episode(id: "description", title: "The Abbasids", description: "A history of Islam"),
      Self.episode(id: "synopsis", title: "Architecture", synopsis: "Islamic geometry"),
    ]

    #expect(
      LibraryQuickFilter.filter(episodes: episodes, query: "islam").map(\.id)
        == ["title", "description", "synopsis"])
    #expect(
      LibraryQuickFilter.filter(episodes: episodes, query: "history islam").map(\.id)
        == ["description"])
    #expect(LibraryQuickFilter.filter(episodes: episodes, query: " . ") == episodes)
  }

  @Test("an episode search key matches exactly where the per-field matcher does")
  func episodeSearchKeyAgreesWithFieldMatcher() {
    let episodes = [
      Self.episode(id: "title", title: "Islam and the West"),
      Self.episode(id: "split", title: "Islam", subtitle: "ic art"),
      Self.episode(id: "spread", title: "The Abbasids", description: "A history of Islam"),
      Self.episode(id: "initials", title: "Caliban's War", synopsis: "James S. A. Corey"),
      Self.episode(id: "empty", title: "Plate Tectonics", subtitle: "", description: nil),
    ]
    let queries = [
      "islam", "islamic", "islam ic", "history islam", "calibans", "sa corey", "tectonics west",
      "", " . ",
    ]

    for query in queries {
      let fragments = LibraryQuickFilter.fragments(query)
      for episode in episodes {
        let reference = LibraryQuickFilter.matches(
          fragments: fragments,
          fields: [
            episode.title, episode.subtitle, episode.synopsisLine, episode.episodeDescription,
          ])
        let keyed = LibraryQuickFilter.matches(
          fragments: fragments, searchKey: LibraryQuickFilter.searchKey(for: episode))
        #expect(keyed == reference, "query \(query), episode \(episode.id)")
      }
    }
    // A fragment never reaches across the boundary between two fields.
    #expect(
      LibraryQuickFilter.matches(
        fragments: ["islamic"], searchKey: LibraryQuickFilter.searchKey(for: episodes[1]))
        == false)
  }

  @Test("the key cache canonicalizes an episode's text once until that text changes")
  func episodeKeyCacheReusesUnchangedEpisodes() {
    var cache = LibraryQuickFilter.SearchKeyCache()
    let first = [
      Self.episode(id: "a", title: "Islam and the West"),
      Self.episode(id: "b", title: "The Abbasids", description: "A history of Islam"),
    ]

    let keys = cache.keys(for: first)
    #expect(keys == first.map(LibraryQuickFilter.searchKey(for:)))
    #expect(cache.computedKeyCount == 2)

    _ = cache.keys(for: first)
    #expect(cache.computedKeyCount == 2)

    let edited = [
      first[0],
      Self.episode(id: "b", title: "The Abbasids", description: "Baghdad"),
      Self.episode(id: "c", title: "Plate Tectonics"),
    ]
    let editedKeys = cache.keys(for: edited)
    #expect(editedKeys == edited.map(LibraryQuickFilter.searchKey(for:)))
    #expect(cache.computedKeyCount == 4)
    #expect(cache.entryCount == 3)

    _ = cache.keys(for: [edited[2]])
    #expect(cache.entryCount == 1)
  }

  @Test("a warmup built away from the cache spares the cache from canonicalizing those episodes")
  func episodeKeyCacheAdoptsAWarmup() {
    var cache = LibraryQuickFilter.SearchKeyCache()
    let episodes = [
      Self.episode(id: "a", title: "Islam and the West"),
      Self.episode(id: "b", title: "The Abbasids", description: "A history of Islam"),
    ]

    let pending = cache.pendingSearchFields(for: episodes)
    #expect(pending.map(\.id) == ["a", "b"])
    cache.adopt(LibraryQuickFilter.SearchKeyCache.Warmup(pending))
    #expect(cache.pendingSearchFields(for: episodes).isEmpty)

    #expect(cache.keys(for: episodes) == episodes.map(LibraryQuickFilter.searchKey(for:)))
    #expect(cache.computedKeyCount == 0)

    // A warmup taken before an episode's text changed is stale for that episode: the cache keeps
    // the key it already holds, and a key it adopts for old text is rebuilt rather than trusted.
    let stale = LibraryQuickFilter.SearchKeyCache.Warmup(
      cache.pendingSearchFields(for: [Self.episode(id: "c", title: "Old title")]))
    let edited = episodes + [Self.episode(id: "c", title: "Plate Tectonics")]
    cache.adopt(stale)
    #expect(cache.pendingSearchFields(for: edited).map(\.id) == ["c"])
    #expect(cache.keys(for: edited) == edited.map(LibraryQuickFilter.searchKey(for:)))
    #expect(cache.computedKeyCount == 1)
  }

  @Test("author groups match only their entity name")
  func authorGroupsUseEntityNameOnly() {
    let group = Self.group(
      kind: .author,
      entityID: "author-entity",
      name: "Ursula K. Le Guin",
      libraryID: "library-1",
      items: [Self.item(id: "book", title: "A Book", author: "Adrian Tchaikovsky")])

    #expect(
      LibraryQuickFilter.filter(groups: [group], query: "ursula").map(\.entityID)
        == ["author-entity"])
    #expect(LibraryQuickFilter.filter(groups: [group], query: "tchaik").isEmpty)
  }

  @Test("series groups match their name and primary author")
  func seriesGroupsUseNameAndPrimaryAuthor() {
    let group = Self.group(
      kind: .series,
      entityID: "series-entity",
      name: "The Expanse",
      libraryID: "library-1",
      items: [
        Self.item(id: "one", title: "Leviathan Wakes", author: "James S. A. Corey"),
        Self.item(id: "two", title: "Caliban's War", author: "James S. A. Corey"),
      ])

    #expect(group.primaryAuthorName == "James S. A. Corey")
    #expect(
      LibraryQuickFilter.filter(groups: [group], query: "expanse").map(\.entityID)
        == ["series-entity"])
    #expect(
      LibraryQuickFilter.filter(groups: [group], query: "corey").map(\.entityID)
        == ["series-entity"])
  }

  @Test("a group of any other kind is matched on its name, never dropped")
  func otherKindGroupsMatchOnName() {
    let group = Self.group(
      kind: .book, entityID: "book-entity", name: "Leviathan Wakes", libraryID: "library-1")

    #expect(
      LibraryQuickFilter.filter(groups: [group], query: "leviathan").map(\.entityID)
        == ["book-entity"])
    #expect(LibraryQuickFilter.filter(groups: [group], query: "corey").isEmpty)
  }

  @Test("group filtering preserves order and destination identity")
  func groupFilterPreservesOrderAndIdentity() {
    let groups = [
      Self.group(
        kind: .author, entityID: "entity-2", name: "Second Match", libraryID: "library-2"),
      Self.group(
        kind: .author, entityID: "entity-skip", name: "Nope", libraryID: "library-skip"),
      Self.group(
        kind: .author, entityID: "entity-1", name: "First Match", libraryID: "library-1"),
      Self.group(
        kind: .author, entityID: "entity-3", name: "Third Match", libraryID: "library-3"),
    ]

    let filtered = LibraryQuickFilter.filter(groups: groups, query: "match")

    #expect(filtered.map(\.entityID) == ["entity-2", "entity-1", "entity-3"])
    #expect(filtered.map(\.libraryID) == ["library-2", "library-1", "library-3"])
  }

  @Test("filtering is pure and repeated calls return equal results")
  func filteringIsPure() {
    let items = [
      Self.item(id: "two", title: "Second Book", author: nil),
      Self.item(id: "one", title: "First Book", author: nil),
    ]
    let groups = [
      Self.group(
        kind: .author, entityID: "author-2", name: "Second Author", libraryID: "library-2"),
      Self.group(
        kind: .author, entityID: "author-1", name: "First Author", libraryID: "library-1"),
    ]
    let originalItems = items
    let originalGroups = groups

    let firstItems = LibraryQuickFilter.filter(items: items, query: "book")
    let secondItems = LibraryQuickFilter.filter(items: items, query: "book")
    let firstGroups = LibraryQuickFilter.filter(groups: groups, query: "author")
    let secondGroups = LibraryQuickFilter.filter(groups: groups, query: "author")

    #expect(firstItems == secondItems)
    #expect(firstGroups == secondGroups)
    #expect(items == originalItems)
    #expect(groups == originalGroups)
  }

  private static func item(
    id: String,
    title: String,
    author: String?,
    category: ItemMediaCategory = .audiobook,
    series: String? = nil
  ) -> ItemSummary {
    ItemSummary(
      serverItemId: id,
      mediaKind: "book",
      title: title,
      author: author,
      durationSeconds: nil,
      category: category,
      seriesName: series)
  }

  private static func group(
    kind: SearchResultKind,
    entityID: String,
    name: String,
    libraryID: String,
    items: [ItemSummary] = []
  ) -> LibraryEntityGroup {
    LibraryEntityGroup(
      entity: AuthorSeriesEntity(
        kind: kind, entityID: entityID, name: name, libraryID: libraryID),
      items: items,
      isFiltered: false)
  }

  private static func episode(
    id: String,
    title: String,
    subtitle: String? = nil,
    description: String? = nil,
    synopsis: String? = nil
  ) -> PodcastEpisodeSummary {
    PodcastEpisodeSummary(
      id: id, title: title, subtitle: subtitle, episodeDescription: description,
      seasonNumber: nil, episodeNumber: nil, episodeType: nil, durationSeconds: nil,
      sizeBytes: nil, publishedAt: nil, progressSeconds: 0, isPlayed: false,
      isFinished: false, downloadStatus: .notDownloaded, isAvailableOnServer: true,
      synopsisLine: synopsis)
  }

  private struct WorkedExample {
    let query: String
    let fragments: [String]
    let effective: Bool
    let expectedIDs: [String]
  }
}
