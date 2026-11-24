import Testing

@testable import WatchPlayback

private typealias Policy = WatchInterruptionPolicy

@Suite struct WatchInterruptionPolicyTests {
  @Test func anInterruptionPausesWhatPlaysAndResumesWhenAsked() {
    var policy = Policy()
    #expect(policy.handle(.interruptionBegan, playing: true) == .pause)
    #expect(policy.handle(.interruptionEnded(shouldResume: true), playing: false) == .resume)
  }

  @Test func anInterruptionEndingWithoutShouldResumeStaysPaused() {
    var policy = Policy()
    _ = policy.handle(.interruptionBegan, playing: true)
    #expect(policy.handle(.interruptionEnded(shouldResume: false), playing: false) == .none)
  }

  /// A8: an interruption while nothing plays does nothing, and its end does not start playback.
  @Test func anInterruptionWhileNothingPlaysDoesNothing() {
    var policy = Policy()
    #expect(policy.handle(.interruptionBegan, playing: false) == .none)
    #expect(policy.handle(.interruptionEnded(shouldResume: true), playing: false) == .none)
  }

  /// The listener taking over during an interruption cancels its resume.
  @Test func aListenerActionCancelsTheResume() {
    var policy = Policy()
    _ = policy.handle(.interruptionBegan, playing: true)
    policy.listenerActed()
    #expect(policy.handle(.interruptionEnded(shouldResume: true), playing: false) == .none)
  }

  @Test func aResumeIsUsedOnce() {
    var policy = Policy()
    _ = policy.handle(.interruptionBegan, playing: true)
    _ = policy.handle(.interruptionEnded(shouldResume: true), playing: false)
    #expect(policy.handle(.interruptionEnded(shouldResume: true), playing: false) == .none)
  }

  @Test func losingTheOutputPausesAndForgetsAnInterruption() {
    var policy = Policy()
    #expect(policy.handle(.routeChanged(.oldDeviceUnavailable), playing: true) == .pause)
    #expect(policy.handle(.routeChanged(.oldDeviceUnavailable), playing: false) == .none)
    _ = policy.handle(.interruptionBegan, playing: true)
    _ = policy.handle(.routeChanged(.oldDeviceUnavailable), playing: false)
    #expect(policy.handle(.interruptionEnded(shouldResume: true), playing: false) == .none)
  }

  @Test(arguments: [Policy.RouteChange.newDeviceAvailable, .categoryChange, .other])
  fileprivate func otherRouteChangesDoNothing(_ change: Policy.RouteChange) {
    var policy = Policy()
    #expect(policy.handle(.routeChanged(change), playing: true) == .none)
    #expect(policy.handle(.routeChanged(change), playing: false) == .none)
  }
}
