import AppModel
import Foundation
import Persistence

nonisolated extension PodcastShowViewPresentation {
  /// The bar's title until the show's name is known: a seedless route learns it after the first
  /// frame.
  static let navigationTitle = "Podcast"

  /// The bar names the show for the whole visit and is never tied to scroll position: every
  /// change of bar title relays out the navigation bar, which would cost a layout on every fling
  /// across the header.
  static func navigationTitle(showTitle: String?) -> String {
    guard let showTitle = showTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      showTitle.isEmpty == false
    else { return navigationTitle }
    return showTitle
  }

  nonisolated enum ScreenPlaceholder: Equatable {
    case loading
    case notFound

    var allowsHitTesting: Bool { false }
  }

  /// The header already names the show, so the bar repeats it only once that name is off screen.
  /// While the show is still loading its header is about to arrive, so the bar waits rather than
  /// naming it for a frame; a show that is not found gets no header, so the bar names it.
  static func showsBarTitle(screenPlaceholder: ScreenPlaceholder?, isHeaderTitleVisible: Bool)
    -> Bool
  {
    switch screenPlaceholder {
    case .loading: false
    case .notFound: true
    case nil: isHeaderTitleVisible == false
    }
  }

  static func screenPlaceholder(for state: ItemDetailModel.State) -> ScreenPlaceholder? {
    switch state {
    case .loading: .loading
    case .notFound: .notFound
    case .loaded: nil
    }
  }

  struct Content: Equatable {
    let episodeIDs: [String]
    let stateText: String
  }

  /// What the show screen renders where the episode list would be. `nil` means "render the list".
  nonisolated enum ListPlaceholder: Equatable {
    case loading(message: String)
    case empty(title: String, message: String, systemImage: String)

    var message: String {
      switch self {
      case .loading(let message): message
      case .empty(_, let message, _): message
      }
    }
  }

  /// The show's state as a toolbar glyph, or `nil` for a state with nothing to report.
  ///
  /// A toolbar glyph, not a list caption, which would reflow every row as `.loading` →
  /// `.refreshing` → settled passes. Transient states get nothing.
  struct StateIndicator: Equatable {
    let systemImage: String
    let title: String
    /// The state's own `copyText`, not a second wording of it.
    let message: String
  }

  static func stateIndicator(for state: PodcastShowModel.State) -> StateIndicator? {
    switch state {
    // Nothing to say, or nothing worth saying for the instant it is true.
    case .loading, .refreshing, .loaded, .empty:
      return nil
    case .staleOffline:
      return StateIndicator(
        systemImage: "wifi.slash", title: "Showing Cached Episodes", message: state.copyText)
    case .recoverableError:
      return StateIndicator(
        systemImage: "exclamationmark.triangle", title: "Couldn't Load Episodes",
        message: state.copyText)
    case .partiallyDecoded:
      return StateIndicator(
        systemImage: "exclamationmark.circle", title: "Some Episodes Are Incomplete",
        message: state.copyText)
    }
  }

  static func content(
    state: PodcastShowModel.State, episodes: [PodcastEpisodeSummary]
  ) -> Content {
    Content(episodeIDs: episodes.map(\.id), stateText: state.copyText)
  }

  /// An empty filtered list is not an empty cache: with episodes cached and none matching, the
  /// filter is what to explain. Only an empty cache gets the state-derived placeholder.
  ///
  /// Nothing above a list that has rows (state copy would flash and reflow within ~0.1s of
  /// opening), nor before the local cache read answers (a spinner would only flash). The spinner
  /// stays for a cache that answered empty.
  static func placeholder(
    state: PodcastShowModel.State,
    hasReadEpisodeCache: Bool = true,
    episodeCount: Int,
    filteredEpisodeCount: Int,
    filter: PodcastEpisodeFilter,
    query: String = ""
  ) -> ListPlaceholder? {
    guard hasReadEpisodeCache, filteredEpisodeCount == 0 else { return nil }
    guard episodeCount == 0 else {
      return .empty(
        title: PodcastShowListCopy.noMatchingEpisodesTitle,
        message: PodcastShowListCopy.noMatches(filter, query: query),
        systemImage: PodcastShowListCopy.noMatchingEpisodesSystemImage)
    }
    switch state {
    case .loading, .refreshing:
      return .loading(message: state.copyText)
    case .empty, .loaded, .staleOffline, .recoverableError, .partiallyDecoded:
      let message = state.copyText.isEmpty ? PodcastShowModel.State.empty.copyText : state.copyText
      return .empty(
        title: PodcastShowListCopy.noEpisodesTitle,
        message: message,
        systemImage: PodcastShowListCopy.noEpisodesSystemImage)
    }
  }
}
