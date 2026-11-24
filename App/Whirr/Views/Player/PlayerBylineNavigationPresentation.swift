import AppModel
import Foundation
import Persistence

/// The expanded player's byline is a show name for podcast episodes and an author name for books.
/// Keeping that distinction here lets the view expose one button without guessing from copy.
enum PlayerBylineNavigationPresentation {
  enum Destination: Equatable {
    case podcastShow(itemID: String)
    case author(named: String)
  }

  static func destination(itemID: String, episodeID: String?, byline: String?) -> Destination? {
    guard let byline = byline?.trimmingCharacters(in: .whitespacesAndNewlines), byline.isEmpty == false
    else { return nil }
    if episodeID != nil { return .podcastShow(itemID: itemID) }
    return .author(named: byline)
  }

  /// The minified item projection can join multiple authors into one byline. Try the complete
  /// value first (for names which themselves contain commas), then its displayed components.
  static func authorEntity(
    named byline: String, among entities: [AuthorSeriesEntity]
  ) -> AuthorSeriesEntity? {
    for candidate in LibraryEntityGrouping.authorNames(from: byline) {
      if let match = entities.first(where: { namesMatch($0.name, candidate) }) { return match }
    }
    return nil
  }

  static func accessibilityHint(for destination: Destination) -> String {
    switch destination {
    case .podcastShow: "Opens this show in Library"
    case .author: "Opens this author in Library"
    }
  }

  static func libraryDestination(
    for destination: Destination, authorEntity: AuthorSeriesEntity? = nil
  ) -> NavigationModel.Destination? {
    let route: NavigationModel.Route
    switch destination {
    case .podcastShow(let itemID):
      route = .podcastShow(itemID: itemID)
    case .author:
      guard let authorEntity else { return nil }
      route = .author(
        id: authorEntity.entityID, libraryID: authorEntity.libraryID,
        seed: AuthorSeriesDestinationSeed(entity: authorEntity))
    }
    return NavigationModel.Destination(section: .library, path: [route])
  }

  private static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(
      rhs,
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      range: nil,
      locale: .current) == .orderedSame
  }
}
