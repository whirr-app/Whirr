import Foundation
import Testing

@testable import Persistence

@Suite("Smart list episode as a home episode")
struct SmartListEpisodeHomeEpisodeTests {
  private func episode(publishedAt: Date?, status: SmartListEpisodeStatus) -> SmartListEpisode {
    SmartListEpisode(
      source: .native, itemID: "rss:1", episodeID: "guid-1", showKey: "https://feed.test/a",
      showTitle: "Show", showAuthor: "Host", title: "Title", publishedAt: publishedAt,
      durationSeconds: 600, progressSeconds: 120, status: status, isDownloaded: true,
      isSaved: false, isPriority: false, artworkURL: nil,
      artworkFeedURL: URL(string: "https://feed.test/a"), showServerUpdatedAt: nil,
      sortKey: SmartListSortKey(
        order: .newest, isPriority: false, value: nil, source: .native,
        showKey: "https://feed.test/a", episodeID: "guid-1"))
  }

  @Test("the card sees the same identity, progress and artwork source")
  func mapsTheFieldsTheCardReads() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let home = episode(publishedAt: date, status: .inProgress).homeEpisode

    #expect(home.itemID == "rss:1")
    #expect(home.episodeID == "guid-1")
    #expect(home.showTitle == "Show")
    #expect(home.publishedAt == date)
    #expect(home.progressSeconds == 120)
    #expect(home.isFinished == false)
    #expect(home.artworkFeedURL == URL(string: "https://feed.test/a"))
  }

  @Test("a played episode is finished and a missing date takes the epoch")
  func playedAndUndated() {
    let home = episode(publishedAt: nil, status: .played).homeEpisode

    #expect(home.isFinished)
    #expect(home.publishedAt == Date(timeIntervalSince1970: 0))
  }
}
