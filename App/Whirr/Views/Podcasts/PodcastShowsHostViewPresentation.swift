import AppModel

/// Pure presentation decisions for the combined all-shows destination. The route remains the
/// source of truth for the first tab: a deep link to `your-shows` must still mean Followed, while
/// the older `podcast-shows` token must still mean On your server.
nonisolated enum PodcastShowsHostViewPresentation {
  nonisolated enum Source: String, CaseIterable, Hashable, Sendable {
    case followed
    case server

    var label: String {
      switch self {
      case .followed: NativePodcastShowsViewPresentation.navigationTitle
      case .server: PodcastsViewPresentation.serverProvenanceLabel
      }
    }
  }

  static let navigationTitle = PodcastsViewPresentation.showsSectionTitle
  static let sourcePickerLabel = "Show source"

  static func initialSource(for route: NavigationModel.Route) -> Source {
    switch route {
    case .nativePodcastShows: .followed
    case .podcastShows: .server
    default: .server
    }
  }

  /// Native disable is live state rather than a persisted tab preference. A server-origin route
  /// remains mounted and must land on the server collection; a native-origin route is normally
  /// removed by `RootModel`, but returning server here makes the host safe during that transition.
  static func source(
    for route: NavigationModel.Route, nativeSubscriptionsEnabled: Bool
  ) -> Source {
    let requested = initialSource(for: route)
    return nativeSubscriptionsEnabled || requested == .server ? requested : .server
  }

  static func sourceIsAvailable(
    _ source: Source, nativeSubscriptionsEnabled: Bool
  ) -> Bool {
    source == .server || nativeSubscriptionsEnabled
  }

  /// The root heading keeps one callback while retaining both historical route identities. A
  /// followed collection gets the native token so a heading tap opens Followed; when that source
  /// is disabled or has no rows, the server token opens On your server instead.
  static func headingRoute(
    nativeSubscriptionsEnabled: Bool, hasFollowedShows: Bool
  ) -> NavigationModel.Route {
    nativeSubscriptionsEnabled && hasFollowedShows ? .nativePodcastShows : .podcastShows
  }

  static func isNativeOriginating(_ route: NavigationModel.Route) -> Bool {
    initialSource(for: route) == .followed
  }
}

/// A child-owned edit session or alert is local `@State`, so the host cannot infer it from the
/// picker binding. Children register a synchronous preparation hook while mounted; the host asks
/// that hook before changing source. A false result leaves the confirmation visible and leaves the
/// picker on its current tab.
@MainActor
final class PodcastShowsSourceSwitchGate {
  typealias Preparation = () -> Bool

  private var handlers: [PodcastShowsHostViewPresentation.Source: Preparation] = [:]

  func register(
    source: PodcastShowsHostViewPresentation.Source, prepare: @escaping Preparation
  ) {
    handlers[source] = prepare
  }

  func unregister(source: PodcastShowsHostViewPresentation.Source) {
    handlers[source] = nil
  }

  func prepare(source: PodcastShowsHostViewPresentation.Source) -> Bool {
    handlers[source]?() ?? true
  }
}
