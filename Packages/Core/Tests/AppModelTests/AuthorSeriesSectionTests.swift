import Persistence
import Testing

@testable import AppModel

@Suite struct AuthorSeriesSectionTests {

  @Test("named series rows group by their normalized series key")
  func groupsNormalizedSeriesNames() {
    let first = Self.row(
      id: "one", title: "One", seriesName: "The Saga #1", libraryID: "library")
    let second = Self.row(
      id: "two", title: "Two", seriesName: "the saga #2", libraryID: "library")

    let sections = AuthorSeriesSection.sections(from: [first, second])

    #expect(sections.count == 1)
    guard case .series(let key, let name) = sections[0].kind else {
      Issue.record("expected one named series section")
      return
    }
    #expect(key == AuthorSeriesEntity.normalizedName("The Saga"))
    #expect(name == "The Saga")
    #expect(sections[0].rows.map(\.entityID) == ["one", "two"])
  }

  @Test("sections alphabetize and keep standalone books last")
  func alphabetizesSectionsWithStandaloneLast() {
    let standalone = Self.row(id: "standalone", title: "Aardvark", libraryID: "library")
    let zeta = Self.row(
      id: "named", title: "Zed", seriesName: "Zeta #1", libraryID: "library")
    let alpha = Self.row(
      id: "alpha", title: "Alpha", seriesName: "Alpha #1", libraryID: "library")

    let sections = AuthorSeriesSection.sections(from: [standalone, zeta, alpha])

    #expect(sections.map(\.displayName) == ["Alpha", "Zeta", "Aardvark"])
    #expect(sections.last?.kind == .standaloneBook)
    #expect(sections.last?.rows.map(\.entityID) == ["standalone"])
  }

  @Test("each loose book becomes its own section rather than one invented collection")
  func givesEachLooseBookItsOwnSection() {
    let rows = [
      Self.row(id: "zulu", title: "Zulu", libraryID: "library"),
      Self.row(id: "series", title: "First", seriesName: "Saga #1", libraryID: "library"),
      Self.row(id: "alpha", title: "Alpha", libraryID: "library"),
    ]

    let sections = AuthorSeriesSection.sections(from: rows)

    let expectedIDs = [
      AuthorSeriesEntity.normalizedName("Saga"),
      AuthorSeriesSection.standaloneBookID(forItemID: "alpha"),
      AuthorSeriesSection.standaloneBookID(forItemID: "zulu"),
    ]
    #expect(sections.map(\.id) == expectedIDs)
    #expect(sections[1].kind == .standaloneBook)
    #expect(sections[2].kind == .standaloneBook)
    #expect(sections[1].rows.map(\.entityID) == ["alpha"])
    #expect(sections[2].rows.map(\.entityID) == ["zulu"])
    // A one-row section makes the row its own wash source, which is the point: the four books on
    // an author's page no longer share a colour extracted from whichever one happened to be first.
    #expect(sections[1].candidateWashSourceItemID == "alpha")
    #expect(sections[2].candidateWashSourceItemID == "zulu")
  }

