import Persistence

/// The progress operations shared by every media type and every surface that presents them.
/// Keeping this vocabulary independent of a particular menu lets long press, swipe, and player
/// overflow all consume the same eligibility decision without sharing their execution details.
public enum MediaProgressAction: Sendable, Equatable, Hashable {
  case markAsFinished
  case resetProgress
  case removeFromContinueListening
}

public enum MediaProgressActionPolicy {
  /// The one eligibility table for progress operations. A missing status is the durable untouched
  /// state: resetting removes the final positive progress row from the shared projection.
  ///
  /// `isHidden` suppresses a removal that would be a no-op. `ContinueListeningVisibilityStore`
  /// feeds it for account-owned and device-owned RSS rows alike.
  public static func actions(
    for playbackStatus: ItemPlaybackStatus?,
    isHidden: Bool = false,
    isCurrentlyPlaying: Bool = false
  ) -> [MediaProgressAction] {
    switch playbackStatus {
    case nil: return [.markAsFinished]
    case .inProgress:
      var actions: [MediaProgressAction] = [.markAsFinished, .resetProgress]
      if isHidden == false, isCurrentlyPlaying == false {
        actions.append(.removeFromContinueListening)
      }
      return actions
    case .finished: return [.resetProgress]
    }
  }

  /// Resolves raw item or episode progress into the coarse state the action table consumes.
  /// Finished wins because completed media ordinarily retains its final audio or ebook position.
  public static func playbackStatus(
    progressSeconds: Double,
    ebookProgress: Double? = nil,
    isFinished: Bool
  ) -> ItemPlaybackStatus? {
    if isFinished { return .finished }
    return progressSeconds > 0 || (ebookProgress ?? 0) > 0 ? .inProgress : nil
  }
}
