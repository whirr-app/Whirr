import AppModel
import DesignSystem
import Foundation
import Persistence

/// Maps a `SearchResultRow` (always `.book`/`.podcast` for the rows `AuthorSeriesService` produces)
/// to the `ItemSummary` that selection and navigation expect, mirroring `HomeMoreView.podcastRow`.
enum AuthorSeriesRowPresentation {
  /// Carries the row's `serverUpdatedAt` because selection keys the detail palette by the summary's
  /// cover revision; without it the key misses the saved palette and the tile's cached cover.
  static func itemSummary(for row: SearchResultRow) -> ItemSummary {
    switch row.kind {
    case .podcast:
      return ItemSummary(
        serverItemId: row.entityID, mediaKind: "podcast", title: row.title,
        author: row.subtitle, durationSeconds: row.durationSeconds, category: .podcast,
        hasReadableEbook: row.hasReadableEbook, serverUpdatedAt: row.serverUpdatedAt)
    case .book, .episode, .author, .series:
      return ItemSummary(
        serverItemId: row.entityID, mediaKind: "book", title: row.title,
        author: row.subtitle, durationSeconds: row.durationSeconds,
        // The row's own resolved category, not a flat `.audiobook`: this summary decides what the
        // tap opens and which action the long-press menu offers, and flattening an ebook would
        // offer Play for something with nothing to play. `.audiobook` is the fallback for a row
        // whose backing item hasn't resolved, as `SearchViewPresentation` treats it.
        category: row.mediaCategory ?? .audiobook,
        hasReadableEbook: row.hasReadableEbook,
        seriesName: row.seriesName,
        narratorName: row.narratorName,
        serverUpdatedAt: row.serverUpdatedAt)
    }
  }

  // MARK: - Row detail

  /// The tile's one line of text below the title: where the book sits in its series, then how long
  /// it is, on one line because the media and playback marks sit on the cover (inline, three
  /// things wrapped in a tile barely wider than one). `nil`, not empty, when there is nothing to
  /// say, so the tile claims no height.
  static func tileDetail(for row: SearchResultRow) -> String? {
    joined([sequenceDetail(for: row), durationDetail(for: row)])
  }

  /// The sequence alone, on both destinations: a series destination hoists its author into the
  /// summary above the card, so a narrow tile repeating it would spend its one line twice.
  static func sequenceDetail(for row: SearchResultRow) -> String? {
    sequenceText(for: row)
  }

  /// `#3`, or `#2.5` for the fractional sequences Audiobookshelf numbers novellas with. Formatted
  /// from the parsed value rather than sliced out of the raw string so a `#3.0` from the server
  /// still reads as `#3`.
  private nonisolated static func sequenceText(
    _ descriptor: LibraryEntityGrouping.SeriesDescriptor
  ) -> String? {
    guard let sequence = descriptor.sequence else { return nil }
    guard sequence != sequence.rounded() else { return "#\(Int(sequence))" }
    return "#\(sequence)"
  }

  /// The badge/label pair for the row's media kind: the same `MediaKindBadgeView` pairing Search
  /// and the Library rows render, resolved through the one presentation that owns kind-to-badge.
  static func mediaBadge(for row: SearchResultRow) -> (kind: MediaKindBadge, label: String)? {
    SearchViewPresentation.mediaBadge(for: row)
  }

  /// The one audiobook fact this screen draws. The narrator stays in the complete spoken label and
  /// on the detail screen. Ebooks stay free of audiobook-only language even if a malformed server
  /// item happens to carry a duration.
  static func durationDetail(for row: SearchResultRow) -> String? {
    guard row.mediaCategory == .audiobook else { return nil }
    return durationText(row.durationSeconds)
  }

  /// The bar is the richer in-progress treatment for these editorial rows. Finished and
  /// unstarted states never return a fraction; an audiobook with no usable duration falls back to
  /// the shared in-progress glyph rather than drawing a misleading empty bar.
  static func progressFraction(
    for row: SearchResultRow,
    progress: ItemPlaybackProgress?,
    status: ItemPlaybackStatus?
  ) -> Double? {
    guard status == .inProgress, let progress, progress.isFinished == false else { return nil }
    switch row.mediaCategory {
    case .ebook:
      guard let ebookProgress = progress.ebookProgress else { return nil }
      return HomeRowPresentation.ebookProgressFraction(ebookProgress: ebookProgress)
    case .audiobook:
      return HomeRowPresentation.progressFraction(
        progressSeconds: progress.currentTime, durationSeconds: row.durationSeconds)
    case .podcast, nil:
      return nil
    }
  }

  private static func durationText(_ seconds: Double?) -> String? {
    ItemDetailDurationPresentation.durationText(category: .audiobook, durationSeconds: seconds)
  }

  private static func narratorCredit(_ narrator: String?) -> String? {
    trimmed(narrator).map { "Narrated by \($0)" }
  }

