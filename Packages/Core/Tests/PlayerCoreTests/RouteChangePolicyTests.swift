import Testing

@testable import PlayerCore

/// `RouteChangePolicy` is the pure decision maker behind the fixed policy: pause on
/// old-device-unavailable route changes, and never resume automatically. Driven entirely by a
/// plain `RouteChangeEvent` and the caller-supplied phase, so it is testable without AVFoundation.
@Suite struct RouteChangePolicyTests {

  @Test func oldDeviceUnavailableWhilePlayingPauses() {
    let policy = RouteChangePolicy()
    let action = policy.handle(.oldDeviceUnavailable, phase: .playing)
    #expect(action == .pause)
  }

  @Test func oldDeviceUnavailableWhileNotPlayingTakesNoAction() {
    let policy = RouteChangePolicy()
    #expect(policy.handle(.oldDeviceUnavailable, phase: .paused) == .none)
    #expect(policy.handle(.oldDeviceUnavailable, phase: .buffering) == .none)
  }

  @Test func newDeviceAvailableTakesNoAction() {
    let policy = RouteChangePolicy()
    let action = policy.handle(.newDeviceAvailable, phase: .playing)
    #expect(action == .none)
  }

  @Test func categoryChangeTakesNoAction() {
    let policy = RouteChangePolicy()
    let action = policy.handle(.categoryChange, phase: .playing)
    #expect(action == .none)
  }

  @Test func overrideTakesNoAction() {
    let policy = RouteChangePolicy()
    let action = policy.handle(.override, phase: .playing)
    #expect(action == .none)
  }

  @Test func otherReasonTakesNoAction() {
    let policy = RouteChangePolicy()
    let action = policy.handle(.other, phase: .playing)
    #expect(action == .none)
  }

  @Test func duplicateAutoPauseEventIsANoOpOnceAlreadyPaused() {
    let policy = RouteChangePolicy()
    let first = policy.handle(.oldDeviceUnavailable, phase: .playing)
    // The caller applies `first` through the same `.pause` intent as any other control, which
    // moves the state machine to `.paused`. A duplicate route-change notification arriving with
    // that phase must not produce a second pause.
    let second = policy.handle(.oldDeviceUnavailable, phase: .paused)

    #expect(first == .pause)
    #expect(second == .none)
  }

  @Test func actionTypeHasNoResumeCase() {
    // Structural guarantee for "never automatic resume": `RouteChangePolicy.Action` only has
    // `.pause`/`.none`, so there is no code path in this type that can resume playback.
    let action: RouteChangePolicy.Action = .none
    switch action {
    case .pause, .none: break
    }
  }
}
