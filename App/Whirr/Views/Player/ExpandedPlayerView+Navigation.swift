import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine

extension ExpandedPlayerView {
  var bylineDestination: PlayerBylineNavigationPresentation.Destination? {
    PlayerBylineNavigationPresentation.destination(
      itemID: itemID, episodeID: displayedEpisodeID, byline: author)
  }

  func openByline() {
    guard let bylineDestination else { return }
    switch bylineDestination {
    case .podcastShow:
      guard
        let destination = PlayerBylineNavigationPresentation.libraryDestination(
          for: bylineDestination)
      else { return }
      installBehindThePlayer(destination)
      navigation.collapsePlayer()
    case .author(let name):
      Task {
        guard
          let page = try? await authorSeriesReading.entities(
            kind: .author, libraryID: nil, limit: 50, offset: 0),
          let entity = PlayerBylineNavigationPresentation.authorEntity(
            named: name, among: page.entities)
        else { return }
        guard
          let destination = PlayerBylineNavigationPresentation.libraryDestination(
            for: bylineDestination, authorEntity: entity)
        else { return }
        installBehindThePlayer(destination)
        navigation.collapsePlayer()
      }
    }
  }

  private var detailsDestination: PlayerDetailsNavigationPresentation.Destination? {
    PlayerDetailsNavigationPresentation.destination(
      itemID: itemID, episodeID: displayedEpisodeID)
  }

  /// Leaves for a book's detail page, or raises an episode's card over this page. A book's page is
  /// pushed behind the player before the collapse (as `openByline` does), seeded from this page's
  /// summary, and the collapse is a dissolve (`PlayerDetailsNavigationPresentation.collapseStyle`);
  /// the mini bar carries the session, so the way back is one tap. An episode's card is a sheet
  /// hosted here (the `.sheet(item:)` in `body`).
  func openDetails() {
    guard let detailsDestination else { return }
    guard
      PlayerDetailsNavigationPresentation.isAlreadyShowing(
        detailsDestination, path: navigation.current.path) == false
    else {
      navigation.collapsePlayer(
        style: PlayerDetailsNavigationPresentation.collapseStyle(
          for: detailsDestination,
          itemDetailPresentation: navigation.itemDetailPresentation,
          isSeeded: false, isAlreadyShowing: true))
      return
    }
    switch detailsDestination {
    case .itemDetail(let itemID):
      let seed = loadedSummary
      pushDetailsBehindThePlayer(
        PlayerDetailsNavigationPresentation.route(itemID: itemID, seed: seed))
      navigation.collapsePlayer(
        style: PlayerDetailsNavigationPresentation.collapseStyle(
          for: detailsDestination,
          itemDetailPresentation: navigation.itemDetailPresentation,
          isSeeded: seed != nil, isAlreadyShowing: false))
    case .episodeCard(let ref):
      guard episodeCard != nil else { return }
      presentedEpisodeCard = ref
    }
  }

  /// Installs the detail route with its push animation suppressed, so the page is in place when
  /// the player uncovers it. `PlayerPresentationController.shouldRemovePresentersView` is `false`,
  /// so the live shell shows through as the player leaves and an animated push would slide in
  /// from the trailing edge behind it. `openByline` does the same through
  /// `installBehindThePlayer` (its Library destination, already visible, has no tab change to
  /// hide the push). The collapse lands in the same update and this transaction would make UIKit
  /// cut it; `InteractivePlayerPresentation` re-enables animations around its own `dismiss`, so
  /// push-then-collapse is safe.
  func pushDetailsBehindThePlayer(_ route: NavigationModel.Route) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      navigation.revealFromPlayer(route)
    }
  }

  /// The section-replacing form of `pushDetailsBehindThePlayer`, for the byline. When the byline's
  /// section is already the visible tab, an animated path replacement plays behind the departing
  /// player as an animated push does, and racing the collapse could leave the pushed show page
  /// drawn as a bare title over an empty screen.
  private func installBehindThePlayer(_ destination: NavigationModel.Destination) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      navigation.navigate(to: destination)
    }
  }

  /// The item-detail fetch's result for this item, for seeding the page View Details pushes.
  /// The identity check is `liveArtworkSource`'s: a queue transition must never seed one item's
  /// page with another item's summary.
  private var loadedSummary: ItemSummary? {
    guard case .loaded(let item) = itemModel?.state, item.serverItemId == itemID else {
      return nil
    }
    return item
  }
}
