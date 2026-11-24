import Testing

@testable import PlayerCore

/// `PlaybackInterruptionPolicy` is the pure decision maker behind the fixed policy in
/// ARCHITECTURE.md §4: pause on interruption; resume only when the system supplies `shouldResume`
/// and playback was active beforehand; never auto-resume after a user pause. It takes plain
/// `PlaybackInterruptionEvent`s and caller-supplied phase/item-id context, so it needs no
/// AVFoundation or audio session; only the App-target notification adapter builds an event from a
/// real notification.
@Suite struct PlaybackInterruptionPolicyTests {

  private static let itemId = "item-1"

  @Test func beganWhilePlayingPausesAndBecomesResumeEligible() {
    var policy = PlaybackInterruptionPolicy()
    let action = policy.handle(.began, phase: .playing, itemId: Self.itemId)
    #expect(action == .pause)
  }

  @Test func beganWhilePausedTakesNoAction() {
    var policy = PlaybackInterruptionPolicy()
    let action = policy.handle(.began, phase: .paused, itemId: Self.itemId)
    #expect(action == .none)
  }

  @Test func beganWhileBufferingTakesNoAction() {
    var policy = PlaybackInterruptionPolicy()
    let action = policy.handle(.began, phase: .buffering, itemId: Self.itemId)
    #expect(action == .none)
  }

  @Test func endedWithShouldResumeAfterActiveInterruptionResumes() {
    var policy = PlaybackInterruptionPolicy()
    _ = policy.handle(.began, phase: .playing, itemId: Self.itemId)
    let action = policy.handle(.ended(shouldResume: true), phase: .paused, itemId: Self.itemId)
    #expect(action == .resume)
  }

  @Test func endedWithoutShouldResumeAfterActiveInterruptionTakesNoAction() {
    var policy = PlaybackInterruptionPolicy()
    _ = policy.handle(.began, phase: .playing, itemId: Self.itemId)
    let action = policy.handle(.ended(shouldResume: false), phase: .paused, itemId: Self.itemId)
    #expect(action == .none)
  }

  @Test func endedWithShouldResumeButNoPriorInterruptionTakesNoAction() {
    var policy = PlaybackInterruptionPolicy()
    let action = policy.handle(.ended(shouldResume: true), phase: .paused, itemId: Self.itemId)
    #expect(action == .none)
  }

  @Test func endedWithShouldResumeButBeganWhilePausedDoesNotResume() {
    // The interruption began while nothing was playing (e.g. the user had already paused), so
    // there is no "playback was active beforehand" to restore, however the system reports it.
    var policy = PlaybackInterruptionPolicy()
    _ = policy.handle(.began, phase: .paused, itemId: Self.itemId)
    let action = policy.handle(.ended(shouldResume: true), phase: .paused, itemId: Self.itemId)
    #expect(action == .none)
  }

  @Test func userPauseDuringInterruptionPreventsAutoResume() {
    var policy = PlaybackInterruptionPolicy()
    _ = policy.handle(.began, phase: .playing, itemId: Self.itemId)
    policy.userDidPause()
    let action = policy.handle(.ended(shouldResume: true), phase: .paused, itemId: Self.itemId)
    #expect(action == .none)
  }

  @Test func nestedDuplicateBeganNotificationsDoNotClearResumeEligibility() {
    var policy = PlaybackInterruptionPolicy()
    let first = policy.handle(.began, phase: .playing, itemId: Self.itemId)
    // A nested/duplicate `.began` arrives before any `.ended`. Phase has already moved to
    // `.paused` from the first pause, but this must not be read as "began while paused" and wipe
    // out the interruption already being tracked.
    let second = policy.handle(.began, phase: .paused, itemId: Self.itemId)
    let ended = policy.handle(.ended(shouldResume: true), phase: .paused, itemId: Self.itemId)

    #expect(first == .pause)
    #expect(second == .none)
    #expect(ended == .resume)
  }

  @Test func duplicateEndedNotificationIsHarmless() {
    var policy = PlaybackInterruptionPolicy()
    _ = policy.handle(.began, phase: .playing, itemId: Self.itemId)
    let firstEnded = policy.handle(.ended(shouldResume: true), phase: .paused, itemId: Self.itemId)
    let secondEnded = policy.handle(.ended(shouldResume: true), phase: .paused, itemId: Self.itemId)

    #expect(firstEnded == .resume)
    #expect(secondEnded == .none)
  }

  @Test func staleEndedEventAfterItemSwitchDoesNotResumeTheNewItem() {
    var policy = PlaybackInterruptionPolicy()
    _ = policy.handle(.began, phase: .playing, itemId: "item-1")
    // The loaded item changed (a `PlayerIntent.load` for a different book) before the system
    // delivered its `.ended` notification for the original interruption.
    let action = policy.handle(.ended(shouldResume: true), phase: .paused, itemId: "item-2")
    #expect(action == .none)
  }
}
