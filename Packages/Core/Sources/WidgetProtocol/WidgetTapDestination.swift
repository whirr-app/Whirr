import Foundation

/// Where a tap on a widget or the sleep-timer Live Activity opens the app. The extension builds
/// these links and the app parses them, so both sides share one format:
///
///     whirr://widget/item/<token>     a title on a shelf, by its opaque per-publication token
///     whirr://widget/player           the expanded player
///     whirr://widget/stats            the Stats screen
///     whirr://widget/new-episodes     the Latest Episodes list
///     whirr://widget/smart-list/<id>  a smart list's screen, by its device-local row id
///
/// A link names no server identifier; the app resolves a token through its account-stamped token
/// map, and a list id only against the device's own lists. Any app or web page can open the scheme, so parsing accepts only these forms and resolving
/// a link only ever navigates.
public enum WidgetTapDestination: Sendable, Equatable, Hashable {
  case item(token: String)
  case player
  case listeningStats
  case latestEpisodes
  case smartList(id: Int64)

  static let scheme = "whirr"
  static let host = "widget"
  private static let itemComponent = "item"
  private static let playerComponent = "player"
  private static let statsComponent = "stats"
  private static let latestEpisodesComponent = "new-episodes"
  private static let smartListComponent = "smart-list"

  /// `nil` only for an item whose token fails validation, which no published snapshot carries.
  public var url: URL? {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = Self.host
    components.path = "/" + pathComponents.joined(separator: "/")
    return Self.isValid(self) ? components.url : nil
  }

  public init?(url: URL) {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == Self.scheme,
      components.percentEncodedHost?.lowercased() == Self.host,
      components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
      components.port == nil, components.percentEncodedQuery == nil,
      components.percentEncodedFragment == nil
    else { return nil }

    // The raw path: a percent escape is refused outright rather than decoded into something
    // that might then pass, and no component may be empty (a doubled or trailing slash).
    let path = components.percentEncodedPath
    guard path.hasPrefix("/") else { return nil }
    let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !parts.contains(where: \.isEmpty) else { return nil }

    let destination: WidgetTapDestination
    switch parts {
    case [Self.playerComponent]: destination = .player
    case [Self.statsComponent]: destination = .listeningStats
    case [Self.latestEpisodesComponent]: destination = .latestEpisodes
    case let pair where pair.count == 2 && pair[0] == Self.itemComponent:
      destination = .item(token: pair[1])
    case let pair where pair.count == 2 && pair[0] == Self.smartListComponent:
      guard let id = WidgetSmartListID.parse(pair[1]) else { return nil }
      destination = .smartList(id: id)
    default: return nil
    }
    guard Self.isValid(destination) else { return nil }
    self = destination
  }

  private var pathComponents: [String] {
    switch self {
    case .item(let token): [Self.itemComponent, token]
    case .player: [Self.playerComponent]
    case .listeningStats: [Self.statsComponent]
    case .latestEpisodes: [Self.latestEpisodesComponent]
    case .smartList(let id): [Self.smartListComponent, WidgetSmartListID.string(id)]
    }
  }

  private static func isValid(_ destination: WidgetTapDestination) -> Bool {
    switch destination {
    case .item(let token): (try? WidgetValidation.validateToken(token)) != nil
    case .smartList(let id): WidgetSmartListID.isValid(id)
    case .player, .listeningStats, .latestEpisodes: true
    }
  }
}
