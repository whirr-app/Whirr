import AppModel
import Persistence

enum PodcastNavigationPresentation {
  static func route(itemID: String, category: ItemMediaCategory) -> NavigationModel.Route {
    switch category {
    case .podcast:
      return .podcastShow(itemID: itemID)
    case .audiobook, .ebook:
      return .itemDetail(itemID: itemID)
    }
  }

  static func route(
    item: ItemSummary,
    podcastFilter: PodcastEpisodeFilter? = nil
  ) -> NavigationModel.Route {
    switch item.category {
    case .podcast:
      return .podcastShow(
        itemID: item.serverItemId, filter: podcastFilter ?? .all, seed: item)
    case .audiobook, .ebook:
      return .itemDetail(itemID: item.serverItemId, seed: item)
    }
  }
}
