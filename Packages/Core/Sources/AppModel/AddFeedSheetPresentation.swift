import Foundation

public enum AddFeedSheetPresentation {
  public static let navigationTitle = "Add Podcast"
  public static let addressFieldPrompt = "Podcast name or feed link"
  public static let idleTitle = "Find a Podcast"
  public static let idleMessage = "Search by a show's name, or paste its feed link to follow it."
  public static let previewingLabel = "Checking…"
  public static let followButtonLabel = "Follow"
  public static let followingLabel = "Following…"
  public static let followedLabel = "Following"
  public static let directorySearchingLabel = "Searching…"
  public static let directoryEmptyTitle = "No podcasts found"
  public static let extractedCredentialNotice =
    "Credentials were removed from the link and will be stored in this device's Keychain when you follow."

  public static func message(for error: AddFeedError) -> String {
    switch error {
    case .invalidAddress:
      return "That doesn't look like a podcast link. Check it and try again."
    case .unreachable:
      return "Couldn't reach that link. Check your connection and try again."
    case .notAFeed:
      return "There's no podcast to follow at that link."
    case .alreadyFollowing:
      return "You're already following this podcast."
    case .couldNotFollow:
      return "Couldn't follow this podcast. Try again."
    }
  }

  /// A directory row was never a link the user typed, so its failures describe the podcast.
  /// `alreadyFollowing` is shown as the row's followed state rather than as a failure.
  public static func directoryFollowMessage(for error: AddFeedError) -> String {
    switch error {
    case .unreachable:
      return "Couldn't reach this podcast. Check your connection and try again."
    case .invalidAddress, .notAFeed:
      return "Couldn't load this podcast's feed. Try again."
    case .alreadyFollowing, .couldNotFollow:
      return "Couldn't follow this podcast. Try again."
    }
  }

  /// A failed search is the directory provider failing, not the user's link or connection: the
  /// provider can be down while everything else works, and add-by-address still does.
  public static func directorySearchMessage(for error: AddFeedError) -> String {
    "Podcast search isn't available right now. Try again later, or paste a feed address."
  }

  public static let detailLoadingLabel = "Loading episodes…"
  public static let detailAboutTitle = "About"
  public static let detailRecentEpisodesTitle = "Recent episodes"
  public static let detailNoEpisodes = "This podcast hasn't published any episodes yet."
  public static let detailRetryLabel = "Try Again"
  public static let detailRowAccessibilityHint = "Shows the podcast's description and recent episodes"
  public static let detailEpisodeAccessibilityHint = "Shows the full episode notes"

  public static func followAccessibilityLabel(title: String) -> String { "Follow \(title)" }
  public static func followingAccessibilityLabel(title: String) -> String { "Following \(title)" }

  public static func episodeCountText(_ count: Int) -> String {
    count == 1 ? "1 episode" : "\(count) episodes"
  }
}
