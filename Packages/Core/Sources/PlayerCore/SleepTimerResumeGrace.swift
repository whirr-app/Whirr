/// Remembers the sleep timer the listener last chose and when playback last stopped, so a resume
/// shortly afterwards restarts the same timer for someone still awake when the audio faded.
///
/// Times are `PlaybackClock.continuousNow()` readings: the window must count hours the phone
/// spends asleep, or a morning resume would look quick.
struct SleepTimerResumeGrace: Sendable, Equatable {
  /// What the listener chose, kept as chosen: an extension changes the running timer, not this.
  private var choice: SleepTimerDuration?
  private var expiredAt: Double?

  /// The listener chose a timer. `.off` forgets everything; anything else replaces the remembered
  /// choice and any expiry still waiting on a resume.
  mutating func timerChosen(_ duration: SleepTimerDuration) {
    choice = duration == .off ? nil : duration
    expiredAt = nil
  }

  /// The running timer stopped playback.
  mutating func timerExpired(at time: Double) {
    guard choice != nil else { return }
    expiredAt = time
  }

  /// The choice to start again for a resume at `time`, or nil. Used up when returned: one expiry
  /// earns one restart, and the restarted timer earns its own when it runs out.
  mutating func takeRestorableChoice(at time: Double, window: Double) -> SleepTimerDuration? {
    guard window > 0, let choice, let expiredAt else { return nil }
    self.expiredAt = nil
    let elapsed = time - expiredAt
    guard elapsed >= 0, elapsed <= window else { return nil }
    return choice
  }
}