  /// One spoken sentence per row, built from the card as well as the row. The row does not draw its
  /// series name, but VoiceOver still needs that context to distinguish two editions in the same
  /// author's list. The card supplies the server's original display capitalisation.
  static func accessibilityLabel(
    for row: SearchResultRow,
    in section: AuthorSeriesSection,
    target: AuthorSeriesModel.Target,
    playbackStatus: ItemPlaybackStatus? = nil,
    progressFraction: Double? = nil
  ) -> String {
    let context: String?
    switch target {
    case .author, .authorName, .narrator:
      switch section.kind {
      case .series:
        let book = sequenceText(for: row).map { "book \($0)" } ?? "book"
        context = "\(book) in \(section.displayName)"
      case .standaloneBook, .standalone, .standaloneEditions:
        context = "standalone"
      }
    case .series, .seriesName:
      let book = sequenceText(for: row).map { "book \($0)" } ?? "book"
      context = book
    }

    let author: String?
    switch target {
    case .author, .authorName:
      author = nil
    case .series, .seriesName, .narrator:
      author = trimmed(row.subtitle)
    }
    let metadata: [String?]
    if row.mediaCategory == .audiobook {
      metadata = [durationText(row.durationSeconds), narratorCredit(row.narratorName)]
    } else {
      metadata = []
    }
    return commaJoined(
      [row.title, context, author, mediaBadge(for: row)?.label] + metadata
        + [playbackAccessibilityLabel(status: playbackStatus, fraction: progressFraction)])
  }

  private static func playbackAccessibilityLabel(
    status: ItemPlaybackStatus?, fraction: Double?
  ) -> String? {
    switch status {
    case .finished:
      ItemFinishedCopy.badgeLabel
    case .inProgress:
      fraction.map { "\(ItemProgressCopy.badgeLabel), \(Int(($0 * 100).rounded()))%" }
        ?? ItemProgressCopy.badgeLabel
    case nil:
      nil
    }
  }

  private static func sequenceText(for row: SearchResultRow) -> String? {
    LibraryEntityGrouping.seriesDescriptor(from: row.seriesName).flatMap(sequenceText)
  }

  static func joined(_ parts: [String?]) -> String? {
    let text = parts.compactMap { $0 }.filter { $0.isEmpty == false }.joined(separator: " · ")
    return text.isEmpty ? nil : text
  }

  private static func commaJoined(_ parts: [String?]) -> String {
    parts.compactMap { $0 }.filter { $0.isEmpty == false }.joined(separator: ", ")
  }

  private static func trimmed(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false
    else { return nil }
    return text
  }
}

/// The shape of the one box every cover in a grid is drawn into.
///
/// One box per grid, so titles don't step across a row. Covers are fitted, not cropped: a square
/// cover in a portrait box leaves a band under the art (reads as a mistake), a portrait cover in a
/// square box is inset at the sides (reads as a margin). So the square wins any grid holding an
/// audiobook; only an all-ebook grid gets the portrait box. Media kind is the proxy because it is
/// known before artwork loads; sizing to decoded covers would relayout the page.
enum AuthorSeriesCoverShape: Equatable {
  case portrait
  case square

  /// Width over height.
  var aspectRatio: CGFloat {
    switch self {
    case .portrait: 2.0 / 3.0
    case .square: 1
    }
  }

  /// A row whose category has not resolved yet counts against the portrait case: an unknown kind
  /// may be an audiobook, and the square is the shape that costs less when the guess is wrong.
  static func shape(for rows: [SearchResultRow]) -> AuthorSeriesCoverShape {
    guard rows.isEmpty == false else { return .square }
    return rows.allSatisfy { $0.mediaCategory == .ebook } ? .portrait : .square
  }
}

/// What the screen draws as one unit.
///
/// A card owns its grid of tiles; a run of loose books shares one, so two sit side by side
/// instead of each taking a full width it has nothing to fill.
enum AuthorSeriesDisplayGroup: Identifiable, Equatable {
  case card(AuthorSeriesSection)
  case looseBooks([AuthorSeriesSection])

  var id: String {
    switch self {
    case .card(let section): section.id
    case .looseBooks(let sections): "loose-books/\(sections.first?.id ?? "")"
    }
  }

  /// The first section the group draws, which is the identity the `Books` header rule is stated in
  /// terms of.
  var leadingSectionID: String? {
    switch self {
    case .card(let section): section.id
    case .looseBooks(let sections): sections.first?.id
    }
  }

