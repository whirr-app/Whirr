import Foundation

/// Playback state as an exclusive enum, not a set of booleans: "unplayed and finished" is not a
/// question anyone can ask, so the type refuses to represent it.
///
/// The three engaged cases partition an item's playback state: every item matches one and only one.
/// `unfinished` is "no progress of any kind" (no finished row, audio position or ebook position),
/// matching its "Unplayed" label.
///
/// The partition is per account. `ItemFilterPredicate` correlates progress rows on `itemId` alone,
/// so two accounts' rows against one item row could satisfy two cases at once. `item` rows are
/// account-scoped and the app is single-account, so this is a boundary, not a live defect;
/// correlating on `accountId` would add a bind argument its callers do not supply.
public enum PlaybackFilter: String, Sendable, Equatable, Hashable, CaseIterable {
  case any
  case unfinished
  case inProgress
  case finished
}

/// The composite browse filter carried across the Library's read boundary and held by its model.
/// It does not replace `SearchFilters` or `PodcastEpisodeFilter`.
///
/// Categories are OR'd among themselves, then AND'd with the download and playback dimensions.
/// `downloadedOnly` is additive; `playback` is exclusive.
public struct BrowseFilters: Sendable, Equatable, Hashable {
  /// `nil` means no category constraint. An empty set is canonicalized to `nil` by every
  /// initializer, so "no constraint" has one representation. Otherwise `nil` and `[]` would be
  /// two unequal values producing identical SQL, and the model's "setting the same value is a
  /// no-op" guard would miss.
  public let categories: Set<ItemMediaCategory>?
  public let downloadedOnly: Bool
  public let playback: PlaybackFilter

  public init(
    categories: Set<ItemMediaCategory>? = nil,
    downloadedOnly: Bool = false,
    playback: PlaybackFilter = .any
  ) {
    if let categories, categories.isEmpty == false {
      self.categories = categories
    } else {
      self.categories = nil
    }
    self.downloadedOnly = downloadedOnly
    self.playback = playback
  }

  public static let unfiltered = BrowseFilters()

  public var isActive: Bool { activeCount > 0 }

  /// Engaged dimensions, not engaged categories: a two-category selection is still one
  /// narrowing as far as the funnel's badge and the "you have filters on" copy are concerned.
  public var activeCount: Int {
    var count = 0
    if categories != nil { count += 1 }
    if downloadedOnly { count += 1 }
    if playback != .any { count += 1 }
    return count
  }
}
