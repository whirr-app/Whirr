import AppModel
import Testing

@Suite("Podcast subscription OPML presentation")
struct PodcastSubscriptionOPMLPresentationTests {
  @Test("the commit control names how many feeds a tap will follow")
  func commitLabelCountsItsOwnScope() {
    #expect(PodcastSubscriptionOPMLPresentation.commitLabel(.follow(count: 8)) == "Follow 8 Podcasts")
    #expect(PodcastSubscriptionOPMLPresentation.commitLabel(.follow(count: 1)) == "Follow 1 Podcast")
    #expect(PodcastSubscriptionOPMLPresentation.commitLabel(.follow(count: 0)) == "Follow")
  }

  @Test("a running batch reports its position, and a finished one offers a way out")
  func commitLabelCarriesProgressAndCompletion() {
    #expect(
      PodcastSubscriptionOPMLPresentation.commitLabel(.following(completed: 2, total: 8))
        == "Following 3 of 8…")
    // The last row is in flight, not the ninth of eight.
    #expect(
      PodcastSubscriptionOPMLPresentation.commitLabel(.following(completed: 8, total: 8))
        == "Following 8 of 8…")
    #expect(PodcastSubscriptionOPMLPresentation.commitLabel(.done) == "Done")
  }

  @Test("only a failed row earns a caption line")
  func rowStatusCopy() {
    #expect(
      PodcastSubscriptionOPMLPresentation.failureText(.failed(.alreadyFollowing))
        == "You're already following this podcast.")
    // Success is carried by the row's accessory, so a committed row gets no caption.
    #expect(PodcastSubscriptionOPMLPresentation.failureText(.followed(feedId: 1)) == nil)
    #expect(PodcastSubscriptionOPMLPresentation.failureText(.following) == nil)
    #expect(PodcastSubscriptionOPMLPresentation.failureText(.pending) == nil)
  }
}
