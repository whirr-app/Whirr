import Persistence
import Testing

@testable import AppModel

@Suite("Media progress action policy")
struct MediaProgressActionPolicyTests {
  @Test("every media type shares one three-state action table")
  func actionsFollowPlaybackState() {
    #expect(MediaProgressActionPolicy.actions(for: nil) == [.markAsFinished])
    #expect(
      MediaProgressActionPolicy.actions(for: .inProgress)
        == [.markAsFinished, .resetProgress, .removeFromContinueListening])
    #expect(MediaProgressActionPolicy.actions(for: .finished) == [.resetProgress])
  }

  @Test("Continue Listening removal requires active, visible progress")
  func continueListeningRemovalEligibility() {
    #expect(
      MediaProgressActionPolicy.actions(
        for: .inProgress, isHidden: false, isCurrentlyPlaying: false
      ).contains(.removeFromContinueListening))
    #expect(
      MediaProgressActionPolicy.actions(
        for: nil, isHidden: false, isCurrentlyPlaying: false
      ).contains(.removeFromContinueListening) == false)
    #expect(
      MediaProgressActionPolicy.actions(
        for: .finished, isHidden: false, isCurrentlyPlaying: false
      ).contains(.removeFromContinueListening) == false)
    #expect(
      MediaProgressActionPolicy.actions(
        for: .inProgress, isHidden: true, isCurrentlyPlaying: false
      ).contains(.removeFromContinueListening) == false)
    #expect(
      MediaProgressActionPolicy.actions(
        for: .inProgress, isHidden: false, isCurrentlyPlaying: true
      ).contains(.removeFromContinueListening) == false)
  }

  @Test("raw audio, ebook, and finished progress resolve to the shared state")
  func playbackStatusResolvesEveryMediaSignal() {
    #expect(
      MediaProgressActionPolicy.playbackStatus(
        progressSeconds: 0, ebookProgress: 0, isFinished: false) == nil)
    #expect(
      MediaProgressActionPolicy.playbackStatus(
        progressSeconds: 1, ebookProgress: 0, isFinished: false) == .inProgress)
    #expect(
      MediaProgressActionPolicy.playbackStatus(
        progressSeconds: 0, ebookProgress: 0.01, isFinished: false) == .inProgress)
    #expect(
      MediaProgressActionPolicy.playbackStatus(
        progressSeconds: 1, ebookProgress: 0.5, isFinished: true) == .finished)
  }
}
