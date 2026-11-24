import ABSApi

public protocol WatchAccountService: Sendable {
  func login(username: String, password: String) async throws -> WatchLoginResult
  func login(apiToken: String) async throws -> WatchLoginResult
  func restore(account: TokenAccount) async throws -> WatchLoginResult
  func logout(account: TokenAccount) async throws
}

public protocol WatchCatalogueService: Sendable {
  func libraries(account: TokenAccount) async throws -> [Library]
  func page(
    account: TokenAccount,
    libraryID: String,
    page: Int,
    limit: Int,
    sort: String?,
    filter: LibraryItemFilter?
  ) async throws -> LibraryItemsPage
  func filterData(account: TokenAccount, libraryID: String) async throws -> LibraryFilterData
  func recentEpisodes(account: TokenAccount, libraryID: String, page: Int, limit: Int) async throws -> [RecentEpisode]
  func detail(account: TokenAccount, itemID: String) async throws -> ItemDetail
  func progress(account: TokenAccount) async throws -> UserProgressSnapshot
}

public protocol WatchPlaybackService: Sendable {
  func startSession(account: TokenAccount, itemID: String, episodeID: String?) async throws -> PlaybackSession
  func fetchSession(account: TokenAccount, sessionID: String) async throws -> PlaybackSession?
  func syncSession(account: TokenAccount, sessionID: String, update: SessionSyncUpdate) async throws
  func closeSession(account: TokenAccount, sessionID: String, finalPosition: SessionSyncUpdate?) async throws
  func streamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization
  func renewStreamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization
}

public protocol WatchDownloadService: Sendable {
  func audioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  func renewAudioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
}

public protocol WatchOfflineUploadService: Sendable {
  func syncLocalSessions(account: TokenAccount, sessions: [LocalPlaybackSession]) async throws
    -> LocalSessionSyncOutcome
}

public typealias WatchLibraryService = WatchAccountService & WatchCatalogueService & WatchPlaybackService
  & WatchDownloadService & WatchOfflineUploadService
