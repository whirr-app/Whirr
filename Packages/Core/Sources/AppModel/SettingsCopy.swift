import Foundation
import Persistence
import SyncEngine

/// User-facing copy for `SettingsModel`, owned and tested entirely in AppModel. Logout is
/// destructive, so its warning lists what it removes: every downloaded book, and any offline
/// listening progress not yet synced.
public enum SettingsCopy {
  /// Downloads destination. A pushed screen rather than a group in the root list, because it holds
  /// two toggles, two pickers and two navigation rows.
  public static let downloadsRowTitle = "Downloads"
  public static let downloadsRowDetail = "Network, automation and storage"
  public static let playbackRowDetail = "Speed, skip and timers"
  public static let podcastsRowDetail = "Subscriptions, downloads and alerts"
  public static let nativePodcastSubscriptionsToggleTitle = "Follow Podcasts Directly"
  public static let nativePodcastSubscriptionsFooter =
    "Follow RSS feeds in Whirr, independently of Audiobookshelf."
  public static let podcastEpisodeNotificationsToggleTitle = "New Episode Notifications"
  public static let podcastEpisodeNotificationsFooter =
    "Requires Background App Refresh."
  public static let backgroundRefreshOffWarning =
    "Background App Refresh is off for Whirr. New episodes are only checked when you open the app."
  public static let backgroundRefreshRestrictedWarning =
    "Background App Refresh is restricted on this device. New episodes are only checked when you open the app."
  public static let backgroundRefreshPausedWarning =
    "Paused while Low Power Mode is on. New episodes are only checked when you open the app."
  public static let notificationsDeniedRefusalTitle = "Notifications Are Off"
  public static let notificationsDeniedRefusalMessage =
    "Allow notifications for Whirr in Settings to get new episode alerts."
  public static let backgroundRefreshDeniedRefusalTitle = "Background App Refresh Is Off"
  public static let backgroundRefreshDeniedRefusalMessage =
    "Turn on Background App Refresh for Whirr in Settings so it can check for new episodes."
  public static let backgroundRefreshRestrictedRefusalTitle = "Background App Refresh Unavailable"
  public static let backgroundRefreshRestrictedRefusalMessage =
    "Background App Refresh is restricted on this device, so Whirr can't check for new episodes."
  public static let openSystemSettingsTitle = "Open Settings"
  public static let nativePodcastSubscriptionsDisableTitle = "Stop Podcast Playback?"
  public static let nativePodcastSubscriptionsDisableMessage =
    "The current episode will stop and the mini-player will close. Your subscriptions and progress will be kept."
  /// The row on that screen that pushes the downloaded-items list. Not "Downloads" again, as the
  /// screen it sits on already carries that title.
  public static let manageDownloadsRowTitle = "Manage Downloads"
  public static let manageDownloadsRowDetail = "Audio saved on this device"
  public static let resolutionCenterRowTitle = "Resolution Center"
  public static let resolutionCenterRowDetail = "Sync conflicts and paused downloads"

  public static let cellularDownloadsToggleTitle = "Allow Mobile Downloads"
  public static let deleteWhenFinishedToggleTitle = "Delete After Playing"
  public static let automaticDownloadsSectionTitle = "Automatic Downloads"
  public static let queueAutoDownloadTitle = "Download Up Next"
  public static let savedShelfAutoDownloadTitle = "Download Saved for Later"
  public static let queueAutoDownloadNever = "Never"
  public static let queueAutoDownloadWiFiOnly = "Wi-Fi Only"
  public static let queueAutoDownloadAlways = "Always"
  public static let storageCeilingTitle = "Storage Limit"
  public static let storageCeilingExplanation = "Only completed downloads are removed."
  public static let storageCeilingUnlimited = "Unlimited"
  public static let storageDownloadsTitle = "Whirr downloads"
  public static let storageAvailableOnDeviceTitle = "Available on device"
  public static let storageLimitSectionTitle = "Limit"
  public static let calculatingStorage = "Calculating storage…"
  public static let unavailableValue = "—"
  public static let reduceStorageLimitTitle = "Reduce Storage Limit?"
  public static let reduceStorageLimitMessage =
    "Whirr may remove completed downloads to reach this limit. Playing, queued, and in-progress downloads are kept."
  /// Spoken-only values. Unavailable data must announce as unavailable rather than as the dash it
  /// renders to, and never as a zero byte count.
  public static let storageUnavailableAccessibilityValue = "Unavailable"
  public static let storageLimitSliderTitle = "Keep downloads under"
  public static let storageCeilingReductionUnknown = "May remove completed downloads."

  public static func storageCategoryTitle(_ category: StorageCategory) -> String {
    switch category {
    case .audiobooks: "Audiobooks"
    case .podcasts: "Podcasts"
    case .documents: "Ebooks and PDFs"
    }
  }

  /// The line under the slider while it rests on a limit that would need confirming. `nil` when
  /// releasing there removes nothing.
  public static func storageCeilingReductionPreview(_ reduction: StorageCeilingReduction) -> String? {
    switch reduction {
    case .none: nil
    case .bytes(let bytes): "Removes about \(formattedBytes(bytes)) of completed downloads."
    case .unknown: storageCeilingReductionUnknown
    }
  }

  public static func queueAutoDownloadLabel(_ policy: QueueAutoDownloadPolicy) -> String {
    switch policy {
    case .never: queueAutoDownloadNever
    case .wifiOnly: queueAutoDownloadWiFiOnly
    case .always: queueAutoDownloadAlways
    }
  }

