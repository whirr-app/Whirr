import ABSApi
import Foundation
import Persistence
import PodcastFeeds
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

extension RSSPlaybackCoordinatorTests {
  // MARK: - Promotion to the local file

  @Test("a stream whose download completes promotes to the local file at the live position")
  func streamPromotesToItsCompletedDownload() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let downloads = try RSSDownloadStore(database: fixture.database)
    let row = try await downloads.claimOrCreateAsync(episodeId: episodeID)
    _ = try await downloads.transitionAsync(downloadId: row.id!, to: .downloading)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try RSSFileStore(
      rootURL: root, fileAttributes: InertFileAttributes(), downloadStore: downloads)
    let coordinator = Self.makeCoordinator(fixture: fixture, fileStore: files)
    let streamed = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    #expect(streamed.source == .streaming)

    let temporary = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try Data([1, 2, 3, 4]).write(to: temporary)
    _ = try files.completeTransfer(
      downloadId: row.id!, temporaryFileURL: temporary,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 4))

    let promoted = try #require(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "episode", currentPosition: 47, streamedDuration: nil))
    #expect(promoted.source == .local)
    #expect(promoted.streamAuthorization == nil)
    #expect(promoted.startPosition == 47)
    #expect(promoted.duration == 120)
    #expect(promoted.tracks.count == 1)
    #expect(promoted.tracks.first?.url.isFileURL == true)

    // The promoted file continues the same listen: its ticks still persist.
    await Self.tick(
      coordinator, fixture: fixture, episodeID: "episode", currentTime: 52, isFinished: false)
    let state = try await RSSEpisodeStateStore(database: fixture.database)
      .fetchState(episodeId: episodeID)
    #expect(state?.position == 52)
  }

  @Test("promotion keeps streaming when the download's length disagrees with the stream's")
  func promotionDeclinesWhenTheDownloadIsADifferentLength() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    // The stream is prepared against the feed's 120s; the download then measures 300s.
    let (coordinator, root, streamed) = try await Self.streamThenCompleteDownload(
      fixture: fixture, episodeID: episodeID, localDuration: 300)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(streamed.source == .streaming)
    #expect(streamed.duration == 120)

    #expect(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "episode", currentPosition: 47, streamedDuration: nil) == nil)
  }

  @Test("promotion swaps within tolerance and declines a position past the local file's end")
  func promotionGatesOnToleranceAndPosition() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (coordinator, root, _) = try await Self.streamThenCompleteDownload(
      fixture: fixture, episodeID: episodeID, localDuration: 121)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "episode", currentPosition: 124, streamedDuration: nil) == nil)
    let promoted = try #require(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "episode", currentPosition: 47, streamedDuration: nil))
    #expect(promoted.duration == 121)
    #expect(promoted.startPosition == 47)
  }

  @Test("promotion compares the download with the observed stream, not the feed's declaration")
  func promotionUsesTheObservedStreamLength() async throws {
    // Dynamic ad insertion: the feed declares 3600s, the stream and its download are both ~3660s.
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode", durationSeconds: 3600)])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (coordinator, root, streamed) = try await Self.streamThenCompleteDownload(
      fixture: fixture, episodeID: episodeID, localDuration: 3660)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(streamed.duration == 3600)

    let promoted = try #require(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "episode", currentPosition: 1200,
        streamedDuration: 3660.5))
    #expect(promoted.duration == 3660)
  }

  @Test("promotion declines when the observed stream is longer than the download")
  func promotionDeclinesWhenTheObservedStreamDiffersFromTheDownload() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode", durationSeconds: 3600)])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (coordinator, root, _) = try await Self.streamThenCompleteDownload(
      fixture: fixture, episodeID: episodeID, localDuration: 3600)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "episode", currentPosition: 1200,
        streamedDuration: 3660) == nil)
  }

  @Test("promotion falls back to the prepared duration without an observed one")
  func promotionFallsBackToThePreparedDuration() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode", durationSeconds: 3600)])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (coordinator, root, _) = try await Self.streamThenCompleteDownload(
      fixture: fixture, episodeID: episodeID, localDuration: 3601)
    defer { try? FileManager.default.removeItem(at: root) }

    let promoted = await coordinator.promoteStreamingSessionToLocalDownload(
      itemID: fixture.itemID, episodeID: "episode", currentPosition: 10, streamedDuration: nil)
    #expect(promoted?.duration == 3601)
  }

  @Test("a completed row whose file is gone is demoted when playback falls back to streaming")
  func playPathDemotesACompletedRowWhoseFileIsMissing() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (files, root) = try Self.completeDownload(for: episodeID, in: fixture)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloads = try RSSDownloadStore(database: fixture.database)
    let localURL = try #require(try files.validatedLocalURL(episodeId: episodeID))
    try FileManager.default.removeItem(at: localURL)
    #expect(try downloads.fetch(episodeId: episodeID)?.state == .completed)

    let prepared = try await Self.makeCoordinator(fixture: fixture, fileStore: files)
      .startSession(itemID: fixture.itemID, episodeID: "episode")

    #expect(prepared.source == .streaming)
    #expect(try downloads.fetch(episodeId: episodeID)?.state == .failed)
  }

  @Test func promotionDeclinesWithoutAFileOrForAnotherIdentity() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode"), Self.episode(identityKey: "other")])
    let otherID = try #require(fixture.episodeIDs["other"])
    let (files, root) = try Self.completeDownload(for: otherID, in: fixture)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = Self.makeCoordinator(fixture: fixture, fileStore: files)

    // Nothing is active yet.
    #expect(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "other", currentPosition: 0, streamedDuration: nil) == nil)

    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    // The active episode has no file, and the downloaded sibling is not the active identity.
    #expect(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "episode", currentPosition: 0, streamedDuration: nil) == nil)
    #expect(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "other", currentPosition: 0, streamedDuration: nil) == nil)
  }

  @Test func promotionDeclinesOnceTheSessionStops() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (files, root) = try Self.completeDownload(for: episodeID, in: fixture)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = Self.makeCoordinator(fixture: fixture, fileStore: files)
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    try await coordinator.stopSession()

    #expect(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "episode", currentPosition: 10, streamedDuration: nil) == nil)
  }

  @Test("a completed local episode falls back to its declared duration when the file is unmeasurable")
  func completedLocalEpisodeFallsBackToDeclaredDurationWhenFileIsUnmeasurable() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (files, root) = try Self.completeDownload(for: episodeID, in: fixture)
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = RSSPlaybackFixtures.DurationLoaderSpy(result: nil)
    let coordinator = Self.makeCoordinator(fixture: fixture, loader: loader, fileStore: files)

    let prepared = try await coordinator.startSession(
      itemID: fixture.itemID, episodeID: "episode")

    #expect(prepared.source == .local)
    #expect(prepared.duration == 120)
    #expect(await loader.callCount == 1)
  }

  @Test("a completed local episode reports the downloaded file's length, not the feed's")
  func completedLocalEpisodePrefersTheMeasuredFileDuration() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (files, root) = try Self.completeDownload(for: episodeID, in: fixture)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = Self.makeCoordinator(
      fixture: fixture, loader: RSSPlaybackFixtures.SourceAwareDurationLoader(localResult: 95), fileStore: files)

    let prepared = try await coordinator.startSession(
      itemID: fixture.itemID, episodeID: "episode")

    #expect(prepared.source == .local)
    #expect(prepared.duration == 95)
    #expect(prepared.tracks.first?.duration == 95)
  }

  @Test("a completed local episode resolves unknown duration from the local file")
  func completedLocalEpisodeResolvesDurationWithoutUsingTheRemoteEnclosure() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode", durationSeconds: nil)])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (files, root) = try Self.completeDownload(for: episodeID, in: fixture)
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = RSSPlaybackFixtures.SourceAwareDurationLoader(localResult: 321)
    let coordinator = Self.makeCoordinator(fixture: fixture, loader: loader, fileStore: files)

    let prepared = try await coordinator.startSession(
      itemID: fixture.itemID, episodeID: "episode")

    #expect(prepared.source == .local)
    #expect(prepared.duration == 321)
    #expect(await loader.remoteURLs.isEmpty)
    #expect(await loader.localURLs.count == 1)
  }

  @Test("a downloaded episode prepares offline when only local duration loading is available")
  func downloadedEpisodePreparesWithRemoteDurationLoaderUnavailable() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode", durationSeconds: nil)])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (files, root) = try Self.completeDownload(for: episodeID, in: fixture)
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = RSSPlaybackFixtures.OfflineRemoteDurationLoader(localResult: 654)
    let coordinator = Self.makeCoordinator(fixture: fixture, loader: loader, fileStore: files)

    let prepared = try await coordinator.startSession(
      itemID: fixture.itemID, episodeID: "episode")

    #expect(prepared.source == .local)
    #expect(prepared.duration == 654)
    #expect(await loader.remoteCallCount == 0)
    #expect(await loader.localCallCount == 1)
  }

  @Test("a downloaded episode without a local duration fails without probing its enclosure")
  func downloadedEpisodeWithoutUsableLocalDurationFailsWithoutRemoteProbe() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode", durationSeconds: nil)])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (files, root) = try Self.completeDownload(for: episodeID, in: fixture)
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = RSSPlaybackFixtures.SourceAwareDurationLoader(localResult: nil)
    let coordinator = Self.makeCoordinator(fixture: fixture, loader: loader, fileStore: files)

    await #expect(
      throws: RSSPlaybackCoordinatorError.durationUnavailable(
        itemID: fixture.itemID, episodeID: "episode")
    ) {
      try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    }

    #expect(await loader.remoteURLs.isEmpty)
    #expect(await loader.localURLs.count == 1)
  }

  // MARK: - Embedded chapters

  static let embeddedChapters = [
    EmbeddedChapter(start: 0, end: 40, title: "Intro"),
    EmbeddedChapter(start: 40, end: 100, title: nil),
    EmbeddedChapter(start: 100, end: 400, title: "Outro"),
  ]

  @Test("a downloaded episode prepares with the chapters embedded in its file")
  func downloadedEpisodePreparesWithEmbeddedChapters() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (files, root) = try Self.completeDownload(for: episodeID, in: fixture)
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = EmbeddedChapterLoaderSpy(chapters: Self.embeddedChapters)
    let coordinator = Self.makeCoordinator(fixture: fixture, chapterLoader: loader, fileStore: files)

    let prepared = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")

    #expect(prepared.source == .local)
    // The 120 s timeline wins over a chapter table that runs past the end of the file.
    #expect(
      prepared.chapters == [
        PreparedPlaybackChapter(id: 0, start: 0, end: 40, title: "Intro"),
        PreparedPlaybackChapter(id: 1, start: 40, end: 100, title: nil),
        PreparedPlaybackChapter(id: 2, start: 100, end: 120, title: "Outro"),
      ])
    #expect(await loader.requestedURLs == [prepared.tracks.first?.url])
  }

  @Test("a second start reads the cached chapters instead of parsing the file again")
  func secondStartUsesTheCache() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (files, root) = try Self.completeDownload(for: episodeID, in: fixture)
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = EmbeddedChapterLoaderSpy(chapters: Self.embeddedChapters)
    let coordinator = Self.makeCoordinator(fixture: fixture, chapterLoader: loader, fileStore: files)

    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    let again = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")

    #expect(again.chapters.count == 3)
    #expect(await loader.callCount == 1)
  }

  @Test("a streamed episode has no chapters and never touches the chapter loader")
  func streamedEpisodeHasNoChapters() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let loader = EmbeddedChapterLoaderSpy(chapters: Self.embeddedChapters)
    let coordinator = Self.makeCoordinator(fixture: fixture, chapterLoader: loader)

    let prepared = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")

    #expect(prepared.source == .streaming)
    #expect(prepared.chapters.isEmpty)
    #expect(await loader.callCount == 0)
  }

  @Test("an unreadable chapter table never stops a downloaded episode from playing")
  func chapterFailureDoesNotBlockPlayback() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let (files, root) = try Self.completeDownload(for: episodeID, in: fixture)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = Self.makeCoordinator(
      fixture: fixture, chapterLoader: EmbeddedChapterLoaderSpy(.failure), fileStore: files)

    let prepared = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")

    #expect(prepared.source == .local)
    #expect(prepared.chapters.isEmpty)
  }

  @Test("a promoted stream gets the chapters of the local file")
  func promotedStreamGetsTheLocalFilesChapters() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let downloads = try RSSDownloadStore(database: fixture.database)
    let row = try await downloads.claimOrCreateAsync(episodeId: episodeID)
    _ = try await downloads.transitionAsync(downloadId: row.id!, to: .downloading)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try RSSFileStore(
      rootURL: root, fileAttributes: InertFileAttributes(), downloadStore: downloads)
    let loader = EmbeddedChapterLoaderSpy(chapters: Self.embeddedChapters)
    let coordinator = Self.makeCoordinator(fixture: fixture, chapterLoader: loader, fileStore: files)
    let streamed = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    #expect(streamed.chapters.isEmpty)
    let temporary = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try Data([1, 2, 3, 4]).write(to: temporary)
    _ = try files.completeTransfer(
      downloadId: row.id!, temporaryFileURL: temporary,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 4))

    let promoted = try #require(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "episode", currentPosition: 47, streamedDuration: nil))

    #expect(promoted.chapters.map(\.title) == ["Intro", nil, "Outro"])
    #expect(promoted.chapters.last?.end == 120)
    #expect(await loader.requestedURLs == [promoted.tracks.first?.url])
  }

  @Test("a declined promotion never parses the file's chapters")
  func declinedPromotionDoesNotParseChapters() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let downloads = try RSSDownloadStore(database: fixture.database)
    let row = try await downloads.claimOrCreateAsync(episodeId: episodeID)
    _ = try await downloads.transitionAsync(downloadId: row.id!, to: .downloading)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try RSSFileStore(
      rootURL: root, fileAttributes: InertFileAttributes(), downloadStore: downloads)
    let loader = EmbeddedChapterLoaderSpy(chapters: Self.embeddedChapters)
    let coordinator = Self.makeCoordinator(fixture: fixture, chapterLoader: loader, fileStore: files)
    let streamed = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    #expect(streamed.chapters.isEmpty)
    let temporary = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try Data([1, 2, 3, 4]).write(to: temporary)
    _ = try files.completeTransfer(
      downloadId: row.id!, temporaryFileURL: temporary,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 4))

    #expect(
      await coordinator.promoteStreamingSessionToLocalDownload(
        itemID: fixture.itemID, episodeID: "episode", currentPosition: 47,
        streamedDuration: 9_999) == nil)

    #expect(await loader.callCount == 0)
  }
}
