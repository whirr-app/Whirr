import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Media item summary row")
@MainActor
struct MediaItemSummaryRowTests {
  @Test("default row has no editorial card, wash accent, or eyebrow")
  func defaultRowHasNoEditorialTreatment() {
    let row = makeRow()

    #expect(row.isCard == false)
    #expect(row.usesWashAccent == false)
    #expect(row.showsEyebrow == false)
    #expect(row.visibleText == ["Project Hail Mary", "Andy Weir", "Audiobook"])
  }

  @Test("a wash turns the row into an editorial card")
  func washTurnsRowIntoEditorialCard() {
    let wash = CoverWash.from(hue: 0.4, saturation: 0.8, brightness: 0.6)

    let row = makeRow(wash: wash)

    #expect(row.isCard)
    #expect(row.usesWashAccent)
  }

  @Test("eyebrow is shown only when a wash and non-empty text are supplied")
  func eyebrowRequiresWashAndNonEmptyText() {
    #expect(makeRow(eyebrow: "Audiobook").showsEyebrow == false)
    #expect(makeRow(wash: .neutral, eyebrow: nil).showsEyebrow == false)
    #expect(makeRow(wash: .neutral, eyebrow: "").showsEyebrow == false)
    #expect(makeRow(wash: .neutral, eyebrow: "Audiobook").showsEyebrow)
  }

  @Test("visible text puts a shown eyebrow before the title")
  func visibleTextIncludesEyebrowInReadingOrder() {
    let row = makeRow(wash: .neutral, eyebrow: "Audiobook")

    #expect(row.visibleText == ["Audiobook", "Project Hail Mary", "Andy Weir", "Audiobook"])
  }

  @Test("the cover centres against the copy column instead of pinning to its first line")
  func coverCentresAgainstCopyColumn() {
    // A title that wraps makes the copy column taller than the fixed-size cover. Top alignment
    // then strands the artwork opposite the first line, which reads as the art "sitting high".
    #expect(MediaItemSummaryRow<Never, Never, Never>.coverAlignment == .center)
    #expect(
      MediaItemSummaryRow<Never, Never, Never>.coverAlignment
        == ArtworkLedRowMetrics.artworkAlignment)
  }

  @Test("a long title wraps to a second line rather than truncating")
  func titleWrapsRatherThanTruncating() {
    // Deliberate: the tail of a long show title is usually what distinguishes it from its
    // siblings, so this row spends a second line rather than eliding it.
    #expect(MediaItemSummaryRow<Never, Never, Never>.titleLineLimit == 2)
  }

  @Test("standard sizes reserve the full title height so one-line titles do not shorten the card")
  func standardSizesReserveTitleHeight() {
    // Cards in one list must share a height: a one-line title is centred in the space a
    // two-line title would take, rather than making its card shorter than its neighbours.
    typealias Row = MediaItemSummaryRow<Never, Never, Never>
    #expect(Row.reservedTitleLines(isAccessibilitySize: false) == Row.titleLineLimit)
    #expect(Row.reservedTitleLines(isAccessibilitySize: true) == nil)
  }

  @Test("accent color falls back to brand ink without a wash or for a neutral wash")
  func accentColorFallsBackWithoutAccent() {
    #expect(makeRow().usesWashAccent == false)
    #expect(makeRow(wash: .neutral).usesWashAccent == false)
  }

  private func makeRow(
    wash: CoverWash? = nil,
    eyebrow: String? = nil
  ) -> MediaItemSummaryRow<Color, EmptyView, EmptyView> {
    MediaItemSummaryRow(
      title: "Project Hail Mary",
      subtitle: "Andy Weir",
      metadata: "Audiobook",
      accessibilityLabel: "Project Hail Mary, Andy Weir, Audiobook",
      coverSize: 56,
      wash: wash,
      eyebrow: eyebrow,
      cover: { Color.clear },
      inlineContent: { EmptyView() },
      trailingContent: { EmptyView() }
    )
  }
}
