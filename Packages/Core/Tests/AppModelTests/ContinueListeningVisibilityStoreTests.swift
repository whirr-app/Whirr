import Persistence
import TestSupport
import Testing

@testable import AppModel

@Suite("Continue Listening visibility store")
@MainActor
struct ContinueListeningVisibilityStoreTests {
  @Test("the store follows successive wholesale emissions")
  func reflectsSuccessiveEmissions() async throws {
    let reading = FakeLibraryReading()
    let store = ContinueListeningVisibilityStore(library: reading)
    let item = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "ep-1"))

    reading.pushContinueListeningHidden([item, episode])
    #expect(await waitUntil { store.isHidden(item) && store.isHidden(episode) })

    reading.pushContinueListeningHidden([episode])
    #expect(await waitUntil { store.isHidden(item) == false && store.isHidden(episode) })
  }

  @Test("literal hidden initialization opens no observation")
  func literalInitializationDoesNotSubscribe() throws {
    let reading = FakeLibraryReading()
    let item = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    // Both stores are built from the same reader, so the subscription count is what separates
    // them: the literal initialiser must answer from its own set without ever reaching a database.
    _ = ContinueListeningVisibilityStore(hidden: [item])
    #expect(reading.continueListeningHiddenSubscriptionCount == 0)

    let observing = ContinueListeningVisibilityStore(library: reading)
    #expect(reading.continueListeningHiddenSubscriptionCount == 1)
    withExtendedLifetime(observing) {}

    let literal = ContinueListeningVisibilityStore(hidden: [item])
    #expect(literal.isHidden(item))
    #expect(literal.isHidden(itemID: "book-1"))
    #expect(literal.isHidden(itemID: "book-2") == false)
  }

  @Test("a hidden native-feed episode reads as hidden through its rss: item id")
  func rssEpisodeResolvesThroughItemID() throws {
    let rssEpisode = try #require(ListeningIdentity.rssEpisode(feedID: 7, episodeID: "guid-1"))
    let store = ContinueListeningVisibilityStore(hidden: [rssEpisode])

    #expect(store.isHidden(itemID: "rss:7", episodeID: "guid-1"))
    #expect(store.isHidden(itemID: "rss:7", episodeID: "guid-2") == false)
    #expect(store.isHidden(itemID: "rss:8", episodeID: "guid-1") == false)
    #expect(store.isHidden(itemID: "rss:7") == false)
  }

  @Test("ABS audiobook and episode ids still resolve to their own identities")
  func absIdentitiesResolveThroughItemID() throws {
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "ep-1"))
    let store = ContinueListeningVisibilityStore(hidden: [book, episode])

    #expect(store.isHidden(itemID: "book-1"))
    #expect(store.isHidden(itemID: "show-1", episodeID: "ep-1"))
    #expect(store.isHidden(itemID: "show-1") == false)
    #expect(store.isHidden(itemID: "book-1", episodeID: "ep-1") == false)
  }
}
