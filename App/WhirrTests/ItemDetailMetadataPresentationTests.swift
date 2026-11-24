import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import Testing

@testable import Whirr

struct ItemDetailMetadataPresentationTests {
  @Test("local series needs no loading placeholder")
  func localSeriesNeedsNoLoadingPlaceholder() {
    let item = summary(series: "The Expanse", fetchedAt: Date())
    let layout = ItemDetailMetadataLayout(item: item)

    #expect(
      ItemDetailMetadataPresentation.seriesRow(item: item, layout: layout)
        == ItemDetailMetadataRow(text: "The Expanse", reservesLayout: true))
  }

  @Test("podcasts reserve no book metadata rows")
  func podcastReservesNoBookMetadataRows() {
    let item = summary(category: .podcast)
    let layout = ItemDetailMetadataLayout(item: item)

    #expect(layout.reservesSeriesRow == false)
    #expect(layout.reservesNarratorRow == false)
  }

  @Test("an audiobook reserves its narrator row until expanded metadata resolves")
  func audiobookReservesNarratorUntilResolution() {
    let awaitingItem = summary()
    let layout = ItemDetailMetadataLayout(item: awaitingItem)

    #expect(layout.reservesNarratorRow)
    #expect(
      ItemDetailMetadataPresentation.narratorRow(item: awaitingItem, layout: layout)
        == ItemDetailMetadataRow(text: nil, reservesLayout: true))

    let resolvedItem = summary(narrator: "Jeff Hays", fetchedAt: Date())
    #expect(
      ItemDetailMetadataPresentation.narratorRow(item: resolvedItem, layout: layout)
        == ItemDetailMetadataRow(text: "Jeff Hays", reservesLayout: true))
  }

  @Test("a resolved audiobook without a narrator collapses the reserved row")
  func absentResolvedNarratorCollapsesReservedRow() {
    let layout = ItemDetailMetadataLayout(item: summary())
    let resolvedItem = summary(fetchedAt: Date())

    #expect(
      ItemDetailMetadataPresentation.narratorRow(item: resolvedItem, layout: layout)
        == ItemDetailMetadataRow(text: nil, reservesLayout: false))
  }

  @Test("ebooks never reserve audiobook narrator space")
  func ebookNeverReservesNarrator() {
    #expect(ItemDetailMetadataLayout(item: summary(category: .ebook)).reservesNarratorRow == false)
  }

  /// An ebook has no reader, but it is in a series as often as its audio edition is. On an
  /// undownloaded book the series is most of what the page has to say.
  @Test("an ebook keeps its series breadcrumb")
  func ebookKeepsItsSeriesBreadcrumb() {
    let item = summary(category: .ebook, series: "Six of Crows #2", fetchedAt: Date())
    let layout = ItemDetailMetadataLayout(item: item)

    #expect(layout.reservesSeriesRow)
    #expect(
      ItemDetailMetadataPresentation.seriesRow(item: item, layout: layout)
        == ItemDetailMetadataRow(text: "Six of Crows #2", reservesLayout: true))
  }

  @Test("an item without a series reserves no series row")
  func itemWithoutSeriesReservesNoSeriesRow() {
    #expect(ItemDetailMetadataLayout(item: summary()).reservesSeriesRow == false)
  }

  // MARK: - Credit admission

  @Test("an ebook with only an author has no series breadcrumb")
  func ebookWithAuthorOnlyHasNoSeriesBreadcrumb() {
    let item = summary(category: .ebook, fetchedAt: Date())
    let layout = ItemDetailMetadataLayout(item: item)

    #expect(
      ItemDetailMetadataPresentation.seriesRow(item: item, layout: layout)
        == ItemDetailMetadataRow(text: nil, reservesLayout: false))
  }

  @Test("an audiobook with only an author has no series breadcrumb")
  func audiobookWithAuthorOnlyHasNoSeriesBreadcrumb() {
    let item = summary(fetchedAt: Date())
    let layout = ItemDetailMetadataLayout(item: item)

    #expect(layout.reservesSeriesRow == false)
  }

  @Test("an ebook with an author and series admits the series breadcrumb")
  func ebookWithAuthorAndSeriesAdmitsSeriesBreadcrumb() {
    let item = summary(category: .ebook, series: "The Expanse #2", fetchedAt: Date())
    let layout = ItemDetailMetadataLayout(item: item)

    #expect(layout.reservesSeriesRow)
  }

  @Test("an audiobook with an author and narrator keeps series admission independent")
  func audiobookAuthorAndNarratorKeepSeriesAdmissionIndependent() {
    let item = summary(narrator: "Michelle Obama", fetchedAt: Date())

    #expect(ItemDetailMetadataLayout(item: item).reservesSeriesRow == false)
  }

  @Test("a full audiobook credit block admits its series breadcrumb")
  func fullAudiobookCreditBlockAdmitsSeriesBreadcrumb() {
    let item = summary(
      series: "The Expanse #2", narrator: "Jefferson Mays", fetchedAt: Date())

    #expect(ItemDetailMetadataLayout(item: item).reservesSeriesRow)
  }

  @Test("series admission is stable while narrator metadata arrives")
  func seriesAdmissionIsStableWhileNarratorMetadataArrives() {
    let awaiting = ItemDetailMetadataLayout(item: summary(series: "The Expanse #2"))
    let resolved = ItemDetailMetadataLayout(
      item: summary(series: "The Expanse #2", narrator: "Jefferson Mays", fetchedAt: Date()))

    #expect(awaiting.reservesSeriesRow)
    #expect(resolved.reservesSeriesRow)
  }

  @Test("a standalone audiobook has no series breadcrumb at either fetch stage")
  func standaloneAudiobookHasNoSeriesBreadcrumbAtEitherFetchStage() {
    let awaiting = ItemDetailMetadataLayout(item: summary())
    let resolved = ItemDetailMetadataLayout(
      item: summary(narrator: "Jefferson Mays", fetchedAt: Date()))

    #expect(awaiting.reservesSeriesRow == false)
    #expect(resolved.reservesSeriesRow == false)
  }

  @Test("an ebook keeps its series breadcrumb at either fetch stage")
  func ebookKeepsSeriesBreadcrumbAtEitherFetchStage() {
    let awaiting = ItemDetailMetadataLayout(item: summary(category: .ebook, series: "Expanse #2"))
    let resolved = ItemDetailMetadataLayout(
      item: summary(category: .ebook, series: "Expanse #2", fetchedAt: Date()))

    #expect(awaiting.reservesSeriesRow)
    #expect(resolved.reservesSeriesRow)
  }

  @Test("an item without credits has no series breadcrumb")
  func uncreditedItemHasNoSeriesBreadcrumb() {
    let item = summary(category: .ebook, author: nil, fetchedAt: Date())

    #expect(ItemDetailMetadataLayout(item: item).reservesSeriesRow == false)
  }

  @Test("a punctuation-only author has no link")
  func punctuationOnlyAuthorHasNoLink() {
    #expect(ItemMetadataLinkPresentation.personLinks(" , ", role: .narrator).isEmpty)
  }

  @Test("a narrator never changes the series breadcrumb reservation")
  func narratorDoesNotChangeSeriesReservation() {
    let withoutNarrator = ItemDetailMetadataLayout(
      item: summary(series: "The Expanse #2", fetchedAt: Date()))
    let withNarrator = ItemDetailMetadataLayout(
      item: summary(series: "The Expanse #2", narrator: "Jefferson Mays", fetchedAt: Date()))

    #expect(withoutNarrator.reservesSeriesRow)
    #expect(withNarrator.reservesSeriesRow)
  }

  // MARK: - Title measure

  /// Both hero shapes set the title at the full content measure, so the cap is the stated budget.
  @Test("a title keeps the two-line budget")
  func titleKeepsTheTwoLineBudget() {
    #expect(
      ItemDetailHeroTextPresentation.titleLineLimit(isAccessibilitySize: false)
        == ItemDetailHeroTextPresentation.fullMeasureLineLimit)
  }

  /// A cap that clips is worse than a tall hero. At accessibility sizes the title runs past any
  /// cap as a matter of course, so there is none.
  @Test("an accessibility size caps neither the title nor a credit name")
  func accessibilitySizeCapsNeitherTitleNorName() {
    #expect(
      ItemDetailHeroTextPresentation.titleLineLimit(isAccessibilitySize: true) == nil)
    #expect(ItemDetailHeroTextPresentation.creditNameLineLimit(isAccessibilitySize: true) == nil)
  }

  /// The flow layout wraps between names and never within one, so a name wider than its row is
  /// clipped unless it may take a second line.
  @Test("a credit name may wrap once rather than clip")
  func creditNameMayWrapOnceRatherThanClip() {
    #expect(ItemDetailHeroTextPresentation.creditNameLineLimit(isAccessibilitySize: false) == 2)
  }

  /// The promoted frame is only safe at this size because high-fidelity widths quantise up: the
  /// hero asks for 272pt and gets the next 256px multiple above it. If either the request tier or
  /// the quantisation step moves, the promoted artwork starts upscaling, a regression nobody sees
  /// until a cover looks soft on one device.
  @Test(
    "the promoted artwork stays inside the pixels the hero actually fetches",
    arguments: [2.0, 3.0])
  func promotedArtworkStaysInsideTheFetchedPixels(displayScale: Double) {
    let fetched = ArtworkVariant.highFidelity(
      displaySize: Double(ItemDetailView.coverDisplaySize), displayScale: displayScale
    ).pixelWidth

    #expect(Double(ItemDetailHeroView.promotedCoverSize) * displayScale <= Double(fetched))
  }

  @Test("the audited regular widths preserve metadata admission beside the promoted cover")
  func auditedRegularWidthsPreserveMetadataAdmission() {
    let item = summary(
      series: "The Expanse #2", narrator: "Jefferson Mays", fetchedAt: Date())
    let layout = ItemDetailMetadataLayout(item: item)

    for width in [CGFloat(802), CGFloat(898)] {
      let detailLayout = ItemDetailLayoutPresentation.resolve(
        horizontalSizeClass: .regular,
        isAccessibilitySize: false,
        availableWidth: width)

      #expect(detailLayout.hero == .promotedStack)
      #expect(detailLayout.readableWidth == AdaptiveLayoutPresentation.readingMeasure)
      #expect(ItemDetailMetadataPresentation.seriesRow(item: item, layout: layout).reservesLayout)
      #expect(ItemDetailMetadataPresentation.narratorRow(item: item, layout: layout).reservesLayout)
    }
  }

  private func summary(
    category: ItemMediaCategory = .audiobook,
    author: String? = "Author",
    series: String? = nil,
    narrator: String? = nil,
    fetchedAt: Date? = nil
  ) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: "item", mediaKind: category == .podcast ? "podcast" : "book",
      title: "Title", author: author, durationSeconds: 1, category: category,
      seriesName: series, narratorName: narrator, expandedMetadataFetchedAt: fetchedAt)
  }
}
