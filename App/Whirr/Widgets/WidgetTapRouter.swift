import AppModel
import Foundation
import WidgetProtocol

/// What a widget or Live Activity tap does once the app is up. Every case only navigates: a link
/// can be opened by any app or web page once the scheme is registered, so nothing here plays,
/// changes or reveals anything.
enum WidgetTapAction: Equatable {
  case presentEpisode(NavigationModel.PodcastEpisodeRef)
  case itemDetail(itemID: String)
  case expandPlayer
  case listeningStats
  case latestEpisodes
  case smartList(id: Int64)
  case none
}

/// What the apply step reads from the live graph, captured when the tap is processed so a held
/// tap never acts on a composition that has since been replaced.
struct WidgetTapContext: Equatable {
  /// The mini player's own condition, which includes a retained last-played item.
  let hasNowPlaying: Bool
  /// Home's selected filter, so the Stats route equals the one the Home stats card pushes.
  let homeFilter: MediaFilter
  /// Without a Podcasts tab, selecting `.podcasts` would pick a tab that is not there.
  let showsPodcastsTab: Bool
}

enum WidgetTapRouter {
  /// A `nil` episode is a book by the publisher's convention; `.itemDetail` is also the safe
  /// fallback for anything else that arrives without one. A smart list row's card says which list
  /// it is playing from; a list link opens only a list the app last published, so a guessed id
  /// for a list that does not exist goes nowhere.
  static func action(
    for destination: WidgetTapDestination, selection: (String) -> CompanionSelection?,
    listSelection: (String) -> WidgetTokenMap.ListSelection? = { _ in nil },
    listName: (Int64) -> String? = { _ in nil }
  ) -> WidgetTapAction {
    switch destination {
    case .item(let token):
      if let selection = selection(token) {
        if let episodeID = selection.episodeID {
          return .presentEpisode(.init(itemID: selection.itemID, episodeID: episodeID))
        }
        return .itemDetail(itemID: selection.itemID)
      }
      guard let row = listSelection(token), let episodeID = row.selection.episodeID else { return .none }
      let context = listName(row.listID).map {
        NavigationModel.SmartListContext(listID: row.listID, name: $0)
      }
      return .presentEpisode(
        .init(itemID: row.selection.itemID, episodeID: episodeID, listContext: context))
    case .player: return .expandPlayer
    case .listeningStats: return .listeningStats
    case .latestEpisodes: return .latestEpisodes
    case .smartList(let id): return listName(id) == nil ? .none : .smartList(id: id)
    }
  }

  /// The card raises over the section the listener was on. The player is collapsed and Settings
  /// dismissed first, as the notification route does, so neither covers it.
  @MainActor
  static func apply(_ action: WidgetTapAction, to navigation: NavigationModel, context: WidgetTapContext) {
    switch action {
    case .presentEpisode(let ref):
      navigation.collapsePlayer()
      navigation.dismissSettings()
      navigation.presentEpisode(ref)
    case .itemDetail(let itemID):
      navigation.collapsePlayer()
      navigation.dismissSettings()
      navigation.navigate(to: .itemDetail(itemID: itemID))
    case .expandPlayer:
      guard context.hasNowPlaying else { return }
      navigation.dismissSettings()
      navigation.expandPlayer()
    case .listeningStats:
      navigation.collapsePlayer()
      navigation.navigate(
        to: NavigationModel.Destination(
          section: .home,
          path: [HomeViewPresentation.detailRoute(for: .listeningStats, selectedFilter: context.homeFilter)]))
    case .latestEpisodes:
      navigation.collapsePlayer()
      navigation.navigate(
        to: NavigationModel.Destination(
          section: context.showsPodcastsTab ? .podcasts : .home, path: [.latestEpisodes]))
    case .smartList(let id):
      navigation.collapsePlayer()
      navigation.dismissSettings()
      navigation.navigate(
        to: NavigationModel.Destination(
          section: context.showsPodcastsTab ? .podcasts : .home, path: [.smartList(id: id)]))
    case .none:
      break
    }
  }
}

/// Holds the latest tap until the library shell is mounted. `presentation == .shell` alone is not
/// enough: at a cold launch the shell presentation is already set while the library is still
/// loading, and navigation applied then would sit unseen and surface later.
@MainActor
final class WidgetTapInbox {
  private(set) var pending: WidgetTapDestination?

  func receive(_ destination: WidgetTapDestination) {
    pending = destination
  }

  /// The held tap, cleared as it is handed out, so delivery by both `onOpenURL` and the mount
  /// trigger applies it once.
  func take(isLibraryShellMounted: Bool) -> WidgetTapDestination? {
    guard isLibraryShellMounted, let pending else { return nil }
    self.pending = nil
    return pending
  }

  /// Logout and an account or endpoint rebuild: the token belongs to the old graph.
  func clear() {
    pending = nil
  }
}
