import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// Delete After Playing on a device-owned episode: an automatic purge removes only a completed
/// download and steps aside for a transfer still in flight, while the explicit "Remove Download"
/// path keeps its cancel-and-remove semantics for the same row.
@Suite struct RSSFinishedDownloadPurgeTests {
  @Test func automaticPurgeLeavesAnInFlightTransferAlone() async throws {
    for state in [DownloadState.pending, .downloading, .paused] {
      let harness = try await DownloadCoordinatorHarness()
      let row = try await harness.seedRSSDownload(bytes: 50)
      let id = try #require(row.id)
      if state != .pending {
        _ = try harness.rssDownloadStore.transition(downloadId: id, to: .downloading)
      }
      if state == .paused {
        _ = try harness.rssDownloadStore.transition(downloadId: id, to: .paused)
      }
      let identity = try await Self.identity(of: row, in: harness)

      try await harness.coordinator.purgeEpisodeDownload(
        itemID: identity.itemID, episodeID: identity.episodeID, source: .finishedDownloadAutoDelete)

      // The harness scheduler may legitimately pick a pending row up while the purge runs, so the
      // row is asserted to still be a live transfer rather than pinned to its seeded state.
      let remaining = try #require(try harness.rssDownloadStore.fetch(downloadId: id))
      #expect(
        [DownloadState.pending, .downloading, .paused].contains(remaining.state),
        "a \(state) transfer must not be purged, found \(remaining.state)")
      #expect(
        harness.backgroundTransferring.calls.contains(.cancel(identity: .rss(rowID: id))) == false,
        "automatic cleanup must never cancel a \(state) transfer")
    }
  }

  @Test func automaticPurgeRemovesACompletedDownloadAndItsFile() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let row = try await harness.seedRSSDownload(bytes: 50)
    let id = try #require(row.id)
    _ = try harness.rssDownloadStore.transition(downloadId: id, to: .downloading)
    _ = try harness.rssDownloadStore.complete(downloadId: id, actualBytes: 50)
    let url = harness.rssFileStore.absoluteURL(forRelativePath: row.relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 50).write(to: url)
    let identity = try await Self.identity(of: row, in: harness)

    try await harness.coordinator.purgeEpisodeDownload(
      itemID: identity.itemID, episodeID: identity.episodeID, source: .finishedDownloadAutoDelete)

    #expect(try harness.rssDownloadStore.fetch(downloadId: id) == nil)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
  }

  @Test func explicitRemovalStillCancelsAndRemovesAnInFlightTransfer() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let row = try await harness.seedRSSDownload(bytes: 50)
    let id = try #require(row.id)
    _ = try harness.rssDownloadStore.transition(downloadId: id, to: .downloading)
    let identity = try await Self.identity(of: row, in: harness)

    try await harness.coordinator.purgeEpisodeDownload(
      itemID: identity.itemID, episodeID: identity.episodeID, source: .podcastEpisodeRemoval)

    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .rss(rowID: id))))
    #expect(try harness.rssDownloadStore.fetch(downloadId: id) == nil)
    #expect(
      try await RSSEpisodeStore(database: harness.database).fetchEpisode(episodeId: row.episodeId)?
        .autoDownloadDecidedAt != nil,
      "explicit RSS deletion permanently decides the episode for auto-download")
  }

  private static func identity(
    of row: RSSDownloadRecord, in harness: DownloadCoordinatorHarness
  ) async throws -> (itemID: String, episodeID: String) {
    let episode = try #require(
      try await RSSEpisodeStore(database: harness.database).fetchEpisode(episodeId: row.episodeId))
    let source = try #require(PodcastSourceIdentity.rss(feedId: episode.feedId))
    return (source.itemId, episode.identityKey)
  }
}
