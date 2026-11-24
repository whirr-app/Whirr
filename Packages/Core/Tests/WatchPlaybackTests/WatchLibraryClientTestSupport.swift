import ABSApi
import Foundation
import Testing

@testable import WatchPlayback

/// Deterministic gate for proving that an account invalidation fences a response already in
/// flight. The test never relies on a timing sleep.
actor BrowseResponseGate {
  private var entered = false
  private var released = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func wait() async {
    entered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    if released { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

final class FakeService: StubWatchLibraryService, @unchecked Sendable {
  var result: WatchLoginResult
  var page = LibraryItemsPage(items: [], total: 0, limit: 100, page: 0)
  var browsePages: [LibraryItemsPage] = []
  var recentEpisodePages: [[RecentEpisode]] = []
  struct PageCall: Equatable {
    let account: TokenAccount
    let libraryID: String
    let page: Int
    let limit: Int
    let sort: String?
    let filter: LibraryItemFilter?
  }
  private var recordedPageCalls: [PageCall] = []
  private var recordedRecentPages: [Int] = []
  var pageCalls: [PageCall] { lock.withLock { recordedPageCalls } }
  var recentPages: [Int] { lock.withLock { recordedRecentPages } }

  var browsePagesByLibrary: [String: [LibraryItemsPage]] = [:]
  var browseGate: BrowseResponseGate?
  var filterDataGate: BrowseResponseGate?
  var filterDataValue = LibraryFilterData(authors: [], series: [])
  var detailValues: [String: ItemDetail] = [:]
  var detailValue: ItemDetail?
  var progressValue = UserProgressSnapshot(progress: [], hiddenSeriesIDs: [])
  var progressGate: BrowseResponseGate?
  var sessionValue: PlaybackSession?
  private(set) var closeSessionCount = 0
  private(set) var logoutCount = 0
  private let lock = NSLock()

  init(userID: String = "u1") throws {
    let account = try TokenAccount(credentialNamespace: "watch-test", userID: userID)
    result = WatchLoginResult(
      serverURL: URL(string: "https://example.test/abs")!, account: account, userID: userID,
      defaultLibraryID: "books", accessExpiry: nil)
  }

  func changeUser(to userID: String) throws {
    let account = try TokenAccount(credentialNamespace: "watch-test", userID: userID)
    result = WatchLoginResult(
      serverURL: URL(string: "https://example.test/abs")!, account: account, userID: userID,
      defaultLibraryID: "books", accessExpiry: nil)
  }

  func login(username: String, password: String) async throws -> WatchLoginResult { result }
  func login(apiToken: String) async throws -> WatchLoginResult { result }
  func restore(account: TokenAccount) async throws -> WatchLoginResult { result }
  func logout(account: TokenAccount) async throws { lock.withLock { logoutCount += 1 } }
  func libraries(account: TokenAccount) async throws -> [Library] {
    [Library(id: "books", name: "Books", mediaType: "book", onlyShowLaterBooksInContinueSeries: false)]
  }

  func page(
    account: TokenAccount, libraryID: String, page: Int, limit: Int, sort: String?, filter: LibraryItemFilter?
  ) async throws -> LibraryItemsPage {
    lock.withLock {
      recordedPageCalls.append(
        PageCall(
          account: account, libraryID: libraryID, page: page, limit: limit, sort: sort, filter: filter))
    }
    if let browseGate { await browseGate.wait() }
    let pages = browsePagesByLibrary[libraryID] ?? browsePages
    return pages.isEmpty ? self.page : pages[min(page, pages.count - 1)]
  }
  func recentEpisodes(account: TokenAccount, libraryID: String, page: Int, limit: Int) async throws -> [RecentEpisode] {
    lock.withLock { recordedRecentPages.append(page) }
    guard !recentEpisodePages.isEmpty else { throw TestUnexpectedCall(method: "recentEpisodes") }
    return recentEpisodePages[min(page, recentEpisodePages.count - 1)]
  }
  func filterData(account: TokenAccount, libraryID: String) async throws -> LibraryFilterData {
    if let filterDataGate { await filterDataGate.wait() }
    return filterDataValue
  }
  func detail(account: TokenAccount, itemID: String) async throws -> ItemDetail {
    if let value = detailValues[itemID] { return value }
    guard let detailValue else { fatalError("unused in this test") }
    return detailValue
  }
  func progress(account: TokenAccount) async throws -> UserProgressSnapshot {
    let value = progressValue
    if let progressGate { await progressGate.wait() }
    return value
  }
  func startSession(account: TokenAccount, itemID: String, episodeID: String?) async throws -> PlaybackSession {
    guard let sessionValue else { fatalError("unused in this test") }
    return sessionValue
  }
  func fetchSession(account: TokenAccount, sessionID: String) async throws -> PlaybackSession? { sessionValue }
  func syncSession(account: TokenAccount, sessionID: String, update: SessionSyncUpdate) async throws {}
  func closeSession(account: TokenAccount, sessionID: String, finalPosition: SessionSyncUpdate?) async throws {
    closeSessionCount += 1
  }
  func streamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization {
    fatalError("unused in this test")
  }
  func renewStreamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization {
    fatalError("unused in this test")
  }
  func audioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  { fatalError("unused in this test") }
  func renewAudioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  { fatalError("unused in this test") }
  func syncLocalSessions(account: TokenAccount, sessions: [LocalPlaybackSession]) async throws
    -> LocalSessionSyncOutcome
  { fatalError("unused in this test") }
}
