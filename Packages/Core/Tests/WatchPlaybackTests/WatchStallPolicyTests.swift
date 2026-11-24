import Testing

@testable import WatchPlayback

private typealias Policy = WatchStallPolicy

@Suite struct WatchStallPolicyTests {
  @Test func waitingWhilePlaybackIsWantedStallsAfterTheBound() {
    var policy = Policy()
    #expect(policy.observe(.waiting, wanted: true, at: 100) == .checkAt(115))
    #expect(policy.check(wanted: true, at: 114.9) == .checkAt(115))
    #expect(policy.check(wanted: true, at: 115) == .stalled)
  }

  @Test func furtherWaitingKeepsTheFirstDeadline() {
    var policy = Policy()
    _ = policy.observe(.waiting, wanted: true, at: 100)
    #expect(policy.observe(.playbackStalled, wanted: true, at: 108) == .checkAt(115))
    #expect(policy.observe(.waiting, wanted: true, at: 116) == .stalled)
  }

  @Test func bufferingThatRecoversInsideTheBoundClearsIt() {
    var policy = Policy()
    _ = policy.observe(.waiting, wanted: true, at: 100)
    #expect(policy.observe(.playing, wanted: true, at: 110) == .none)
    #expect(policy.check(wanted: true, at: 200) == .none)
    #expect(policy.observe(.waiting, wanted: true, at: 200) == .checkAt(215))
  }

  /// A7: a system pause the listener did not ask for is as stuck as a stream that waits.
  @Test func aSilentPauseWhilePlaybackIsWantedCountsAsWaiting() {
    var policy = Policy()
    #expect(policy.observe(.paused, wanted: true, at: 10) == .checkAt(25))
    #expect(policy.check(wanted: true, at: 25) == .stalled)
  }

  @Test func nothingStallsWhilePlaybackIsNotWanted() {
    var policy = Policy()
    #expect(policy.observe(.waiting, wanted: false, at: 0) == .none)
    #expect(policy.check(wanted: false, at: 100) == .none)
    #expect(policy.observe(.failedToPlayToEnd, wanted: false, at: 100) == .none)
  }

  @Test func aPauseClearsAPendingStall() {
    var policy = Policy()
    _ = policy.observe(.waiting, wanted: true, at: 0)
    #expect(policy.observe(.paused, wanted: false, at: 5) == .none)
    #expect(policy.check(wanted: true, at: 20) == .none)
  }

  @Test func failingToPlayToTheEndStallsAtOnce() {
    var policy = Policy()
    #expect(policy.observe(.failedToPlayToEnd, wanted: true, at: 3) == .stalled)
  }

  /// One episode is reported once: a later observation or check before playback recovers or is
  /// asked for again says nothing.
  @Test func aStallIsReportedOnce() {
    var policy = Policy()
    _ = policy.observe(.waiting, wanted: true, at: 0)
    #expect(policy.check(wanted: true, at: 15) == .stalled)
    #expect(policy.check(wanted: true, at: 30) == .none)
    #expect(policy.observe(.failedToPlayToEnd, wanted: true, at: 31) == .none)
    #expect(policy.observe(.waiting, wanted: true, at: 32) == .none)
    _ = policy.observe(.playing, wanted: true, at: 40)
    #expect(policy.observe(.failedToPlayToEnd, wanted: true, at: 41) == .stalled)
  }

  @Test func aResetStartsAFreshEpisode() {
    var policy = Policy()
    #expect(policy.observe(.failedToPlayToEnd, wanted: true, at: 0) == .stalled)
    policy.reset()
    #expect(policy.observe(.waiting, wanted: true, at: 1) == .checkAt(16))
  }
}
