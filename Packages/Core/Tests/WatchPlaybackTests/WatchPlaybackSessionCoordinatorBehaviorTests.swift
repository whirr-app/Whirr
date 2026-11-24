import ABSApi
import Foundation
import PlayerCore
import Testing

@testable import ABSApi
@testable import WatchPlayback

/// The coordinator prepares and drives local playback only. Every server session call
/// on this service is unexpected and throws, so a stray `/play`, sync or close fails the test.
private actor CoordinatorService: StubWatchLibraryService {
  var detailCount = 0
  var downloadCount = 0
  var renewedDownloadCount = 0
  var renewFailure: APIError?
  let detailValue: ItemDetail
  let downloadRequests: [String: AuthorizedDownloadRequest]

  init(detail: ItemDetail, downloadRequests: [String: AuthorizedDownloadRequest]) {
    self.detailValue = detail
    self.downloadRequests = downloadRequests
  }

  func detail(account: TokenAccount, itemID: String) async throws -> ItemDetail {
    detailCount += 1
    return detailValue
  }
  func audioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  {
    downloadCount += 1
    guard let request = downloadRequests[fileID] else { throw APIError.decoding }
    return request
  }
  func renewAudioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  {
    renewedDownloadCount += 1
    if let renewFailure { throw renewFailure }
    guard let request = downloadRequests[fileID] else { throw APIError.decoding }
    return request
  }
  func setRenewFailure(_ failure: APIError?) { renewFailure = failure }
}

private struct CoordinatorFixture {
  let account: WatchAccountRecord
  let service: CoordinatorService
  let audio: RecordingWatchAudio
  let coordinator: WatchPlaybackSessionCoordinator
}

private func makeFixture(chapters: [Chapter] = []) async throws -> CoordinatorFixture {
  let account = try playbackAccount()
  let tokenAccount = try account.tokenAccount()
  let abs = try playbackClient(account: account)
  let detail = ItemDetail(
    id: "book-1", libraryID: "library", mediaType: "book",
    media: .book(
      BookMedia(
        title: "Fixture", subtitle: nil, authorName: nil, narratorName: nil, seriesName: nil,
        description: nil, duration: 20,
        audioFiles: AudioFileCatalog(
          files: [
            AudioFileInfo(index: 0, ino: "one", expectedSize: 10, mimeType: "audio/mpeg", duration: 10),
            AudioFileInfo(index: 1, ino: "two", expectedSize: 10, mimeType: "audio/mpeg", duration: 10),
          ], invalidEntryCount: 0),
        tracks: [
          AudioTrack(index: 0, startOffset: 0, duration: 10, title: "One", contentUrl: nil, mimeType: "audio/mpeg"),
          AudioTrack(index: 1, startOffset: 10, duration: 10, title: "Two", contentUrl: nil, mimeType: "audio/mpeg"),
        ], chapters: chapters, ebookFile: nil)
    ))
  var downloadRequests: [String: AuthorizedDownloadRequest] = [:]
  for fileID in ["one", "two"] {
    let request = try await abs.makeAuthorizedDownloadRequest(
      FileDownloadRequest(itemID: "book-1", fileID: fileID, expectedMIMEType: "audio/mpeg", expectedSize: 10),
      account: tokenAccount)
    downloadRequests[request.fileID] = request
  }
  let service = CoordinatorService(detail: detail, downloadRequests: downloadRequests)
  let audio = await MainActor.run { RecordingWatchAudio() }
  let coordinator = WatchPlaybackSessionCoordinator(
    account: account, service: service, audio: audio)
  return CoordinatorFixture(account: account, service: service, audio: audio, coordinator: coordinator)
}

@Test("independent preparation authorizes files without any server playback session")
func independentPreparationOpensNoSession() async throws {
  let fixture = try await makeFixture()
  let preparation = try await fixture.coordinator.prepareIndependent(selection: absSelection(), position: 6)
  #expect(preparation.tracks.count == 2)
  #expect(await fixture.service.detailCount == 1)
  #expect(await fixture.service.downloadCount == 2)
  #expect(await MainActor.run { fixture.audio.position } == 6)

  try await fixture.coordinator.play()
  try await fixture.coordinator.pause()
  try await fixture.coordinator.seek(to: 8)
}

