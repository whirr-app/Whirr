import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite(.timeLimit(.minutes(1))) struct RSSDownloadsModelTests {
  @Test func groupsDownloadsByFeedAndPreservesSourceMetadata() async {
    let reading = FakeRSSDownloadsReading()
    let model = RSSDownloadsModel(reading: reading, downloadIntents: FakeDownloadIntents())
    #expect(model.hasLoaded == false)
    let feed = RSSDownloadedFeed(
      id: 7, title: "The Feed", author: "Host", sourceURL: URL(string: "https://example.test/feed.xml")!,
      episodes: [
        RSSDownloadedEpisode(
          id: "ep-1", title: "Episode One", state: .completed, actualBytes: 123,
          expectedBytes: 123, holdReason: nil)
      ])
    reading.push([feed])
    await waitUntil { model.feeds == [feed] && model.hasLoaded }

    #expect(model.feeds.count == 1)
    #expect(model.feeds[0].title == "The Feed")
    #expect(model.feeds[0].author == "Host")
    #expect(model.feeds[0].episodes.map(\.title) == ["Episode One"])
    #expect(model.feeds[0].totalBytes == 123)
    #expect(model.hasLoaded)
  }

  @Test func firstEmptySnapshotStillResolvesLoading() async {
    let reading = FakeRSSDownloadsReading()
    let model = RSSDownloadsModel(reading: reading, downloadIntents: FakeDownloadIntents())

    reading.push([])
    await waitUntil { model.hasLoaded }

    #expect(model.feeds.isEmpty)
  }

  @Test func emptySelectedPurgeMakesNoIntent() async {
    let intents = FakeDownloadIntents()
    let model = RSSDownloadsModel(reading: FakeRSSDownloadsReading(), downloadIntents: intents)
    await model.purgeSelectedDownloads(feedIDs: [], episodeIDs: [:])
    #expect(model.actionErrorMessage == nil)
    #expect(intents.calls.isEmpty)
  }

  @Test func selectedPurgeSkipsUnknownFeedsAndChildrenOfSelectedFeed() async {
    let reading = FakeRSSDownloadsReading()
    let intents = FakeDownloadIntents()
    let model = RSSDownloadsModel(reading: reading, downloadIntents: intents)
    reading.push([
      RSSDownloadedFeed(
        id: 7, title: "Feed", author: nil, sourceURL: URL(string: "https://example.test")!,
        episodes: [
          RSSDownloadedEpisode(
            id: "ep", title: "Episode", state: .completed, actualBytes: 1,
            expectedBytes: 1, holdReason: nil)
        ])
    ])
    await waitUntil { model.hasLoaded }
    await model.purgeSelectedDownloads(
      feedIDs: [7, 99], episodeIDs: [7: ["ep"], 99: ["missing"]])
    let rssID = PodcastSourceIdentity.rss(feedId: 7)?.itemId ?? ""
    #expect(
      intents.calls == [
        .purgeItemDownload(
          itemID: rssID, source: .itemDetail)
      ])
  }

  @Test func selectedEpisodePurgeKeepsFailureAndSkipsDeletingOrMissingEpisodes() async {
    let reading = FakeRSSDownloadsReading()
    let intents = SelectionPurgeTestIntents(failureID: "a")
    let model = RSSDownloadsModel(reading: reading, downloadIntents: intents)
    reading.push([
      RSSDownloadedFeed(
        id: 7, title: "Feed", sourceURL: URL(string: "https://example.test")!,
        episodes: ["a", "b", "deleting"].map {
          RSSDownloadedEpisode(
            id: $0, title: $0, state: $0 == "deleting" ? .deleting : .completed,
            actualBytes: 1, expectedBytes: 1, holdReason: nil)
        })
    ])
    await waitUntil { model.hasLoaded }
    await model.purgeSelectedDownloads(feedIDs: [], episodeIDs: [7: ["a", "b", "deleting", "missing"]])
    #expect(await intents.purgedEpisodes == ["a", "b"])
    #expect(model.actionErrorMessage == RSSDownloadsCopy.purgeFailed)
    await model.purgeSelectedDownloads(feedIDs: [], episodeIDs: [:])
    #expect(model.actionErrorMessage == nil)
  }

  @Test func feedPurgeUsesTheRSSItemIdentity() async throws {
    let reading = FakeRSSDownloadsReading()
    let intents = FakeDownloadIntents()
    let model = RSSDownloadsModel(reading: reading, downloadIntents: intents)
    let feedId: Int64 = 7

    await model.purgeItemDownload(feedId: feedId)

    #expect(
      intents.calls == [
        .purgeItemDownload(
          itemID: try #require(PodcastSourceIdentity.rss(feedId: feedId)).itemId, source: .itemDetail)
      ])
    #expect(model.actionErrorMessage == nil)
  }

  @Test func episodePurgeForwardsTheRSSItemIdentityAndEpisode() async throws {
    let reading = FakeRSSDownloadsReading()
    let intents = FakeDownloadIntents()
    let model = RSSDownloadsModel(reading: reading, downloadIntents: intents)
    let feedId: Int64 = 11
    let episodeId = "episode-1"

    await model.purgeEpisodeDownload(feedId: feedId, episodeID: episodeId)

    #expect(
      intents.calls == [
        .purgeEpisodeDownload(
          itemID: try #require(PodcastSourceIdentity.rss(feedId: feedId)).itemId,
          episodeID: episodeId,
          source: .podcastEpisodeRemoval)
      ])
  }

  @Test func aThrowingPurgeSurfacesAnActionError() async {
    let reading = FakeRSSDownloadsReading()
    let intents = FakeDownloadIntents()
    let model = RSSDownloadsModel(reading: reading, downloadIntents: intents)
    intents.stubNextCall(throwing: RSSDownloadsTestError.purge)

    await model.purgeItemDownload(feedId: 7)

    #expect(model.actionErrorMessage == RSSDownloadsCopy.purgeFailed)
  }

  @Test func aLaterSuccessfulPurgeClearsAnEarlierFailure() async {
    let reading = FakeRSSDownloadsReading()
    let intents = FakeDownloadIntents()
    let model = RSSDownloadsModel(reading: reading, downloadIntents: intents)
    intents.stubNextCall(throwing: RSSDownloadsTestError.purge)

    await model.purgeItemDownload(feedId: 7)
    #expect(model.actionErrorMessage != nil)

    intents.stubNextCall(throwing: nil)
    await model.purgeEpisodeDownload(feedId: 7, episodeID: "episode-1")

    #expect(model.actionErrorMessage == nil)
  }
}

