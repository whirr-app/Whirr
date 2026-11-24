import Foundation
import Persistence
import Testing

@testable import AppModel

/// The source mark a podcast card earns on a surface that mixes server shows with followed feeds.
@Suite struct PodcastSourceMarkPolicyTests {
  private func feedID(_ id: Int64) throws -> String {
    try #require(PodcastSourceIdentity.rss(feedId: id)).itemId
  }

  @Test func aSurfaceMixesSourcesOnlyWhenItHoldsBothKinds() throws {
    let feed = try feedID(17)
    #expect(PodcastSourceMarkPolicy.surfaceMixesSources(podcastItemIDs: ["li_a", feed]))
    #expect(PodcastSourceMarkPolicy.surfaceMixesSources(podcastItemIDs: ["li_a", "li_b"]) == false)
    #expect(PodcastSourceMarkPolicy.surfaceMixesSources(podcastItemIDs: [feed]) == false)
    #expect(PodcastSourceMarkPolicy.surfaceMixesSources(podcastItemIDs: []) == false)
  }

  /// An id in neither namespace decides nothing on its own: it must not pair with one real source
  /// to claim a mix that is not there.
  @Test func anUnreadableIdentityIsNeitherKind() throws {
    #expect(PodcastSourceMarkPolicy.surfaceMixesSources(podcastItemIDs: ["li_a", ""]) == false)
    #expect(
      PodcastSourceMarkPolicy.surfaceMixesSources(podcastItemIDs: ["rss:not-a-feed", "li_a"])
        == false)
  }

  @Test func onlyTheServerShowIsMarked() throws {
    let feed = try feedID(17)
    #expect(
      PodcastSourceMarkPolicy.mark(itemID: "li_a", category: .podcast, surfaceMixesSources: true)
        == .server)
    #expect(
      PodcastSourceMarkPolicy.mark(itemID: feed, category: .podcast, surfaceMixesSources: true)
        == nil)
  }

  /// The mark answers a question only a mixed surface asks. A shelf of one kind already answers it,
  /// and marking every tile there would say nothing.
  @Test func anUnmixedSurfaceMarksNothing() {
    #expect(
      PodcastSourceMarkPolicy.mark(itemID: "li_a", category: .podcast, surfaceMixesSources: false)
        == nil)
  }

  /// Audiobooks and ebooks are never followed from a feed, so their source is not in question even
  /// when they share a shelf with podcasts that are.
  @Test func onlyPodcastsCarryTheMark() {
    #expect(
      PodcastSourceMarkPolicy.mark(itemID: "li_a", category: .audiobook, surfaceMixesSources: true)
        == nil)
    #expect(
      PodcastSourceMarkPolicy.mark(itemID: "li_a", category: .ebook, surfaceMixesSources: true)
        == nil)
  }
}
