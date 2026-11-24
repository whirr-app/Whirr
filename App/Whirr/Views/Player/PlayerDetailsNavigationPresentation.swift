import AppModel
import Foundation
import Persistence

/// Where the expanded player's View Details entry goes, and whether it has anywhere to go at all.
///
/// A book has a pushed item-detail route, so the player collapses to reveal it. An episode has no
/// page: its details are the episode card, a sheet over the player like Chapters and History,
/// since the show page would duplicate the byline, which already opens it. Kept apart from
/// `PlayerBylineNavigationPresentation` ("who made this" versus "what is this") so neither
/// silently retargets the other.
enum PlayerDetailsNavigationPresentation {
  enum Destination: Equatable {
    case itemDetail(itemID: String)
    case episodeCard(NavigationModel.PodcastEpisodeRef)
  }

  static func destination(itemID: String, episodeID: String?) -> Destination? {
    guard itemID.isEmpty == false else { return nil }
    guard let episodeID, episodeID.isEmpty == false else {
      return .itemDetail(itemID: itemID)
    }
    return .episodeCard(NavigationModel.PodcastEpisodeRef(itemID: itemID, episodeID: episodeID))
  }

  /// Whether the destination is already what collapsing would reveal: the player often rises over
  /// its own detail screen, and pushing again would stack the page on itself. Only the top of the
  /// stack counts; a buried screen is a real navigation. An episode card is never already showing,
  /// being raised over the player.
  static func isAlreadyShowing(
    _ destination: Destination,
    path: [NavigationModel.Route]
  ) -> Bool {
    switch destination {
    case .itemDetail(let itemID):
      guard let top = path.last, case .itemDetail(let topItemID, _) = top else { return false }
      return topItemID == itemID
    case .episodeCard:
      return false
    }
  }

  /// The route to install for a book. Seeded from the player's loaded summary when it has one,
  /// the way every card tap seeds its push (`PodcastNavigationPresentation.route(item:)`), so the
  /// page beneath the player is complete on its first frame rather than a spinner that swaps for
  /// content while the player is still leaving.
  static func route(itemID: String, seed: ItemSummary?) -> NavigationModel.Route {
    .itemDetail(itemID: itemID, seed: seed)
  }

  /// How the player should leave for this destination.
  ///
  /// A book's page shares the player's cover, title and wash, so a slide reads as the cover
  /// jumping and the player dissolves instead. That needs the page beneath complete at fade start:
  /// already the stack top, or a seeded push; an unseeded push (summary not loaded) keeps the
  /// slide, as a fade onto a spinner is worse. At regular width (ADR 0008) item detail is a
  /// shell-level card that rises after the collapse onto the section root, so a dissolve would
  /// fade into the wrong page and the card keeps the slide. An episode card never collapses
  /// through this entry.
  static func collapseStyle(
    for destination: Destination,
    itemDetailPresentation: NavigationModel.ItemDetailPresentation,
    isSeeded: Bool,
    isAlreadyShowing: Bool
  ) -> NavigationModel.PlayerCollapseStyle {
    guard case .itemDetail = destination, itemDetailPresentation == .push else { return .slide }
    return isSeeded || isAlreadyShowing ? .dissolve : .slide
  }

  static func accessibilityHint(for destination: Destination) -> String {
    switch destination {
    case .itemDetail: "Opens this title's details"
    case .episodeCard: "Opens this episode's details"
    }
  }
}