  /// Shares Up Next's value vocabulary: adjacent pickers answering the same question with
  /// different wording would read as different questions.
  public static func savedShelfAutoDownloadLabel(_ policy: SavedShelfAutoDownloadPolicy) -> String {
    switch policy {
    case .never: queueAutoDownloadNever
    case .wifiOnly: queueAutoDownloadWiFiOnly
    case .always: queueAutoDownloadAlways
    }
  }

  public static func storageCeilingLabel(_ ceiling: StorageCeiling) -> String {
    guard let bytes = ceiling.bytes else { return storageCeilingUnlimited }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  /// A byte count in the one format every storage figure uses.
  public static func storageBytes(_ bytes: Int64) -> String {
    formattedBytes(bytes)
  }

  public static func storageUsage(
    usedBytes: Int64, ceiling: StorageCeiling
  ) -> String {
    let used = formattedBytes(usedBytes)
    guard ceiling.isUnlimited == false else { return "\(used) downloaded" }
    return "\(used) of \(storageCeilingLabel(ceiling))"
  }

  public static func compactAvailableCapacity(_ bytes: Int64) -> String {
    "\(formattedBytes(bytes)) available"
  }

  public static func downloadedBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return unavailableValue }
    return formattedBytes(bytes)
  }

  public static func availableCapacity(_ bytes: Int64?) -> String {
    guard let bytes else { return unavailableValue }
    return formattedBytes(bytes)
  }

  public static func useStorageLimitAction(_ ceiling: StorageCeiling) -> String {
    "Use \(storageCeilingLabel(ceiling))"
  }

  public static let artworkCacheRowDetail = "Covers kept on this device"
  public static let artworkCacheClearArtwork = "Clear Cached Artwork"
  public static let artworkCacheClearingArtwork = "Clearing…"
  public static let artworkCacheClearArtworkTitle = "Clear Cached Artwork?"
  public static let artworkCacheConfirmClearArtwork = "Clear"

  /// Width template for the row's trailing slot while the size is still being measured. With
  /// monospaced digits it matches the width of a typical measured value.
  public static let artworkCacheRowSizePlaceholder = "000 MB"

  // MARK: - Library selection

  public static let librarySelectionTitle = "Libraries"
  public static let librarySelectionRowDetail = "Visible libraries"
  public static let librarySelectionFooter =
    "Turning off a library keeps its downloads, listening progress and Up Next."
  public static let librarySelectionLoading = "Loading libraries…"
  public static let librarySelectionEmpty = "No accessible libraries are available."
  public static let librarySelectionRefreshUnavailable =
    "Refresh unavailable, cached list shown."
  public static let librarySelectionLastLibraryMessage =
    "Whirr needs at least one library. Sign out if you do not want this account on the device."

  /// Width template for the root row's trailing slot while the selection loads. With monospaced
  /// digits it matches the width of the count that replaces it.
  public static let librarySelectionCountPlaceholder = librarySelectionCount(libraries: [])

  /// Counts the reconciled accessible rows, never the account profile's `librariesAccessible`.
  /// An empty profile array means all access, so it is not a countable source of truth.
  public static func librarySelectionCount(libraries: [SelectableLibrary]) -> String {
    let accessible = libraries.filter(\.isAccessible)
    let included = accessible.count(where: \.isIncluded)
    return "\(included) of \(accessible.count)"
  }

  public static func artworkCacheClearArtworkMessage(bytes: Int64) -> String {
    "Frees \(formattedBytes(bytes)) on this device. Covers refill automatically over Wi-Fi. Clearing can help when artwork is stuck or incorrect. Server artwork is kept."
  }

  public static func artworkCacheSizeDetail(bytes: Int64?) -> String {
    guard let bytes else { return "—" }
    return formattedBytes(bytes)
  }

  /// One byte formatter for every figure this screen quotes, so the row, the action and the
  /// confirmation agree.
  static func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  /// Home destination, named for the tab it configures. Root Settings rows name their destination,
  /// so the group they sit in carries no header of its own.
  public static let homeScreenRowTitle = "Home"
  public static let homeScreenRowDetail = "Sections, order and taps"
  /// The app ships open-source packages whose MIT/BSD-3 notices must accompany the binary.
  public static let acknowledgementsRowTitle = "Acknowledgements"
  public static let acknowledgementsRowDetail = "Open-source licences"

  public static let homeSectionsHeader = "Sections"
  public static let continueListeningHeader = "Continue Listening & Reading"
  public static let continueCardOpenOnTapTitle = "Open Immediately"
  public static let continueCardOpenOnTapFooter =
    "Tapping a card resumes playback or opens the reader. When off, it opens item details instead."
  public static let moveSectionUp = "Move Up"
  public static let moveSectionDown = "Move Down"

  public static let logoutTitle = "Log Out?"
  /// Account removal cancels every marked background transfer before it deletes rows and files,
  /// so the warning covers a download still running as well as finished ones.
  public static let logoutMessage =
    "This signs you out, cancels any download still in progress, removes every downloaded book from this device, and discards any offline listening progress that hasn't yet synced to the server."
  public static let confirmLogout = "Log Out"
  public static let cancel = "Cancel"

  /// `AccountRemovalError.deletionFailed`: a blocking, retryable local failure. The durable removal
  /// journal survives it, so retrying re-attempts the same sequence.
  public static let logoutFailedTitle = "Couldn't Finish Logging Out"
  public static let logoutFailedMessage =
    "Couldn’t remove all local account data. Try again."
  public static let retryLogout = "Try Again"
}
