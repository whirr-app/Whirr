import Persistence

/// How far through one podcast episode the listener is, in the words and bar every episode row
/// shows. The show page's row and the cross-show card rows both read this one value, so they
/// cannot drift into saying different things about the same episode.
public struct PodcastEpisodeListeningState: Sendable, Equatable {
  /// `nil` for an unplayed episode, as `MediaProgressActionPolicy.playbackStatus` resolves it.
  public let playbackStatus: ItemPlaybackStatus?
  /// The show row's progress line: "23 min played", "Played" or "Not played".
  public let progressText: String
  /// The bar's fill, present only part way through. Neither end draws one: an unplayed episode
  /// has nothing to show, and a finished one keeps the position it was marked done at, so the
  /// state rather than the fraction closes that end. `nil` too when the duration is unknown.
  public let progressFraction: Double?

  public init(progressSeconds: Double, durationSeconds: Double?, isFinished: Bool) {
    playbackStatus = MediaProgressActionPolicy.playbackStatus(
      progressSeconds: progressSeconds, isFinished: isFinished)
    progressText = PodcastCopy.progress(seconds: progressSeconds, isFinished: isFinished)
    progressFraction =
      if playbackStatus == .inProgress, let durationSeconds, durationSeconds.isFinite,
        let fraction = HomeRowPresentation.progressFraction(
          progressSeconds: progressSeconds, durationSeconds: durationSeconds),
        fraction > 0, fraction < 1
      {
        fraction
      } else {
        nil
      }
  }

  /// The progress words for a row that stays silent until the episode is started, so an unplayed
  /// card is unchanged rather than reading "Not played".
  public var startedProgressText: String? {
    playbackStatus == nil ? nil : progressText
  }
}
