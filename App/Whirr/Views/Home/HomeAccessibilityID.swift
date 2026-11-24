import AppModel

/// Semantic accessibility identifiers for the Home screen, so tests and UI automation can address
/// these controls by stable name rather than view-tree position.
enum HomeAccessibilityID {
  /// `MediaFilterPicker` (All/Audiobooks/Podcasts/eBooks).
  static let filterPicker = "home.filterPicker"

  static let sectionContinueListening = "home.section.continueListening"
  static let sectionContinueReading = "home.section.continueReading"
  static let sectionContinueSeries = "home.section.continueSeries"
  static let sectionNewEpisodes = "home.section.newEpisodes"
  static let sectionRecentlyAdded = "home.section.recentlyAdded"
  static let sectionDownloaded = "home.section.downloaded"
  static let sectionSavedForLater = "home.section.savedForLater"
  static let sectionListeningStats = "home.section.listeningStats"
  static let sectionSmartLists = "home.section.smartLists"
  static let listeningStatsCard = "home.listeningStats.card"

  /// Top-to-bottom default order when every section is present, matching
  /// `HomeViewPresentation.sections`' fixed ordering.
  static let sectionOrder: [String] = [
    sectionContinueListening,
    sectionContinueReading,
    sectionContinueSeries,
    sectionNewEpisodes,
    sectionRecentlyAdded,
    sectionDownloaded,
    sectionSavedForLater,
    sectionListeningStats,
    sectionSmartLists,
  ]

  static func sectionIdentifier(for kind: HomeViewPresentation.Section.Kind) -> String {
    switch kind {
    case .continueListening: sectionContinueListening
    case .continueReading: sectionContinueReading
    case .continueSeries: sectionContinueSeries
    case .newEpisodes: sectionNewEpisodes
    case .recentlyAdded: sectionRecentlyAdded
    case .downloaded: sectionDownloaded
    case .savedForLater: sectionSavedForLater
    case .listeningStats: sectionListeningStats
    case .smartLists: sectionSmartLists
    }
  }

  /// One `HomeCardView`'s identifier is this prefix plus the item's own `serverItemId`.
  static let cardRowPrefix = "home.card."

  static func cardIdentifier(itemID: String) -> String {
    cardRowPrefix + itemID
  }

  /// Episode identity includes both the parent show and episode so two saved episodes from one
  /// podcast remain independently addressable.
  static func episodeCardIdentifier(itemID: String, episodeID: String) -> String {
    cardRowPrefix + itemID + "/" + episodeID
  }

  static let moreItemRowPrefix = "home.more.item."
  static let morePodcastRowPrefix = "home.more.podcast."

  static let removeFromContinueListeningAction = "home.action.removeFromContinueListening"

  /// Home More's selection extras. They root on `SelectionChromePresentation.Screen.homeContinue`'s
  /// prefix, which the shared toolbar uses for its own controls.
  static let selectionDownload = "homeMore.selection.download"
  static let selectionActions = "homeMore.selection.actions"
  static let selectionRemoveFromShelf = "homeMore.selection.removeFromShelf"
}
