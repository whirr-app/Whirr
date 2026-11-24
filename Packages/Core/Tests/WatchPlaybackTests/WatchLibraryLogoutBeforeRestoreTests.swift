import ABSApi
import Foundation
import Testing

@testable import WatchPlayback

private final class LogoutService: StubWatchLibraryService, @unchecked Sendable {
  let result: WatchLoginResult
  private let lock = NSLock()
  private var restoreContinuation: CheckedContinuation<WatchLoginResult, Error>?
  private(set) var logoutAccounts: [TokenAccount] = []
  let restoreStarted = AsyncStream<Void>.makeStream()

  init(userID: String = "user-1") throws {
    let account = try TokenAccount(credentialNamespace: "watch-test", userID: userID)
    result = WatchLoginResult(
      serverURL: URL(string: "https://example.test/abs")!, account: account, userID: userID,
      defaultLibraryID: "books", accessExpiry: nil)
  }

  func login(username: String, password: String) async throws -> WatchLoginResult { result }
  func login(apiToken: String) async throws -> WatchLoginResult { result }

  func restore(account: TokenAccount) async throws -> WatchLoginResult {
    return try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      restoreContinuation = continuation
      lock.unlock()
      restoreStarted.continuation.yield(())
    }
  }

  func releaseRestore() {
    lock.lock()
    let continuation = restoreContinuation
    restoreContinuation = nil
    lock.unlock()
    continuation?.resume(returning: result)
  }

  func logout(account: TokenAccount) async throws {
    lock.withLock { logoutAccounts.append(account) }
  }

  func libraries(account: TokenAccount) async throws -> [Library] { [] }
  func page(account: TokenAccount, libraryID: String, page: Int, limit: Int, sort: String?, filter: LibraryItemFilter?)
    async throws -> LibraryItemsPage
  {
    fatalError("unused in logout lifecycle tests")
  }
  func detail(account: TokenAccount, itemID: String) async throws -> ItemDetail {
    fatalError("unused in logout lifecycle tests")
  }
  func progress(account: TokenAccount) async throws -> UserProgressSnapshot {
    fatalError("unused in logout lifecycle tests")
  }
  func startSession(account: TokenAccount, itemID: String, episodeID: String?) async throws -> PlaybackSession {
    fatalError("unused in logout lifecycle tests")
  }
  func fetchSession(account: TokenAccount, sessionID: String) async throws -> PlaybackSession? {
    fatalError("unused in logout lifecycle tests")
  }
  func syncSession(account: TokenAccount, sessionID: String, update: SessionSyncUpdate) async throws {}
  func closeSession(account: TokenAccount, sessionID: String, finalPosition: SessionSyncUpdate?) async throws {}
  func streamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization {
    fatalError("unused in logout lifecycle tests")
  }
  func renewStreamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization {
    fatalError("unused in logout lifecycle tests")
  }
  func audioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  {
    fatalError("unused in logout lifecycle tests")
  }
  func renewAudioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  {
    fatalError("unused in logout lifecycle tests")
  }
  func syncLocalSessions(account: TokenAccount, sessions: [LocalPlaybackSession]) async throws
    -> LocalSessionSyncOutcome
  {
    fatalError("unused in logout lifecycle tests")
  }
}

private func logoutRecord() throws -> WatchAccountRecord {
  try WatchAccountRecord(
    serverURL: URL(string: "https://example.test/abs")!, userID: "user-1", username: "user",
    defaultLibraryID: "books")
}

@Test("logout discovers and revokes a persisted account before clearing local state")
func logoutBeforeRestoreRevokesPersistedAccount() async throws {
  let settings = LockedMemorySettings()
  let tokens = InMemoryTokenStore()
  let store = WatchAccountStore(tokenStore: tokens, settings: settings)
  let service = try LogoutService()
  let client = WatchLibraryClient(accountStore: store, service: service)
  let record = try logoutRecord()
  try await store.save(record)
  try tokens.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: record.tokenAccount())

  try await client.logout()

  #expect(try service.logoutAccounts == [record.tokenAccount()])
  #expect(try await store.load() == nil)
  #expect(try tokens.load(for: record.tokenAccount()) == nil)
  #expect(await client.currentAccount() == nil)
}

@Test("logout generation prevents an in-flight restore from resurrecting its account")
func logoutFencesInFlightRestore() async throws {
  let settings = LockedMemorySettings()
  let tokens = InMemoryTokenStore()
  let store = WatchAccountStore(tokenStore: tokens, settings: settings)
  let service = try LogoutService()
  let client = WatchLibraryClient(accountStore: store, service: service)
  let record = try logoutRecord()
  try await store.save(record)
  try tokens.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: record.tokenAccount())

  let restoreTask = Task { () -> WatchAccountRecord? in
    do { return try await client.restore() } catch { return nil }
  }
  for await _ in service.restoreStarted.stream { break }

  try await client.logout()
  service.releaseRestore()

  #expect(await restoreTask.value == nil)
  #expect(await client.currentAccount() == nil)
  #expect(try await store.load() == nil)
  #expect(try tokens.load(for: record.tokenAccount()) == nil)
}
