/// Semantic accessibility identifiers for item detail, Settings, and the downloads, storage,
/// resolution and removal screens, for tests and UI automation (same convention as `PlayerAccessibilityID`). Each `*Order` array
/// is the screen's top-to-bottom VoiceOver/keyboard order, assertable without rendering.
enum ScreenAccessibilityID {

  // MARK: - Item detail (hero, play button, download control cluster)

  /// The glass download bubble in the navigation bar's trailing toolbar item.
  static let itemDetailDownloadControl = "itemDetail.downloadControl"
  /// The accent-tinted, full-width play/resume/pause button.
  static let itemDetailPlayButton = "itemDetail.playButton"
  static let itemDetailHistoryList = "itemDetail.historyList"
  static let itemDetailHistoryRowPrefix = "itemDetail.historyRow."

  /// The download control sits in the navigation bar's toolbar, above the scrollable body, so it
  /// leads this order. The hero carries no offline badge; the toolbar bubble states download state.
  static let itemDetailOrder: [String] = [
    itemDetailDownloadControl,
    itemDetailPlayButton,
  ]

  // MARK: - Browse/search row offline badge

  static let libraryRowOfflineBadgePrefix = "libraryRow.offlineBadge."

  // MARK: - Storage screen

  static let storageScreen = "storage.screen"
  static let storageTotals = "storage.totals"
  static let storageCeilingSummary = "storage.ceilingSummary"
  static let storageList = "storage.list"
  static let storageRowPrefix = "storage.row."
  static let storageEpisodeRowPrefix = "storage.episodeRow."
  static let storageDeleteAllButton = "storage.deleteAllButton"
  /// The removed-episode reclaim action, offered in the totals card only while something is
  /// stranded behind a soft-deleted podcast episode.
  static let storageReclaimEpisodesButton = "storage.reclaimEpisodesButton"
  /// Selection extras root on `SelectionChromePresentation.Screen.downloads`' prefix, which the
  /// shared toolbar uses for its own controls, rather than on `storage.`.
  static let storageSelectionRemove = "downloads.selection.remove"

  static let storageOrder: [String] = [
    storageTotals,
    storageCeilingSummary,
    storageList,
  ]

  // MARK: - Resolution center screen

  static let resolutionCenterScreen = "resolutionCenter.screen"
  static let resolutionCenterList = "resolutionCenter.list"
  static let resolutionCenterEmptyState = "resolutionCenter.emptyState"
  static let resolutionCenterRowPrefix = "resolutionCenter.row."

  // MARK: - Settings additions

  static let settingsCellularToggle = "settings.cellularToggle"
  static let settingsDeleteWhenFinishedToggle = "settings.deleteWhenFinishedToggle"
  static let settingsQueueAutoDownloadPicker = "settings.queueAutoDownloadPicker"
  static let settingsSavedShelfAutoDownloadPicker = "settings.savedShelfAutoDownloadPicker"
  static let settingsStorageLimitLink = "settings.storageLimitLink"
  static let settingsStorageLimitScreen = "settings.storageLimit.screen"
  static let settingsStorageLimitSummary = "settings.storageLimit.summary"
  static let settingsStorageLimitSlider = "settings.storageLimit.slider"
  static let settingsStorageLimitManageDownloadsLink = "settings.storageLimit.manageDownloadsLink"
  static let settingsStorageLink = "settings.storageLink"
  static let settingsResolutionCenterLink = "settings.resolutionCenterLink"
  static let settingsLogoutButton = "settings.logoutButton"
  /// The Settings root's Podcasts row, leading to `PodcastSettingsView`.
  static let settingsPodcastsLink = "settings.podcastsLink"
  /// The Settings root's Home Screen row, leading to `HomeSettingsView`'s section list.
  static let settingsHomeScreenLink = "settings.homeScreenLink"
  /// The Settings root's Downloads row, leading to `DownloadSettingsView`.
  static let settingsDownloadsLink = "settings.downloadsLink"
  static let settingsReduceAdsLink = "settings.reduceAdsLink"
  /// The Settings root's device-local library-selection destination.
  static let settingsLibrariesLink = "settings.librariesLink"
  static let settingsLibrariesScreen = "settings.libraries.screen"
  static let settingsLibraryTogglePrefix = "settings.library.toggle."
  /// The Settings root's read-only Server & Account row.
  static let settingsServerAccountLink = "settings.serverAccountLink"
  static let serverAddressesLink = "settings.serverAddressesLink"
  static let serverAddressRowPrefix = "settings.serverAddress.row."
  static let serverAddressAddButton = "settings.serverAddress.add"
  static let serverAddressError = "settings.serverAddress.error"
  static let serverAddressUsername = "settings.serverAddress.username"
  static let serverAddressPassword = "settings.serverAddress.password"
  static let serverAddressAPIToken = "settings.serverAddress.apiToken"
  /// The destructive cover-cache clear in Downloads' storage group.
  static let settingsClearArtworkButton = "settings.clearArtworkButton"
  static let homeSectionRowPrefix = "settings.homeSectionRow."

  /// `DownloadSettingsView`'s top-to-bottom order. Delete After Playing closes the automatic
  /// group, and the Storage Limit link sits directly above the Manage Downloads row that frees
  /// space, which is followed by the cover-cache clear.
  static let settingsDownloadsCardOrder: [String] = [
    settingsCellularToggle,
    settingsQueueAutoDownloadPicker,
    settingsSavedShelfAutoDownloadPicker,
    settingsDeleteWhenFinishedToggle,
    settingsStorageLimitLink,
    settingsStorageLink,
    settingsClearArtworkButton,
    settingsResolutionCenterLink,
  ]

  // MARK: - Removal-pending screen

  static let removalPendingScreen = "removalPending.screen"
  static let removalPendingRetryButton = "removalPending.retryButton"
}
