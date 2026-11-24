import Foundation
import Testing

@testable import AppModel

/// The app's one written form of a playback speed, and the listening-time copy built on it.
@Suite struct PlaybackRateCopyTests {
  @Test func displayMatchesThePickersNotation() {
    #expect(PlaybackRateCopy.display(1) == "1×")
    #expect(PlaybackRateCopy.display(0.9) == "0.9×")
    #expect(PlaybackRateCopy.display(1.25) == "1.25×")
    #expect(PlaybackRateCopy.display(1.5) == "1.5×")
    #expect(PlaybackRateCopy.display(1.05) == "1.05×")
    #expect(PlaybackRateCopy.display(1, includesMultiplier: false) == "1")
  }

  @Test func invalidRatesReadAsNormalSpeed() {
    for rate in [0, -1, Double.nan, .infinity, -.infinity] {
      #expect(PlaybackRateCopy.display(rate) == "1×")
      #expect(PlaybackRateCopy.spoken(rate) == "normal speed")
    }
  }

  @Test func spokenNamesTheRateInWords() {
    #expect(PlaybackRateCopy.spoken(1) == "normal speed")
    #expect(PlaybackRateCopy.spoken(0.9) == "0.9 times speed")
    #expect(PlaybackRateCopy.spoken(1.25) == "1.25 times speed")
  }

  @Test func remainingNamesTheSpeedOnlyWhenItIsNotNormal() {
    #expect(PodcastCopy.remaining(seconds: 600) == "10 min left")
    #expect(PodcastCopy.remaining(seconds: 600, playbackRate: 1) == "10 min left")
    #expect(PodcastCopy.remaining(seconds: 600, playbackRate: 0.9) == "11 min left at 0.9×")
    #expect(PodcastCopy.remaining(seconds: 600, playbackRate: 1.25) == "8 min left at 1.25×")
    #expect(PodcastCopy.remaining(seconds: 600, playbackRate: .nan) == "10 min left")
    // Ad subtraction can leave nothing ahead; zero is an answer, not an unknown length.
    #expect(PodcastCopy.remaining(seconds: 0) == "0 min left")
    #expect(PodcastCopy.remaining(seconds: -10) == "0 min left")
  }

  @Test func spokenRemainingNamesTheSpeedInWords() {
    #expect(PodcastCopy.spokenRemaining(seconds: 600) == "10 min left")
    #expect(
      PodcastCopy.spokenRemaining(seconds: 600, playbackRate: 0.9)
        == "11 min left at 0.9 times speed")
  }
}
