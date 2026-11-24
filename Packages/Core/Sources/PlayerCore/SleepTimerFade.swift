public enum SleepTimerFade {
  /// How long before expiry the ramp begins. Short, as the curve is already at roughly half
  /// perceived loudness at the halfway point, so a long window quietens audio for a listener
  /// still awake. The floor is the tick rate: position updates arrive every 2 s while
  /// backgrounded (`AVQueuePlayerAudioEngine.backgroundPositionInterval`), when a timer usually
  /// expires, so this gives about 8 steps. Much shorter and it is a step.
  public static let windowSeconds: Double = 15

  /// Linear amplitude for `remainingSeconds` left on the clock. 1.0 at/above the window, 0 at or
  /// past expiry. Squared so the amplitude falls faster than the perceived loudness does, which
  /// is what makes the last few seconds read as a fade rather than a step to silence.
  public static func volume(remainingSeconds: Double) -> Double {
    guard remainingSeconds.isFinite else { return 1.0 }
    guard remainingSeconds > 0 else { return 0.0 }
    guard remainingSeconds < Self.windowSeconds else { return 1.0 }

    let fraction = remainingSeconds / Self.windowSeconds
    return min(max(fraction * fraction, 0), 1)
  }
}
