import Testing

@testable import Whirr

@Suite("Transcript and Look Back play/pause")
struct TranscriptPlayPauseButtonTests {
  @Test("offered only while the sheet's title is the one loaded")
  func offeredWhileLoaded() {
    // Opened from a list before the episode plays: tapping a sentence is what starts it.
    #expect(TranscriptPlayPause.presentation(isLoaded: false, isPlaybackIntended: true) == nil)
    #expect(
      TranscriptPlayPause.presentation(isLoaded: true, isPlaybackIntended: true)
        == .init(title: "Pause", systemImage: "pause.fill"))
    #expect(
      TranscriptPlayPause.presentation(isLoaded: true, isPlaybackIntended: false)
        == .init(title: "Play", systemImage: "play.fill"))
  }
}
