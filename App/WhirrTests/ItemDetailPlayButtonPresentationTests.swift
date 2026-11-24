import AppModel
import SwiftUI
import Testing

@testable import Whirr

struct ItemDetailPlayButtonPresentationTests {
  @Test("Resume and Pause name the verb alone, whatever the progress")
  func partPlayedLabelCarriesNoTime() {
    #expect(
      ItemDetailPlayButtonPresentation.label(
        isActive: true, isPlaying: false, positionSeconds: 14_760, isFinished: false,
        durationSeconds: 26_760,
        unstartedDurationText: "7h 26m")
        == "Resume")
    #expect(
      ItemDetailPlayButtonPresentation.label(
        isActive: false, isPlaying: false, positionSeconds: 600, isFinished: false,
        durationSeconds: 6_000,
        unstartedDurationText: "1h 40m")
        == "Resume")
    #expect(
      ItemDetailPlayButtonPresentation.label(
        isActive: true, isPlaying: true, positionSeconds: 3_600, isFinished: false,
        durationSeconds: 7_500,
        unstartedDurationText: "2h 5m")
        == "Pause")
    // The loaded title resumes even from zero: a figure there would tick once playback began.
    #expect(
      ItemDetailPlayButtonPresentation.label(
        isActive: true, isPlaying: false, positionSeconds: 0, isFinished: false,
        durationSeconds: 1_200,
        unstartedDurationText: "20m")
        == "Resume")
  }

  @Test("finished audio offers Play Again and its replay symbol")
  func finishedAudioUsesPlayAgainPresentation() {
    #expect(
      ItemDetailPlayButtonPresentation.label(
        isActive: false, isPlaying: false, positionSeconds: 26_760, isFinished: true,
        durationSeconds: 26_760, unstartedDurationText: "7h 26m")
        == "Play Again")
    #expect(
      ItemDetailPlayButtonPresentation.label(
        isActive: true, isPlaying: false, positionSeconds: 26_760, isFinished: true,
        durationSeconds: 26_760)
        == "Play Again")
    #expect(
      ItemDetailPlayButtonPresentation.label(
        isActive: true, isPlaying: true, positionSeconds: 26_760, isFinished: true,
        durationSeconds: 26_760)
        == "Pause")

    #expect(
      ItemDetailPlayButtonPresentation.symbolName(isPlaying: false, isFinished: true)
        == "arrow.counterclockwise")
    #expect(
      ItemDetailPlayButtonPresentation.symbolName(isPlaying: true, isFinished: true)
        == "pause.fill")
    #expect(
      ItemDetailPlayButtonPresentation.symbolName(isPlaying: false, isFinished: false)
        == "play.fill")
  }

  /// An unstarted title has no stat line under the credits: the runtime rides on the verb instead,
  /// so the hero says nothing until there is progress to explain.
  @Test("Play carries the unstarted runtime, and only Play")
  func playCarriesTheUnstartedRuntime() {
    #expect(
      ItemDetailPlayButtonPresentation.label(
        isActive: false, isPlaying: false, positionSeconds: 0, isFinished: false,
        durationSeconds: 11_820,
        unstartedDurationText: "3h 17m")
        == "Play · 3h 17m")
    // No runtime to state (an ebook, or a title with unknown duration) leaves the bare verb.
    #expect(
      ItemDetailPlayButtonPresentation.label(
        isActive: false, isPlaying: false, positionSeconds: 0, isFinished: false,
        durationSeconds: nil,
        unstartedDurationText: nil)
        == "Play")
    #expect(
      ItemDetailPlayButtonPresentation.label(
        isActive: false, isPlaying: false, positionSeconds: 0, isFinished: false,
        durationSeconds: 1_200,
        unstartedDurationText: "")
        == "Play")
  }

  @Test("the remainder is stated beside the progress bar instead")
  func remainingLabelCarriesTheTime() {
    #expect(
      ItemDetailPlayButtonPresentation.remainingLabel(
        positionSeconds: 14_760, durationSeconds: 26_760, playbackRate: 1.0)
        == "3 hrs, 20 min left")
    #expect(
      ItemDetailPlayButtonPresentation.remainingLabel(
        positionSeconds: 600, durationSeconds: 6_000, playbackRate: 1.15)
        == "1 hr, 18 min left")
    #expect(
      ItemDetailPlayButtonPresentation.remainingLabel(
        positionSeconds: 3_600, durationSeconds: 7_500, playbackRate: 1.0)
        == "1 hr, 5 min left")
  }

  /// The hero's stat is state, not fact. It has a lead only when it has a bar, and the lead is
  /// the remainder. An unstarted or finished title has no stat line at all.
  @Test("the hero stat exists only while there is progress to explain")
  func heroStatExistsOnlyWhilePartPlayed() {
    #expect(
      ItemDetailPlayButtonPresentation.heroStatLead(
        positionSeconds: 14_760, durationSeconds: 26_760, isFinished: false, playbackRate: 1.0)
        == "3 hrs, 20 min left")
    #expect(
      ItemDetailPlayButtonPresentation.heroStatLead(
        positionSeconds: 0, durationSeconds: 26_760, isFinished: false, playbackRate: 1.0)
        == nil)
    #expect(
      ItemDetailPlayButtonPresentation.heroStatLead(
        positionSeconds: 14_760, durationSeconds: 26_760, isFinished: true, playbackRate: 1.0)
        == nil)
    // An unknown runtime follows the same gate the bar and the remainder share.
    #expect(
      ItemDetailPlayButtonPresentation.heroStatLead(
        positionSeconds: 600, durationSeconds: nil, isFinished: false, playbackRate: 1.0)
        == nil)
  }

  @Test func progressPercentRoundsTheSameClampedFractionAsTheBar() {
    #expect(ItemDetailPlayButtonPresentation.progressPercentLabel(fraction: 0.894) == "89% complete")
    #expect(ItemDetailPlayButtonPresentation.progressPercentLabel(fraction: 1.4) == "100% complete")
    // A title in its first minutes has nothing to report; the bar and the remainder carry it.
    #expect(ItemDetailPlayButtonPresentation.progressPercentLabel(fraction: -.infinity) == nil)
    #expect(ItemDetailPlayButtonPresentation.progressPercentLabel(fraction: 0) == nil)
    #expect(ItemDetailPlayButtonPresentation.progressPercentLabel(fraction: 0.004) == nil)
    #expect(ItemDetailPlayButtonPresentation.progressPercentLabel(fraction: 0.006) == "1% complete")
  }

  @Test("the progress pairing appears only while a title is genuinely part-played")
  func progressPairingIsGatedTheSameWayThePodcastCardIs() {
    // Unstarted, finished, overrun and unknown-duration titles render neither bar nor remainder,
    // matching `PodcastEpisodeCardPresentation.remainingProgressFraction`.
    #expect(
      ItemDetailPlayButtonPresentation.progressFraction(
        positionSeconds: 0, durationSeconds: 1_200, isFinished: false) == nil)
    #expect(
      ItemDetailPlayButtonPresentation.progressFraction(
        positionSeconds: 1_200, durationSeconds: 1_200, isFinished: false) == nil)
    #expect(
      ItemDetailPlayButtonPresentation.progressFraction(
        positionSeconds: 1_500, durationSeconds: 1_200, isFinished: false) == nil)
    #expect(
      ItemDetailPlayButtonPresentation.progressFraction(
        positionSeconds: 600, durationSeconds: nil, isFinished: false) == nil)

    #expect(
      ItemDetailPlayButtonPresentation.progressFraction(
        positionSeconds: 720, durationSeconds: 1_200, isFinished: false) == 0.6)

    #expect(
      ItemDetailPlayButtonPresentation.progressFraction(
        positionSeconds: 720, durationSeconds: 1_200, isFinished: true) == nil)

    // The remainder follows the same gate, so the figure and the bar are never seen apart.
    #expect(
      ItemDetailPlayButtonPresentation.remainingLabel(
        positionSeconds: 0, durationSeconds: 1_200) == nil)
    #expect(
      ItemDetailPlayButtonPresentation.remainingLabel(
        positionSeconds: 1_200, durationSeconds: 1_200) == nil)
    #expect(
      ItemDetailPlayButtonPresentation.remainingLabel(
        positionSeconds: 600, durationSeconds: nil) == nil)
  }

  @Test("finished audio and ebooks show no remaining-time lead or progress bar")
  func finishedItemsSuppressRemainingTimeAndProgress() {
    let finishedAudio = ItemDetailPlayButtonPresentation.heroStatLead(
      positionSeconds: 14_760, durationSeconds: 26_760, isFinished: true)
    #expect(finishedAudio == nil)
    #expect(
      ItemDetailPlayButtonPresentation.progressFraction(
        positionSeconds: 14_760, durationSeconds: 26_760, isFinished: true) == nil)

    let finishedEbook = ReadAffordanceState.continueReading(percent: 37)
    #expect(
      ItemDetailPlayButtonPresentation.ebookRemainingLabel(
        for: finishedEbook, isFinished: false) == "63% left")
    #expect(
      ItemDetailPlayButtonPresentation.ebookProgressFraction(
        for: finishedEbook, isFinished: false) == 0.37)
    #expect(
      ItemDetailPlayButtonPresentation.ebookRemainingLabel(
        for: finishedEbook, isFinished: true) == nil)
    #expect(
      ItemDetailPlayButtonPresentation.ebookProgressFraction(
        for: finishedEbook, isFinished: true) == nil)
  }

  @Test("preparing suppresses the tap without dimming the control")
  func preparingSuppressesTheTapWithoutDimmingTheControl() {
    // The cold first tap enters `.preparing` for a moment. Disabling the button there removes the
    // glass fill and restores it, which reads as a blink rather than a transition, so the control
    // stays enabled and refuses the tap instead.
    #expect(ItemDetailPlayButtonPresentation.acceptsTap(phase: .preparing, isActive: true) == false)

    // Every other phase accepts a tap, active or not.
    for phase in [
      PlaybackModel.Phase.idle, .buffering, .stalled, .playing, .paused, .seeking,
      .recoverableError, .unrecoverableError,
    ] {
      #expect(ItemDetailPlayButtonPresentation.acceptsTap(phase: phase, isActive: true))
      #expect(ItemDetailPlayButtonPresentation.acceptsTap(phase: phase, isActive: false))
    }
  }

  @Test("another title preparing never suppresses this one's tap")
  func anotherTitlePreparingDoesNotSuppressThisTap() {
    #expect(ItemDetailPlayButtonPresentation.acceptsTap(phase: .preparing, isActive: false))
  }

}
