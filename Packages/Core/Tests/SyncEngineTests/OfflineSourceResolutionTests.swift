import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `PlaybackSessionCoordinator.startSession` resolves a fully-downloaded item to a complete
/// local session, even online (ARCHITECTURE.md decision log), while a non- or partially-downloaded
/// item streams. The integrity sweep runs first, so a file that vanished from under a `completed`
/// row is never trusted. A row caught mid-removal (`deleting`) fails closed.
@Suite struct OfflineSourceResolutionTests {

  // MARK: - Complete item plays locally, no network at all

  @Test func completeItemPlaysLocallyWithCredentialFreeFileURLsAndTheCumulativeTimelineWhileTheAPIIsUnreachable()
    async throws
  {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-complete")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 100)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 1, fileDurationSeconds: 150)
    let coordinator = try h.makeCoordinator()

    let prepared = try await coordinator.startSession(itemID: "item-complete", episodeID: nil)

    #expect(prepared.source == .local)
    #expect(prepared.duration == 250)
    #expect(prepared.tracks.count == 2)
    #expect(prepared.tracks[0].startOffset == 0)
    #expect(prepared.tracks[0].duration == 100)
    #expect(prepared.tracks[1].startOffset == 100)
    #expect(prepared.tracks[1].duration == 150)
    for track in prepared.tracks {
      #expect(track.url.isFileURL, "local tracks resolve to credential-free app-container file URLs")
    }
    #expect(h.http.requests.isEmpty, "no /play, /sync, or /close traffic for a complete local item")
  }

