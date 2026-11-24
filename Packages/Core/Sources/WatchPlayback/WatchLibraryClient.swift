import ABSApi
import Foundation
import WatchProtocol

/// Account-scoped Watch catalogue/authentication actor. It keeps no password, token, URL, or
/// server session in catalogue values; ABSClient remains the sole HTTP/auth implementation.
public actor WatchLibraryClient {
  public static let maximumPageSize = 100

  private let accountStore: WatchAccountStore
  let service: any WatchAccountService & WatchCatalogueService
  private var record: WatchAccountRecord?
  var browseCache: [String: [WatchLibraryItem]] = [:]
  var browseCacheOrder: [String] = []
  var browseCacheRowCount = 0
  var generation = 0
  private var continueRequestGeneration = 0

  public init(accountStore: WatchAccountStore, service: any WatchAccountService & WatchCatalogueService) {
    self.accountStore = accountStore
    self.service = service
  }

  public static func production(accountStore: WatchAccountStore, server: ABSServerConfig) -> WatchLibraryClient {
    WatchLibraryClient(
      accountStore: accountStore, service: ABSWatchLibraryService(server: server, tokenStore: accountStore.tokenStore))
  }

  public func currentAccount() -> WatchAccountRecord? { record }

  public func invalidateBrowseCache() {
    browseCache.removeAll()
    browseCacheOrder.removeAll()
    browseCacheRowCount = 0
  }

  public func restore() async throws -> WatchAccountRecord? {
    let requestGeneration = generation
    guard let stored = try await accountStore.load() else { return nil }
    guard requestGeneration == generation else { return nil }
    record = stored
    let result: WatchLoginResult
    do {
      result = try await service.restore(account: stored.tokenAccount())
    } catch {
      // A transient restore failure must not erase a valid persisted account or cached data.
      return nil
    }
    guard requestGeneration == generation else { return nil }
    guard result.userID == stored.userID, result.serverURL == stored.serverURL else {
      record = nil
      return nil
    }
    let restored = try WatchAccountRecord(
      serverURL: stored.serverURL, userID: stored.userID, username: stored.username,
      defaultLibraryID: stored.defaultLibraryID ?? result.defaultLibraryID)
    record = restored
    return restored
  }

  public func login(username: String, password: String) async throws -> WatchAccountRecord {
    let requestGeneration = generation
    let result = try await service.login(username: username, password: password)
    return try await commitLogin(result, username: username, expectedGeneration: requestGeneration)
  }

  public func login(apiToken: String) async throws -> WatchAccountRecord {
    let requestGeneration = generation
    let result = try await service.login(apiToken: apiToken)
    return try await commitLogin(result, username: nil, expectedGeneration: requestGeneration)
  }

  private func commitLogin(_ result: WatchLoginResult, username: String?, expectedGeneration: Int) async throws
    -> WatchAccountRecord
  {
    guard expectedGeneration == generation else { throw WatchLibraryError.staleRequest }
    if let current = record, current.userID != result.userID {
      try? await service.logout(account: result.account)
      throw WatchLibraryError.accountMismatch
    }
    if let current = record, current.serverURL != result.serverURL {
      invalidateBrowseCache()
    }
    let next = try WatchAccountRecord(
      serverURL: result.serverURL,
      userID: result.userID, username: username ?? record?.username,
      defaultLibraryID: result.defaultLibraryID ?? record?.defaultLibraryID)
    try await accountStore.save(next)
    record = next
    return next
  }

  public func logout() async throws {
    generation += 1
    invalidateBrowseCache()

    let account: WatchAccountRecord?
    if let record { account = record } else { account = try await accountStore.load() }

    var failure: Error?
    if let account {
      do { try await service.logout(account: account.tokenAccount()) } catch { failure = error }
    }
    do {
      if let account { try await accountStore.clearTokens(for: account) }
      try await accountStore.clearSettings()
    } catch {
      if let account { record = account }  // retain a tombstone so a later logout can retry local erasure
      throw WatchLibraryError.storageFailure
    }
    record = nil
    if let failure { throw failure }
  }

  public func libraries() async throws -> [WatchLibrary] {
    let account = try authenticatedAccount()
    return try await service.libraries(account: account).map {
      WatchLibrary(id: $0.id, name: $0.name, mediaType: $0.mediaType)
    }
  }

  public func catalogue(libraryID: String, page: Int = 0, limit: Int = 100) async throws -> WatchLibraryPage {
    guard page >= 0 else { throw WatchLibraryError.invalidPage }
    let boundedLimit = min(max(1, limit), Self.maximumPageSize)
    let account = try authenticatedAccount()
    let response = try await service.page(
      account: account, libraryID: libraryID, page: page, limit: boundedLimit, sort: nil, filter: nil)
    // Keep the Watch projection bounded even if an older server ignores `limit`.
    let items = response.items.prefix(boundedLimit).compactMap { makeCatalogueItem($0, libraryID: libraryID) }
    return WatchLibraryPage(
      items: Array(items), total: max(0, response.total),
      limit: min(max(1, response.limit), Self.maximumPageSize), page: max(0, response.page))
  }

  public func continueListening() async throws -> [WatchContinueItem] {
    try await serverProgress().continued
  }

  /// The server's full progress rows and the Continue list derived from them, from one read. Start
  /// and resume weigh the full rows; the Continue list drops finished and hidden titles.
  public func serverProgress() async throws -> WatchServerProgress {
    let account = try authenticatedAccount()
    let accountGeneration = generation
    continueRequestGeneration &+= 1
    let requestGeneration = continueRequestGeneration
    let progress = try await service.progress(account: account)
    guard accountGeneration == generation, requestGeneration == continueRequestGeneration else {
      throw WatchLibraryError.staleRequest
    }
    let continued: [WatchContinueItem] = progress.progress.compactMap { row in
      guard row.isFinished == false, row.hideFromContinueListening == false else { return nil }
      let selection = WatchSelection.audiobookshelf(itemID: row.libraryItemID, episodeID: row.episodeID)
      let seconds =
        row.currentTime
        ?? row.progress.flatMap { progress in
          row.duration.map { progress * $0 }
        }
      let item = WatchContinueItem(
        id: row.episodeID.map { "\(row.libraryItemID):\($0)" } ?? row.libraryItemID,
        selection: selection, progressSeconds: seconds, durationSeconds: row.duration,
        isFinished: row.isFinished, lastUpdate: row.lastUpdate)
      return item.isResumableAudio ? item : nil
    }
    return WatchServerProgress(rows: progress.progress, continued: continued)
  }

  func authenticatedAccount() throws -> TokenAccount {
    guard let record else { throw WatchLibraryError.notAuthenticated }
    return try record.tokenAccount()
  }

  private func makeCatalogueItem(_ item: LibraryItemSummary, libraryID: String) -> WatchLibraryItem? {
    let id = item.id
    guard id.isEmpty == false else { return nil }
    let kind: WatchMediaKind
    if item.mediaType?.lowercased() == "podcast" {
      kind = .podcast
    } else if item.mediaType?.lowercased() == "book" || (item.numAudioFiles ?? 0) > 0 {
      kind = .audiobook
    } else {
      return nil
    }
    let selection = WatchSelection.audiobookshelf(itemID: id, episodeID: nil)
    return WatchLibraryItem(
      id: id, libraryID: libraryID, kind: kind, title: item.title, author: item.authorName,
      selection: selection, durationSeconds: item.durationSeconds, episodeCount: item.podcastEpisodeCount,
      series: item.seriesName, addedAt: item.addedAt)
  }
}
