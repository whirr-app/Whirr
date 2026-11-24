import Foundation
import Persistence

public enum ItemProgressIntentError: Error, Equatable, Sendable {
  case notAuthenticated
}

/// Durable one-shot progress actions used by item context menus. The local projection and outbox
/// row commit together in `ItemProgressIntentStore`; the drain and any preference-enabled
/// finished-download cleanup are requested only after that transaction succeeds.
public actor ItemProgressCoordinator: ItemProgressIntents {
  private let accountDAO: AccountDAO
  private let itemDAO: ItemDAO
  private let progressDAO: MediaProgressDAO
  private let store: ItemProgressIntentStore
  private let requestDrain: @Sendable () async -> Void
  private let downloadPreferences: any DownloadPreferences
  private let requestFinishedDownloadDeletion: @Sendable (String, String?) async -> Void

  public init(
    database: AppDatabase,
    requestDrain: @escaping @Sendable () async -> Void = {},
    downloadPreferences: any DownloadPreferences = NoOpDownloadPreferences(),
    requestFinishedDownloadDeletion: @escaping @Sendable (String, String?) async -> Void = {
      _, _ in
    }
  ) throws {
    accountDAO = AccountDAO(database: database)
    itemDAO = ItemDAO(database: database)
    progressDAO = MediaProgressDAO(database: database)
    store = try ItemProgressIntentStore(database: database)
    self.requestDrain = requestDrain
    self.downloadPreferences = downloadPreferences
    self.requestFinishedDownloadDeletion = requestFinishedDownloadDeletion
  }

  public func resetProgress(itemID: String, episodeID: String?) async throws {
    guard let account = try await accountDAO.fetchAsync() else {
      throw ItemProgressIntentError.notAuthenticated
    }
    try await store.resetProgressAsync(
      itemID: itemID, episodeID: episodeID, originKey: account.clientUUID)
    await requestDrain()
  }

  public func resetEbookProgress(itemID: String) async throws {
    guard let account = try await accountDAO.fetchAsync() else {
      throw ItemProgressIntentError.notAuthenticated
    }
    try await store.resetEbookProgressAsync(itemID: itemID, originKey: account.clientUUID)
    await requestDrain()
  }

  /// Commits the reader's position and its outbox row together, then starts a drain without
  /// waiting for it. An item missing locally is a silent no-op: throwing would make the reading
  /// tracker treat every emission as failed and retry it each interval.
  public func writeEbookPosition(
    itemID: String, readingPositionJSON: String, ebookProgress: Double, ebookLocation: String?
  ) async throws {
    guard let account = try await accountDAO.fetchAsync() else {
      throw ItemProgressIntentError.notAuthenticated
    }
    let accountID = try Self.accountID(account)
    guard let localID = try await itemDAO.fetchOneAsync(accountId: accountID, serverItemId: itemID)?.id
    else { return }
    try await progressDAO.writeEbookPositionAndEnqueueAsync(
      accountId: accountID,
      identity: .item(itemId: localID),
      entityKey: itemID,
      readingPositionJSON: readingPositionJSON,
      ebookProgress: ebookProgress,
      ebookLocation: ebookLocation,
      originKey: account.clientUUID)
    startDrainWithoutWaiting()
  }

  /// The reader's finish: same shape as `writeEbookPosition`.
  public func markEbookAsFinished(itemID: String) async throws {
    guard let account = try await accountDAO.fetchAsync() else {
      throw ItemProgressIntentError.notAuthenticated
    }
    let accountID = try Self.accountID(account)
    guard let localID = try await itemDAO.fetchOneAsync(accountId: accountID, serverItemId: itemID)?.id
    else { return }
    try await progressDAO.markEbookAsFinishedAndEnqueueAsync(
      accountId: accountID,
      identity: .item(itemId: localID),
      entityKey: itemID,
      originKey: account.clientUUID)
    startDrainWithoutWaiting()
  }

  /// Requests a drain and waits for it, for a caller that must keep the process alive until the
  /// send completes (the reader going to the background).
  public func requestSync() async {
    await requestDrain()
  }

  public func markAsFinished(itemID: String, episodeID: String?, duration: Double?) async throws {
    try await setProgress(
      itemID: itemID,
      episodeID: episodeID,
      currentTime: max(0, duration ?? 0),
      isFinished: true)
    await deleteFinishedDownloadIfEnabled(itemID: itemID, episodeID: episodeID)
  }

  public func setContinueListeningVisibility(
    itemID: String, episodeID: String?, isHidden: Bool
  ) async throws {
    guard let account = try await accountDAO.fetchAsync() else {
      throw ItemProgressIntentError.notAuthenticated
    }
    try await store.setContinueListeningVisibilityAsync(
      itemID: itemID,
      episodeID: episodeID,
      isHidden: isHidden,
      originKey: account.clientUUID)
    await requestDrain()
  }

  /// One transaction for every episode, then one drain request for the batch.
  public func setEpisodesFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {
    guard episodes.isEmpty == false else { return }
    guard let account = try await accountDAO.fetchAsync() else {
      throw ItemProgressIntentError.notAuthenticated
    }
    try await store.setProgressAsync(
      itemID: itemID, episodes: episodes, isFinished: isFinished,
      originKey: account.clientUUID)
    await requestDrain()
    if isFinished, downloadPreferences.deleteWhenFinished {
      for episode in episodes {
        await requestFinishedDownloadDeletion(itemID, episode.episodeID)
      }
    }
  }

  private func setProgress(
    itemID: String,
    episodeID: String?,
    currentTime: Double,
    isFinished: Bool
  ) async throws {
    guard let account = try await accountDAO.fetchAsync() else {
      throw ItemProgressIntentError.notAuthenticated
    }
    try await store.setProgressAsync(
      itemID: itemID,
      episodeID: episodeID,
      currentTime: currentTime,
      isFinished: isFinished,
      originKey: account.clientUUID)
    await requestDrain()
  }

  /// Unlike this type's other methods, the reader's writes do not await the drain. The reading
  /// tracker awaits each emission and the finish button awaits its write, so an awaited drain
  /// would let a slow network stall page-position emission and the finish action.
  private nonisolated func startDrainWithoutWaiting() {
    let requestDrain = self.requestDrain
    Task { await requestDrain() }
  }

  private static func accountID(_ account: AccountRecord) throws -> Int64 {
    guard let id = account.id else { throw ItemProgressIntentError.notAuthenticated }
    return id
  }

  private func deleteFinishedDownloadIfEnabled(itemID: String, episodeID: String?) async {
    guard downloadPreferences.deleteWhenFinished else { return }
    await requestFinishedDownloadDeletion(itemID, episodeID)
  }
}
