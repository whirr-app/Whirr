import Foundation
import Testing

@testable import Persistence

/// `HomePodcastEpisode.id` is what every episode list keys its rows by, so it has to be unique per
/// episode. A constant id silently collapses a list into repeats of one row.
@Suite("Home podcast episode identity")
struct HomePodcastEpisodeTests {

  private static func episode(itemID: String, episodeID: String) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: itemID,
      showTitle: "Show",
      showAuthor: nil,
      episodeID: episodeID,
      title: "Episode",
      subtitle: nil,
      publishedAt: Date(timeIntervalSince1970: 0),
      durationSeconds: nil)
  }

  @Test("the id is built from the item and episode, not a fixed string")
  func idIsBuiltFromItemAndEpisode() {
    #expect(Self.episode(itemID: "item-1", episodeID: "ep-1").id == "item-1/ep-1")
  }

  @Test("episodes of the same show get distinct ids")
  func episodesOfTheSameShowAreDistinct() {
    let first = Self.episode(itemID: "item-1", episodeID: "ep-1")
    let second = Self.episode(itemID: "item-1", episodeID: "ep-2")
    #expect(first.id != second.id)
  }

  @Test("a cross-show list of episodes has no duplicate ids")
  func crossShowListHasNoDuplicateIDs() {
    let episodes = [
      Self.episode(itemID: "item-1", episodeID: "ep-1"),
      Self.episode(itemID: "item-1", episodeID: "ep-2"),
      Self.episode(itemID: "item-2", episodeID: "ep-1"),
    ]
    #expect(Set(episodes.map(\.id)).count == episodes.count)
  }
}
