import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// A downloaded episode plays with its own persisted chapters; books keep the `itemChapter` snapshot.
@Suite struct PodcastEpisodeChapterPlaybackTests {
  private static func chapters(_ titles: [String]) -> [StoredItemChapter] {
    titles.enumerated().map { index, title in
      StoredItemChapter(
        serverChapterId: index, position: index, start: Double(index) * 60,
        end: Double(index + 1) * 60, title: title)
    }
  }

  @Test func offlineEpisodeStartReturnsItsOwnChaptersNotItsSiblingsOrTheItems() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "podcast-chapters", mediaKind: "podcast")
    let episodeA = try await h.makePodcastEpisode(itemRowId: itemRowId, episodeID: "episode-a")
    let episodeB = try await h.makePodcastEpisode(itemRowId: itemRowId, episodeID: "episode-b")
    try h.completeDownload(
      itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 180, podcastEpisodeId: episodeA)
    let store = PodcastEpisodeChapterStore(database: h.database)
    try store.replace(
      accountId: h.accountId, podcastEpisodeId: episodeA, chapters: Self.chapters(["Intro", "Main"]))
    try store.replace(
      accountId: h.accountId, podcastEpisodeId: episodeB, chapters: Self.chapters(["Sibling"]))
    try ItemChapterStore(database: h.database).replace(
      accountId: h.accountId, itemId: itemRowId, chapters: Self.chapters(["Item level"]))
    let coordinator = try h.makeCoordinator()

    let prepared = try await coordinator.startSession(
      itemID: "podcast-chapters", episodeID: "episode-a")

    #expect(prepared.source == .local)
    #expect(prepared.chapters.map(\.title) == ["Intro", "Main"])
    #expect(prepared.chapters.map(\.end) == [60, 120])
  }

  @Test func offlineEpisodeWithoutStoredChaptersHasNone() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "podcast-none", mediaKind: "podcast")
    let episode = try await h.makePodcastEpisode(itemRowId: itemRowId, episodeID: "episode-a")
    try h.completeDownload(
      itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 180, podcastEpisodeId: episode)
    let coordinator = try h.makeCoordinator()

    let prepared = try await coordinator.startSession(itemID: "podcast-none", episodeID: "episode-a")

    #expect(prepared.chapters.isEmpty)
  }

  @Test func offlineBookStillReadsItemChapters() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "book-chapters")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 180)
    try ItemChapterStore(database: h.database).replace(
      accountId: h.accountId, itemId: itemRowId, chapters: Self.chapters(["One", "Two"]))
    let coordinator = try h.makeCoordinator()

    let prepared = try await coordinator.startSession(itemID: "book-chapters", episodeID: nil)

    #expect(prepared.chapters.map(\.title) == ["One", "Two"])
  }

  @Test func promotingAStreamedEpisodeCarriesTheLocalEpisodeChapters() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: "podcast-promote", mediaKind: "podcast")
    let episode = try await h.makePodcastEpisode(itemRowId: itemRowId, episodeID: "episode-a")
    h.enqueuePlayResponse(itemID: "podcast-promote", duration: 600)
    let coordinator = try h.makeCoordinator()
    let streamed = try await coordinator.startSession(
      itemID: "podcast-promote", episodeID: "episode-a")
    #expect(streamed.source == .streaming)
    try h.completeDownload(
      itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600, podcastEpisodeId: episode)
    try PodcastEpisodeChapterStore(database: h.database).replace(
      accountId: h.accountId, podcastEpisodeId: episode, chapters: Self.chapters(["Intro", "Main"]))

    let promoted = await coordinator.promoteStreamingSessionToLocalDownload(
      itemID: "podcast-promote", episodeID: "episode-a", currentPosition: 30,
      streamedDuration: nil)

    let prepared = try #require(promoted)
    #expect(prepared.source == .local)
    #expect(prepared.chapters.map(\.title) == ["Intro", "Main"])
  }

  @Test func aRefreshWritesAndReplacesTheEpisodeChaptersFromTheDecodedEpisode() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: "podcast-refresh", mediaKind: "podcast")
    let episode = try await h.makePodcastEpisode(itemRowId: itemRowId, episodeID: "episode-a")
    let store = PodcastRefreshStore(database: h.database)
    func refresh(_ chapters: [Chapter]) -> PodcastRefresh {
      PodcastRefresh(
        accountID: h.accountId, localItemID: itemRowId, itemID: "podcast-refresh",
        episodes: [
          PodcastRefreshCoordinator.mapEpisode(
            PodcastEpisode(
              id: "episode-a", title: "A", contentUrl: nil, mimeType: nil, duration: 600,
              publishedAt: nil, chapters: chapters))
        ],
        progressObservations: [], autoDownloadEpisodes: nil, lastEpisodeCheck: nil, isComplete: true)
    }
    let chapterStore = PodcastEpisodeChapterStore(database: h.database)

    try await store.applyPodcastRefresh(
      refresh([
        Chapter(id: 0, start: 0, end: 100, title: "Intro"),
        Chapter(id: 1, start: 100, end: nil, title: "Main"),
      ]), decideProgress: { _ in .keepLocal })
    let first = try chapterStore.fetch(accountId: h.accountId, podcastEpisodeId: episode)
    #expect(first.map(\.title) == ["Intro", "Main"])
    #expect(first.map(\.end) == [100, 600], "an open-ended last chapter closes at the duration")

    try await store.applyPodcastRefresh(
      refresh([Chapter(id: 0, start: 0, end: 600, title: "Only")]), decideProgress: { _ in .keepLocal })
    #expect(
      try chapterStore.fetch(accountId: h.accountId, podcastEpisodeId: episode).map(\.title) == ["Only"])
  }
}
