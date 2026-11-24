import ABSApi
import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

@Suite struct AuthorSeriesViewPresentationTests {

  // MARK: - The tile's one line of text

  /// The series card header names the series, so the tile's one line shows the number within the
  /// card and the book's duration.
  @Test("the tile line carries the sequence and the duration, and never the author")
  func tileDetailPairsSequenceAndDuration() {
    let detail = AuthorSeriesRowPresentation.tileDetail(
      for: Self.row(
        title: "Abaddon's Gate", author: "James S. A. Corey", series: "The Expanse #3",
        duration: 3_600))

    #expect(detail == "#3 · 1 hr")
    #expect(detail?.contains("James S. A. Corey") == false)
  }

  /// A tile draws only what it knows. An audiobook outside a series has a duration and no number.
  /// An ebook inside one has a number and no duration.
  @Test("either half of the tile line can stand alone")
  func tileDetailSurvivesEitherHalfMissing() {
    #expect(
      AuthorSeriesRowPresentation.tileDetail(
        for: Self.row(title: "Piranesi", duration: 54_000)) == "15 hr")
    #expect(
      AuthorSeriesRowPresentation.tileDetail(
        for: Self.row(title: "Annihilation", series: "Southern Reach #1", category: .ebook))
        == "#1")
  }

  /// `nil`, not an empty string. An ebook outside a series has neither fact, and a blank line would
  /// still take up height under the title.
  @Test("a book with neither a sequence nor a duration draws no line at all")
  func tileDetailIsNilWhenThereIsNothingToSay() {
    #expect(
      AuthorSeriesRowPresentation.tileDetail(
        for: Self.row(title: "The Shoemaker's Wife", author: "Adriana Trigiani", category: .ebook))
        == nil)
    #expect(
      AuthorSeriesRowPresentation.tileDetail(
        for: Self.row(title: "Unmeasured", category: .audiobook, duration: 0)) == nil)
  }

  /// Audiobookshelf numbers novellas fractionally. `#2.5` is the row a reader looks for when they
  /// open a series they are partway through.
  @Test("a fractional sequence survives, and a whole one does not grow a decimal point")
  func sequenceFormatting() {
    #expect(
      AuthorSeriesRowPresentation.tileDetail(
        for: Self.row(title: "Novella", series: "Discworld #2.5", category: .ebook)) == "#2.5")
    #expect(
      AuthorSeriesRowPresentation.tileDetail(
        for: Self.row(title: "Whole", series: "Discworld #3.0", category: .ebook)) == "#3")
  }

  /// The tile line must survive the series summary lifting the author out of the card, so the
  /// sequence stays sequence-only wherever it is drawn.
  @Test("the compact detail keeps only the sequence, never the author")
  func sequenceDetailIsSequenceOnly() {
    #expect(
      AuthorSeriesRowPresentation.sequenceDetail(
        for: Self.row(title: "Three", author: "James S. A. Corey", series: "The Expanse #3"))
        == "#3")
    let novella = AuthorSeriesRowPresentation.sequenceDetail(
      for: Self.row(title: "Novella", author: "James S. A. Corey", series: "The Expanse #2.5"))
    #expect(novella == "#2.5")
    #expect(novella?.contains("James S. A. Corey") == false)
    #expect(
      AuthorSeriesRowPresentation.sequenceDetail(
        for: Self.row(title: "Whole", series: "The Expanse #3.0")) == "#3")
    #expect(
      AuthorSeriesRowPresentation.sequenceDetail(for: Self.row(title: "Standalone")) == nil)
  }

  // MARK: - Card copy

  @Test("card headings preserve server capitalization and a series counts books, not editions")
  func cardHeadingAndItemCount() {
    let first = Self.row(id: "item-1", title: "First", series: "the Expanse #1")
    let duplicate = Self.row(id: "item-1", title: "Duplicate", series: "the Expanse #1")
    let second = Self.row(id: "item-2", title: "Second", series: "the Expanse #2")
    let section = AuthorSeriesSection.sections(from: [first, duplicate, second])[0]

    #expect(AuthorSeriesCopy.cardHeading(for: section) == "the Expanse")
    #expect(section.itemCount == 2)
    // Two different novels are not two editions of one.
    #expect(AuthorSeriesCopy.itemCountText(for: section, hasMore: false) == "2 books")
    #expect(AuthorSeriesCopy.cardHeadingLabel(for: section, hasMore: false) == "the Expanse, 2 books")
  }

  @Test("a final single-book card uses the singular count and an incomplete page has no count")
  func cardCountWaitsForExhaustion() {
    let section = AuthorSeriesSection(
      id: "series-1",
      kind: .series(key: "series-1", name: "The Expanse"),
      rows: [Self.row(title: "Leviathan Wakes", series: "The Expanse #1")])

    #expect(AuthorSeriesCopy.itemCountText(for: section, hasMore: false) == "1 book")
    #expect(AuthorSeriesCopy.itemCountText(for: section, hasMore: true) == nil)
    #expect(AuthorSeriesCopy.cardHeadingLabel(for: section, hasMore: true) == "The Expanse")
  }

  @Test("a series summary joins its author and final book count")
  func seriesSummaryIncludesAuthorAndCount() {
    let section = AuthorSeriesSection(
      id: "series-1",
      kind: .series(key: "series-1", name: "The Expanse"),
      rows: [
        Self.row(title: "First", author: "James S. A. Corey"),
        Self.row(id: "second", title: "Second", author: "James S. A. Corey"),
      ])

    #expect(
      AuthorSeriesCopy.seriesSummary(for: section, hasMore: false)
        == "James S. A. Corey · 2 books")
  }

  @Test("a series summary keeps its author while pagination withholds the count")
  func seriesSummaryWithMoreIsAuthorOnly() {
    let section = AuthorSeriesSection(
      id: "series-1",
      kind: .series(key: "series-1", name: "The Expanse"),
      rows: [Self.row(title: "First", author: "James S. A. Corey")])

    #expect(AuthorSeriesCopy.seriesSummary(for: section, hasMore: true) == "James S. A. Corey")
  }

  @Test("a series summary can show only a final count when authors are absent")
  func seriesSummaryWithNoAuthorUsesOnlyCount() {
    let section = AuthorSeriesSection(
      id: "series-1",
      kind: .series(key: "series-1", name: "The Expanse"),
      rows: [
        Self.row(title: "First", author: "   "),
        Self.row(id: "second", title: "Second"),
      ])

    #expect(AuthorSeriesCopy.seriesSummary(for: section, hasMore: false) == "2 books")
    #expect(AuthorSeriesCopy.seriesSummary(for: section, hasMore: true) == nil)
  }

  @Test("a series summary uses the earliest author on an even split")
  func seriesSummaryUsesPrimaryAuthorTieBreak() {
    let section = AuthorSeriesSection(
      id: "series-1",
      kind: .series(key: "series-1", name: "The Expanse"),
      rows: [
        Self.row(title: "First", author: "Author Two"),
        Self.row(id: "second", title: "Second", author: "Author One"),
        Self.row(id: "third", title: "Third", author: "Author One"),
        Self.row(id: "fourth", title: "Fourth", author: "Author Two"),
      ])

    #expect(
      AuthorSeriesCopy.seriesSummary(for: section, hasMore: false) == "Author Two · 4 books")
  }

  @Test("a loose book heads itself and carries no count")
  func standaloneBookHeadsItself() {
    let section = AuthorSeriesSection.sections(from: [Self.row(title: "Piranesi")])[0]

    #expect(section.kind == .standaloneBook)
    #expect(AuthorSeriesCopy.cardHeading(for: section) == "Piranesi")
    #expect(AuthorSeriesCopy.itemCountText(for: section, hasMore: false) == nil)
    #expect(
      AuthorSeriesCopy.showsCardHeader(for: section, target: .author(id: "author")) == false)
  }

  @Test("the Books header separates loose books from the series above, and is absent otherwise")
  func standaloneHeaderOnlySeparatesFromCollections() {
    let sections = AuthorSeriesSection.sections(from: [
      Self.row(id: "series", title: "First", series: "Saga #1"),
      Self.row(id: "loose", title: "Piranesi"),
    ])
    #expect(
      AuthorSeriesCopy.standaloneHeaderSectionID(for: sections, target: .author(id: "author"))
        == AuthorSeriesSection.standaloneBookID(forItemID: "loose"))

    // Nothing above to separate from: the header would only name the whole screen.
    let looseOnly = AuthorSeriesSection.sections(from: [Self.row(id: "loose", title: "Piranesi")])
    #expect(
      AuthorSeriesCopy.standaloneHeaderSectionID(for: looseOnly, target: .author(id: "author"))
        == nil)
    #expect(
      AuthorSeriesCopy.standaloneHeaderSectionID(for: sections, target: .series(id: "series"))
        == nil)
  }

  @Test("a cross-format standalone card is headed by its shared title and edition count")
  func groupedStandaloneHeading() {
    let section = AuthorSeriesSection(
      id: AuthorSeriesSection.standaloneEditionsID(forTitle: "Cloud Cuckoo Land"),
      kind: .standaloneEditions(
        key: AuthorSeriesEntity.normalizedName("Cloud Cuckoo Land"),
        title: "Cloud Cuckoo Land"),
      rows: [
        Self.row(title: "Cloud Cuckoo Land", category: .audiobook),
        Self.row(id: "ebook", title: "Cloud Cuckoo Land", category: .ebook),
      ])

    #expect(AuthorSeriesCopy.cardHeading(for: section) == "Cloud Cuckoo Land")
    #expect(AuthorSeriesCopy.itemCountText(for: section, hasMore: false) == "2 editions")
    #expect(
      AuthorSeriesCopy.cardHeadingLabel(for: section, hasMore: false)
        == "Cloud Cuckoo Land, 2 editions")
  }

  @Test("author-page series and edition cards draw headers, a loose book's row does not")
  func cardHeaderVisibility() {
    let standaloneBook = AuthorSeriesSection.sections(from: [Self.row(title: "Piranesi")])[0]
    let grouped = AuthorSeriesSection(
      id: AuthorSeriesSection.standaloneEditionsID(forTitle: "Cloud Cuckoo Land"),
      kind: .standaloneEditions(key: "cloudcuckooland", title: "Cloud Cuckoo Land"),
      rows: [
        Self.row(title: "Cloud Cuckoo Land", category: .audiobook),
        Self.row(id: "ebook", title: "Cloud Cuckoo Land", category: .ebook),
      ])
    let series = AuthorSeriesSection(
      id: "saga", kind: .series(key: "saga", name: "Saga"),
      rows: [Self.row(title: "First", series: "Saga #1")])

    #expect(
      AuthorSeriesCopy.showsCardHeader(for: standaloneBook, target: .author(id: "author"))
        == false)
    #expect(AuthorSeriesCopy.showsCardHeader(for: grouped, target: .author(id: "author")))
    #expect(AuthorSeriesCopy.showsCardHeader(for: series, target: .author(id: "author")))
    #expect(AuthorSeriesCopy.showsCardHeader(for: grouped, target: .series(id: "series")) == false)
  }

  // MARK: - The media badge

  @Test("an ebook row badges as an ebook and an audiobook row as an audiobook")
  func mediaBadgeFollowsTheRowsCategory() {
    #expect(
      AuthorSeriesRowPresentation.mediaBadge(for: Self.row(title: "A", category: .ebook))?.label
        == HomeRowPresentation.badgeLabel(for: .ebook))
    #expect(
      AuthorSeriesRowPresentation.mediaBadge(for: Self.row(title: "A", category: .audiobook))?.label
        == HomeRowPresentation.badgeLabel(for: .audiobook))
  }

  // MARK: - Audiobook metadata

  @Test("playback progress uses audio duration and ebook fraction")
  func playbackProgressUsesTheRowsMediaCategory() {
    let audiobook = Self.row(title: "Audio", category: .audiobook, duration: 3_600)
    let ebook = Self.row(title: "eBook", category: .ebook)

    #expect(
      AuthorSeriesRowPresentation.progressFraction(
        for: audiobook,
        progress: ItemPlaybackProgress(currentTime: 900, isFinished: false),
        status: .inProgress) == 0.25)
    #expect(
      AuthorSeriesRowPresentation.progressFraction(
        for: ebook,
        progress: ItemPlaybackProgress(
          currentTime: 0, ebookProgress: 0.4, isFinished: false),
        status: .inProgress) == 0.4)
  }

  @Test("finished, unstarted, and unknown-duration rows have no progress bar")
  func progressBarRequiresACalculableInProgressFraction() {
    let audiobook = Self.row(title: "Audio", category: .audiobook, duration: nil)
    let progress = ItemPlaybackProgress(currentTime: 900, isFinished: false)

    #expect(
      AuthorSeriesRowPresentation.progressFraction(
        for: audiobook, progress: progress, status: .inProgress) == nil)
    #expect(
      AuthorSeriesRowPresentation.progressFraction(
        for: audiobook, progress: progress, status: .finished) == nil)
    #expect(
      AuthorSeriesRowPresentation.progressFraction(
        for: audiobook, progress: progress, status: nil) == nil)
  }

  /// Every tile shows the duration. The narrator appears only in the spoken label, so an
  /// audiobook's credit does not depend on whether it belongs to a series.
  @Test("the drawn duration never carries a narrator credit")
  func durationDetailIsDurationOnly() {
    let audiobook = Self.row(
      title: "Leviathan Wakes", category: .audiobook, duration: 3_600,
      narrator: "Jefferson Mays")

    let metadata = AuthorSeriesRowPresentation.durationDetail(for: audiobook)
    #expect(metadata == "1 hr")
    #expect(metadata?.contains("Narrated by") == false)
    #expect(
      AuthorSeriesRowPresentation.tileDetail(for: audiobook)?.contains("Jefferson Mays") == false)
    #expect(
      AuthorSeriesRowPresentation.durationDetail(
        for: Self.row(title: "Zero", category: .audiobook, duration: 0)) == nil)
    #expect(
      AuthorSeriesRowPresentation.durationDetail(
        for: Self.row(title: "Absent", category: .audiobook, duration: nil)) == nil)
  }

  @Test("ebook rows never borrow audiobook metadata")
  func ebookRowsOmitAudiobookMetadata() {
    let ebook = Self.row(
      title: "Ebook", category: .ebook, duration: 7_200, narrator: "Server oddity")

    #expect(AuthorSeriesRowPresentation.durationDetail(for: ebook) == nil)
  }

  // MARK: - Display groups

  /// Loose books share the two columns a series card uses, so the grid is the unit. Each book
  /// still carries its own card, and so its own colour.
  @Test("loose books collapse into one grid while every real group keeps its own card")
  func looseBooksShareOneGrid() {
    let sections = AuthorSeriesSection.sections(from: [
      Self.row(id: "saga-1", title: "First", series: "Saga #1"),
      Self.row(id: "loose-a", title: "Aardvark"),
      Self.row(id: "loose-b", title: "Beetle"),
    ])
    let groups = AuthorSeriesDisplayGroup.groups(for: sections)

    #expect(groups.count == 2)
    #expect(groups.first == .card(sections[0]))
    #expect(groups.last == .looseBooks([sections[1], sections[2]]))
    // The header rule is stated in terms of the first loose section, which leads its group.
    #expect(
      groups.last?.leadingSectionID
        == AuthorSeriesCopy.standaloneHeaderSectionID(
          for: sections, target: .author(id: "author")))
  }

  /// The projection puts every card ahead of the single books so this run stays whole. A card
  /// between two books would leave a column fragment on either side.
  @Test("an editions card sits ahead of the run rather than splitting it")
  func anEditionsCardPrecedesTheRun() {
    let sections = AuthorSeriesSection.sections(from: [
      Self.row(id: "loose-a", title: "Aardvark"),
      Self.row(id: "mid-audio", title: "Middle", category: .audiobook),
      Self.row(id: "mid-ebook", title: "Middle", category: .ebook),
      Self.row(id: "loose-z", title: "Zebra"),
    ])
    let groups = AuthorSeriesDisplayGroup.groups(for: sections)

    #expect(groups.count == 2)
    #expect(groups[0] == .card(sections[0]))
    #expect(groups[1] == .looseBooks([sections[1], sections[2]]))
  }

  /// The grouping is run-length, so a card appearing mid-run breaks the run rather than silently
  /// resequencing the books around it.
  @Test("a card between two books breaks the run instead of reordering it")
  func aCardMidRunBreaksTheRun() {
    let alpha = AuthorSeriesSection(
      id: AuthorSeriesSection.standaloneBookID(forItemID: "a"), kind: .standaloneBook,
      rows: [Self.row(id: "a", title: "Alpha")])
    let card = AuthorSeriesSection(
      id: "series", kind: .series(key: "series", name: "Saga"),
      rows: [Self.row(id: "s", title: "Saga One", series: "Saga #1")])
    let omega = AuthorSeriesSection(
      id: AuthorSeriesSection.standaloneBookID(forItemID: "z"), kind: .standaloneBook,
      rows: [Self.row(id: "z", title: "Omega")])

    #expect(
      AuthorSeriesDisplayGroup.groups(for: [alpha, card, omega])
        == [.looseBooks([alpha]), .card(card), .looseBooks([omega])])
  }

  @Test("no sections at all produce no groups")
  func emptySectionsProduceNoGroups() {
    #expect(AuthorSeriesDisplayGroup.groups(for: []).isEmpty)
  }

  // MARK: - Cover shape

  /// Only a grid made up entirely of ebooks uses the taller portrait box. One ebook among
  /// audiobooks would otherwise band every square audiobook cover by a third.
  @Test("a grid of audiobooks alone gets a square cover box")
  func audiobooksAloneGetASquareBox() {
    #expect(
      AuthorSeriesCoverShape.shape(for: [
        Self.row(title: "One", category: .audiobook),
        Self.row(title: "Two", category: .audiobook),
      ]) == .square)
  }

  @Test("a grid of ebooks alone gets the portrait cover box")
  func ebooksAloneGetAPortraitBox() {
    #expect(
      AuthorSeriesCoverShape.shape(for: [
        Self.row(title: "One", category: .ebook),
        Self.row(title: "Two", category: .ebook),
      ]) == .portrait)
    #expect(
      AuthorSeriesCoverShape.shape(for: [Self.row(title: "Only", category: .ebook)])
        == .portrait)
  }

  @Test("one audiobook anywhere in a grid takes the square box")
  func oneAudiobookTakesTheSquareBox() {
    #expect(
      AuthorSeriesCoverShape.shape(for: [
        Self.row(title: "One", category: .audiobook),
        Self.row(title: "Two", category: .ebook),
      ]) == .square)
  }

  /// Neither box crops, since the cover is fitted into whichever it gets. An unresolved category
  /// only decides which inset shows if the guess is wrong, and a side inset reads better than a
  /// band under the artwork.
  @Test("an unresolved category takes the square box")
  func anUnresolvedCategoryTakesTheSquareBox() {
    let unresolved = SearchResultRow(
      kind: .book, entityID: "unresolved", title: "Unresolved", mediaCategory: nil,
      libraryID: "lib")

    #expect(
      AuthorSeriesCoverShape.shape(for: [
        Self.row(title: "One", category: .ebook), unresolved,
      ]) == .square)
  }

  @Test("a grid with no rows at all takes the square box")
  func noRowsTakeTheSquareBox() {
    #expect(AuthorSeriesCoverShape.shape(for: []) == .square)
  }

  // MARK: - Selection

  /// The category decides what a tap opens and what the long-press menu offers. Flattening every
  /// book to `.audiobook` would offer Play for something with nothing to play.
  @Test("the selected summary carries the row's own category and series")
  func selectionCarriesTheRowsCategory() {
    let summary = AuthorSeriesRowPresentation.itemSummary(
      for: Self.row(
        id: "server-item-42", title: "Annihilation", series: "Southern Reach #1", category: .ebook))

    #expect(summary.category == .ebook)
    #expect(summary.seriesName == "Southern Reach #1")
    #expect(summary.serverItemId == "server-item-42")
  }

  @Test("the selected summary carries duration and narrator metadata")
  func selectionCarriesAudiobookMetadata() {
    let summary = AuthorSeriesRowPresentation.itemSummary(
      for: Self.row(title: "The Book", duration: 4_500, narrator: "Robin Miles"))

    #expect(summary.durationSeconds == 4_500)
    #expect(summary.narratorName == "Robin Miles")
  }

  @Test("a row with no resolved category still opens as an audiobook")
  func unresolvedCategoryFallsBack() {
    let summary = AuthorSeriesRowPresentation.itemSummary(
      for: SearchResultRow(kind: .book, entityID: "1", title: "A", libraryID: "lib"))

    #expect(summary.category == .audiobook)
  }

  /// Selection prepares the detail palette under the summary's cover revision. The key needs the
  /// row's `serverUpdatedAt`, or it matches neither the saved palette nor the cover the tile drew,
  /// and the detail page opens on the neutral fallback before fading to its accent.
  @Test("the selected summary keeps the row's cover revision", arguments: [SearchResultKind.book, .podcast])
  func selectionKeepsTheRowsCoverRevision(kind: SearchResultKind) {
    let row = Self.row(
      kind: kind, title: "Annihilation", serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let summary = AuthorSeriesRowPresentation.itemSummary(for: row)

    #expect(summary.artworkRevision == row.artworkRevision)
    #expect(summary.artworkRevision != .unversioned)
  }

  // MARK: - Accessibility

  @Test("an author label carries section series context and the format once")
  func authorAccessibilityLabelUsesSectionContext() {
    let row = Self.row(
      title: "Annihilation", author: "Jeff VanderMeer", series: "southern reach #1",
      category: .ebook)
    let section = AuthorSeriesSection(
      id: "southern reach",
      kind: .series(key: "southern reach", name: "Southern Reach"), rows: [row])

    let label = AuthorSeriesRowPresentation.accessibilityLabel(
      for: row, in: section,
      target: .author(id: "author-1"))

    #expect(label == "Annihilation, book #1 in Southern Reach, eBook")
    #expect(label.contains("Jeff VanderMeer") == false)
  }

  @Test("a standalone author label says standalone instead of an author fallback")
  func standaloneAccessibilityLabel() {
    let row = Self.row(title: "Piranesi", author: "Susanna Clarke", category: .audiobook)
    let section = AuthorSeriesSection(
      id: AuthorSeriesSection.standaloneBookID(forItemID: row.entityID), kind: .standaloneBook,
      rows: [row])

    #expect(
      AuthorSeriesRowPresentation.accessibilityLabel(
        for: row, in: section, target: .author(id: "author-1"))
        == "Piranesi, standalone, Audiobook")
  }

  @Test("an audiobook label speaks the full duration and narrator credit")
  func audiobookAccessibilityLabelIncludesMetadata() {
    let row = Self.row(
      title: "Piranesi", category: .audiobook, duration: 54_000,
      narrator: "Chiwetel Ejiofor")
    let section = AuthorSeriesSection(
      id: AuthorSeriesSection.standaloneBookID(forItemID: row.entityID), kind: .standaloneBook,
      rows: [row])

    #expect(
      AuthorSeriesRowPresentation.accessibilityLabel(
        for: row, in: section, target: .author(id: "author-1"))
        == "Piranesi, standalone, Audiobook, 15 hr, Narrated by Chiwetel Ejiofor")
  }

  @Test("grouped standalone editions keep independent format-specific labels")
  func groupedStandaloneAccessibilityLabels() {
    let audiobook = Self.row(title: "Cloud Cuckoo Land", category: .audiobook)
    let ebook = Self.row(id: "ebook", title: "Cloud Cuckoo Land", category: .ebook)
    let section = AuthorSeriesSection(
      id: AuthorSeriesSection.standaloneEditionsID(forTitle: "Cloud Cuckoo Land"),
      kind: .standaloneEditions(key: "cloudcuckooland", title: "Cloud Cuckoo Land"),
      rows: [audiobook, ebook])

    #expect(
      AuthorSeriesRowPresentation.accessibilityLabel(
        for: audiobook, in: section, target: .author(id: "author"))
        == "Cloud Cuckoo Land, standalone, Audiobook")
    #expect(
      AuthorSeriesRowPresentation.accessibilityLabel(
        for: ebook, in: section, target: .author(id: "author"))
        == "Cloud Cuckoo Land, standalone, eBook")
  }

  @Test("a series label keeps sequence and author while naming the format once")
  func seriesAccessibilityLabel() {
    let row = Self.row(
      title: "Annihilation", author: "Jeff VanderMeer", series: "Southern Reach #1",
      category: .ebook)
    let section = AuthorSeriesSection(
      id: "southern reach",
      kind: .series(key: "southern reach", name: "Southern Reach"), rows: [row])

    #expect(
      AuthorSeriesRowPresentation.accessibilityLabel(
        for: row, in: section, target: .series(id: "series-1"))
        == "Annihilation, book #1, Jeff VanderMeer, eBook")
  }

  @Test("a series label omits an absent author without losing the sequence")
  func seriesAccessibilityLabelOmitsAbsentAuthor() {
    let row = Self.row(title: "Annihilation", series: "Southern Reach #1", category: .ebook)
    let section = AuthorSeriesSection(
      id: "southern reach",
      kind: .series(key: "southern reach", name: "Southern Reach"), rows: [row])

    #expect(
      AuthorSeriesRowPresentation.accessibilityLabel(
        for: row, in: section, target: .series(id: "series-1"))
        == "Annihilation, book #1, eBook")
  }

  private static func row(
    kind: SearchResultKind = .book,
    id: String? = nil,
    title: String,
    author: String? = nil,
    series: String? = nil,
    category: ItemMediaCategory = .audiobook,
    duration: Double? = nil,
    narrator: String? = nil,
    serverUpdatedAt: Date? = nil
  ) -> SearchResultRow {
    SearchResultRow(
      kind: kind, entityID: id ?? "item-\(title)", title: title, subtitle: author,
      mediaCategory: category, seriesName: series, durationSeconds: duration,
      narratorName: narrator, libraryID: "lib", serverUpdatedAt: serverUpdatedAt)
  }
}
