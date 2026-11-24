/// Sleep timer values. No Apple API exists for this, so it is PlayerCore's own logic, driven by
/// `PlaybackClock` and the state machine's pause handling. Local playback preference: never
/// persisted or synced to ABS.

/// What the caller asked for when setting or replacing the sleep timer. `.off` cancels whatever is
/// running. Every other choice replaces any active timer, so only one is ever active. `.endOfItem`
/// is distinct from `.endOfChapter` at the intent boundary even though both reduce to an absolute
/// position: podcast UI promises the end of the episode, even when chapter metadata exists.
public enum SleepTimerDuration: Sendable, Equatable {
  case off
  case fifteenMinutes
  case thirtyMinutes
  case fortyFiveMinutes
  case sixtyMinutes
  case custom(seconds: Double)
  case endOfChapter
  case endOfItem

  /// Countdown length in seconds, or nil for the modes that are not time-based.
  var seconds: Double? {
    switch self {
    case .off, .endOfChapter, .endOfItem: return nil
    case .fifteenMinutes: return 15 * 60
    case .thirtyMinutes: return 30 * 60
    case .fortyFiveMinutes: return 45 * 60
    case .sixtyMinutes: return 60 * 60
    case .custom(let seconds): return seconds
    }
  }
}

/// The sleep timer's current shape. `countdown` decrements only while audio plays ("sleep in 15
/// minutes" is 15 minutes of listening), so a pause, call or stall freezes it. Nothing drives a
/// reducer step while paused, so wall-clock counting would run invisibly behind a frozen display.
/// `PlayerReducer` advances it on every step following a playing segment. `endOfChapter` carries
/// the absolute global position the chapter ends at, computed once when set; `PlayerReducer`
/// fires it by comparing against `state.globalPosition`.
public enum SleepTimerMode: Sendable, Equatable {
  case off
  case countdown(remainingSeconds: Double)
  case endOfChapter(atPosition: Double)
}

/// `PlayerState.sleepTimer`'s value: the mode plus an accessible, testable remaining-time
/// description. PlayerCore has no UI dependency, so this is a plain formatted `String` that UI can
/// render as-is or wrap.
public struct SleepTimerState: Sendable, Equatable {
  public var mode: SleepTimerMode

  /// What the running countdown was originally asked for, in seconds: the picked preset, not what
  /// is left, so the timer menu knows which choice is in force. Ticks rewrite `mode` and leave
  /// this alone, so the menu avoids per-second invalidation. nil when no countdown is running and
  /// once one has been extended (no longer an offered choice).
  public var configuredSeconds: Double?

  /// True when this timer was started again by a resume shortly after the previous one stopped
  /// playback (`SleepTimerResumeGrace`), not by the listener choosing it. Survives ticks, which
  /// rewrite only `mode`; extending or replacing the timer rebuilds the state and clears it.
  public var restartedOnResume: Bool

  public init(
    mode: SleepTimerMode, configuredSeconds: Double? = nil, restartedOnResume: Bool = false
  ) {
    self.mode = mode
    self.configuredSeconds = configuredSeconds
    self.restartedOnResume = restartedOnResume
  }

  public static let off = SleepTimerState(mode: .off)

  /// nil when the timer is off; otherwise a human-readable, VoiceOver-friendly description of how
  /// much longer playback will continue. Spoken, not drawn: a control that already says "sleep
  /// timer" has no room to print the sentence (see `compactRemainingText`).
  public var accessibleRemainingText: String? {
    switch mode {
    case .off:
      return nil
    case .countdown:
      guard let clock = remainingClock else { return nil }
      return "\(clock) remaining"
    case .endOfChapter:
      return "Until end of chapter"
    }
  }

  /// nil when the timer is off; otherwise the shortest form that still says which timer is
  /// running. What a control under a moon glyph shows: the clock alone, since "remaining" is the
  /// only thing it could mean and the word costs a third of the label's width in a four-control
  /// row.
  public var compactRemainingText: String? {
    switch mode {
    case .off:
      return nil
    case .countdown:
      return remainingClock
    case .endOfChapter:
      // Not "End of chapter": the row gives each control roughly a clock's width, and the longer
      // phrase only fits by shrinking below the size its three siblings are drawn at.
      return "Chapter"
    }
  }

  private var remainingClock: String? {
    guard case .countdown(let remainingSeconds) = mode else { return nil }
    let clamped = max(0, remainingSeconds)
    let minutes = Int(clamped) / 60
    let seconds = Int(clamped) % 60
    let paddedSeconds = seconds < 10 ? "0\(seconds)" : "\(seconds)"
    return "\(minutes):\(paddedSeconds)"
  }
}
