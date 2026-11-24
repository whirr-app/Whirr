import AppModel
import Foundation
import Persistence

/// Every place in the app that raises the shared item menu, and so every place that can render a
/// podcast show or episode. A new section is a new case, and `everyPodcastSurfaceOffersAMenu`
/// fails until it has a menu.
///
/// Also the one rule for the suppression context a menu raises in: a call site names its UI
/// (`itemContextMenu(placement:)`), and `menuSurface` derives the `PodcastMenuSurface`;
/// `ItemMenuPlacementTests` ties every call site to its case.
///
/// Up Next is not listed: its queue sheet uses a media-neutral menu
/// (`ListeningQueueViewPresentation.contextActions`).
nonisolated enum PodcastMenuBearingSurface: String, CaseIterable {
  case homeItemCard
  case homeEpisodeCard
  case homeMoreRow
  case libraryBrowseRow
  case searchResultRow
  case podcastShowEpisodeRow
  case podcastsTabContinueListeningCard
  case podcastsTabLatestEpisodeRow
  case smartListEpisodeRow
  case podcastsTabShowTile
  /// The pushed all-shows page's tiles. Read-only mode raises the same show menu the root's
  /// preview tiles do; edit mode replaces it with reordering, because the tiles already own long
  /// press. That suppresses the interaction, not this surface's menu.
  case podcastAllShowsPageTile
  /// A Downloads screen row, which may be an episode of any show.
  case downloadsRow
  /// A Saved for Later row, which may be an episode of any show.
  case savedForLaterRow
  /// The item detail screen's overflow menu. It never carries an episode, so its surface is never
  /// read; it is listed so every entry point to the menu has a named caller.
  case itemDetail

  /// Whether this surface's rows can carry an episode identity. Show-level surfaces get the
  /// `.podcastShow` menu; the rest get the full episode list. `.homeItemCard` is an episode
  /// surface because Home's Continue Listening draws its episodes on that card.
  var isEpisodeSurface: Bool {
    switch self {
    case .libraryBrowseRow, .podcastsTabShowTile, .podcastAllShowsPageTile, .itemDetail:
      false
    case .homeItemCard, .homeEpisodeCard, .homeMoreRow, .searchResultRow, .podcastShowEpisodeRow,
      .podcastsTabContinueListeningCard, .podcastsTabLatestEpisodeRow, .smartListEpisodeRow,
      .downloadsRow, .savedForLaterRow:
      true
    }
  }

  /// The suppression context this surface raises its menu in. See
  /// `PodcastShowPresentation.suppressedActions(on:)`.
  var menuSurface: PodcastMenuSurface {
    switch self {
    case .podcastShowEpisodeRow: .show
    case .homeItemCard, .homeEpisodeCard, .podcastsTabContinueListeningCard,
      .podcastsTabShowTile, .podcastAllShowsPageTile:
      .card
    case .homeMoreRow, .libraryBrowseRow, .searchResultRow, .podcastsTabLatestEpisodeRow,
      .smartListEpisodeRow, .downloadsRow, .savedForLaterRow, .itemDetail:
      .episodeList
    }
  }
}
