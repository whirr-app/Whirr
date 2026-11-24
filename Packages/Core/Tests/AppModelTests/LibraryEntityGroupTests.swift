import Foundation
import Persistence
import Testing

@testable import AppModel

@Suite struct LibraryEntityGroupTests {

  // MARK: - Series descriptors

  @Test("a numbered series splits into its name and its sequence")
  func numberedSeries() {
    let descriptor = LibraryEntityGrouping.seriesDescriptor(from: "The Expanse #3")
    #expect(descriptor?.name == "The Expanse")
    #expect(descriptor?.sequence == 3)
  }

  @Test("a fractional sequence survives, because Audiobookshelf numbers novellas that way")
  func fractionalSequence() {
    #expect(LibraryEntityGrouping.seriesDescriptor(from: "Discworld #2.5")?.sequence == 2.5)
  }

  @Test("an unnumbered series keeps its whole name and no sequence")
  func unnumberedSeries() {
    let descriptor = LibraryEntityGrouping.seriesDescriptor(from: "Southern Reach")
    #expect(descriptor?.name == "Southern Reach")
    #expect(descriptor?.sequence == nil)
  }

  /// A `#` that is not a sequence marker must not manufacture a series called "Book".
  @Test("a hash that is not a sequence marker leaves the name whole")
  func nonSequenceHash() {
    let descriptor = LibraryEntityGrouping.seriesDescriptor(from: "Book #one of nothing")
    #expect(descriptor?.name == "Book #one of nothing")
    #expect(descriptor?.sequence == nil)
  }

  @Test("no series name yields no descriptor")
  func absentSeries() {
    #expect(LibraryEntityGrouping.seriesDescriptor(from: nil) == nil)
    #expect(LibraryEntityGrouping.seriesDescriptor(from: "   ") == nil)
  }

  // MARK: - Author names

