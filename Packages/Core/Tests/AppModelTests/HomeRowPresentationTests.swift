import Persistence
import Testing

@testable import AppModel

/// phase-4b-home-screen.md T4B.5: pure formatting for one `HomeItem` card. `durationSeconds` is
/// nil-able and often absent on the minified wire shape, so the nil-duration path is tested as a
/// first-class case throughout, not an afterthought.
@Suite struct HomeRowPresentationTests {

  // MARK: - progressFraction

  @Test func fractionIsProgressOverDuration() {
    let fraction = HomeRowPresentation.progressFraction(progressSeconds: 1800, durationSeconds: 3600)
    #expect(fraction == 0.5)
  }

  @Test func fractionIsNilWhenDurationIsNil() {
    #expect(HomeRowPresentation.progressFraction(progressSeconds: 100, durationSeconds: nil) == nil)
  }

  @Test func fractionIsNilWhenDurationIsZeroOrNegative() {
    #expect(HomeRowPresentation.progressFraction(progressSeconds: 100, durationSeconds: 0) == nil)
    #expect(HomeRowPresentation.progressFraction(progressSeconds: 100, durationSeconds: -10) == nil)
  }

  @Test func fractionClampsToOneWhenProgressExceedsDuration() {
    let fraction = HomeRowPresentation.progressFraction(progressSeconds: 4000, durationSeconds: 3600)
    #expect(fraction == 1)
  }

  @Test func fractionClampsToZeroWhenProgressIsNegative() {
    let fraction = HomeRowPresentation.progressFraction(progressSeconds: -10, durationSeconds: 3600)
    #expect(fraction == 0)
  }

  @Test func fractionAtTheJustStartedEdgeIsZero() {
    let fraction = HomeRowPresentation.progressFraction(progressSeconds: 0, durationSeconds: 3600)
    #expect(fraction == 0)
  }

  // MARK: - remainingCaption

  @Test func captionShowsHoursAndMinutesForTimedMedia() {
    // 10h total, 3h10m in -> 6h50m remaining.
    let caption = HomeRowPresentation.remainingCaption(
      progressSeconds: 3 * 3600 + 10 * 60, durationSeconds: 10 * 3600, isFinished: false,
      category: .audiobook)
    #expect(caption == "6h 50m left")
  }

  @Test("caption uses listening time rather than raw audio time at faster playback")
  func captionAccountsForPlaybackRate() {
    let normal = HomeRowPresentation.remainingCaption(
      progressSeconds: 0, durationSeconds: 80 * 3600, isFinished: false,
      category: .audiobook, playbackRate: 1.0)
    let faster = HomeRowPresentation.remainingCaption(
      progressSeconds: 0, durationSeconds: 80 * 3600, isFinished: false,
      category: .audiobook, playbackRate: 1.15)

    #expect(normal == "80h 0m left")
    #expect(faster == "69h 34m left")
  }

  @Test("invalid playback rates fall back to normal speed")
  func captionFallsBackForInvalidPlaybackRates() {
    let expected = HomeRowPresentation.remainingCaption(
      progressSeconds: 0, durationSeconds: 80 * 3600, isFinished: false,
      category: .audiobook, playbackRate: 1.0)

    for rate in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
      #expect(
        HomeRowPresentation.remainingCaption(
          progressSeconds: 0, durationSeconds: 80 * 3600, isFinished: false,
          category: .audiobook, playbackRate: rate) == expected)
    }
  }

  @Test("ebook captions stay percentages regardless of playback rate")
  func ebookCaptionIgnoresPlaybackRate() {
    #expect(
      HomeRowPresentation.remainingCaption(
        progressSeconds: 0.18 * 50 * 3600, durationSeconds: 50 * 3600, isFinished: false,
        category: .ebook, playbackRate: 1.15) == "18%")
  }

  @Test func captionOmitsHoursWhenRemainingIsUnderAnHour() {
    // 45m total, 13m in -> 32m remaining. A podcast episode reads the same countdown as a book.
    let caption = HomeRowPresentation.remainingCaption(
      progressSeconds: 13 * 60, durationSeconds: 45 * 60, isFinished: false, category: .podcast)
    #expect(caption == "32m left")
  }

  @Test("a very long audiobook still reads a countdown, never a percent")
  func captionStaysACountdownForLongTimedMedia() {
    // 50h total, 18% in -> 41h remaining. Magnitude must not change the caption's kind.
    let caption = HomeRowPresentation.remainingCaption(
      progressSeconds: 0.18 * 50 * 3600, durationSeconds: 50 * 3600, isFinished: false,
      category: .audiobook)
    #expect(caption == "41h 0m left")
  }

  @Test("ebooks read percent-complete, having no meaningful clock")
  func captionIsPercentForEbooks() {
    let caption = HomeRowPresentation.remainingCaption(
      progressSeconds: 0.18 * 50 * 3600, durationSeconds: 50 * 3600, isFinished: false,
      category: .ebook)
    #expect(caption == "18%")
  }

  @Test func captionIsFinishedRegardlessOfRemainingTime() {
    let caption = HomeRowPresentation.remainingCaption(
      progressSeconds: 3600, durationSeconds: 3600, isFinished: true, category: .audiobook)
    #expect(caption == "Finished")
  }

  @Test func captionIsEmptyWhenDurationIsNil() {
    for category in ItemMediaCategory.allCases {
      let caption = HomeRowPresentation.remainingCaption(
        progressSeconds: 100, durationSeconds: nil, isFinished: false, category: category)
      #expect(caption.isEmpty)
    }
  }

  @Test func captionIsEmptyWhenDurationIsZeroOrNegative() {
    #expect(
      HomeRowPresentation.remainingCaption(
        progressSeconds: 0, durationSeconds: 0, isFinished: false, category: .audiobook
      ).isEmpty)
    #expect(
      HomeRowPresentation.remainingCaption(
        progressSeconds: 0, durationSeconds: -1, isFinished: false, category: .audiobook
      ).isEmpty)
  }

  @Test("just-started edge: a long, barely-started audiobook reads its full remaining time")
  func captionAtTheJustStartedEdge() {
    let caption = HomeRowPresentation.remainingCaption(
      progressSeconds: 0, durationSeconds: 50 * 3600, isFinished: false, category: .audiobook)
    #expect(caption == "50h 0m left")
  }

  @Test("progress past duration never produces a negative remaining time")
  func captionClampsRemainingToZeroWhenProgressExceedsDuration() {
    let caption = HomeRowPresentation.remainingCaption(
      progressSeconds: 4000, durationSeconds: 3600, isFinished: false, category: .audiobook)
    #expect(caption == "0m left")
  }

  // MARK: - badgeLabel

  @Test(
    "badge label per category",
    arguments: [
      (ItemMediaCategory.audiobook, "Audiobook"),
      (ItemMediaCategory.podcast, "Podcast"),
      (ItemMediaCategory.ebook, "eBook"),
    ]
  )
  func badgeLabelPerCategory(category: ItemMediaCategory, expected: String) {
    #expect(HomeRowPresentation.badgeLabel(for: category) == expected)
  }
}
