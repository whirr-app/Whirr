import AppModel
import Persistence

/// Pure choice lists `PodcastSettingsView`/`PodcastShowSettingsView` render their pickers through,
/// kept separate from the view bodies so a test can pin the exact options offered without
/// instantiating SwiftUI. Mirrors `PodcastShowViewPresentation`'s convention.
nonisolated enum PodcastSettingsViewPresentation {
  /// The global Keep Latest picker's five choices: 1 / 3 / 5 / 10 / All. `0` renders as "All"
  /// through `PodcastDownloadCopy.keepLatestValueLabel`.
  static let keepLatestChoices: [Int] = [1, 3, 5, 10, 0]

  /// Settings has two distinct section headings for its own two-section list, which is not the
  /// root's single-section/tile-provenance scheme, so they are owned here rather than borrowed
  /// from `PodcastsViewPresentation`.
  static let followedSectionTitle = "Direct Feeds"
  static let serverSectionTitle = "Audiobookshelf"

  /// Which download-defaults sections the Downloads destination renders, and in which order.
  enum DownloadDefaultsScope: Hashable {
    case direct
    case server
  }

  /// The two stores are independent, but most accounts only feed one of them, so the split is
  /// shown rather than switched: a source with no shows is omitted whenever the other has some,
  /// leaving a single plain section for a direct-only or Audiobookshelf-only account. An account
  /// with shows from both, or with none yet, sees both.
  static func downloadDefaultsScopes(
    showRows: [PodcastShowSettingsSummary],
    nativeSubscriptionsEnabled: Bool,
    hasDirectFeedDefaults: Bool
  ) -> [DownloadDefaultsScope] {
    guard nativeSubscriptionsEnabled, hasDirectFeedDefaults else { return [.server] }
    let partitioned = partitionedShowRows(showRows, nativeSubscriptionsEnabled: true)
    switch (partitioned.native.isEmpty, partitioned.server.isEmpty) {
    case (false, true): return [.direct]
    case (true, false): return [.server]
    default: return [.direct, .server]
    }
  }

  /// Preserve each source's existing order while keeping device-owned feeds visibly distinct from
  /// ABS rows. Disabling native subscriptions hides, but never deletes, their settings.
  static func partitionedShowRows(
    _ rows: [PodcastShowSettingsSummary], nativeSubscriptionsEnabled: Bool
  ) -> (native: [PodcastShowSettingsSummary], server: [PodcastShowSettingsSummary]) {
    var native: [PodcastShowSettingsSummary] = []
    var server: [PodcastShowSettingsSummary] = []
    for row in rows {
      if PodcastSourceIdentity(itemId: row.itemID)?.rssFeedId != nil {
        if nativeSubscriptionsEnabled { native.append(row) }
      } else {
        server.append(row)
      }
    }
    return (native, server)
  }
}