  @Test("a joined author string offers both the whole string and each component")
  func joinedAuthors() {
    #expect(
      LibraryEntityGrouping.authorNames(from: "Neil Gaiman, Terry Pratchett")
        == ["Neil Gaiman, Terry Pratchett", "Neil Gaiman", "Terry Pratchett"])
  }

  /// Splitting alone would turn one comma-bearing name into two names matching nothing; offering
  /// the whole string as well is what lets the server's own author list decide which reading is real.
  @Test("a single author is offered whole, not split")
  func singleAuthor() {
    #expect(LibraryEntityGrouping.authorNames(from: "Ursula K. Le Guin") == ["Ursula K. Le Guin"])
  }

  @Test("no author yields no names")
  func absentAuthor() {
    #expect(LibraryEntityGrouping.authorNames(from: nil).isEmpty)
    #expect(LibraryEntityGrouping.authorNames(from: " ").isEmpty)
  }

  // MARK: - Joining

  @Test("an author row counts, badges, and lists the series of the items it matched")
  func authorRowIsEnriched() {
    let groups = LibraryEntityGrouping.groups(
      kind: .author,
      entities: [Self.author("Ursula K. Le Guin")],
      items: [
        Self.item(id: "1", title: "The Dispossessed", author: "Ursula K. Le Guin"),
        Self.item(
          id: "2", title: "The Left Hand of Darkness", author: "Ursula K. Le Guin",
          category: .ebook, series: "Hainish Cycle #4"),
      ],
      filters: .unfiltered)

    #expect(groups.count == 1)
    #expect(groups[0].bookCount == 2)
    #expect(groups[0].categories == [.audiobook, .ebook])
    #expect(groups[0].seriesNames == ["Hainish Cycle"])
  }

  /// The point of the whole join: a series has no artwork of its own, so its earliest sequenced
  /// entry lends one, not whichever entry the server happened to list first.
  @Test("a series borrows the cover of its first book, by sequence and not by arrival")
  func seriesCoverIsTheFirstBook() {
    let groups = LibraryEntityGrouping.groups(
      kind: .series,
      entities: [Self.series("The Expanse")],
      items: [
        Self.item(id: "caliban", title: "Caliban's War", series: "The Expanse #2"),
        Self.item(id: "leviathan", title: "Leviathan Wakes", series: "The Expanse #1"),
        Self.item(id: "gate", title: "Abaddon's Gate", series: "The Expanse #3"),
      ],
      filters: .unfiltered)

    #expect(groups[0].coverItemID == "leviathan")
    #expect(groups[0].items.map(\.serverItemId) == ["leviathan", "caliban", "gate"])
  }

  /// A series' "first book" must not be a bonus story the server never numbered.
  @Test("unsequenced series entries sort after the sequenced ones")
  func unsequencedEntriesSortLast() {
    let groups = LibraryEntityGrouping.groups(
      kind: .series,
      entities: [Self.series("The Expanse")],
      items: [
        Self.item(id: "extra", title: "Auberon", series: "The Expanse"),
        Self.item(id: "leviathan", title: "Leviathan Wakes", series: "The Expanse #1"),
      ],
      filters: .unfiltered)

    #expect(groups[0].coverItemID == "leviathan")
  }

  @Test("diacritics do not split one author into two")
  func diacriticFolding() {
    let groups = LibraryEntityGrouping.groups(
      kind: .author,
      entities: [Self.author("China Miéville")],
      items: [Self.item(id: "1", title: "Embassytown", author: "China Mieville")],
      filters: .unfiltered)

    #expect(groups[0].bookCount == 1)
  }

  /// The books either spelling of an author's initials is filed under all belong to the one row
  /// the entity listing merges them into. Otherwise a series arrives split, books 1 and 2 under
  /// one spelling and 3 and 4 under the other.
  @Test("both spellings of an author's initials join the same row")
  func initialSpellingsJoinOneRow() {
    let groups = LibraryEntityGrouping.groups(
      kind: .author,
      entities: [Self.author("J. N. Chaney")],
      items: [
        Self.item(id: "1", title: "Renegade Star", author: "J. N. Chaney", series: "Renegade #1"),
        Self.item(id: "3", title: "Renegade Moon", author: "J.N. Chaney", series: "Renegade #3"),
      ],
      filters: .unfiltered)

    #expect(groups.count == 1)
    #expect(groups[0].bookCount == 2)
    #expect(groups[0].seriesNames == ["Renegade"])
  }

  // MARK: - The filter rule

  /// The defect this whole join exists to fix: the funnel narrowed Titles and left Authors and
  /// Series showing every entity in the library.
  @Test("an active filter hides an entity whose items it matched none of")
  func filterHidesUnmatchedEntities() {
    let entities = [Self.author("Ebook Only"), Self.author("Audiobook Only")]
    let audiobooksOnly = BrowseFilters(categories: [.audiobook])
    let groups = LibraryEntityGrouping.groups(
      kind: .author,
      entities: entities,
      // The items are already filtered (the same projection Titles renders), so the
      // ebook-only author has nothing here.
      items: [Self.item(id: "1", title: "A Book", author: "Audiobook Only")],
      filters: audiobooksOnly)

    #expect(groups.map(\.name) == ["Audiobook Only"])
  }

  /// A library that has not finished syncing should still list its authors.
  @Test("with no filter active an entity with no local items is kept")
  func unfilteredKeepsUnmatchedEntities() {
    let groups = LibraryEntityGrouping.groups(
      kind: .author,
      entities: [Self.author("Not Synced Yet", bookCount: 7)],
      items: [],
      filters: .unfiltered)

    #expect(groups.count == 1)
    // The server's own count stands in while there is nothing local to count.
    #expect(groups[0].bookCount == 7)
  }

  /// `numBooks` counts the entity's whole shelf, so quoting it under an active filter would
  /// contradict the filter it is standing in for.
  @Test("the server's count is not quoted under an active filter")
  func serverCountIsNotQuotedWhenFiltered() {
    let group = LibraryEntityGroup(
      entity: Self.author("Someone", bookCount: 7), items: [], isFiltered: true)
    #expect(group.bookCount == 0)
  }

  @Test("matched items outrank the server's count")
  func matchedItemsWin() {
    let group = LibraryEntityGroup(
      entity: Self.author("Someone", bookCount: 7),
      items: [Self.item(id: "1", title: "A Book", author: "Someone")],
      isFiltered: false)
    #expect(group.bookCount == 1)
  }

  // MARK: - Fixtures

  private static func author(_ name: String, bookCount: Int? = nil) -> AuthorSeriesEntity {
    AuthorSeriesEntity(
      kind: .author, entityID: "author-\(name)", name: name, libraryID: "lib-1",
      bookCount: bookCount)
  }

  private static func series(_ name: String) -> AuthorSeriesEntity {
    AuthorSeriesEntity(
      kind: .series, entityID: "series-\(name)", name: name, libraryID: "lib-1")
  }

  private static func item(
    id: String,
    title: String,
    author: String? = nil,
    category: ItemMediaCategory = .audiobook,
    series: String? = nil
  ) -> ItemSummary {
    ItemSummary(
      serverItemId: id, mediaKind: "book", title: title, author: author, durationSeconds: nil,
      category: category, seriesName: series)
  }
}
