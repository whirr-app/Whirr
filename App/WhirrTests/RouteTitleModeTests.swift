import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

/// A pushed screen's bar must not depend on the path to it. A screen left on `.automatic` takes
/// the title mode of whatever pushed it, so the same show screen arrived through a different bar
/// from the all-shows page than from the Podcasts root, and re-laid-out mid-push.
@Suite("Route title mode")
struct RouteTitleModeTests {
  typealias Route = NavigationModel.Route

  /// One value of every route. `destinationFiles(for:)` switches exhaustively, so a new route
  /// fails to compile here until it is added to both.
  static let everyRoute: [Route] = [
    .itemDetail(itemID: "i"), .podcastShow(itemID: "p"), .podcastShows, .nativePodcastShows,
    .homeMore(section: .newEpisodes, filter: .podcasts),
    .homeMore(section: .savedForLater, filter: .all), .storage, .resolutionCenter,
    .author(id: "a"), .authorName(name: "a"), .series(id: "s"), .seriesName(name: "s"),
    .narrator(name: "n"), .podcastSettings, .podcastShowSettings(itemID: "p"),
    .libraryCollection(kind: .collection, serverID: "c", libraryID: "l"), .smartLists,
    .smartList(id: 1),
  ]

  /// The files that compose each route's destination screen.
  static func destinationFiles(for route: Route) -> [String] {
    switch route {
    case .itemDetail: ["ItemDetailView.swift"]
    case .podcastShow: ["PodcastShowView.swift", "PodcastShowContentView.swift"]
    case .podcastShows, .nativePodcastShows:
      ["PodcastShowsHostView.swift", "PodcastShowsView.swift", "NativePodcastShowsView.swift"]
    case .homeMore(let section, _):
      section == .savedForLater ? ["SavedForLaterView.swift"] : ["HomeMoreView.swift"]
    case .storage: ["DownloadsView.swift"]
    case .resolutionCenter: ["ResolutionCenterView.swift"]
    case .author, .authorName, .series, .seriesName, .narrator: ["AuthorSeriesView.swift"]
    case .podcastSettings: ["PodcastSettingsView.swift"]
    case .podcastShowSettings: ["PodcastShowSettingsView.swift"]
    case .libraryCollection: ["LibraryCollectionView.swift"]
    case .smartLists: ["EditSmartListsView.swift"]
    case .smartList: ["SmartListView.swift"]
    }
  }

  @Test("a show's bar is inline from every origin")
  func theShowAndTheAllShowsPageAreBothInline() {
    #expect(LibraryShellPresentation.titleDisplayMode(for: .podcastShow(itemID: "p")) == .inline)
    #expect(LibraryShellPresentation.titleDisplayMode(for: .podcastShows) == .inline)
    #expect(LibraryShellPresentation.titleDisplayMode(for: .nativePodcastShows) == .inline)
  }

  @Test("only a smart list keeps the shelf roots' inline-large title")
  func onlyASmartListIsInlineLarge() {
    for route in Self.everyRoute {
      let expected: LibraryShellPresentation.RouteTitleMode =
        if case .smartList = route { .inlineLarge } else { .inline }
      #expect(LibraryShellPresentation.titleDisplayMode(for: route) == expected, "\(route)")
    }
  }

  /// The table is the default; a screen may still declare its own mode, but only the same one.
  /// A screen that disagreed would win over the table on one path and not another.
  @Test("a screen that declares its own title mode agrees with its route")
  func screenDeclarationsAgreeWithTheTable() throws {
    let sources = try ViewSourceScan.sources()
    let pattern = try Regex(#"(?:TitleDisplayMode\(|titleDisplayMode: )\.([A-Za-z]+)"#)
    for route in Self.everyRoute {
      let expected =
        switch LibraryShellPresentation.titleDisplayMode(for: route) {
        case .inline: "inline"
        case .inlineLarge: "inlineLarge"
        }
      for name in Self.destinationFiles(for: route) {
        let url = try #require(sources.first { $0.lastPathComponent == name }, "\(name)")
        let text = try ViewSourceScan.executableText(of: url)
        for match in text.matches(of: pattern) {
          let declared = match.output[1].substring.map(String.init) ?? ""
          #expect(declared == expected, "\(name) declares .\(declared) for \(route)")
        }
      }
    }
  }
}
