/// Plain playback-interruption signal (ARCHITECTURE.md §4), decoupled from AVFoundation so
/// `PlaybackInterruptionPolicy` stays Foundation-only and independently testable. Only the
/// App-target `AVAudioSession` notification adapter constructs one, mapped from a real
/// `AVAudioSession.interruptionNotification`'s `userInfo`.
public enum PlaybackInterruptionEvent: Sendable, Equatable {
  case began
  case ended(shouldResume: Bool)
}

/// Pure interruption policy (ARCHITECTURE.md §4): pause on interruption; resume only when the
/// system supplies `shouldResume` and playback was active beforehand; never auto-resume after a
/// user pause. Foundation-only. Driven by the `PlaybackInterruptionEvent`s the App-target adapter
/// produces plus the phase/item-id read from `PlaybackControlling.state` at delivery.
///
/// The caller carries out `.pause`/`.resume` through the same `PlayerIntent`s as on-screen and
/// remote controls; this type never touches `PlayerController`/`AudioEngine`.
public struct PlaybackInterruptionPolicy: Sendable, Equatable {
  public enum Action: Sendable, Equatable {
    case pause
    case resume
    case none
  }

  /// The id of the item this interruption paused, tracked so a late/stale event belonging to an
  /// item a subsequent `PlayerIntent.load` has since displaced never resolves against the new one.
  /// `nil` whenever no interruption is currently being tracked.
  private var interruptedItemId: String?
  private var shouldResumeOnEnd = false

  public init() {}

  public mutating func handle(_ event: PlaybackInterruptionEvent, phase: PlayerPhase, itemId: String?)
    -> Action
  {
    switch event {
    case .began:
      // A nested/duplicate `.began` before any `.ended` is a no-op: by the time it arrives the
      // first `.began`'s pause has already moved `phase` to `.paused`, so this must not be read as
      // "began while paused" and clear the interruption already being tracked.
      guard interruptedItemId == nil else { return .none }
      guard phase == .playing, let itemId else { return .none }
      interruptedItemId = itemId
      shouldResumeOnEnd = true
      return .pause
    case .ended(let shouldResume):
      defer {
        interruptedItemId = nil
        shouldResumeOnEnd = false
      }
      guard let pendingItemId = interruptedItemId, pendingItemId == itemId else { return .none }
      guard shouldResume, shouldResumeOnEnd else { return .none }
      return .resume
    }
  }

  /// Call whenever the user explicitly pauses, including during an interruption, so playback is
  /// never auto-resumed after a user pause even if the system later reports `shouldResume` for
  /// the interruption active at the time.
  public mutating func userDidPause() {
    shouldResumeOnEnd = false
  }
}