/// The machine bounds consecutive failed renewals; the coordinator renews whenever asked.
@Test("each renewal request gets a fresh authorization")
func everyRenewalIsServed() async throws {
  let fixture = try await makeFixture()
  _ = try await fixture.coordinator.prepareIndependent(selection: absSelection())
  _ = try await fixture.coordinator.renewIndependent(selection: absSelection())
  _ = try await fixture.coordinator.renewIndependent(selection: absSelection())
  #expect(await fixture.service.renewedDownloadCount == 2)
}

@Test("a failed renewal can be asked again")
func aFailedRenewalCanBeRetried() async throws {
  let fixture = try await makeFixture()
  _ = try await fixture.coordinator.prepareIndependent(selection: absSelection())
  await fixture.service.setRenewFailure(.transport)
  await #expect(throws: APIError.self) {
    try await fixture.coordinator.renewIndependent(selection: absSelection())
  }
  await fixture.service.setRenewFailure(nil)
  _ = try await fixture.coordinator.renewIndependent(selection: absSelection())
}

@Test("downloaded preparation loads the audio and opens no session")
func offlinePreparationOpensNoSession() async throws {
  let fixture = try await makeFixture()
  let preparation = try await fixture.coordinator.prepareIndependent(selection: absSelection())

  try await fixture.coordinator.prepareOffline(preparation, position: 4)
  try await fixture.coordinator.play()
  try await fixture.coordinator.pause()
  try await fixture.coordinator.seek(to: 5)
}

@Test("preparation and setRate reject invalid rates with the same coordinator error")
func invalidRatesUseCoordinatorError() async throws {
  let fixture = try await makeFixture()
  let preparation = try await fixture.coordinator.prepareIndependent(selection: absSelection())
  for rate in [Double.nan, .infinity, -.infinity, 0, 0.24, 4.01] {
    await #expect(throws: WatchPlaybackCoordinatorError.invalidSelection) {
      try await fixture.coordinator.prepareIndependent(selection: absSelection(), rate: rate)
    }
    await #expect(throws: WatchPlaybackCoordinatorError.invalidSelection) {
      try await fixture.coordinator.prepareOffline(preparation, rate: rate)
    }
    await #expect(throws: WatchPlaybackCoordinatorError.invalidSelection) {
      try await fixture.coordinator.setRate(rate)
    }
  }
  #expect(await fixture.service.detailCount == 1)
}

@Test("native selections are not streamed from the server")
func coordinatorRejectsNativeSelection() async throws {
  let fixture = try await makeFixture()
  await #expect(throws: WatchLibraryError.nativeSelectionUnavailable) {
    try await fixture.coordinator.prepareIndependent(selection: .nativeFeed(feedID: "feed", episodeID: "ep"))
  }
  #expect(await fixture.service.detailCount == 0)
}

@Test("cancel unloads the audio")
func cancelUnloadsTheAudio() async throws {
  let fixture = try await makeFixture()
  _ = try await fixture.coordinator.prepareIndependent(selection: absSelection())
  try await fixture.coordinator.play()
  await fixture.coordinator.cancel()
  #expect(await MainActor.run { fixture.audio.isPlaying } == false)
}

@Test @MainActor func watchChapterPreparationsPreserveMarkersAcrossAudioTracks() async throws {
  let fixture = try await makeFixture(chapters: [
    Chapter(id: 0, start: 0, end: 5, title: "Opening"), Chapter(id: 1, start: 5, end: 20, title: "Harbour"),
  ])
  let preparation = try await fixture.coordinator.prepareIndependent(selection: absSelection(), position: 12)
  #expect(preparation.chapters.chapters.count == 2)
  #expect(preparation.chapters.currentChapter(at: 12)?.start == 5)
  #expect(preparation.chapters.currentChapter(at: 5)?.end == 20)
  #expect(preparation.chapters.currentChapter(at: 20)?.end == 20)
}
