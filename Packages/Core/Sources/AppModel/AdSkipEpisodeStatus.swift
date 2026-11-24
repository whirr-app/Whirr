/// What an episode card says about ad skipping before playback.
public enum AdSkipEpisodeStatus: Sendable, Equatable {
  /// Nothing to say: ad skip is off, the episode is not a downloaded file analysis covers, the
  /// conditions are not known yet, or its file cannot be read just now.
  case none
  /// Analysis may run, and other episodes are ahead of this one.
  case queued
  /// The episode is being analysed, or is next.
  case checking
  /// Analysis is held, and the episode is not analysed yet.
  case waiting(PlaybackAdAnalysisStatus.Hold)
  /// Analysed. `breaks` are the skips the listener would hear, which can be none.
  case ready(AdSkipBreaks)
  /// Analysis gave up on the file under this transcriber.
  case failed
}

extension AdSkipEpisodeStatus {
  /// Lower is less settled. Any other status comes before `ready`, and of two analysed copies the
  /// one with fewer breaks does.
  var settledness: Int {
    switch self {
    case .checking: 0
    case .queued: 1
    case .waiting: 2
    case .failed: 3
    case .none: 4
    case .ready(let breaks): 5 + breaks.count
    }
  }
}