private enum RSSDownloadsTestError: Error {
  case purge
}

private final class FakeRSSDownloadsReading: RSSDownloadsReading, @unchecked Sendable {
  private var continuation: AsyncStream<[RSSDownloadedFeed]>.Continuation?

  func observeRSSDownloads() -> AsyncStream<[RSSDownloadedFeed]> {
    AsyncStream { continuation in self.continuation = continuation }
  }

  func push(_ feeds: [RSSDownloadedFeed]) { continuation?.yield(feeds) }
}

// Stays: `StorageModelTests.swift` also uses it, and `FakeDownloadIntents` can only fail every
// call, not one chosen item, so replacing it needs a per-call failure hook added there first.
/// A deterministic failure followed by success, without scheduling-dependent mutation of a fake.
actor SelectionPurgeTestIntents: DownloadIntents {
  let failureID: String
  private(set) var purgedItems: [String] = []
  private(set) var purgedEpisodes: [String] = []
  init(failureID: String) { self.failureID = failureID }
  func purgeItemDownload(itemID: String, source: DownloadPurgeSource) async throws {
    purgedItems.append(itemID)
    if itemID == failureID { throw RSSDownloadsTestError.purge }
  }
  func purgeEpisodeDownload(itemID: String, episodeID: String, source: DownloadPurgeSource) async throws {
    purgedEpisodes.append(episodeID)
    if episodeID == failureID { throw RSSDownloadsTestError.purge }
  }
  func requestDownload(itemID: String) async throws {}
  func requestEbookDownload(itemID: String) async throws {}
  func requestSupplementDownload(itemID: String, fileIno: String) async throws {}
  func requestEpisodeDownload(itemID: String, episodeID: String) async throws {}
  func pauseEpisodeDownload(itemID: String, episodeID: String) async throws {}
  func resumeEpisodeDownload(itemID: String, episodeID: String) async throws {}
  func pauseEbookDownload(itemID: String) async throws {}
  func resumeEbookDownload(itemID: String) async throws {}
  func purgeEbookDownload(itemID: String, source: DownloadPurgeSource) async throws {}
  func pauseItemDownload(itemID: String) async throws {}
  func resumeItemDownload(itemID: String) async throws {}
  func purgeAllDownloads(source: DownloadPurgeSource) async throws {}
  func purgeTombstonedEpisodeDownloads(source: DownloadPurgeSource) async throws {}
  func isQueuePausedForLowDisk() async -> Bool { false }
}
