/// What the episode card's primary button currently is. Play must not dismiss the card, and the
/// mini-player is behind the sheet, so the button morphs in place to confirm playback started.
///
/// Resolved from episode-scoped playback intent
/// (`PlaybackModel.isPlaybackIntended(for:episodeID:)`), not `phase`: a real stream flaps
/// `buffering`/`seeking` around every play and seek, glitching a phase-keyed glyph.
public enum PodcastEpisodeCardPlayControl: Sendable, Equatable {
  /// Not the loaded episode: the tap begins a fresh session through `PodcastEpisodeIntents.play`.
  case start
  /// The loaded episode, playing: the tap pauses it.
  case pause
  /// The loaded episode, paused: the tap resumes the session already prepared for it.
  case resume

  public static func resolve(isCurrentEpisode: Bool, isPlaybackIntended: Bool) -> Self {
    guard isCurrentEpisode else { return .start }
    return isPlaybackIntended ? .pause : .resume
  }

  /// The glyph names the tap, so it agrees with the label beside it rather than reporting status.
  /// Not a `waveform`: that reads as an indicator, and animating one reads as loading.
  public var systemImage: String {
    switch self {
    case .pause: "pause.fill"
    case .start, .resume: "play.fill"
    }
  }

  /// Whether the tap has to prepare a new session (`.start`) rather than toggle the loaded one.
  /// The two non-playing states are drawn identically and differ only here.
  public var startsNewSession: Bool { self == .start }

  /// Every state names the tap rather than the status, so the button is a legible action in
  /// VoiceOver as drawn, with no separate accessibility label.
  public func label(for presentation: PodcastEpisodeCardPresentation) -> String {
    switch self {
    case .pause: presentation.pauseButtonLabel
    case .start, .resume: presentation.playButtonLabel
    }
  }
}
