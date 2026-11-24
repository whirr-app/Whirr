import Foundation

/// The one owner of the list-facing playback position quantum. Every list projection carrying a
/// stored position (show pages, Home shelves and More lists, Saved for Later, the Podcasts tab's
/// latest episodes, Author and Series tiles) projects it through here, so a checkpoint inside one
/// quantum yields an identical list and `removeDuplicates` drops it.
///
/// The playing row resolves the live playhead through `PlaybackModel.displayedPositionSeconds`
/// instead. Lists print minutes ("23 min played"), so the floor costs at most one minute on any
/// other caption. Resume, the episode card, item detail and sync read exact positions elsewhere.
public enum PlaybackPositionListProjection {
  /// One minute: the finest unit any list caption prints.
  public static let quantum: Double = 60

  /// The position floored to the quantum. A position inside the first quantum stays exact, so a
  /// started episode never rounds down to unplayed and leaves the in-progress filters; invalid
  /// positions pass through for the presentation layer's own guards.
  public static func quantizedSeconds(_ seconds: Double) -> Double {
    guard seconds.isFinite, seconds >= quantum else { return seconds }
    return floor(seconds / quantum) * quantum
  }
}
