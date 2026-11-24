import Persistence
import Testing

@testable import AppModel

@Suite("Podcast episode listening state")
struct PodcastEpisodeListeningStateTests {
  @Test("an unplayed episode carries no progress words and no bar")
  func unplayedCarriesNothing() {
    let state = PodcastEpisodeListeningState(
      progressSeconds: 0, durationSeconds: 3_600, isFinished: false)

    #expect(state.playbackStatus == nil)
    #expect(state.progressText == PodcastCopy.notPlayed)
    #expect(state.startedProgressText == nil)
    #expect(state.progressFraction == nil)
  }

  @Test("a started episode reads as minutes played with a part-way bar")
  func startedReadsAsMinutesPlayed() {
    let state = PodcastEpisodeListeningState(
      progressSeconds: 1_380, durationSeconds: 3_600, isFinished: false)

    #expect(state.playbackStatus == .inProgress)
    #expect(state.progressText == "23 min played")
    #expect(state.startedProgressText == "23 min played")
    #expect(state.progressFraction == 1_380.0 / 3_600.0)
  }

  @Test("a finished episode reads as played and draws no bar, wherever it stopped")
  func finishedReadsAsPlayedWithNoBar() {
    // Marking an episode done part way keeps its position, so the state, not the fraction, closes
    // that end of the range.
    let state = PodcastEpisodeListeningState(
      progressSeconds: 600, durationSeconds: 3_600, isFinished: true)

    #expect(state.playbackStatus == .finished)
    #expect(state.progressText == PodcastCopy.played)
    #expect(state.startedProgressText == PodcastCopy.played)
    #expect(state.progressFraction == nil)
  }

  @Test("an unknown or zero duration keeps the words but draws no bar")
  func unknownDurationKeepsWordsWithoutABar() {
    for duration in [nil, 0, -1, Double.infinity, Double.nan] as [Double?] {
      let state = PodcastEpisodeListeningState(
        progressSeconds: 300, durationSeconds: duration, isFinished: false)

      #expect(state.startedProgressText == "5 min played")
      #expect(state.progressFraction == nil)
    }
  }

  @Test("a position at or past the end draws no bar, like the show row")
  func positionAtTheEndDrawsNoBar() {
    let state = PodcastEpisodeListeningState(
      progressSeconds: 3_600, durationSeconds: 3_600, isFinished: false)

    #expect(state.playbackStatus == .inProgress)
    #expect(state.progressFraction == nil)
  }

  @Test("the status agrees with the shared action policy for every input")
  func statusAgreesWithTheActionPolicy() {
    let inputs: [(Double, Bool)] = [(0, false), (1, false), (600, false), (0, true), (600, true)]

    for (progress, isFinished) in inputs {
      let state = PodcastEpisodeListeningState(
        progressSeconds: progress, durationSeconds: 3_600, isFinished: isFinished)

      #expect(
        state.playbackStatus
          == MediaProgressActionPolicy.playbackStatus(
            progressSeconds: progress, isFinished: isFinished))
    }
  }

  @Test("the words are the show page's own progress copy")
  func wordsAreTheShowPagesCopy() {
    for (progress, isFinished) in [(0.0, false), (90.0, false), (4_000.0, false), (10.0, true)] {
      let state = PodcastEpisodeListeningState(
        progressSeconds: progress, durationSeconds: 5_000, isFinished: isFinished)

      #expect(
        state.progressText == PodcastCopy.progress(seconds: progress, isFinished: isFinished))
    }
  }
}
