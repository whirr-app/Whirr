import AppModel
import Persistence

/// Pure choice lists and copy `PodcastShowSettingsView` renders through, kept separate from the
/// view body so a test can pin the tri-state pickers' options and the not-found copy without
/// instantiating SwiftUI. Mirrors `PodcastShowViewPresentation`'s convention.
nonisolated enum PodcastShowSettingsViewPresentation {
  static let privateFeedSectionHeader = "Private Feed"
  static let privateFeedUsernameLabel = "Username"
  static let privateFeedPasswordLabel = "Password"
  static let privateFeedSaveLabel = "Save Credentials"
  static let privateFeedRemoveLabel = "Remove Credentials"
  static let privateFeedFooter =
    "Basic authentication is stored in this device's Keychain and sent only to this feed."
  static let includeInLatestTitle = "Include in Latest Episodes"
  static let includeInLatestFooter =
    "Turn this off to keep new episodes from this feed out of Home and Podcasts."
  /// The Automatic Downloads picker's three choices: Default / On / Off. A two-state toggle would
  /// pin every show on first render and make the global default decorative.
  static let autoDownloadOverrideChoices: [PodcastShowAutoDownloadOverride] = [
    .inherit, .enabled, .disabled,
  ]

  /// `nil` = inherit the global default; `0` = keep all; else the show's own count. The same
  /// choices as the global screen, plus the leading "inherit" option.
  static let keepLatestOverrideChoices: [Int?] =
    [nil] + PodcastSettingsViewPresentation.keepLatestChoices.map { $0 }

  /// `nil` = inherit the global default.
  static let deleteAfterPlayedOverrideChoices: [Bool?] = [nil, true, false]

  /// The read-only server section's header. Kept distinct from the override sections' headers so
  /// the server's fact and this device's controls never visually merge.
  static let serverSectionHeader = "Audiobookshelf Server"

  /// The not-found state's title, paired with `PodcastDownloadCopy.showSettingsNotFound`'s
  /// message. Says what happened (the show is gone) rather than a bare "Error" or "Not Found".
  static let notFoundTitle = "Show Not Available"
}
