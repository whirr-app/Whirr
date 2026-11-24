import Foundation
import Persistence
import Testing

@testable import AppModel

/// The read-only "Source" section of Show Settings: which kind of show this is, decided by the
/// item id alone, and for a feed where it is followed from and when it was last checked.
@Suite struct PodcastShowSourcePresentationTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func sourceFollowsTheItemIdentityNamespace() throws {
    #expect(PodcastShowSourcePresentation.source(itemID: "li_abc123") == .audiobookshelf)
    let rssID = try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId
    #expect(PodcastShowSourcePresentation.source(itemID: rssID) == .rssFeed)
    #expect(PodcastShowSourcePresentation.source(itemID: "") == nil)
    #expect(PodcastShowSourcePresentation.source(itemID: "rss:not-a-feed") == nil)
  }

  @Test func everyKnownSourceEarnsItsOwnShowScreenCaption() throws {
    let rssID = try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId
    #expect(PodcastShowSourcePresentation.showCaption(itemID: rssID) == "Followed on this device")
    #expect(
      PodcastShowSourcePresentation.showCaption(itemID: "li_abc123")
        == "On your Audiobookshelf server")
    #expect(PodcastShowSourcePresentation.showCaption(itemID: "") == nil)
    #expect(
      PodcastShowSourcePresentation.rssFeedOwnership.hasPrefix("Followed directly on this device"))
  }

  @Test func sourceValuesReadDistinctly() {
    #expect(PodcastShowSourcePresentation.sourceValue(.audiobookshelf) == "Audiobookshelf")
    #expect(PodcastShowSourcePresentation.sourceValue(.rssFeed) == "RSS Feed")
  }

  @Test func absShowNamesTheLibraryAndNeverAFeed() {
    let section = PodcastShowSourcePresentation.section(
      source: .audiobookshelf,
      feedURL: URL(string: "https://example.com/feed.xml"),
      lastChecked: now.addingTimeInterval(-3600),
      now: now)

    #expect(section.rows.map(\.field) == [.source])
    #expect(section.rows.first?.value == "Audiobookshelf")
    #expect(section.footer == "Synced from your Audiobookshelf library.")
    #expect(section.footer.contains("Last checked") == false)
  }

  @Test func rssShowNamesTheFeedAndTheDeviceAsOwner() throws {
    let feedURL = try #require(URL(string: "https://example.com/feed.xml"))
    let section = PodcastShowSourcePresentation.section(
      source: .rssFeed, feedURL: feedURL, lastChecked: now.addingTimeInterval(-3600), now: now)

    #expect(section.rows.map(\.field) == [.source, .feedURL])
    #expect(section.rows.map(\.label) == ["Source", "Feed"])
    #expect(section.rows.map(\.value) == ["RSS Feed", "https://example.com/feed.xml"])
    #expect(
      section.footer
        == "Last checked 1 hour ago. Followed directly on this device. It is not on your Audiobookshelf server."
    )
  }

  /// A feed that has not refreshed yet, or whose URL has not loaded, still gets the section: the
  /// source row is the point, and the rest is added as it arrives.
  @Test func rssShowWithoutFeedFactsStillNamesItsSource() {
    let section = PodcastShowSourcePresentation.section(source: .rssFeed, now: now)

    #expect(section.rows.map(\.field) == [.source])
    #expect(section.footer == "Followed directly on this device. It is not on your Audiobookshelf server.")
  }

  /// The footer must never send the user to the web app for a feed the server has never seen.
  @Test func rssFooterNeverPointsAtTheWebApp() {
    for lastChecked in [nil, now.addingTimeInterval(-60)] {
      let footer = PodcastShowSourcePresentation.rssFeedFooter(lastChecked: lastChecked, now: now)
      #expect(footer.contains("web app") == false)
    }
  }
}
