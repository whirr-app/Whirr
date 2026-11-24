import AppModel
import DesignSystem
import Foundation
import Persistence
import Testing

@testable import Whirr

/// The source-level rules for these cards live in `Scripts/source-rules/chrome.toml`; what stays
/// here is metrics and behaviour, plus the two scans that need the order of a declaration's members.
@Suite("Author series editorial cards")
struct AuthorSeriesEditorialCardTests {
  /// A card claims its contents belong together. An invented "Standalone" collection made that
  /// claim about unrelated books and dressed them all in one book's extracted colour. A full-width
  /// row per book spent its width on metadata many books lack (an ebook has no duration or
  /// narrator). Books share the two columns a series card uses instead, each with its own card and
  /// colour.
  @Test("loose books share the two-column grid and each still owns its wash")
  func looseBooksShareTheGridAndOwnTheirWash() {
    // A column must hold the card's padding as well as the tile, or the tile draws narrower than
    // the minimum that chose the column count.
    #expect(
      AuthorSeriesGridMetrics.columnMinimumWidth(
        forTileMinimumWidth: AuthorSeriesGridMetrics.coverTileMinimumWidth)
        == AuthorSeriesGridMetrics.coverTileMinimumWidth
        + 2 * EditorialCardSurfaceModifier.contentPadding)
    #expect(
      AuthorSeriesGridMetrics.tileWidth(insideColumnWidth: 179)
        == 179 - 2 * EditorialCardSurfaceModifier.contentPadding)
    #expect(
      AuthorSeriesGridMetrics.columnCount(
        forContentWidth: 370,
        minimumTileWidth: AuthorSeriesGridMetrics.columnMinimumWidth(
          forTileMinimumWidth: AuthorSeriesGridMetrics.coverTileMinimumWidth)) == 2,
      "a phone's content width must still resolve two self-carded columns")

    // One section per book, so the wash store (keyed by section) only sees that book's cover.
    let sections = AuthorSeriesSection.sections(from: [
      SearchResultRow(kind: .book, entityID: "one", title: "Alpha", libraryID: "library"),
      SearchResultRow(kind: .book, entityID: "two", title: "Beta", libraryID: "library"),
    ])
    #expect(sections.count == 2)
    #expect(sections.map(\.candidateWashSourceItemID) == ["one", "two"])
  }

  /// The media badge and playback mark are drawn on the artwork, as on every other screen. The
  /// tile-side bans are source rules; the order inside `CoverImageView` needs a read here.
  @Test("the media and playback marks sit on the cover, not on a line of their own")
  func coverCarriesTheMarks() throws {
    // The cover must place the marks inside the fitted artwork's bounds, so they sit before the
    // frame that positions that artwork.
    let coverSource = try String(
      contentsOf: Self.repositoryRoot().appending(path: "App/Whirr/Views/Artwork/CoverImageView.swift"),
      encoding: .utf8)
    let fitBranch = try #require(
      coverSource.components(separatedBy: "case .fitTransparent:").last)
    let overlayIndex = try #require(
      fitBranch.range(of: "CoverArtworkMarksOverlay(marks: marks)")?.lowerBound)
    let frameIndex = try #require(fitBranch.range(of: ".frame(maxWidth: .infinity")?.lowerBound)
    #expect(
      overlayIndex < frameIndex,
      "the marks must be overlaid on the fitted artwork, not on the frame that positions it")
  }

  @Test("grid metrics preserve portrait cards and accessible columns")
  func gridMetricsPreserveCardShape() {
    // Compared within a tolerance: the stored `CGFloat` and a freshly written `2.0 / 3.0` differ
    // bit-for-bit, and the contract is the portrait shape, not a particular rounding.
    #expect(
      abs(AuthorSeriesCoverShape.portrait.aspectRatio - 2.0 / 3.0) < 0.0001,
      "a grid that has to hold an ebook cover must keep its two-to-three box")
    #expect(
      AuthorSeriesCoverShape.square.aspectRatio == 1,
      "a grid holding only audiobooks must draw a square box")
    #expect(
      AuthorSeriesGridMetrics.coverDisplaySize == 140,
      "cover requests must use the 140-point home-card rung")
    #expect(
      AuthorSeriesGridMetrics.coverTileMinimumWidth == 140,
      "the regular grid must keep its 140-point minimum cover tile width")
    // 200, not 180, keeps one readable column on an accessibility Dynamic Type phone. A 430-point
    // phone has about 366 points of card width. Two 180-point columns plus a gap need 368, so 180
    // would tip it into an unreadable two-column layout by two points.
    #expect(
      AuthorSeriesGridMetrics.accessibilityCoverTileMinimumWidth == 200,
      "accessibility cover tiles must stay one-column readable on a phone")
    #expect(
      AuthorSeriesGridMetrics.columnCount(
        forContentWidth: 898,
        minimumTileWidth: AuthorSeriesGridMetrics.coverTileMinimumWidth)
        == AdaptiveListLayout.columnCount(
          forContentWidth: 898,
          minimumTileWidth: AuthorSeriesGridMetrics.coverTileMinimumWidth,
          spacing: AuthorSeriesGridMetrics.gridSpacing))
    #expect(
      AuthorSeriesGridMetrics.tileWidth(forContentWidth: 898, columns: 5)
        == AdaptiveListLayout.tileWidth(
          forContentWidth: 898,
          columns: 5,
          spacing: AuthorSeriesGridMetrics.gridSpacing))
  }

  /// Every phone stays at two columns. Three columns of about 107 points wrap a sequence one
  /// character per line beside its badges, so the minimum must clear the three-column threshold at
  /// both ends of the phone range.
  @Test("phone card widths resolve to two readable columns")
  func gridResolvesTwoColumnsOnEveryPhone() {
    // Screen width less the list inset (16 per side) and the card padding (12 per side). Examples:
    // a 402-point iPhone 17 and a 440-point Pro Max.
    for contentWidth in [346.0 as CGFloat, 384.0] {
      let columns = AuthorSeriesGridMetrics.columnCount(
        forContentWidth: contentWidth,
        minimumTileWidth: AuthorSeriesGridMetrics.coverTileMinimumWidth)
      #expect(columns == 2, "a \(contentWidth)-point card must lay out two columns")

      let tileWidth = AuthorSeriesGridMetrics.tileWidth(
        forContentWidth: contentWidth, columns: columns)
      let occupied =
        tileWidth * CGFloat(columns)
        + AuthorSeriesGridMetrics.gridSpacing * CGFloat(columns - 1)
      #expect(occupied <= contentWidth, "columns and gaps must fit inside the card")
      #expect(
        tileWidth >= AuthorSeriesGridMetrics.coverTileMinimumWidth,
        "a resolved tile must never be narrower than the cover minimum that chose its column count")
    }

    #expect(
      AuthorSeriesGridMetrics.columnCount(
        forContentWidth: 346,
        minimumTileWidth: AuthorSeriesGridMetrics.accessibilityCoverTileMinimumWidth)
        == 1,
      "an accessibility size must collapse a phone card to one column")
    #expect(
      AuthorSeriesGridMetrics.columnCount(forContentWidth: 0, minimumTileWidth: 140) == 1,
      "an unmeasured card must still resolve a column rather than none")
  }

  /// `CoverImageView` declares no size, so an `.aspectRatio` frame with no resolved height falls
  /// back to the decoded image's dimensions. A portrait cover then draws at full tile width, and a
  /// square one at a fraction of it, in the same row.
  @Test("tile artwork is framed by the tile, not by the decoded image")
  func tileArtworkIgnoresDecodedImageSize() {
    #expect(
      AuthorSeriesGridMetrics.coverHeight(forTileWidth: 168, shape: .portrait) == 252,
      "a 168-point tile must draw a 252-point portrait cover")
    #expect(
      AuthorSeriesGridMetrics.coverHeight(forTileWidth: 168, shape: .square) == 168,
      "a 168-point tile must draw a 168-point square cover")
  }

  @Test("the Library author card keeps the media kinds on the count's line")
  func libraryAuthorCardKeepsKindsOnTheCountLine() throws {
    let source = try String(
      contentsOf: Self.repositoryRoot().appending(
        path: "App/Whirr/Views/Library/LibraryBrowseEntitiesView.swift"),
      encoding: .utf8)
    let afterMarker = try #require(
      source.components(separatedBy: "private struct LibraryAuthorCardLabel").last,
      "the author card label must still be its own type")
    let cardLabel = afterMarker.components(separatedBy: "\nprivate ").first ?? afterMarker
    let sharedLine = try #require(
      cardLabel.range(of: "HStack(alignment: .center, spacing: WhirrSpacing.xSmall) {"),
      "the count and the kinds must share one metadata line")
    let subtitle = try #require(
      cardLabel.range(of: "Text(subtitle)"), "the card must still draw its count")
    let badge = try #require(
      cardLabel.range(of: "MediaKindBadgeView("), "the card must still badge its media kinds")

    #expect(
      subtitle.lowerBound > sharedLine.upperBound,
      "the count must sit inside the shared line rather than above it")
    #expect(
      badge.lowerBound > subtitle.upperBound,
      "the kinds must follow the count on that line rather than take a line of their own")
  }

  /// The kinds sit in a fixed column, not right after the count. Placed after the count, their
  /// column would move with the count's length, and a scan down the list would zigzag.
  @Test("the Library author card pins the media kinds to the card's trailing edge")
  func libraryAuthorCardTrailsTheMediaKinds() throws {
    let source = try String(
      contentsOf: Self.repositoryRoot().appending(
        path: "App/Whirr/Views/Library/LibraryBrowseEntitiesView.swift"),
      encoding: .utf8)
    let afterMarker = try #require(
      source.components(separatedBy: "private struct LibraryAuthorCardLabel").last,
      "the author card label must still be its own type")
    let cardLabel = afterMarker.components(separatedBy: "\nprivate ").first ?? afterMarker
    let subtitle = try #require(
      cardLabel.range(of: "Text(subtitle)"), "the card must still draw its count")
    let spacer = try #require(
      cardLabel.range(of: "Spacer(minLength: 0)"),
      "the metadata line must push its kinds away from its count")
    let badge = try #require(
      cardLabel.range(of: "MediaKindBadgeView("), "the card must still badge its media kinds")

    #expect(
      spacer.lowerBound > subtitle.upperBound && badge.lowerBound > spacer.upperBound,
      "the spacer must sit between the count and the kinds, so the kinds trail the card")
  }

  private static func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // App/WhirrTests
      .deletingLastPathComponent()  // App
      .deletingLastPathComponent()  // the repository root
  }
}
