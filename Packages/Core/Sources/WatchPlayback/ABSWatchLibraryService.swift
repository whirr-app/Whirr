import ABSApi
import Foundation

/// Production adapter. All HTTP, bearer, refresh, decoding, and logout policy remains in ABSApi.
public struct ABSWatchLibraryService: WatchLibraryService, Sendable {
  public let server: ABSServerConfig
  public let deviceID: String
  private let client: ABSClient
  private let sessionTokens: WatchSessionTokenStore

  public init(
    server: ABSServerConfig, tokenStore: any TokenStoring, deviceID: String = WatchDeviceIdentity.persistentID()
  ) {
    self.server = server
    self.deviceID = deviceID
    let sessionTokens = WatchSessionTokenStore(base: tokenStore)
    self.sessionTokens = sessionTokens
    client = .production(server: server, tokenStore: sessionTokens)
  }

  public func login(username: String, password: String) async throws -> WatchLoginResult {
    let session = try await client.login(credentials: LoginCredentials(username: username, password: password))
    return WatchLoginResult(
      serverURL: server.baseURL, account: session.account, userID: session.userID,
      defaultLibraryID: session.defaultLibraryID,
      accessExpiry: session.accessExpiry)
  }

  public func login(apiToken: String) async throws -> WatchLoginResult {
    let session = try await client.login(apiToken: apiToken)
    return WatchLoginResult(
      serverURL: server.baseURL, account: session.account, userID: session.userID,
      defaultLibraryID: session.defaultLibraryID,
      accessExpiry: session.accessExpiry)
  }

  public func restore(account: TokenAccount) async throws -> WatchLoginResult {
    let profile = try await client.fetchUserProfile(account: account)
    return WatchLoginResult(
      serverURL: server.baseURL, account: account, userID: profile.id, defaultLibraryID: nil, accessExpiry: nil)
  }

  public func logout(account: TokenAccount) async throws {
    defer { sessionTokens.invalidate() }
    try await client.logout(for: account)
  }

  public func libraries(account: TokenAccount) async throws -> [Library] {
    try await client.listLibraries(account: account)
  }

  public func page(
    account: TokenAccount,
    libraryID: String,
    page: Int,
    limit: Int,
    sort: String?,
    filter: LibraryItemFilter?
  ) async throws -> LibraryItemsPage {
    try await client.listLibraryItems(
      account: account, library: libraryID, page: page, limit: limit, sort: sort, filter: filter)
  }

  public func filterData(account: TokenAccount, libraryID: String) async throws -> LibraryFilterData {
    try await client.getLibraryFilterData(account: account, library: libraryID)
  }

  public func recentEpisodes(account: TokenAccount, libraryID: String, page: Int, limit: Int) async throws
    -> [RecentEpisode]
  {
    try await client.recentEpisodes(account: account, library: libraryID, page: page, limit: limit)
  }

  public func detail(account: TokenAccount, itemID: String) async throws -> ItemDetail {
    try await client.fetchItemDetail(account: account, itemID: itemID)
  }

  public func progress(account: TokenAccount) async throws -> UserProgressSnapshot {
    try await client.fetchUserProgressSnapshot(account: account)
  }

  public func startSession(account: TokenAccount, itemID: String, episodeID: String?) async throws -> PlaybackSession {
    try await client.startPlaybackSession(
      account: account, itemID: itemID, episodeID: episodeID,
      options: StartPlaybackSessionOptions(deviceID: deviceID, clientName: "whirr-watch", forceDirectPlay: true))
  }
  public func fetchSession(account: TokenAccount, sessionID: String) async throws -> PlaybackSession? {
    try await client.fetchPlaybackSession(account: account, sessionID: sessionID)
  }
  public func syncSession(account: TokenAccount, sessionID: String, update: SessionSyncUpdate) async throws {
    try await client.syncPlaybackSession(account: account, sessionID: sessionID, update: update)
  }
  public func closeSession(account: TokenAccount, sessionID: String, finalPosition: SessionSyncUpdate?) async throws {
    try await client.closePlaybackSession(account: account, sessionID: sessionID, finalPosition: finalPosition)
  }
  public func streamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization {
    try await client.makePlaybackStreamAuthorization(account: account)
  }
  public func renewStreamAuthorization(account: TokenAccount) async throws -> PlaybackStreamAuthorization {
    try await client.renewPlaybackStreamAuthorization(account: account)
  }
  public func audioDownload(account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int)
    async throws -> AuthorizedDownloadRequest
  {
    let request = try FileDownloadRequest(
      itemID: itemID, fileID: fileID, expectedMIMEType: mimeType, expectedSize: expectedSize)
    return try await client.makeAuthorizedDownloadRequest(request, account: account)
  }
  public func renewAudioDownload(
    account: TokenAccount, itemID: String, fileID: String, mimeType: String, expectedSize: Int
  ) async throws -> AuthorizedDownloadRequest {
    let request = try FileDownloadRequest(
      itemID: itemID, fileID: fileID, expectedMIMEType: mimeType, expectedSize: expectedSize)
    return try await client.renewAuthorizedDownloadRequest(request, account: account)
  }
  public func syncLocalSessions(account: TokenAccount, sessions: [LocalPlaybackSession]) async throws
    -> LocalSessionSyncOutcome
  {
    try await client.syncLocalSessions(account: account, sessions: sessions)
  }
}
