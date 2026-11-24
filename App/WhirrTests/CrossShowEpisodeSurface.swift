import AppModel
import Foundation
import Persistence

@testable import Whirr

/// The five surfaces, outside the show screen and the Up Next queue, that render an episode
/// belonging to some show other than the one on screen. Each resolves a tap to the episode card.
/// `everyCrossShowEpisodeSurfaceOpensTheCard` walks this inventory, so a new surface that resolves
/// to a show push (or nothing) fails that test instead of being noticed on a device.
///
/// Test-only: no production view reads this inventory, so it lives beside the test that walks it.
nonisolated enum CrossShowEpisodeSurface: String, CaseIterable {
  case podcastsTabLatestEpisodeRow
  case homeNewEpisodeCard
  case homeMoreEpisodeRow
  case searchEpisodeResult
  /// A smart list's row. The ref carries the list, which the card shows and starts through.
  case smartListEpisodeRow

  /// A well-formed fixture for this surface, resolved through the function (or, where the model
  /// guarantees both ids, the field access) its view's tap closure uses. `nil` means the tap
  /// cannot open the card at all.
  var resolvedEpisodeRef: NavigationModel.PodcastEpisodeRef? {
    switch self {
    case .podcastsTabLatestEpisodeRow:
      let episode = Self.episodeFixture(itemID: "show-1", episodeID: "ep-1")
      return NavigationModel.PodcastEpisodeRef(itemID: episode.itemID, episodeID: episode.episodeID)
    case .homeNewEpisodeCard:
      let episode = Self.episodeFixture(itemID: "show-3", episodeID: "ep-3")
      return NavigationModel.PodcastEpisodeRef(itemID: episode.itemID, episodeID: episode.episodeID)
    case .homeMoreEpisodeRow:
      let episode = Self.episodeFixture(itemID: "show-4", episodeID: "ep-4")
      return NavigationModel.PodcastEpisodeRef(itemID: episode.itemID, episodeID: episode.episodeID)
    case .searchEpisodeResult:
      let row = SearchResultRow(
        kind: .episode, entityID: "ep-5", parentItemID: "show-5", title: "Episode", subtitle: nil,
        matchReason: nil, mediaCategory: nil, libraryID: "lib")
      return SearchViewPresentation.episodeRef(for: row)
    case .smartListEpisodeRow:
      let episode = Self.episodeFixture(itemID: "show-6", episodeID: "ep-6")
      return NavigationModel.PodcastEpisodeRef(
        itemID: episode.itemID, episodeID: episode.episodeID,
        listContext: NavigationModel.SmartListContext(listID: 1, name: "List"))
    }
  }

  private static func episodeFixture(itemID: String, episodeID: String) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: itemID, showTitle: "Show", showAuthor: "Publisher", episodeID: episodeID,
      title: "Episode", subtitle: nil, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      durationSeconds: 1_800)
  }
}
