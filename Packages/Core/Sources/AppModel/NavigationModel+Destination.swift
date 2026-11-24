import Foundation
import Persistence

extension NavigationModel {
  /// A deep-linkable place in the shell: which section, and how deep into it. Round-trips
  /// losslessly through `deepLinkPath` (property-tested in `NavigationModelTests`).
  public struct Destination: Sendable, Equatable, Hashable {
    public var section: Section
    public var path: [Route]

    public init(section: Section, path: [Route] = []) {
      self.section = section
      self.path = path
    }

    /// A stable string representation, safe to persist or hand back to `init(deepLinkPath:)`.
    /// Item ids are percent-escaped to alphanumerics, so no id can smuggle a `/` into the
    /// component structure.
    public var deepLinkPath: String {
      ([section.rawValue] + path.flatMap(\.deepLinkComponents)).joined(separator: "/")
    }

    public init?(deepLinkPath: String) {
      var components = deepLinkPath.components(separatedBy: "/")
      guard let sectionToken = components.first, let section = Section(rawValue: sectionToken) else {
        return nil
      }
      components.removeFirst()

      var path: [Route] = []
      while !components.isEmpty {
        // Every route kind contributes a fixed-arity component group; an odd tail or an
        // unrecognised kind means this isn't a link we wrote.
        switch components[0] {
        case Route.storageToken:
          path.append(.storage)
          components.removeFirst(1)
        case Route.resolutionCenterToken:
          path.append(.resolutionCenter)
          components.removeFirst(1)
        case Route.podcastShowPrefix:
          guard components.count >= 2 else { return nil }
          let escaped = components[1]
          path.append(.podcastShow(itemID: escaped.removingPercentEncoding ?? escaped))
          components.removeFirst(2)
        case Route.filteredPodcastShowPrefix:
          guard
            components.count >= 3,
            let filter = PodcastEpisodeFilter(rawValue: components[2])
          else { return nil }
          let escaped = components[1]
          path.append(
            .podcastShow(itemID: escaped.removingPercentEncoding ?? escaped, filter: filter))
          components.removeFirst(3)
        case Route.podcastShowsToken:
          path.append(.podcastShows)
          components.removeFirst(1)
        case Route.nativePodcastShowsToken:
          path.append(.nativePodcastShows)
          components.removeFirst(1)
        case Route.homeMorePrefix:
          guard
            components.count >= 3,
            let section = HomeMoreSection(rawValue: components[1]),
            let filter = MediaFilter(rawValue: components[2])
          else { return nil }
          path.append(.homeMore(section: section, filter: filter))
          components.removeFirst(3)
        case Route.itemDetailPrefix:
          guard components.count >= 2 else { return nil }
          let escaped = components[1]
          path.append(.itemDetail(itemID: escaped.removingPercentEncoding ?? escaped))
          components.removeFirst(2)
        case Route.authorPrefix:
          guard components.count >= 2 else { return nil }
          let escaped = components[1]
          path.append(.author(id: escaped.removingPercentEncoding ?? escaped))
          components.removeFirst(2)
        case Route.libraryAuthorPrefix:
          guard components.count >= 3 else { return nil }
          let escapedLibrary = components[1]
          let escapedID = components[2]
          path.append(
            .author(
              id: escapedID.removingPercentEncoding ?? escapedID,
              libraryID: escapedLibrary.removingPercentEncoding ?? escapedLibrary))
          components.removeFirst(3)
        case Route.seriesPrefix:
          guard components.count >= 2 else { return nil }
          let escaped = components[1]
          path.append(.series(id: escaped.removingPercentEncoding ?? escaped))
          components.removeFirst(2)
        case Route.librarySeriesPrefix:
          guard components.count >= 3 else { return nil }
          let escapedLibrary = components[1]
          let escapedID = components[2]
          path.append(
            .series(
              id: escapedID.removingPercentEncoding ?? escapedID,
              libraryID: escapedLibrary.removingPercentEncoding ?? escapedLibrary))
          components.removeFirst(3)
        case Route.authorNamePrefix:
          guard components.count >= 2 else { return nil }
          let escaped = components[1]
          path.append(.authorName(name: escaped.removingPercentEncoding ?? escaped))
          components.removeFirst(2)
        case Route.seriesNamePrefix:
          guard components.count >= 2 else { return nil }
          let escaped = components[1]
          path.append(.seriesName(name: escaped.removingPercentEncoding ?? escaped))
          components.removeFirst(2)
        case Route.narratorPrefix:
          guard components.count >= 2 else { return nil }
          let escaped = components[1]
          path.append(.narrator(name: escaped.removingPercentEncoding ?? escaped))
          components.removeFirst(2)
        case Route.podcastSettingsToken:
          path.append(.podcastSettings)
          components.removeFirst(1)
        case Route.podcastShowSettingsPrefix:
          guard components.count >= 2 else { return nil }
          let escaped = components[1]
          path.append(.podcastShowSettings(itemID: escaped.removingPercentEncoding ?? escaped))
          components.removeFirst(2)
        case Route.libraryCollectionPrefix:
          guard
            components.count >= 4,
            let kind = LibraryCollectionListKind(rawValue: components[1])
          else { return nil }
          path.append(
            .libraryCollection(
              kind: kind,
              serverID: components[3].removingPercentEncoding ?? components[3],
              libraryID: components[2].removingPercentEncoding ?? components[2]))
          components.removeFirst(4)
        case Route.smartListsToken:
          path.append(.smartLists)
          components.removeFirst(1)
        case Route.smartListPrefix:
          guard components.count >= 2, let id = Int64(components[1]) else { return nil }
          path.append(.smartList(id: id))
          components.removeFirst(2)
        default:
          return nil
        }
      }

      self.init(section: section, path: path)
    }
  }
}