  @Test func completeEpisodePlaysLocallyOfflineWithoutMixingAPartialSibling() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "podcast-offline", mediaKind: "podcast")
    let episodeA = try await h.makePodcastEpisode(itemRowId: itemRowId, episodeID: "episode-a")
    let episodeB = try await h.makePodcastEpisode(itemRowId: itemRowId, episodeID: "episode-b")
    try h.completeDownload(
      itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 180,
      podcastEpisodeId: episodeA)
    try h.pendingDownload(itemRowId: itemRowId, podcastEpisodeId: episodeB)
    let coordinator = try h.makeCoordinator()

    let prepared = try await coordinator.startSession(
      itemID: "podcast-offline", episodeID: "episode-a")

    #expect(prepared.source == .local)
    #expect(prepared.episodeID == "episode-a")
    #expect(prepared.duration == 180)
    #expect(prepared.tracks.count == 1)
    #expect(prepared.tracks[0].url.isFileURL)
    #expect(h.http.requests.isEmpty)
    #expect(
      try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?
        .podcastEpisodeId == episodeA)
  }

  // MARK: - Partial/none streams

  @Test func anItemWithNoDownloadsAtAllStreams() async throws {
    let h = try await OfflinePlaybackHarness()
    _ = try await h.makeItem(serverItemId: "item-none")
    h.enqueuePlayResponse(itemID: "item-none")
    let coordinator = try h.makeCoordinator()

    let prepared = try await coordinator.startSession(itemID: "item-none", episodeID: nil)

    #expect(prepared.source == .streaming)
    #expect(h.http.requests.count == 1)
  }

  @Test func aPartiallyDownloadedItemStreams() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: "item-partial")
    try h.pendingDownload(itemRowId: itemRowId)
    h.enqueuePlayResponse(itemID: "item-partial")
    let coordinator = try h.makeCoordinator()

    let prepared = try await coordinator.startSession(itemID: "item-partial", episodeID: nil)

    #expect(prepared.source == .streaming)
    #expect(h.http.requests.count == 1)
  }

  // MARK: - Sweep-first: a missing file demotes rather than trusting a stale "complete"

  @Test func aFileMissingOutFromUnderACompletedRowDemotesToStreamingWhenOnline() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: "item-demoted")
    let downloadId = try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60)
    try h.deleteFileOnDisk(downloadId: downloadId)
    h.enqueuePlayResponse(itemID: "item-demoted")
    let coordinator = try h.makeCoordinator()

    let prepared = try await coordinator.startSession(itemID: "item-demoted", episodeID: nil)

    #expect(prepared.source == .streaming, "the sweep demotes the row; streaming is still available")
    #expect(h.http.requests.count == 1)
    let demoted = try #require(try h.downloadStore.fetch(downloadId: downloadId))
    #expect(demoted.state == .failed)
    #expect(demoted.errorCategory == .storage)
  }

  @Test func playbackStartLeavesAStaleDownloadForAnotherItemUntouched() async throws {
    let h = try await OfflinePlaybackHarness()
    let selectedItemId = try await h.makeItem(serverItemId: "item-selected")
    try h.completeDownload(
      itemRowId: selectedItemId, orderIndex: 0, fileDurationSeconds: 60)
    let otherItemId = try await h.makeItem(serverItemId: "item-other")
    let otherDownloadId = try h.completeDownload(
      itemRowId: otherItemId, orderIndex: 0, fileDurationSeconds: 60)
    try h.deleteFileOnDisk(downloadId: otherDownloadId)
    let coordinator = try h.makeCoordinator()

    let prepared = try await coordinator.startSession(itemID: "item-selected", episodeID: nil)

    #expect(prepared.source == .local)
    #expect(try h.downloadStore.fetch(downloadId: otherDownloadId)?.state == .completed)
  }

  @Test func aFileMissingOutFromUnderACompletedRowSurfacesADistinctUnplayableOfflineErrorWhenStreamingAlsoFails()
    async throws
  {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-demoted-offline")
    let downloadId = try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60)
    try h.deleteFileOnDisk(downloadId: downloadId)
    let coordinator = try h.makeCoordinator()

    await #expect(throws: PlaybackCoordinatorError.unplayableOffline(itemID: "item-demoted-offline")) {
      _ = try await coordinator.startSession(itemID: "item-demoted-offline", episodeID: nil)
    }
  }

  /// The reported case: the server is stopped and an item that was never downloaded is tapped.
  /// Without this the start fails with a raw transport error, which falls back to "Couldn't start
  /// playback. Try again." - advice that cannot work while the server is down.
  @Test func anUndownloadedItemWithAStoppedServerSaysTheServerIsUnreachable() async throws {
    let h = try await OfflinePlaybackHarness(transportFailure: URLError(.cannotConnectToHost))
    _ = try await h.makeItem(serverItemId: "item-never-downloaded")
    let coordinator = try h.makeCoordinator()

    await #expect(
      throws: PlaybackCoordinatorError.unplayableOffline(itemID: "item-never-downloaded")
    ) {
      _ = try await coordinator.startSession(itemID: "item-never-downloaded", episodeID: nil)
    }
  }

  /// The other half of the same rule: a server that answered is reachable, so its failure keeps
  /// its own meaning instead of being relabelled as an outage.
  @Test func anAnsweredFailureIsNotRelabelledAsAnOutage() async throws {
    let h = try await OfflinePlaybackHarness(transportFailure: APIError.serverFailure(statusCode: 500))
    _ = try await h.makeItem(serverItemId: "item-server-error")
    let coordinator = try h.makeCoordinator()

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await coordinator.startSession(itemID: "item-server-error", episodeID: nil)
    }
  }

  @Test func aMissingEpisodeFileDemotesOnlyThatEpisodeAndNeverSubstitutesAHealthySibling() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "podcast-demoted-offline", mediaKind: "podcast")
    let episodeA = try await h.makePodcastEpisode(itemRowId: itemRowId, episodeID: "episode-a")
    let episodeB = try await h.makePodcastEpisode(itemRowId: itemRowId, episodeID: "episode-b")
    let downloadA = try h.completeDownload(
      itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60,
      podcastEpisodeId: episodeA)
    let downloadB = try h.completeDownload(
      itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 90,
      podcastEpisodeId: episodeB)
    let sibling = try #require(try h.downloadStore.fetch(downloadId: downloadB))
    let siblingURL = h.downloadFileStore.absoluteURL(
      forRelativePath: sibling.destinationRelativePath)
    try h.deleteFileOnDisk(downloadId: downloadA)
    let coordinator = try h.makeCoordinator()

    await #expect(
      throws: PlaybackCoordinatorError.unplayableOffline(itemID: "podcast-demoted-offline")
    ) {
      _ = try await coordinator.startSession(
        itemID: "podcast-demoted-offline", episodeID: "episode-a")
    }

    let demoted = try #require(try h.downloadStore.fetch(downloadId: downloadA))
    #expect(demoted.state == .failed)
    #expect(demoted.errorCategory == .storage)
    #expect(try h.downloadStore.fetch(downloadId: downloadB)?.state == .completed)
    #expect(FileManager.default.fileExists(atPath: siblingURL.path))
  }

  // MARK: - A download caught mid-removal fails closed

  @Test func aDownloadRowCaughtDeletingMidPreparationFailsClosedRatherThanFallingBackSilently() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: "item-deleting")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60)
    let secondDownloadId = try h.completeDownload(itemRowId: itemRowId, orderIndex: 1, fileDurationSeconds: 60)
    // A concurrent purge that is already past its "mark deleting" boundary.
    try h.markDeleting(downloadId: secondDownloadId)
    let coordinator = try h.makeCoordinator()

    await #expect(throws: PlaybackCoordinatorError.localSourceUnavailable(itemID: "item-deleting")) {
      _ = try await coordinator.startSession(itemID: "item-deleting", episodeID: nil)
    }
    #expect(h.http.requests.isEmpty, "fails closed without ever attempting to stream instead")
  }

  @Test func aFailedSourceResolutionStillAdmitsATickForTheItemThatWasAboutToPlay() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: "item-failed-resolution-tick")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60)
    let deletingDownloadId = try h.completeDownload(
      itemRowId: itemRowId, orderIndex: 1, fileDurationSeconds: 60)
    try h.markDeleting(downloadId: deletingDownloadId)
    let coordinator = try h.makeCoordinator()

    await #expect(throws: PlaybackCoordinatorError.localSourceUnavailable(itemID: "item-failed-resolution-tick")) {
      _ = try await coordinator.startSession(itemID: "item-failed-resolution-tick", episodeID: nil)
    }

    await coordinator.recordProgressTick(
      itemID: "item-failed-resolution-tick", episodeID: nil, currentTime: 42, listenedDelta: 5,
      isFinished: false, isSeek: false)

    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.currentTime == 42)
    #expect(progress.isFinished == false)
  }
}
