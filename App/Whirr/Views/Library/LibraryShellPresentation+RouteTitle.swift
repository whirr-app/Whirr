import AppModel
import SwiftUI

extension LibraryShellPresentation {
  /// How a pushed screen's bar holds its title. Its own type, rather than
  /// `ToolbarTitleDisplayMode`, so tests can compare it.
  enum RouteTitleMode: Equatable {
    case inline
    case inlineLarge

    var toolbarTitleDisplayMode: ToolbarTitleDisplayMode {
      switch self {
      case .inline: .inline
      case .inlineLarge: .inlineLarge
      }
    }
  }

  /// Every pushed route names its bar's title mode here, and the shell applies it to the
  /// destination. A screen left on `.automatic` takes the mode of whatever pushed it, so the same
  /// screen got a different bar depending on the path to it. Pushing a show from the all-shows
  /// page, which had inherited the Podcasts root's mode, re-laid-out the bar mid-push. The switch
  /// is exhaustive so a new route cannot ship without choosing.
  static func titleDisplayMode(for route: NavigationModel.Route) -> RouteTitleMode {
    switch route {
    // A smart list is a shelf in its own right and matches the shelf roots.
    case .smartList: .inlineLarge
    case .itemDetail, .podcastShow, .podcastShows, .nativePodcastShows, .homeMore, .storage,
      .resolutionCenter, .author, .authorName, .series, .seriesName, .narrator, .podcastSettings,
      .podcastShowSettings, .libraryCollection, .smartLists:
      .inline
    }
  }
}
