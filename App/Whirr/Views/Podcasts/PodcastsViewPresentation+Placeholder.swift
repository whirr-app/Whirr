import AppModel
import Persistence

/// Which loading, empty or error state the Podcasts root shows, and where it sits.
nonisolated extension PodcastsViewPresentation {
  /// The full-screen loading state belongs to a screen with nothing at all to show yet, so it
  /// requires all three models to still be loading. Gating on "any model is loading" instead
  /// would let the slowest source blank out sections that already have content.
  static func isLoading(
    continueListening: HomeModel.State,
    latestEpisodes: HomeMoreModel.State,
    shows: PodcastShowsModel.State
  ) -> Bool {
    continueListening == .loading && latestEpisodes == .loading && shows == .loading
  }

  nonisolated enum PlaceholderAction: Equatable {
    case retry

    var label: String { "Retry" }
  }

  /// The root always owns one vertical scroll surface. A failed shows observation only becomes a
  /// full-screen state when neither of the other two podcast projections has anything to render.
  nonisolated enum Placeholder: Equatable {
    case loading
    case empty
    case error(action: PlaceholderAction)

    /// Loading and empty promise pull-to-refresh. The error has an explicit Retry button and
    /// therefore remains interactive.
    var allowsHitTesting: Bool {
      if case .error = self { return true }
      return false
    }

    var action: PlaceholderAction? {
      if case .error(let action) = self { return action }
      return nil
    }
  }

  static func placeholder(
    continueListening: HomeModel.State,
    latestEpisodes: HomeMoreModel.State,
    shows: PodcastShowsModel.State,
    hasContent: Bool
  ) -> Placeholder? {
    placeholder(
      for: .all,
      continueListening: continueListening,
      latestEpisodes: latestEpisodes,
      shows: shows,
      hasContent: hasContent)
  }

  static func placeholder(
    for filter: Filter,
    continueListening: HomeModel.State,
    latestEpisodes: HomeMoreModel.State,
    shows: PodcastShowsModel.State,
    nativeShows: NativePodcastShowsModel.State = .empty,
    rssDownloadsHaveLoaded: Bool = true,
    nativeSubscriptionsEnabled: Bool = true,
    hasIncludedPodcastLibrary: Bool = true,
    hasContent: Bool
  ) -> Placeholder? {
    let nativeRows = Self.nativeShows(in: nativeShows)
    let serverRows = PodcastsViewPresentation.shows(in: shows)
    let showsStatus = showsSectionStatus(
      nativeShows: nativeRows,
      nativeState: nativeShows,
      serverShows: serverRows,
      serverState: shows,
      nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
      hasIncludedPodcastLibrary: hasIncludedPodcastLibrary)

    switch filter {
    case .all:
      if hasContent == false {
        // Keep the root's original empty-screen barrier for the two episode shelves: an empty
        // show projection does not prove that there is no Podcasts content while either shelf is
        // still observing. Disabled native and excluded server projections are already reported
        // as settled by `showsSectionStatus`, so they do not hold this barrier open.
        if showsStatus == .loading || continueListening == .loading || latestEpisodes == .loading {
          return .loading
        }
      }
      guard hasContent == false else { return nil }
      return showsStatus == .error ? .error(action: .retry) : .empty

    case .yourShows:
      if showsStatus == .loading, hasContent == false { return .loading }
      if showsStatus == .error { return .error(action: .retry) }
      return hasContent ? nil : .empty

    case .downloaded:
      guard hasContent == false else { return nil }
      let nativeLoading = nativeSubscriptionsEnabled && nativeShows == .loading
      let serverLoading = hasIncludedPodcastLibrary && Self.serverStateIsLoading(shows)
      if serverLoading || nativeLoading || rssDownloadsHaveLoaded == false {
        return .loading
      }
      if hasIncludedPodcastLibrary, shows == .error { return .error(action: .retry) }
      return .empty
    }
  }

  private static func nativeShows(in state: NativePodcastShowsModel.State) -> [ItemSummary] {
    switch state {
    case .loaded(let snapshot): snapshot.shows
    case .loading, .empty: []
    }
  }
}
