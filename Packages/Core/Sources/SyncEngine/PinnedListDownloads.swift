import Foundation
import Persistence

/// Pinned-list downloads as AppModel sees them. AppModel holds this boundary, never the reconciler
/// actor itself, as `DownloadIntents` fronts `DownloadCoordinator`.
public protocol PinnedListDownloadControlling: Sendable {
  func observePinnedKeys() -> AsyncStream<Set<LibraryCollectionKey>>
  /// Nil when the list is not pinned or not stored.
  func observeSummary(_ key: LibraryCollectionKey) -> AsyncStream<PinnedListDownloadSummary?>
  func downloadPreview(_ key: LibraryCollectionKey) async throws -> PinnedListDownloadPreview
  func pin(_ key: LibraryCollectionKey) async throws
  func downloadsUnpinningWouldRemove(_ key: LibraryCollectionKey) async throws -> Int
  func unpin(_ key: LibraryCollectionKey) async throws
  /// Resumes the list's failed audio downloads. Automatic retry never reaches them.
  func retryFailed(_ key: LibraryCollectionKey) async throws
}

public struct PinnedListDownloads: PinnedListDownloadControlling {
  private let accountID: Int64
  private let store: PinnedListStore
  private let reconciler: PinnedListDownloadReconciler
  private let intents: any DownloadIntents

  public init(
    accountID: Int64, store: PinnedListStore, reconciler: PinnedListDownloadReconciler,
    intents: any DownloadIntents
  ) {
    self.accountID = accountID
    self.store = store
    self.reconciler = reconciler
    self.intents = intents
  }

  public func observePinnedKeys() -> AsyncStream<Set<LibraryCollectionKey>> {
    store.observePinnedKeys(accountID: accountID)
  }

  public func observeSummary(_ key: LibraryCollectionKey) -> AsyncStream<PinnedListDownloadSummary?> {
    store.observeSummary(accountID: accountID, key: key)
  }

  public func downloadPreview(_ key: LibraryCollectionKey) async throws -> PinnedListDownloadPreview {
    try await store.downloadPreview(accountID: accountID, key: key)
  }

  public func pin(_ key: LibraryCollectionKey) async throws {
    try await reconciler.pin(key)
  }

  public func downloadsUnpinningWouldRemove(_ key: LibraryCollectionKey) async throws -> Int {
    try await reconciler.downloadsUnpinningWouldRemove(key)
  }

  public func unpin(_ key: LibraryCollectionKey) async throws {
    try await reconciler.unpin(key)
  }

  public func retryFailed(_ key: LibraryCollectionKey) async throws {
    for member in try await store.failedMembers(accountID: accountID, key: key) {
      if let episodeID = member.serverEpisodeID {
        try await intents.resumeEpisodeDownload(itemID: member.serverItemID, episodeID: episodeID)
      } else {
        try await intents.resumeItemDownload(itemID: member.serverItemID)
      }
    }
  }
}

/// For the setup and removal graphs and lightweight test graphs: nothing is ever pinned.
public struct NoOpPinnedListDownloads: PinnedListDownloadControlling {
  public init() {}

  public func observePinnedKeys() -> AsyncStream<Set<LibraryCollectionKey>> {
    AsyncStream { continuation in
      continuation.yield([])
      continuation.finish()
    }
  }

  public func observeSummary(_ key: LibraryCollectionKey) -> AsyncStream<PinnedListDownloadSummary?> {
    AsyncStream { continuation in
      continuation.yield(nil)
      continuation.finish()
    }
  }

  public func downloadPreview(_ key: LibraryCollectionKey) async throws -> PinnedListDownloadPreview {
    PinnedListDownloadPreview(count: 0, expectedBytes: 0)
  }

  public func pin(_ key: LibraryCollectionKey) async throws {}
  public func downloadsUnpinningWouldRemove(_ key: LibraryCollectionKey) async throws -> Int { 0 }
  public func unpin(_ key: LibraryCollectionKey) async throws {}
  public func retryFailed(_ key: LibraryCollectionKey) async throws {}
}
