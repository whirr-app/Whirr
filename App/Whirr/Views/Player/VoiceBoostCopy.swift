/// Every string Voice Boost shows, in one place so the Settings row and the speed card's quick
/// toggle cannot drift apart.
nonisolated enum VoiceBoostCopy {
  static let toggleTitle = "Voice Boost"
  /// The speed card's toggle row.
  static let menuSymbol = "person.wave.2.fill"
  /// The Settings section header. Not "Voice Boost", so it does not repeat the row's own title.
  static let settingsHeader = "Audio"
  /// One sentence, naming no device: the same app runs on iPad.
  static let footer = "Makes voices clearer and evens out loud and quiet passages."
  /// The Settings footer, where the toggle is the default for every show.
  static let settingsFooter = footer + " Shows can have their own setting."
}
