import AppModel
import DesignSystem
import Testing

@testable import Whirr

@Suite("Player time formatting")
struct PlayerTimeFormattingTests {
  @Test("clock arithmetic decomposes seconds without a formatter")
  func clockArithmetic() {
    #expect(PlayerTimeFormatting.clockParts(0) == .init(hours: 0, minutes: 0, seconds: 0))
    #expect(PlayerTimeFormatting.clockParts(59.9) == .init(hours: 0, minutes: 0, seconds: 59))
    #expect(PlayerTimeFormatting.clockParts(60) == .init(hours: 0, minutes: 1, seconds: 0))
    #expect(PlayerTimeFormatting.clockParts(3_665) == .init(hours: 1, minutes: 1, seconds: 5))
    #expect(PlayerTimeFormatting.clockParts(-1) == .init(hours: 0, minutes: 0, seconds: 0))
  }

  @Test("remaining time is displayed as a negative platform clock value")
  func remainingClock() {
    #expect(PlayerTimeFormatting.remainingClock(currentTime: 65, duration: 3_665) == "−1:00:00")
  }

  @Test("unknown duration has a stable remaining-time fallback")
  func unknownRemainingClock() {
    #expect(PlayerTimeFormatting.remainingClock(currentTime: 65, duration: nil) == "−−:−−")
  }

  // MARK: - Scrub preview projection

