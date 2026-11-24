import Foundation
import Persistence
import Testing

@testable import AppModel

@Suite struct ContinueListeningMergeTests {
  @Test("null progress recency sorts last")
  func nullRecencySortsLast() {
    let dated = Self.item(id: "dated", episodeID: "episode", recency: 100)
    let undated = Self.item(id: "undated", episodeID: "episode", recency: nil)

    let result = ContinueListeningMerge.merge(
      abs: [undated], rss: [dated], nativeSubscriptionsEnabled: true, limit: 10)

    #expect(result.map(\.serverItemId) == ["dated", "undated"])
  }

  @Test("timestamp ties are ordered independently of source array order")
  func timestampTiesAreSourceOrderIndependent() {
    let first = Self.item(id: "z", episodeID: "episode", recency: 100)
    let second = Self.item(id: "a", episodeID: "episode", recency: 100)
    let third = Self.item(id: "m", episodeID: nil, recency: 100)

    let resultA = ContinueListeningMerge.merge(
      abs: [first, second], rss: [third], nativeSubscriptionsEnabled: true, limit: 10)
    let resultB = ContinueListeningMerge.merge(
      abs: [second, first], rss: [third], nativeSubscriptionsEnabled: true, limit: 10)

    #expect(resultA.map(\.serverItemId) == ["a", "m", "z"])
    #expect(resultB == resultA)
  }

  @Test("deduplication keeps the first survivor after sorting")
  func deduplicationKeepsFirstSurvivor() {
    let older = Self.item(id: "rss:1", episodeID: "episode", recency: 100, title: "older")
    let newer = Self.item(id: "rss:1", episodeID: "episode", recency: 200, title: "newer")

    let result = ContinueListeningMerge.merge(
      abs: [older], rss: [newer], nativeSubscriptionsEnabled: true, limit: 10)

    #expect(result.count == 1)
    #expect(result.first?.title == "newer")
  }

  @Test("limit is applied after global sorting and deduplication")
  func limitAppliesAfterSortingAndDeduplication() {
    let duplicateOlder = Self.item(id: "rss:1", episodeID: "episode", recency: 100)
    let low = Self.item(id: "low", episodeID: "episode", recency: 10)
    let duplicateNewer = Self.item(id: "rss:1", episodeID: "episode", recency: 300)
    let middle = Self.item(id: "middle", episodeID: "episode", recency: 200)

    let result = ContinueListeningMerge.merge(
      abs: [duplicateOlder, low], rss: [duplicateNewer, middle],
      nativeSubscriptionsEnabled: true, limit: 2)

    #expect(result.map(\.serverItemId) == ["rss:1", "middle"])
  }

  private static func item(
    id: String, episodeID: String?, recency: TimeInterval?, title: String? = nil
  ) -> HomeItem {
    HomeItem(
      serverItemId: id, title: title ?? id, author: nil, category: .podcast,
      durationSeconds: 1_800, progressSeconds: 100, isFinished: false, addedAt: nil,
      isDownloaded: false, episodeID: episodeID, episodeTitle: episodeID,
      progressRecency: recency.map { Date(timeIntervalSince1970: $0) })
  }
}
