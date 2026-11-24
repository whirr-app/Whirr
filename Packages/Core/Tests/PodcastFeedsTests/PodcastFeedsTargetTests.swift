import PodcastFeeds
import Testing

@Test func podcastFeedsModuleIsLinkable() {
  let namespace: PodcastFeeds.Type = PodcastFeeds.self
  #expect(namespace == PodcastFeeds.self)
}