  @Test("with no scrub in flight the readout follows the live playhead")
  func displayedTimeFollowsPlayheadWhenNotScrubbing() {
    #expect(
      PlayerTimeFormatting.displayedTime(scrubFraction: nil, currentTime: 65, duration: 36_960) == 65)
  }

  @Test("an in-flight scrub projects its fraction onto the duration")
  func displayedTimeFollowsScrubFraction() {
    #expect(
      PlayerTimeFormatting.displayedTime(scrubFraction: 0.5, currentTime: 65, duration: 36_960) == 18_480)
  }

  @Test("a scrub fraction is clamped, and an unusable duration falls back to the playhead")
  func displayedTimeGuardsAgainstBadInput() {
    #expect(
      PlayerTimeFormatting.displayedTime(scrubFraction: 1.4, currentTime: 65, duration: 36_960) == 36_960)
    #expect(PlayerTimeFormatting.displayedTime(scrubFraction: -1, currentTime: 65, duration: 36_960) == 0)
    #expect(PlayerTimeFormatting.displayedTime(scrubFraction: 0.5, currentTime: 65, duration: nil) == 65)
    #expect(PlayerTimeFormatting.displayedTime(scrubFraction: 0.5, currentTime: 65, duration: 0) == 65)
    #expect(PlayerTimeFormatting.displayedTime(scrubFraction: .nan, currentTime: 65, duration: 36_960) == 65)
  }

  // MARK: - Chapter scoping

  // A concrete window used across the cases below: a 10:16:00 book (36 960s) whose current
  // chapter runs from 20:00 to 1:16:00 (a 56:00 span), with the playhead at 40:00.
  private static let bookDuration: Double = 36_960
  private static let chapterStart: Double = 1_200
  private static let chapterEnd: Double = 4_560

  @Test("progress is measured through the current chapter, not the whole book")
  func scopedFractionMeasuresThroughTheChapter() {
    // 40:00 is 20:00 into a 56:00 chapter, a third of the way, where the same playhead is only
    // ~6.5% through the whole book. This ratio is the point of chapter scoping.
    let fraction = PlayerTimeFormatting.scopedFraction(
      currentTime: 2_400, start: Self.chapterStart, end: Self.chapterEnd)
    #expect(abs(fraction - 1_200.0 / 3_360.0) < 1e-9)
  }

  @Test("the playhead at the chapter's edges reads as empty and full")
  func scopedFractionClampsToTheChapterEdges() {
    #expect(
      PlayerTimeFormatting.scopedFraction(currentTime: 1_000, start: Self.chapterStart, end: Self.chapterEnd)
        == 0)
    #expect(
      PlayerTimeFormatting.scopedFraction(currentTime: 5_000, start: Self.chapterStart, end: Self.chapterEnd)
        == 1)
    #expect(
      PlayerTimeFormatting.scopedFraction(
        currentTime: Self.chapterStart, start: Self.chapterStart, end: Self.chapterEnd)
        == 0)
    #expect(
      PlayerTimeFormatting.scopedFraction(currentTime: Self.chapterEnd, start: Self.chapterStart, end: Self.chapterEnd)
        == 1)
  }

  @Test("a degenerate or non-finite chapter window reads as zero, never NaN")
  func scopedFractionGuardsUnusableWindows() {
    #expect(PlayerTimeFormatting.scopedFraction(currentTime: 30, start: 30, end: 30) == 0)
    #expect(PlayerTimeFormatting.scopedFraction(currentTime: 30, start: 40, end: 20) == 0)
    #expect(PlayerTimeFormatting.scopedFraction(currentTime: .nan, start: 0, end: 100) == 0)
    #expect(PlayerTimeFormatting.scopedFraction(currentTime: 30, start: .nan, end: 100) == 0)
  }

  @Test("a chapter-relative scrub fraction projects back to a global time inside the chapter")
  func scopedTimeProjectsFractionOntoTheChapterWindow() {
    #expect(
      PlayerTimeFormatting.scopedTime(fraction: 0.5, start: Self.chapterStart, end: Self.chapterEnd)
        == 2_880)
    #expect(
      PlayerTimeFormatting.scopedTime(fraction: 0, start: Self.chapterStart, end: Self.chapterEnd)
        == Self.chapterStart)
    #expect(
      PlayerTimeFormatting.scopedTime(fraction: 1, start: Self.chapterStart, end: Self.chapterEnd)
        == Self.chapterEnd)
  }

  @Test("scopedTime and scopedFraction invert each other")
  func scopedTimeInvertsScopedFraction() {
    let time: Double = 2_400
    let fraction = PlayerTimeFormatting.scopedFraction(
      currentTime: time, start: Self.chapterStart, end: Self.chapterEnd)
    #expect(
      abs(PlayerTimeFormatting.scopedTime(fraction: fraction, start: Self.chapterStart, end: Self.chapterEnd) - time)
        < 1e-6)
  }

  @Test("an out-of-range or non-finite scrub fraction is clamped into the chapter window")
  func scopedTimeClampsFraction() {
    #expect(
      PlayerTimeFormatting.scopedTime(fraction: 1.4, start: Self.chapterStart, end: Self.chapterEnd)
        == Self.chapterEnd)
    #expect(
      PlayerTimeFormatting.scopedTime(fraction: -0.3, start: Self.chapterStart, end: Self.chapterEnd)
        == Self.chapterStart)
    #expect(
      PlayerTimeFormatting.scopedTime(fraction: .nan, start: Self.chapterStart, end: Self.chapterEnd)
        == Self.chapterStart)
  }

  @Test("chapter clocks use one raw-media second so both sides transition together")
  func scopedChapterClocksStayComplementary() {
    let beforeBoundary = PlayerTimeFormatting.scopedChapterClocks(
      currentTime: 2_400.9, start: Self.chapterStart, end: Self.chapterEnd)
    let onBoundary = PlayerTimeFormatting.scopedChapterClocks(
      currentTime: 2_401, start: Self.chapterStart, end: Self.chapterEnd)

    #expect(beforeBoundary.elapsed == "20:00")
    #expect(beforeBoundary.remaining == "−36:00")
    #expect(onBoundary.elapsed == "20:01")
    #expect(onBoundary.remaining == "−35:59")
  }

  @Test("chapter clocks clamp to the chapter and never become negative")
  func scopedChapterClocksClampToTheChapter() {
    let before = PlayerTimeFormatting.scopedChapterClocks(
      currentTime: 1_000, start: Self.chapterStart, end: Self.chapterEnd)
    let after = PlayerTimeFormatting.scopedChapterClocks(
      currentTime: 5_000, start: Self.chapterStart, end: Self.chapterEnd)

    #expect(before.elapsed == "00:00")
    #expect(before.remaining == "−56:00")
    #expect(after.elapsed == "56:00")
    #expect(after.remaining == "−00:00")
  }

  @Test("the centre label gives a minute-precision estimate of listening time left")
  func bookRemainingLabelStatesEstimatedListeningTime() {
    #expect(
      PlayerTimeFormatting.bookRemainingLabel(currentTime: 2_400, totalDuration: Self.bookDuration)
        == "9h 36m left in book")
  }

  @Test("the expanded player's book remainder uses listening time while scrubber clocks stay raw")
  func expandedPlayerRateAdjustsOnlyBookRemainder() {
    let normal = PlayerTimeFormatting.bookRemainingLabel(
      currentTime: 2_400, totalDuration: Self.bookDuration, playbackRate: 1.0)
    let faster = PlayerTimeFormatting.bookRemainingLabel(
      currentTime: 2_400, totalDuration: Self.bookDuration, playbackRate: 1.5)

    let slower = PlayerTimeFormatting.bookRemainingLabel(
      currentTime: 2_400, totalDuration: Self.bookDuration, playbackRate: 0.9)
    let chapterClocks = PlayerTimeFormatting.scopedChapterClocks(
      currentTime: 2_400, start: Self.chapterStart, end: Self.chapterEnd)

    #expect(normal == "9h 36m left in book")
    #expect(slower == "10h 40m left in book at 0.9×")
    #expect(faster == "6h 24m left in book at 1.5×")
    #expect(chapterClocks.elapsed == "20:00")
    #expect(chapterClocks.remaining == "−36:00")
    let accessibleFaster =
      "20:00 into chapter, 36:00 left in chapter, approximately 6 hours 24 minutes "
      + "of listening time left in book at 1.5 times speed"
    #expect(
      PlayerTimeFormatting.scopedAccessibilityValue(
        currentTime: 2_400, start: Self.chapterStart, end: Self.chapterEnd,
        totalDuration: Self.bookDuration, playbackRate: 1.5)
        == accessibleFaster)
  }

  @Test("invalid expanded-player playback rates use raw book remainder")
  func expandedPlayerRateFallsBackForInvalidRates() {
    let expected = PlayerTimeFormatting.bookRemainingLabel(
      currentTime: 2_400, totalDuration: Self.bookDuration, playbackRate: 1.0)

    for rate in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
      #expect(
        PlayerTimeFormatting.bookRemainingLabel(
          currentTime: 2_400, totalDuration: Self.bookDuration, playbackRate: rate)
          == expected)
    }
  }

  @Test("book remainder rounds to minutes and names sub-minute and completed states")
  func bookRemainingLabelUsesDeliberateMinutePrecision() {
    #expect(
      PlayerTimeFormatting.bookRemainingLabel(currentTime: 0, totalDuration: 3_629)
        == "1h left in book")
    #expect(
      PlayerTimeFormatting.bookRemainingLabel(currentTime: 0, totalDuration: 3_631)
        == "1h 1m left in book")
    #expect(
      PlayerTimeFormatting.bookRemainingLabel(currentTime: 61, totalDuration: 120)
        == "<1m left in book")
    #expect(
      PlayerTimeFormatting.bookRemainingLabel(currentTime: 120, totalDuration: 120)
        == "0m left in book")
  }

  @Test("the book-remaining label is absent when the total duration is unknown")
  func bookRemainingLabelIsNilWithoutADuration() {
    #expect(PlayerTimeFormatting.bookRemainingLabel(currentTime: 2_400, totalDuration: nil) == nil)
    #expect(PlayerTimeFormatting.bookRemainingLabel(currentTime: 2_400, totalDuration: 0) == nil)
  }

  @Test("the accessibility value carries the same three facts the visible labels do")
  func scopedAccessibilityValueMirrorsTheVisibleLabels() {
    let expected =
      "20:00 into chapter, 36:00 left in chapter, approximately 10 hours 40 minutes "
      + "of listening time left in book at 0.9 times speed"
    #expect(
      PlayerTimeFormatting.scopedAccessibilityValue(
        currentTime: 2_400, start: Self.chapterStart, end: Self.chapterEnd,
        totalDuration: Self.bookDuration, playbackRate: 0.9)
        == expected)
  }

  @Test("without a book duration the accessibility value drops the book clause")
  func scopedAccessibilityValueDropsBookClauseWhenUnknown() {
    #expect(
      PlayerTimeFormatting.scopedAccessibilityValue(
        currentTime: 2_400, start: Self.chapterStart, end: Self.chapterEnd, totalDuration: nil)
        == "20:00 into chapter, 36:00 left in chapter")
  }

  // MARK: - Scrub precision labelling

  @Test("only the reduced scrub resolutions are labelled")
  func precisionLabelNamesReducedSpeedsOnly() {
    #expect(ExpandedPlayerView.precisionLabel(.full) == nil)
    #expect(ExpandedPlayerView.precisionLabel(.half) == "HALF-SPEED")
    #expect(ExpandedPlayerView.precisionLabel(.quarter) == "QUARTER-SPEED")
    #expect(ExpandedPlayerView.precisionLabel(.fine) == "FINE")
  }

}
