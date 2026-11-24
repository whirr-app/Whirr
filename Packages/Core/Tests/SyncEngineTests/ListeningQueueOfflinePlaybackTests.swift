import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Offline queued audiobook and episode playback. The queue's consumption rule lives in
/// `PlaybackModel` (AppModel) and is source-neutral; this proves a queued row of either medium
/// still resolves and starts with the API unreachable, so consumption never fires against a start
/// that could not happen. Lives here because `OfflinePlaybackHarness` (a real
/// `DownloadStore`/`DownloadFileStore` over a temporary root) belongs to this target.
@Suite struct ListeningQueueOfflinePlaybackTests {

  @Test("a queued audiobook and a queued episode both start from their local copies, offline")
  func queuedAudiobookAndEpisodeBothStartOffline() async throws {
    let harness = try await OfflinePlaybackHarness(
      httpFailure: FakeHTTPClientError(message: "unreachable"))
    let bookRowId = try await harness.makeItem(serverItemId: "book-offline")
    try harness.completeDownload(itemRowId: bookRowId, orderIndex: 0, fileDurationSeconds: 120)
    let showRowId = try await harness.makeItem(serverItemId: "show-offline", mediaKind: "podcast")
    let episodeRowId = try await harness.makePodcastEpisode(
      itemRowId: showRowId, episodeID: "episode-offline")
    try harness.completeDownload(
      itemRowId: showRowId, orderIndex: 0, fileDurationSeconds: 90,
      podcastEpisodeId: episodeRowId)

    let store = ListeningQueueStore(database: harness.database, accountId: harness.accountId)
    let audiobook = try #require(ListeningIdentity.audiobook(itemID: "book-offline"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(
        itemID: "show-offline", episodeID: "episode-offline"))
    try await store.append(identity: audiobook)
    try await store.append(identity: episode)
    let coordinator = try harness.makeCoordinator()

    let first = try #require(await store.peekNextLive())
    #expect(first.identity == audiobook)
    let preparedBook = try await coordinator.startSession(itemID: "book-offline", episodeID: nil)
    #expect(preparedBook.source == .local)
    try await store.acknowledgeStarted(identity: first.identity, rowID: nil)

    let second = try #require(await store.peekNextLive())
    #expect(second.identity == episode)
    let preparedEpisode = try await coordinator.startSession(
      itemID: "show-offline", episodeID: "episode-offline")
    #expect(preparedEpisode.source == .local)
    try await store.acknowledgeStarted(identity: second.identity, rowID: nil)

    #expect(await store.fetchQueue().isEmpty)
    #expect(harness.http.requests.isEmpty, "neither start touched the network")
  }

  /// An item that is not downloaded cannot start while the API is unreachable, and its queue row
  /// must survive that (a failed preparation consumes nothing).
  @Test("an undownloaded queued row survives a failed offline start")
  func undownloadedQueuedRowSurvivesAFailedOfflineStart() async throws {
    let harness = try await OfflinePlaybackHarness(
      httpFailure: FakeHTTPClientError(message: "unreachable"))
    let bookRowId = try await harness.makeItem(serverItemId: "book-offline")
    try harness.completeDownload(itemRowId: bookRowId, orderIndex: 0, fileDurationSeconds: 120)
    try await harness.makeItem(serverItemId: "book-streaming-only")

    let store = ListeningQueueStore(database: harness.database, accountId: harness.accountId)
    let streamingOnly = try #require(
      ListeningIdentity.audiobook(itemID: "book-streaming-only"))
    try await store.append(identity: streamingOnly)
    let coordinator = try harness.makeCoordinator()

    await #expect(throws: (any Error).self) {
      try await coordinator.startSession(itemID: "book-streaming-only", episodeID: nil)
    }

    #expect(
      await store.fetchQueue().map(\.identity) == [streamingOnly],
      "nothing is consumed by a start that never succeeded")
  }
}
