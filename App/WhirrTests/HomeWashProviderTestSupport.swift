import ABSApi
import Foundation
import Persistence

@testable import Whirr

/// The provider's production API takes `EditorialWashSubject`s, so a screen cannot ask for an
/// `rss:` wash without saying where its artwork is. The scheduling and publication suites exercise
/// server items by bare id; this seam keeps them readable without reopening a string-keyed entry
/// point in the app.
extension HomeWashProvider {
  func request(
    washesFor itemIDs: [String],
    intent: RequestIntent = .visible,
    artworkRevision: ArtworkRevision = .unversioned
  ) {
    request(
      itemIDs.map { EditorialWashSubject.audiobookshelf($0, revision: artworkRevision) },
      intent: intent)
  }

  func preloadCachedWashes(
    for itemIDs: [String], sourcesByID: [String: ArtworkSource] = [:]
  ) async {
    await preloadCachedWashes(
      itemIDs.map {
        EditorialWashSubject(
          itemID: $0, artworkSource: sourcesByID[$0], artworkRevision: .unversioned)
      })
  }
}
