/// What the import sheet's one pinned commit control is currently for.
///
/// One button through the whole flow, so its state is a model value, not view-local booleans. Once
/// every row is committed it must not keep reading "Follow Selected" while disabled.
public enum PodcastImportCommitState: Sendable, Equatable {
  /// Rows are still pending. `count` is how many of them are ticked; zero means the commit is
  /// unavailable but the list can still be re-ticked.
  case follow(count: Int)
  /// A batch is running. `completed` counts rows that have already resolved either way.
  case following(completed: Int, total: Int)
  /// Every row reached a terminal status. Leaving is the positive action.
  case done
}

public enum PodcastSubscriptionOPMLPresentation {
  public static let importLabel = "Import OPML"
  public static let exportLabel = "Export OPML"
  public static let previewTitle = "Import Podcasts"
  public static let followedLabel = "Followed"
  public static let followingLabel = "Following…"
  public static let doneLabel = "Done"
  public static let invalidDocumentMessage = "That file isn't a valid OPML subscription list."
  public static let noFeedsMessage = "That OPML file doesn't contain any podcast feeds."
  public static let exportFailureMessage = "Couldn't prepare your podcast subscriptions for export."

  /// The commit control names its own scope, so the user need not look back up the list to learn
  /// what a tap would do.
  public static func commitLabel(_ state: PodcastImportCommitState) -> String {
    switch state {
    case .follow(let count):
      switch count {
      case ...0: "Follow"
      case 1: "Follow 1 Podcast"
      default: "Follow \(count) Podcasts"
      }
    case .following(let completed, let total):
      "Following \(min(completed + 1, max(total, 1))) of \(total)…"
    case .done:
      doneLabel
    }
  }

  /// Only a failure gets a caption line. Following and followed are carried by the row's own
  /// accessory, because a caption under every committed row grows the list by one line per feed
  /// and pushes the commit control off screen mid-import.
  public static func failureText(_ status: OPMLImportRow.Status) -> String? {
    guard case .failed(let error) = status else { return nil }
    return AddFeedSheetPresentation.message(for: error)
  }
}
