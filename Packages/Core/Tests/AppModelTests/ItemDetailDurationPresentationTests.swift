import Persistence
import Testing

@testable import AppModel

@Suite("ItemDetailDurationPresentation")
struct ItemDetailDurationPresentationTests {
  /// An ebook-only item carries a server `media.duration` of `0`, not nil, so `if let
  /// durationSeconds` would pass and render a meaningless "0m" under the author.
  @Test("an ebook shows no duration, even though the server sends zero rather than nothing")
  func ebookShowsNoDuration() {
    #expect(
      ItemDetailDurationPresentation.showsDuration(category: .ebook, durationSeconds: 0) == false)
    #expect(
      ItemDetailDurationPresentation.showsDuration(category: .ebook, durationSeconds: nil) == false)
  }

  /// A bundled-EPUB audiobook is `.audiobook`, not `.ebook`, so this does not silence narrated
  /// titles that happen to ship an EPUB.
  @Test("an audiobook with a real duration still shows it")
  func audiobookWithRealDurationStillShowsIt() {
    #expect(
      ItemDetailDurationPresentation.showsDuration(category: .audiobook, durationSeconds: 3600))
    #expect(
      ItemDetailDurationPresentation.showsDuration(category: .podcast, durationSeconds: 1800))
  }

  /// A zero-duration audiobook is a genuine "we don't know yet" rather than a category fact, and a
  /// "0m" there is equally useless.
  @Test("no duration row for a missing or zero audiobook duration")
  func noDurationRowForMissingOrZeroAudiobookDuration() {
    #expect(
      ItemDetailDurationPresentation.showsDuration(category: .audiobook, durationSeconds: nil)
        == false)
    #expect(
      ItemDetailDurationPresentation.showsDuration(category: .audiobook, durationSeconds: 0)
        == false)
  }

  @Test("durationText never leaks the unknown-duration caption onto a library item")
  func durationTextSuppressesUnknownDurations() {
    #expect(
      ItemDetailDurationPresentation.durationText(category: .audiobook, durationSeconds: 3600)
        == "1 hr")
    #expect(
      ItemDetailDurationPresentation.durationText(category: .ebook, durationSeconds: 3600) == nil)
    for seconds in [nil, 0, -1, Double.nan, Double.infinity] as [Double?] {
      #expect(
        ItemDetailDurationPresentation.durationText(
          category: .audiobook, durationSeconds: seconds) == nil)
    }
  }

  @Test("remaining listening time uses persisted progress and playback rate")
  func remainingListeningTimeUsesProgressAndRate() {
    let remaining = ItemDetailDurationPresentation.remainingSeconds(
      durationSeconds: 100, progressSeconds: 10, playbackRate: 1.15)

    #expect(remaining != nil)
    #expect(abs((remaining ?? 0) - (90 / 1.15)) < 0.000_001)
  }

  @Test("invalid playback rates use raw remaining audio seconds")
  func remainingListeningTimeFallsBackForInvalidRates() {
    for rate in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
      #expect(
        ItemDetailDurationPresentation.remainingSeconds(
          durationSeconds: 100, progressSeconds: 10, playbackRate: rate) == 90)
    }
  }
}
