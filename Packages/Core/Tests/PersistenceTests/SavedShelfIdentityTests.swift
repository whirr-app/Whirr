import Persistence
import Testing

@Suite struct SavedShelfIdentityTests {
  @Test("every case exposes its server-facing item and episode ids")
  func accessorsFlattenEveryCase() {
    let item = SavedShelfIdentity.item(itemID: "li_book")
    #expect(item.itemID == "li_book")
    #expect(item.episodeID == nil)

    let episode = SavedShelfIdentity.podcastEpisode(itemID: "li_show", episodeID: "ep_1")
    #expect(episode.itemID == "li_show")
    #expect(episode.episodeID == "ep_1")

    let rss = SavedShelfIdentity.rssEpisode(itemID: "rss:7", episodeID: "guid-1")
    #expect(rss.itemID == "rss:7")
    #expect(rss.episodeID == "guid-1")
  }

  @Test("an ABS item with no episode resolves to the whole-item identity")
  func resolvesABSItem() {
    #expect(SavedShelfIdentity.resolving(itemID: "li_book") == .item(itemID: "li_book"))
  }

  @Test("an ABS item with an episode resolves to the ABS podcast-episode identity")
  func resolvesABSEpisode() {
    #expect(
      SavedShelfIdentity.resolving(itemID: "li_show", episodeID: "ep_1")
        == .podcastEpisode(itemID: "li_show", episodeID: "ep_1"))
  }

  @Test("an episode under a device-owned rss: item resolves to the RSS episode identity")
  func resolvesRSSEpisode() {
    #expect(
      SavedShelfIdentity.resolving(itemID: "rss:7", episodeID: "guid-1")
        == .rssEpisode(itemID: "rss:7", episodeID: "guid-1"))
  }

  @Test("a device-owned rss: item with no episode has no saved identity")
  func rssItemWithoutEpisodeHasNoIdentity() {
    #expect(SavedShelfIdentity.resolving(itemID: "rss:7") == nil)
  }

  @Test("a malformed reserved id is not device-owned and keeps the ABS shapes")
  func malformedReservedIDKeepsABSShapes() {
    #expect(SavedShelfIdentity.resolving(itemID: "rss:007") == .item(itemID: "rss:007"))
    #expect(
      SavedShelfIdentity.resolving(itemID: "rss:007", episodeID: "ep_1")
        == .podcastEpisode(itemID: "rss:007", episodeID: "ep_1"))
  }
}
