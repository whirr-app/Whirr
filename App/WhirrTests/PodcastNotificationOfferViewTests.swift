import AppModel
import Foundation
import Testing

@testable import Whirr

@Suite("Podcast notification offer view")
struct PodcastNotificationOfferViewTests {
  @Test("the offer shows under All and Shows, never under Downloads")
  func filters() {
    #expect(PodcastsViewPresentation.showsNotificationOffer(for: .all))
    #expect(PodcastsViewPresentation.showsNotificationOffer(for: .yourShows))
    #expect(PodcastsViewPresentation.showsNotificationOffer(for: .downloaded) == false)
  }

  @Test("harness screens resolve by name")
  func harnessScreen() {
    #expect(UIHarness.screen(for: "podcasts-notification-offer") == .podcastsNotificationOffer)
    #expect(UIHarness.screen(for: "player-reduce-ads-offer") == .playerReduceAdsOffer)
  }
}
