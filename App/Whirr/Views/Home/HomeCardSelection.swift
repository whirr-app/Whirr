import AppModel
import Persistence

/// The one tap target shared by every Continue Listening card. Home defines the product behavior;
/// other browse surfaces resolve through this type so they cannot quietly return to navigation.
nonisolated struct ContinueListeningCardSelection: Sendable, Equatable {
  let itemID: String
  let episodeID: String?

  static func target(for item: HomeItem) -> Self {
    Self(itemID: item.serverItemId, episodeID: item.episodeID)
  }
}

/// Pure routing decision for a Home item card. The screen remains responsible for performing the
/// navigation through its injected callbacks.
///
/// `opensContinueCardImmediately` is one preference across both continuation shelves (a tap enters
/// the content or opens details), so neighbouring shelves never differ.
nonisolated enum HomeCardSelection: Sendable, Equatable {
  case item(ItemSummary)
  case downloadedPodcast(ItemSummary)
  case episode(itemID: String, episodeID: String)
  case resume(itemID: String, episodeID: String?)
  case read(itemID: String, title: String, category: ItemMediaCategory)

  static func destination(
    for item: HomeItem,
    in section: HomeMoreSection,
    opensContinueCardImmediately: Bool = true
  ) -> Self {
    if opensContinueCardImmediately {
      if HomeViewPresentation.cardOpensReader(for: section) {
        return .read(itemID: item.serverItemId, title: item.title, category: item.category)
      }
      if HomeViewPresentation.cardResumesPlayback(for: item.category, in: section) {
        let target = ContinueListeningCardSelection.target(for: item)
        return .resume(itemID: target.itemID, episodeID: target.episodeID)
      }
    }
    if item.category == .podcast, section == .downloaded {
      return .downloadedPodcast(item.itemSummary)
    }
    if item.category == .podcast, let episodeID = item.episodeID {
      return .episode(itemID: item.serverItemId, episodeID: episodeID)
    }
    return .item(item.itemSummary)
  }
}