  @Test("loose book sections use deterministic title, category, library, and ID order")
  func ordersLooseBookSectionsDeterministically() {
    let rows = [
      Self.row(
        id: "podcast-z", title: "Same", category: .podcast, libraryID: "library-b"),
      Self.row(
        id: "alpha", title: "Alpha", category: .podcast, libraryID: "library-b"),
      Self.row(
        id: "audio-z", title: "Same", category: .audiobook, libraryID: "library-b"),
      Self.row(
        id: "audio-a", title: "Same", category: .audiobook, libraryID: "library-b"),
      Self.row(
        id: "podcast-a", title: "Same", category: .podcast, libraryID: "library-a"),
    ]

    let sections = AuthorSeriesSection.sections(
      from: rows, identityOrder: ["library-a", "library-b"])

    #expect(sections.count == 5)
    #expect(sections.allSatisfy { $0.kind == .standaloneBook })
    #expect(
      sections.flatMap(\.rows).map(\.entityID) == [
        "alpha", "audio-a", "audio-z", "podcast-a", "podcast-z",
      ])
  }

  @Test("matching standalone audiobook and ebook editions share one title card")
  func groupsMatchingStandaloneFormats() {
    let rows = [
      Self.row(
        id: "ebook", title: "Cloud Cuckoo Land", category: .ebook,
        libraryID: "ebooks"),
      Self.row(
        id: "audio", title: "Cloud Cuckoo Land", category: .audiobook,
        libraryID: "audiobooks"),
    ]

    let sections = AuthorSeriesSection.sections(
      from: rows, identityOrder: ["audiobooks", "ebooks"])

    #expect(sections.count == 1)
    #expect(
      sections[0].id
        == AuthorSeriesSection.standaloneEditionsID(forTitle: "Cloud Cuckoo Land"))
    guard case .standaloneEditions(let key, let title) = sections[0].kind else {
      Issue.record("expected one grouped standalone-editions section")
      return
    }
    #expect(key == AuthorSeriesEntity.normalizedName("Cloud Cuckoo Land"))
    #expect(title == "Cloud Cuckoo Land")
    #expect(sections[0].displayName == "Cloud Cuckoo Land")
    #expect(sections[0].rows.map(\.entityID) == ["audio", "ebook"])
    #expect(sections.contains(where: { $0.kind == .standaloneBook }) == false)
  }

  @Test("cross-format standalone editions stay grouped alongside loose rows")
  func groupsMatchingStandaloneFormatsAlongsideLooseRows() {
    let rows = [
      Self.row(id: "loose", title: "Loose Book", libraryID: "library"),
      Self.row(
        id: "ebook", title: "Cloud Cuckoo Land", category: .ebook,
        libraryID: "ebooks"),
      Self.row(
        id: "audio", title: "Cloud Cuckoo Land", category: .audiobook,
        libraryID: "audiobooks"),
    ]

    let sections = AuthorSeriesSection.sections(
      from: rows, identityOrder: ["audiobooks", "ebooks", "library"])

    #expect(
      sections.map(\.id) == [
        AuthorSeriesSection.standaloneEditionsID(forTitle: "Cloud Cuckoo Land"),
        AuthorSeriesSection.standaloneBookID(forItemID: "loose"),
      ])
    #expect(sections[0].displayName == "Cloud Cuckoo Land")
    #expect(sections[0].rows.map(\.entityID) == ["audio", "ebook"])
    #expect(sections[1].rows.map(\.entityID) == ["loose"])
  }

  /// A card mid-run splits the loose books' grid into single-column fragments either side of it, so
  /// every card comes first and the single books follow as one uninterrupted run. Each half keeps
  /// its own alphabet.
  @Test("edition cards precede the loose books, each half in its own alphabet")
  func sortsEditionCardsAheadOfLooseBooks() {
    let rows = [
      Self.row(id: "loose", title: "Aardvark", libraryID: "library"),
      Self.row(id: "later", title: "Zeppelin", libraryID: "library"),
      Self.row(
        id: "ebook", title: "Zebra", category: .ebook, libraryID: "ebooks"),
      Self.row(
        id: "audio", title: "Zebra", category: .audiobook, libraryID: "audiobooks"),
      Self.row(id: "a-ebook", title: "Albatross", category: .ebook, libraryID: "ebooks"),
      Self.row(id: "a-audio", title: "Albatross", category: .audiobook, libraryID: "audiobooks"),
    ]

    let sections = AuthorSeriesSection.sections(
      from: rows, identityOrder: ["audiobooks", "ebooks", "library"])

    #expect(
      sections.map(\.id) == [
        AuthorSeriesSection.standaloneEditionsID(forTitle: "Albatross"),
        AuthorSeriesSection.standaloneEditionsID(forTitle: "Zebra"),
        AuthorSeriesSection.standaloneBookID(forItemID: "loose"),
        AuthorSeriesSection.standaloneBookID(forItemID: "later"),
      ])
    #expect(
      sections.map(\.displayName) == ["Albatross", "Zebra", "Aardvark", "Zeppelin"])
  }

  @Test("no single-format loose rows omit every loose book section")
  func omitsAggregateWithoutSingleFormatRows() {
    let rows = [
      Self.row(
        id: "ebook", title: "Cloud Cuckoo Land", category: .ebook,
        libraryID: "ebooks"),
      Self.row(
        id: "audio", title: "Cloud Cuckoo Land", category: .audiobook,
        libraryID: "audiobooks"),
    ]

    let sections = AuthorSeriesSection.sections(from: rows)

    #expect(sections.count == 1)
    #expect(sections.contains(where: { $0.kind == .standaloneBook }) == false)
  }

  @Test("standalone title matching follows the existing folded entity-name policy")
  func normalizesStandaloneEditionTitles() {
    let rows = [
      Self.row(
        id: "audio", title: "The Café Book", category: .audiobook,
        libraryID: "audiobooks"),
      Self.row(
        id: "ebook", title: "the cafe-book", category: .ebook,
        libraryID: "ebooks"),
    ]

    let sections = AuthorSeriesSection.sections(from: rows)

    #expect(sections.count == 1)
    #expect(sections[0].rows.map(\.entityID) == ["audio", "ebook"])
    #expect(sections[0].displayName == "The Café Book")
  }

  @Test("matching standalone copies do not group without both audiobook and ebook formats")
  func doesNotGroupMatchingSingleFormatCopies() {
    let rows = [
      Self.row(
        id: "audio-b", title: "Cloud Cuckoo Land", category: .audiobook,
        libraryID: "library-b"),
      Self.row(
        id: "audio-a", title: "Cloud Cuckoo Land", category: .audiobook,
        libraryID: "library-a"),
    ]

    let sections = AuthorSeriesSection.sections(
      from: rows, identityOrder: ["library-a", "library-b"])

    #expect(sections.count == 2)
    #expect(sections.allSatisfy { $0.kind == .standaloneBook })
    #expect(
      sections.map(\.id) == [
        AuthorSeriesSection.standaloneBookID(forItemID: "audio-a"),
        AuthorSeriesSection.standaloneBookID(forItemID: "audio-b"),
      ])
    #expect(sections.flatMap(\.rows).map(\.entityID) == ["audio-a", "audio-b"])
  }

  @Test("series rows sort by numeric sequence and put unsequenced entries last")
  func sortsNumericAndFractionalSequences() {
    let rows = [
      Self.row(id: "three", title: "Three", seriesName: "Saga #3", libraryID: "library"),
      Self.row(id: "unsequenced", title: "Bonus", seriesName: "Saga", libraryID: "library"),
      Self.row(id: "fraction", title: "Fraction", seriesName: "Saga #2.5", libraryID: "library"),
      Self.row(id: "one", title: "One", seriesName: "Saga #1", libraryID: "library"),
    ]

    let sections = AuthorSeriesSection.sections(from: rows)

    #expect(sections[0].rows.map(\.entityID) == ["one", "fraction", "three", "unsequenced"])
  }

  @Test("missing sequence stays in the named series and nameless #3 is unsequenced")
  func usesTheSharedSeriesDescriptorForMalformedNames() {
    let descriptor = LibraryEntityGrouping.seriesDescriptor(from: "#3")
    #expect(descriptor?.name == "#3")
    #expect(descriptor?.sequence == nil)

    let rows = [
      Self.row(id: "numbered", title: "Numbered", seriesName: "Saga #1", libraryID: "library"),
      Self.row(id: "missing", title: "Missing", seriesName: "Saga", libraryID: "library"),
      Self.row(id: "nameless", title: "Nameless", seriesName: "#3", libraryID: "library"),
    ]

    let sections = AuthorSeriesSection.sections(from: rows)

    #expect(sections.map(\.displayName) == ["#3", "Saga"])
    #expect(sections.last?.rows.map(\.entityID) == ["numbered", "missing"])
    #expect(sections.first?.rows.map(\.entityID) == ["nameless"])
  }

  @Test("same sequence and title use category, identity, and server ID tie breakers")
  func appliesDeterministicTieBreakers() {
    let rows = [
      Self.row(
        id: "ebook-z", title: "Same", seriesName: "Saga #1", category: .ebook,
        libraryID: "library-b"),
      Self.row(
        id: "podcast", title: "Same", seriesName: "Saga #1", category: .podcast,
        libraryID: "library-a"),
      Self.row(
        id: "audio-z", title: "Same", seriesName: "Saga #1", category: .audiobook,
        libraryID: "library-b"),
      Self.row(
        id: "audio-a", title: "Same", seriesName: "Saga #1", category: .audiobook,
        libraryID: "library-b"),
      Self.row(
        id: "audio-other-library", title: "Same", seriesName: "Saga #1", category: .audiobook,
        libraryID: "library-a"),
    ]

    let sections = AuthorSeriesSection.sections(
      from: rows, identityOrder: ["library-a", "library-b"])

    #expect(
      sections[0].rows.map(\.entityID)
        == ["audio-other-library", "audio-a", "audio-z", "podcast", "ebook-z"])
  }

  @Test("different titles at one sequence survive and sort by localized title")
  func keepsDifferentTitlesAtTheSameSequence() {
    let rows = [
      Self.row(id: "zulu", title: "Zulu", seriesName: "Saga #1", libraryID: "library"),
      Self.row(id: "alpha", title: "Alpha", seriesName: "Saga #1", libraryID: "library"),
    ]

    let sections = AuthorSeriesSection.sections(from: rows)

    #expect(sections[0].rows.map(\.entityID) == ["alpha", "zulu"])
  }

  @Test("localized title ties still end in a stable server ID order")
  func resolvesLocalizedTitleTiesDeterministically() {
    let rows = [
      Self.row(id: "id-b", title: "Same", seriesName: "Saga #1", libraryID: "library"),
      Self.row(id: "id-a", title: "Same", seriesName: "Saga #1", libraryID: "library"),
    ]

    let sections = AuthorSeriesSection.sections(from: rows)

    #expect(sections[0].rows.map(\.entityID) == ["id-a", "id-b"])
  }

  @Test("duplicate server IDs collapse while distinct IDs survive")
  func deduplicatesServerIDs() {
    let rows = [
      Self.row(
        id: "duplicate", title: "Later copy", seriesName: "Saga #2", libraryID: "library-b"),
      Self.row(
        id: "duplicate", title: "First copy", seriesName: "Saga #1", libraryID: "library-a"),
      Self.row(id: "distinct", title: "Distinct", seriesName: "Saga #3", libraryID: "library-a"),
    ]

    let sections = AuthorSeriesSection.sections(
      from: rows, identityOrder: ["library-a", "library-b"])

    #expect(sections.flatMap(\.rows).map(\.entityID) == ["duplicate", "distinct"])
    #expect(sections.flatMap(\.rows).first?.title == "First copy")
  }

  private static func row(
    id: String,
    title: String,
    seriesName: String? = nil,
    category: ItemMediaCategory? = nil,
    libraryID: String
  ) -> SearchResultRow {
    SearchResultRow(
      kind: .book, entityID: id, title: title, mediaCategory: category,
      seriesName: seriesName, libraryID: libraryID)
  }
}
