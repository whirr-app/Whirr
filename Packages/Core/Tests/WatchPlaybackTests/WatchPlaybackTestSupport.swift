import ABSApi
import Foundation
import PlayerCore
import WatchProtocol

@testable import ABSApi
@testable import WatchPlayback

final class LockedMemorySettings: WatchSettingsStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Data?
  private var saveFailuresRemaining: Int

  init(saveFailures: Int = 0) {
    saveFailuresRemaining = saveFailures
  }

  func load() throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func save(_ data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    if saveFailuresRemaining > 0 {
      saveFailuresRemaining -= 1
      throw WatchLibraryError.storageFailure
    }
    value = data
  }

  func clear() throws {
    lock.lock()
    value = nil
    lock.unlock()
  }
  func failNextSave() {
    lock.withLock { saveFailuresRemaining += 1 }
  }
}

@MainActor
final class RecordingWatchAudio: WatchSessionAudio {
  var position: Double = 0
  var isPlaying = false
  var loads = 0
  private var paused: CheckedContinuation<Void, Never>?

  func waitForPause() async {
    guard isPlaying else { return }
    await withCheckedContinuation { paused = $0 }
  }

  func load(_ preparation: WatchAudioPreparation, position: Double) async throws {
    loads += 1
    self.position = position
  }

  func play() async throws { isPlaying = true }
  func pause() {
    isPlaying = false
    paused?.resume()
    paused = nil
  }
  func seek(to position: Double) async throws { self.position = position }
  func setRate(_ rate: Double) {}
  func stop() { isPlaying = false }
}

// Stays: WatchPlaybackTests does not depend on TestSupport, and adding it edits Package.swift
// (an owner gate).
actor NullHTTPClient: HTTPClienting {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw APIError.transport }
}

struct TestUnexpectedCall: Error {
  let method: String
}

/// Default witnesses let actor fakes retain their isolation and override only used capabilities.
protocol StubWatchLibraryService: WatchLibraryService {}

extension StubWatchLibraryService {
  func login(username: String, password: String) async throws -> WatchLoginResult {
    throw TestUnexpectedCall(method: "login")
  }
  func login(apiToken: String) async throws -> WatchLoginResult { throw TestUnexpectedCall(method: "login") }
  func restore(account: TokenAccount) async throws -> WatchLoginResult { throw TestUnexpectedCall(method: "restore") }
  func logout(account: TokenAccount) async throws { throw TestUnexpectedCall(method: "logout") }
  func libraries(account: TokenAccount) async throws -> [Library] { throw TestUnexpectedCall(method: "libraries") }

  func page(
    account: TokenAccount,
    libraryID: String,
    page: Int,
    limit: Int,
    sort: String?,
    filter: LibraryItemFilter?
  ) async throws -> LibraryItemsPage { throw TestUnexpectedCall(method: "page") }
  func filterData(account: TokenAccount, libraryID: String) async throws -> LibraryFilterData {
    throw TestUnexpectedCall(method: "filterData")
  }
  func recentEpisodes(account: TokenAccount, libraryID: String, page: Int, limit: Int) async throws -> [RecentEpisode] {
    throw TestUnexpectedCall(method: "recentEpisodes")
  }
  func detail(account: TokenAccount, itemID: String) async throws -> ItemDetail {
    throw TestUnexpectedCall(method: "detail")
  }
  func progress(account: TokenAccount) async throws -> UserProgressSnapshot {
    throw TestUnexpectedCall(method: "progress")
  }
  func startSession(account: TokenAccount, itemID: String, episodeID: String?) async throws -> PlaybackSession {
    throw TestUnexpectedCall(method: "startSession")
  }
  func fetchSession(account: TokenAccount, sessionID: String) async throws -> PlaybackSession? {
    throw TestUnexpectedCall(method: "fetchSession")
  }
  func syncSession(account: TokenAccount, sessionID: String, update: SessionSyncUpdate) async throws {
    throw TestUnexpectedCall(method: "syncSession")
  }
  func closeSession(account: TokenAccount, sessionID: String, finalPosition: SessionSyncUpdate?) async throws {
    throw TestUnexpectedCall(method: "closeSession")
  }
  func streamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization {
    throw TestUnexpectedCall(method: "streamAuthorization")
  }
  func renewStreamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization {
    throw TestUnexpectedCall(method: "renewStreamAuthorization")
  }
  func audioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  { throw TestUnexpectedCall(method: "audioDownload") }
  func renewAudioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  { throw TestUnexpectedCall(method: "renewAudioDownload") }
  func syncLocalSessions(account: TokenAccount, sessions: [LocalPlaybackSession]) async throws
    -> LocalSessionSyncOutcome
  { throw TestUnexpectedCall(method: "syncLocalSessions") }
}

func accountStamp(account: String, server: String) throws -> WatchAccountStamp {
  try WatchAccountStamp(accountIdentityHash: account, serverIdentityHash: server)
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "watch-test-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A settable clock for the progress store's `now` closure.
final class ProgressStoreClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ date: Date) { value = date }
  var date: Date {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}

func absSelection() -> WatchSelection {
  .audiobookshelf(itemID: "book-1", episodeID: nil)
}

func playbackAccount() throws -> WatchAccountRecord {
  try WatchAccountRecord(serverURL: URL(string: "https://example.test/abs")!, userID: "watch-user")
}

func playbackClient(account: WatchAccountRecord) throws -> ABSClient {
  let tokens = InMemoryTokenStore()
  try tokens.save(TokenPair(accessToken: "access-token", refreshToken: nil), for: account.tokenAccount())
  return ABSClient(
    server: try ABSServerConfig(url: account.serverURL), httpClient: NullHTTPClient(), tokenStore: tokens)
}

func session(audioTracks: [PlaybackSessionAudioTrack], chapters: [ABSApi.PlaybackChapter] = []) -> PlaybackSession {
  PlaybackSession(
    id: "session-1", libraryItemID: "book-1", episodeID: nil, mediaType: "book",
    displayTitle: "Fixture", displayAuthor: nil, duration: 20, currentTime: 0,
    playMethod: 0, deviceID: "watch", audioTracks: audioTracks, chapters: chapters)
}
