/// The Home section whose disclosure heading expands into a pushed list.
///
/// New cases go last: a stored order from an earlier release appends missing sections in this
/// order (`HomeSectionOrder`).
public enum HomeMoreSection: String, Sendable, Equatable, Hashable, CaseIterable {
  case continueListening
  case continueReading
  case continueSeries
  case newEpisodes
  case recentlyAdded
  case downloaded
  case savedForLater
  /// A card rather than a shelf; its heading opens the Stats screen, not a list.
  case listeningStats
  /// Rows rather than a shelf; its heading opens the Smart Lists screen, and a row its list.
  case smartLists

  public var showsProgress: Bool { self == .continueListening || self == .continueReading }
}
