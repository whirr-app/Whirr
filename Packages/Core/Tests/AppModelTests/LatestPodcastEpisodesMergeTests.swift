import Foundation
import Persistence
import Testing

@testable import AppModel

@Suite struct LatestPodcastEpisodesMergeTests {
  @Test("enabled prefers RSS and the native-preferred ABS policy")
  func enabledUsesNativePreferredSnapshot() {
    let serverTwin = Self.episode(itemID: "server", episodeID: "twin", date: 300)
    let serverOnly = Self.episode(itemID: "server", episodeID: "only", date: 100)
    let nativeTwin = Self.episode(itemID: "rss:1", episodeID: "native", date: 200)
    let snapshot = HomeLatestPodcastEpisodesSnapshot(
      all: [serverTwin, serverOnly], nativePreferred: [serverOnly])

    let result = LatestPodcastEpisodesMerge.merge(
      snapshot: snapshot, rss: [nativeTwin], nativeSubscriptionsEnabled: true, limit: 10)

    #expect(result == [nativeTwin, serverOnly])
  }

  @Test("disabled restores all ABS rows and excludes RSS")
  func disabledUsesAllSnapshot() {
    let serverTwin = Self.episode(itemID: "server", episodeID: "twin", date: 300)
    let serverOnly = Self.episode(itemID: "server", episodeID: "only", date: 100)
    let native = Self.episode(itemID: "rss:1", episodeID: "native", date: 400)
    let snapshot = HomeLatestPodcastEpisodesSnapshot(
      all: [serverTwin, serverOnly], nativePreferred: [serverOnly])

    let result = LatestPodcastEpisodesMerge.merge(
      snapshot: snapshot, rss: [native], nativeSubscriptionsEnabled: false, limit: 10)

    #expect(result == [serverTwin, serverOnly])
  }

  @Test("RSS wins exact duplicates and equal dates have a stable source and identity order")
  func duplicateAndTiePolicyIsDeterministic() {
    let absDuplicate = Self.episode(
      itemID: "shared", episodeID: "episode", title: "ABS", date: 200)
    let rssDuplicate = Self.episode(
      itemID: "shared", episodeID: "episode", title: "RSS", date: 100)
    let rssTie = Self.episode(itemID: "rss:b", episodeID: "episode", date: 200)
    let absTie = Self.episode(itemID: "server:a", episodeID: "episode", date: 200)
    let snapshot = HomeLatestPodcastEpisodesSnapshot(
      all: [absDuplicate, absTie], nativePreferred: [absDuplicate, absTie])

    let result = LatestPodcastEpisodesMerge.merge(
      snapshot: snapshot, rss: [rssDuplicate, rssTie], nativeSubscriptionsEnabled: true, limit: 10)

    #expect(result.map(\.title) == [rssTie.title, absTie.title, rssDuplicate.title])
    #expect(result.contains(absDuplicate) == false)
  }

  @Test("limit is clamped after the cross-source merge")
  func limitIsClampedAfterMerge() {
    let snapshot = HomeLatestPodcastEpisodesSnapshot(
      all: [Self.episode(itemID: "server", episodeID: "one", date: 100)],
      nativePreferred: [Self.episode(itemID: "server", episodeID: "one", date: 100)])
    let rss = [Self.episode(itemID: "rss:1", episodeID: "two", date: 200)]

    #expect(
      LatestPodcastEpisodesMerge.merge(
        snapshot: snapshot, rss: rss, nativeSubscriptionsEnabled: true, limit: -1
      ).isEmpty)
    #expect(
      LatestPodcastEpisodesMerge.merge(
        snapshot: snapshot, rss: rss, nativeSubscriptionsEnabled: true, limit: 1
      ) == [rss[0]])
  }

  private static func episode(
    itemID: String, episodeID: String, title: String? = nil, date: TimeInterval
  ) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: itemID, showTitle: itemID, showAuthor: nil, episodeID: episodeID,
      title: title ?? "\(itemID)-\(episodeID)", subtitle: nil,
      publishedAt: Date(timeIntervalSince1970: date), durationSeconds: 1_800)
  }
}
