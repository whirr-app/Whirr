enum PodcastAccessibilityID {
  /// The Podcasts root's `MediaFilterPicker`; Home and Saved for Later keep their own.
  static let filterPicker = "podcasts.filterPicker"
  static let notificationOffer = "podcasts.notificationOffer"
  static let notificationOfferAccept = "podcasts.notificationOffer.accept"
  static let notificationOfferDecline = "podcasts.notificationOffer.decline"
  static let showHeader = "podcast.show.header"
  static let episodeSearchField = "podcast.show.episode-search"
  static let showFilter = "podcast.show.filter"
  static let episodeList = "podcast.show.episodes"
  static let showOptions = "podcast.show.options"
  static let showStateIndicator = "podcast.show.state-indicator"
  /// Up Next belongs to the player, so its identifiers live in `PlayerAccessibilityID`.
  static let screenIdentifiers = [
    showHeader, episodeSearchField, showFilter, episodeList, showOptions, showStateIndicator,
  ]

  /// The show page's selection extras. They root on
  /// `SelectionChromePresentation.Screen.podcastEpisodes`' prefix, which the shared toolbar
  /// uses for its own controls.
  static let selectionDownload = "podcast.selection.download"
  static let selectionMarkAsFinished = "podcast.selection.markAsFinished"
  static let selectionCancelServerSave = "podcast.selection.cancelServerSave"
  static let selectionSaveToServer = "podcast.selection.saveToServer"
  static let selectionActions = "podcast.selection.actions"
  static let selectionRemoveDownloads = "podcast.selection.removeDownloads"

  static func episodeRow(showID: String, episodeID: String) -> String {
    "podcast.show.\(showID).episode.\(episodeID)"
  }
}
