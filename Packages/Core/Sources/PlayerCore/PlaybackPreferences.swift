/// Local-only playback preferences, not synced to ABS (ARCHITECTURE.md §4). Injected so
/// `PlayerController` can restore the default across relaunch without importing
/// Persistence/UserDefaults. The App-owned playback-rate coordinator owns mutations and provides
/// the conformance.
public protocol PlaybackPreferences: Sendable {
  /// The last-saved playback rate, or nil if none has ever been saved.
  func loadRate() -> Double?
  func saveRate(_ rate: Double)
  /// Whether a long pause should rewind slightly when playback resumes. Defaults to on.
  func loadSmartRewindEnabled() -> Bool
  /// How soon after a sleep timer stops playback a resume restarts that timer, in seconds. 0 is
  /// off, which is the default.
  func loadSleepTimerResumeGraceSeconds() -> Double
}

/// The default `PlaybackPreferences`: never saves and leaves smart rewind enabled. Lets
/// `PlayerController`'s `preferences` parameter default for callers uninterested in local
/// playback preferences.
public struct NoOpPlaybackPreferences: PlaybackPreferences {
  public init() {}
  public func loadRate() -> Double? { nil }
  public func saveRate(_ rate: Double) {}
  public func loadSmartRewindEnabled() -> Bool { true }
  public func loadSleepTimerResumeGraceSeconds() -> Double { 0 }
}
