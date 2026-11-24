import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Podcast episode card row")
@MainActor
struct PodcastEpisodeCardRowTests {
  @Test("metadata joins date and duration with a middle dot")
  func metadataTextJoinsDateAndDuration() {
    let row = makeRow()

    #expect(row.metadataText == "12 July 2026 · 42 minutes")
  }

  @Test("visible text follows the row's reading order")
  func visibleTextFollowsReadingOrder() {
    let row = makeRow()

    #expect(
      row.visibleText == [
        "Decoder Ring", "The Mystery of the Missing Hit", "12 July 2026", "42 minutes",
      ])
  }

  @Test("accent color falls back to brand ink without a wash")
  func accentColorFallsBackWithoutWash() {
    #expect(makeRow(wash: nil).accentColor == WhirrColorToken.brandInk.color)
  }

  @Test("accent color falls back to brand ink for a neutral wash")
  func accentColorFallsBackForNeutralWash() {
    #expect(makeRow(wash: .neutral).accentColor == WhirrColorToken.brandInk.color)
  }

  @Test("accent color uses the wash accent when one exists")
  func accentColorUsesWashAccent() {
    let wash = CoverWash.from(hue: 0.4, saturation: 0.8, brightness: 0.6)

    #expect(wash.accentColor != nil)
    #expect(makeRow(wash: wash).usesWashAccent)
    #expect(makeRow(wash: .neutral).usesWashAccent == false)
    #expect(makeRow(wash: nil).usesWashAccent == false)
  }

  @Test("the title reserves a fixed two-line budget so every card is one height")
  func titleReservesATwoLineBudget() {
    #expect(PodcastEpisodeCardRow<Color>.titleLineLimit == 2)
    #expect(makeRow().reservesTitleSpace)
  }

  @Test("the cover centres against the copy column through the shared card metric")
  func coverCentresAgainstCopyColumn() {
    #expect(PodcastEpisodeCardRow<Color>.coverAlignment == .center)
    #expect(
      PodcastEpisodeCardRow<Color>.coverAlignment
        == ArtworkLedRowMetrics.artworkAlignment)
  }

  @Test("the row never paints its own card fill")
  func theRowNeverPaintsItsOwnCardFill() {
    // Card chrome belongs to the call site (`editorialCardSurface` outside a List,
    // `podcastEpisodeCardListRow` inside one): only it knows whether a swipe container will mask
    // the fill. The wash still reaches this row to decide the accent.
    let wash = CoverWash.from(hue: 0.4, saturation: 0.8, brightness: 0.6)

    #expect(PodcastEpisodeCardRow<Color>.paintsCardBackground == false)
    #expect(makeRow(wash: wash).usesWashAccent)
  }

  @Test("the row owns the card's inner padding, unlike its fill")
  func theRowOwnsTheCardsInnerPadding() {
    // The fill has to come from outside; the padding must not. Padding applied by the card
    // modifier sits outside every control declared here, so the card's outer ring stops selecting
    // the episode. `podcastEpisodeCardListRow` therefore passes none.
    #expect(PodcastEpisodeCardRow<Color>.cardContentPadding == WhirrSpacing.small)
  }

  @Test("play button label reflects the playback state")
  func playButtonAccessibilityLabelReflectsPlaybackState() {
    #expect(makeRow(isPlaying: false).playButtonAccessibilityLabel == "Play")
    #expect(makeRow(isPlaying: true).playButtonAccessibilityLabel == "Pause")
  }

  // MARK: - Selecting

  @Test("selecting hands the row's own tap and play control to the enclosing list")
  func selectingSurrendersTheRowsControls() {
    // A multiselect list draws its own selection control and owns the tap. Leaving this row's
    // select button and play button in place would nest two competing targets inside one cell.
    #expect(makeRow().ownsRowSelection)
    #expect(makeRow().showsPlayControl)
    #expect(makeRow(isSelecting: true).ownsRowSelection == false)
    #expect(makeRow(isSelecting: true).showsPlayControl == false)
  }

  @Test("selecting changes no copy, so no row reflows on entering edit mode")
  func selectingLeavesEveryVisibleStringInPlace() {
    // The eyebrow, title, date and duration stay where they were. Only the controls go.
    #expect(makeRow(isSelecting: true).visibleText == makeRow().visibleText)
    #expect(makeRow(isSelecting: true).metadataText == makeRow().metadataText)
    #expect(makeRow(isSelecting: true).accessibilityLabel == makeRow().accessibilityLabel)
  }

  @Test("selecting keeps the card's metrics, so the rhythm survives the transition")
  func selectingKeepsTheCardsMetrics() {
    #expect(makeRow(isSelecting: true).reservesTitleSpace)
    #expect(makeRow(isSelecting: true).coverSize == makeRow().coverSize)
  }

  @Test("the wash accent still dresses the eyebrow while selecting")
  func selectingKeepsTheWashAccent() {
    let wash = CoverWash.from(hue: 0.4, saturation: 0.8, brightness: 0.6)

    #expect(makeRow(wash: wash, isSelecting: true).usesWashAccent)
  }

  // MARK: - Listening and download state

  @Test("progress words replace the duration rather than joining it")
  func progressWordsReplaceTheDuration() {
    let row = makeRow(progressText: "19 min left")

    #expect(row.timeText == "19 min left")
    #expect(row.metadataText == "12 July 2026 · 19 min left")
    #expect(
      row.visibleText == [
        "Decoder Ring", "The Mystery of the Missing Hit", "12 July 2026", "19 min left",
      ])
  }

  @Test("a row under a day heading drops its date and keeps one time fact")
  func undatedRowKeepsOneTimeFact() {
    #expect(makeRow(dateText: nil).metadataText == "42 minutes")
    #expect(makeRow(dateText: nil, progressText: "19 min left").metadataText == "19 min left")
    #expect(
      makeRow(dateText: nil).visibleText
        == ["Decoder Ring", "The Mystery of the Missing Hit", "42 minutes"])
  }

  @Test("the show line and the time line are each held to one line")
  func showAndTimeLinesAreSingleLine() {
    #expect(PodcastEpisodeCardRow<Color>.showTitleLineLimit == 1)
    #expect(PodcastEpisodeCardRow<Color>.metadataLineLimit == 1)
  }

  @Test("no listening or download state leaves the row exactly as before")
  func defaultsLeaveTheRowUnchanged() {
    let row = makeRow()

    #expect(row.metadataText == "12 July 2026 · 42 minutes")
    #expect(row.visibleProgressFraction == nil)
    #expect(row.showsDownloadedMark == false)
    #expect(row.spokenLabel == row.accessibilityLabel)
  }

  @Test("the cover bar draws only part way through, like the show row")
  func coverBarDrawsOnlyPartWay() {
    #expect(makeRow(progressFraction: 0.4).visibleProgressFraction == 0.4)
    #expect(makeRow(progressFraction: 0).visibleProgressFraction == nil)
    #expect(makeRow(progressFraction: 1).visibleProgressFraction == nil)
    #expect(makeRow(progressFraction: 1.7).visibleProgressFraction == nil)
    #expect(makeRow(progressFraction: .nan).visibleProgressFraction == nil)
  }

  @Test("a downloaded episode shows the mark and says so, not by colour alone")
  func downloadedEpisodeShowsAndSpeaksTheMark() {
    let row = makeRow(downloadedLabel: "Downloaded")

    #expect(row.showsDownloadedMark)
    #expect(
      row.spokenLabel
        == "The Mystery of the Missing Hit, Decoder Ring, 12 July 2026, 42 minutes, Downloaded")
  }

  @Test("a downloaded episode being checked for ads swaps the mark and says so")
  func checkingForAdsSwapsTheMark() {
    let row = makeRow(downloadedLabel: "Downloaded", isCheckingForAds: true)

    #expect(row.showsCheckingForAds)
    #expect(
      row.spokenLabel
        == "The Mystery of the Missing Hit, Decoder Ring, 12 July 2026, 42 minutes, Downloaded, checking for ads"
    )
  }

  @Test("an episode not on the phone shows no ad check")
  func checkingForAdsNeedsTheFile() {
    let row = makeRow(isCheckingForAds: true)

    #expect(row.showsCheckingForAds == false)
    #expect(row.spokenLabel == row.accessibilityLabel)
  }

  @Test("an empty downloaded label draws no mark")
  func emptyDownloadedLabelDrawsNoMark() {
    #expect(makeRow(downloadedLabel: "").showsDownloadedMark == false)
  }

  @Test("selecting keeps listening and download state in place")
  func selectingKeepsListeningAndDownloadState() {
    let idle = makeRow(progressText: "23 min played", progressFraction: 0.4, downloadedLabel: "Downloaded")
    let selecting = makeRow(
      isSelecting: true, progressText: "23 min played", progressFraction: 0.4,
      downloadedLabel: "Downloaded")

    #expect(selecting.metadataText == idle.metadataText)
    #expect(selecting.visibleProgressFraction == idle.visibleProgressFraction)
    #expect(selecting.spokenLabel == idle.spokenLabel)
  }

  private func makeRow(
    title: String = "The Mystery of the Missing Hit",
    showTitle: String = "Decoder Ring",
    dateText: String? = "12 July 2026",
    wash: CoverWash? = nil,
    isPlaying: Bool = false,
    isSelecting: Bool = false,
    progressText: String? = nil,
    progressFraction: Double? = nil,
    downloadedLabel: String? = nil,
    isCheckingForAds: Bool = false
  ) -> PodcastEpisodeCardRow<Color> {
    PodcastEpisodeCardRow(
      title: title,
      showTitle: showTitle,
      dateText: dateText,
      durationText: "42 minutes",
      accessibilityLabel:
        "The Mystery of the Missing Hit, Decoder Ring, 12 July 2026, 42 minutes",
      coverSize: 72,
      wash: wash,
      isPlaying: isPlaying,
      isSelecting: isSelecting,
      progressText: progressText,
      progressFraction: progressFraction,
      downloadedLabel: downloadedLabel,
      isCheckingForAds: isCheckingForAds,
      cover: { Color.clear },
      onSelect: {},
      onPlay: {}
    )
  }
}