  /// Consecutive loose books collapse into one grid; everything the projection still groups keeps a
  /// card of its own. Grouping by run rather than by resequencing keeps the projection's order the
  /// order the reader sees: the projection puts every card ahead of the books so this run is
  /// unbroken, and a card that did land mid-run would break the grid rather than be silently sorted
  /// out of the way.
  static func groups(for sections: [AuthorSeriesSection]) -> [AuthorSeriesDisplayGroup] {
    var groups: [AuthorSeriesDisplayGroup] = []
    var run: [AuthorSeriesSection] = []

    func flushRun() {
      guard run.isEmpty == false else { return }
      groups.append(.looseBooks(run))
      run = []
    }

    for section in sections {
      switch section.kind {
      case .standaloneBook:
        run.append(section)
      case .series, .standalone, .standaloneEditions:
        flushRun()
        groups.append(.card(section))
      }
    }
    flushRun()
    return groups
  }
}

enum AuthorSeriesCopy {
  static let loadingMessage = "Loading…"
  static let emptyTitle = "No Books"
  static let emptySystemImage = "books.vertical"
  static let loadingMoreLabel = "Loading more books"

  /// The section projection has already preserved the server's display spelling. Returning it
  /// directly keeps a card heading and its spoken label from inventing an uppercase variant.
  static func cardHeading(for section: AuthorSeriesSection) -> String {
    section.displayName
  }

  /// Author pages name each group once. Series destinations already have that name in the
  /// navigation bar, and a loose book's row already draws its own title as its first line.
  static func showsCardHeader(
    for section: AuthorSeriesSection, target: AuthorSeriesModel.Target
  ) -> Bool {
    guard target.isSeriesDestination == false else { return false }
    switch section.kind {
    case .series, .standalone, .standaloneEditions:
      return true
    case .standaloneBook:
      return false
    }
  }

  /// The plain header above the run of books that belong to no series. It exists to separate them
  /// from the collections above, so `standaloneHeaderSectionID` withholds it when nothing precedes.
  static let standaloneHeading = "Books"

  /// A count is meaningful only after every identity has exhausted its pages. The section's
  /// `itemCount` is visible, deduplicated server items, which is why the two kinds are worded
  /// differently: a series card counts books, while an editions card counts formats of one book.
  /// "N editions" on a series card would call four different novels four printings of one.
  static func itemCountText(
    for section: AuthorSeriesSection, hasMore: Bool
  ) -> String? {
    guard hasMore == false else { return nil }
    switch section.kind {
    case .standaloneEditions:
      return section.itemCount == 1 ? "1 edition" : "\(section.itemCount) editions"
    case .series, .standalone:
      return section.itemCount == 1 ? "1 book" : "\(section.itemCount) books"
    case .standaloneBook:
      // Its row is the count.
      return nil
    }
  }

  /// A quiet line above a series destination's card. The author follows the same frequency and
  /// earliest-seen tie-break as the Library series row; the count waits for pagination to finish.
  static func seriesSummary(
    for section: AuthorSeriesSection, hasMore: Bool
  ) -> String? {
    let author = LibraryEntityGrouping.primaryAuthorName(among: section.rows.map(\.subtitle))
    return AuthorSeriesRowPresentation.joined([
      author, itemCountText(for: section, hasMore: hasMore),
    ])
  }

  /// The heading element includes its count only when the count is visible. Keep this separate
  /// from the drawn count so the view can style the two pieces without changing VoiceOver copy.
  static func cardHeadingLabel(
    for section: AuthorSeriesSection, hasMore: Bool
  ) -> String {
    [cardHeading(for: section), itemCountText(for: section, hasMore: hasMore)]
      .compactMap { $0 }
      .joined(separator: ", ")
  }

  /// The section whose row the `Books` header is drawn above, or `nil` for no header at all.
  ///
  /// The header separates loose books from the series that precede them. An author with nothing but
  /// loose books has nothing to separate them from, so the whole page would sit under a header
  /// naming what every screen here already is.
  static func standaloneHeaderSectionID(
    for sections: [AuthorSeriesSection], target: AuthorSeriesModel.Target
  ) -> String? {
    guard target.isSeriesDestination == false else { return nil }
    guard let index = sections.firstIndex(where: { isStandalone($0.kind) }), index > 0 else {
      return nil
    }
    return sections[index].id
  }

  private static func isStandalone(_ kind: AuthorSeriesSection.Kind) -> Bool {
    switch kind {
    case .standaloneBook, .standaloneEditions, .standalone: true
    case .series: false
    }
  }

  static func emptyMessage(for target: AuthorSeriesModel.Target) -> String {
    switch target {
    case .author, .authorName: "This author has no items in your library."
    case .series, .seriesName: "This series has no items in your library."
    case .narrator: "This narrator has no audiobooks in your library."
    }
  }

  static let filteredEmptyTitle = "No Matches"

  /// Fallback for explicitly filtered models; normal entity navigation opens an unfiltered shelf.
  static func filteredEmptyMessage(for target: AuthorSeriesModel.Target) -> String {
    let subject =
      switch target {
      case .author, .authorName: "this author"
      case .series, .seriesName: "this series"
      case .narrator: "this narrator"
      }
    return "Nothing from \(subject) matches your current filter. "
      + "Go back and clear it to see everything again."
  }
}
