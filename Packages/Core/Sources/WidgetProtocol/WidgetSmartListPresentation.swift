import Foundation

/// What the smart list widget draws, chosen from the snapshot (the account state), the list file
/// and the widget's configured list. Kept out of the extension so it can be tested.
public enum WidgetSmartListPresentation: Sendable, Equatable {
  /// Nothing readable yet: no snapshot, no list file, or a list file left by another account.
  /// Drawn as the redacted placeholder.
  case unavailable
  case signedOut
  /// Signed in with no lists: the widget suggests creating one.
  case noLists
  /// The configured list no longer exists.
  case deleted
  case list(WidgetSmartList, isPlaying: Bool)

  /// `configuredListID` is `nil` for a widget not yet configured, which shows the first list.
  public init(snapshot: WidgetSnapshot?, lists: WidgetSmartLists?, configuredListID: Int64?) {
    guard let snapshot else {
      self = .unavailable
      return
    }
    guard let stamp = snapshot.accountStamp else {
      self = .signedOut
      return
    }
    // The two files are written separately; until the list file is this account's, draw neither
    // account's lists.
    guard let lists, lists.accountStamp == stamp else {
      self = .unavailable
      return
    }
    if let configuredListID {
      if let list = lists.list(id: configuredListID) {
        self = .list(list, isPlaying: lists.isPlaying)
      } else {
        self = lists.lists.isEmpty ? .noLists : .deleted
      }
    } else if let first = lists.lists.first {
      self = .list(first, isPlaying: lists.isPlaying)
    } else {
      self = .noLists
    }
  }

  /// The row the widget's one play button starts: the list's first, from which the list's run
  /// continues. `nil` for an empty list, which offers no button.
  public var playFromTop: WidgetItem? {
    guard case .list(let list, _) = self else { return nil }
    return list.items.first
  }

  /// Whether the button offers pause rather than play: one of the list's drawn rows is loaded and
  /// playback is intended. Playback from anywhere else leaves the button offering play.
  public var showsListPause: Bool {
    guard case .list(let list, let isPlaying) = self, playFromTop != nil else { return false }
    return isPlaying && list.loadedToken != nil
  }

  /// "12 episodes", "1 episode", "No episodes"; `nil` when the count is unknown.
  public static func countText(_ matchCount: Int?) -> String? {
    guard let matchCount else { return nil }
    switch matchCount {
    case 0: return "No episodes"
    case 1: return "1 episode"
    default: return "\(matchCount) episodes"
    }
  }
}
