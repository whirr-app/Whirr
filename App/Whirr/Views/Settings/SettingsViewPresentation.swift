import AppModel
import Persistence
import SyncEngine

nonisolated enum SettingsSection: CaseIterable, Equatable {
  case appearance
  /// The rows that push a sub-screen, in one group. No header: each row's label already names its
  /// destination, and iOS's own Settings groups such rows without one.
  case destinations
  case about

  /// `nil` renders the group with no header and no extra top padding.
  var header: String? {
    switch self {
    case .appearance: return "Appearance"
    case .destinations: return nil
    case .about: return nil
    }
  }
}

/// One pushed destination in the root Settings list, in display order. Home is first because the
/// tab it configures is the one the app opens on.
nonisolated enum SettingsDestination: CaseIterable, Equatable {
  case homeScreen
  case playback
  /// Device-side podcast auto-download defaults and the per-show override list. Separate from
  /// `.downloads` because it configures a policy (what to fetch automatically), not manual-download
  /// opt-ins.
  case podcasts
  /// Podcast ad skipping. A root row rather than a group on Playback: it transcribes downloaded
  /// episodes in the background, so its state and battery cost belong where they can be seen, and
  /// it applies only to podcasts. Hidden on a phone without an English recogniser.
  case reduceAds
  /// The manual-download opt-ins, the storage ceiling, and the two management screens.
  case downloads
  /// Watch companion setup, and what is on the Watch. Above Libraries because it is visited far
  /// more often than the library set is changed.
  case appleWatch
  /// The device-local included-library set, based on reconciled library rows rather than the
  /// profile's all-access sentinel.
  case libraries
  /// The server/account identity, durable library projection, live connection state, and the
  /// Log Out action, an infrequent action that belongs beside the account it removes.
  case serverAccount
}

nonisolated enum SettingsViewPresentation {
  enum ColorSchemeScope: Equatable {
    case presentationPreference
    case contentEnvironment
  }

  /// Whether the root Podcasts row is tappable. Uses the same positive-evidence gate that hides the
  /// Podcasts tab (`RootModel.hasIncludedPodcastLibrary`). A `nil` snapshot means the selection
  /// is still loading, and the row must never grey out on missing evidence.
  static func isPodcastsDestinationEnabled(
    snapshot: LibrarySelectionSnapshot?, nativeSubscriptionsEnabled: Bool = false
  ) -> Bool {
    (snapshot?.hasIncludedPodcastLibrary ?? true) || nativeSubscriptionsEnabled
  }

  /// Keep appearance changes below the sheet host. Publishing a `preferredColorScheme` upward
  /// makes the host remove and re-resolve that preference when an interactive dismissal commits,
  /// which interrupts the system's in-flight swipe animation.
  static let colorSchemeScope: ColorSchemeScope = .contentEnvironment

}
