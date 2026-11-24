import Persistence
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite struct SavedStatusStoreTests {

  @Test func constructionOpensExactlyOneSubscriptionRegardlessOfHowManyIdentitiesAreRead() {
    let reading = FakeSavedShelfReading()
    let store = SavedStatusStore(savedShelf: reading)

    for index in 0..<50 {
      _ = store.isSaved(.item(itemID: "item-\(index)"))
      _ = store.isSaved(itemID: "item-\(index)")
    }

    #expect(reading.savedIdentitySubscriptionCount == 1)
  }

  @Test func anIdentityAbsentFromTheProjectionIsNotSaved() async {
    let reading = FakeSavedShelfReading()
    let store = SavedStatusStore(savedShelf: reading)
    let item = SavedShelfIdentity.item(itemID: "item-1")
    let episode = SavedShelfIdentity.podcastEpisode(itemID: "item-1", episodeID: "episode-1")

    reading.pushSavedIdentities([item])
    await waitUntil { store.isSaved(item) }

    #expect(store.isSaved(episode) == false)
    #expect(store.isSaved(itemID: "item-1"))
    #expect(store.isSaved(itemID: "item-1", episodeID: "episode-1") == false)
  }

  @Test func itemAndPodcastEpisodeIdentitiesRemainDistinct() async {
    let reading = FakeSavedShelfReading()
    let store = SavedStatusStore(savedShelf: reading)
    let item = SavedShelfIdentity.item(itemID: "item-1")
    let episode = SavedShelfIdentity.podcastEpisode(itemID: "item-1", episodeID: "episode-1")

    reading.pushSavedIdentities([episode])
    await waitUntil { store.isSaved(episode) }

    #expect(store.isSaved(item) == false)
    #expect(store.isSaved(itemID: "item-1", episodeID: "episode-1"))
    #expect(store.isSaved(itemID: "item-1") == false)
  }

  @Test func aNativeEpisodeIsLookedUpByItsRSSIdentityNotAnABSOne() async {
    let reading = FakeSavedShelfReading()
    let store = SavedStatusStore(savedShelf: reading)
    let itemID = "rss:7"
    let native = SavedShelfIdentity.rssEpisode(itemID: itemID, episodeID: "episode-1")
    let absShaped = SavedShelfIdentity.podcastEpisode(itemID: itemID, episodeID: "episode-1")

    reading.pushSavedIdentities([native])
    await waitUntil { store.isSaved(native) }

    #expect(store.isSaved(itemID: itemID, episodeID: "episode-1"))
    #expect(store.isSaved(absShaped) == false)
    #expect(store.isSaved(itemID: itemID) == false)

    reading.pushSavedIdentities([absShaped])
    await waitUntil { store.isSaved(absShaped) }
    #expect(store.isSaved(itemID: itemID, episodeID: "episode-1") == false)
  }

  @Test func aNativeItemWithNoEpisodeIsNeverSaved() async {
    let reading = FakeSavedShelfReading()
    let store = SavedStatusStore(savedShelf: reading)
    // Not a shape the shelf writes for a native show; even if one appeared, a whole native show is
    // not a Saved for Later identity, so the item-level read must not report it.
    let wholeNative = SavedShelfIdentity.item(itemID: "rss:7")

    reading.pushSavedIdentities([wholeNative])
    await waitUntil { store.isSaved(wholeNative) }

    #expect(store.isSaved(itemID: "rss:7") == false)
  }

  @Test func aLaterEmissionReplacesTheWholeProjection() async {
    let reading = FakeSavedShelfReading()
    let store = SavedStatusStore(savedShelf: reading)
    let item = SavedShelfIdentity.item(itemID: "item-1")
    let episode = SavedShelfIdentity.podcastEpisode(itemID: "item-1", episodeID: "episode-1")

    reading.pushSavedIdentities([item, episode])
    await waitUntil { store.isSaved(episode) }

    reading.pushSavedIdentities([item])
    await waitUntil { store.isSaved(episode) == false }

    #expect(store.isSaved(item))
  }

  @Test func membershipRemainsUnresolvedUntilTheFirstEmission() async {
    let reading = FakeSavedShelfReading()
    let store = SavedStatusStore(savedShelf: reading)

    #expect(store.hasResolvedMembership == false)

    reading.pushSavedIdentities([])
    #expect(await waitUntil { store.hasResolvedMembership })
    #expect(store.isSaved(itemID: "item-1") == false)
  }

  @Test func storeDeinitializesWhileItsObservationStreamRemainsAlive() async {
    let reading = FakeSavedShelfReading()
    weak var observer: SavedStatusStore?
    var store: SavedStatusStore?

    do {
      store = SavedStatusStore(savedShelf: reading)
      observer = store
      reading.pushSavedIdentities([.item(itemID: "item-1")])
      #expect(await waitUntil { store?.hasResolvedMembership == true })
      store = nil
    }

    #expect(await waitUntil { observer == nil })
  }
}
