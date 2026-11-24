import Foundation
import Persistence
import PodcastFeeds
import SyncEngine

/// Feed-management boundary for a device-owned subscription.
public protocol NativeFeedManaging: Sendable {
  func unsubscribe(feedId: Int64) async throws
  func hasCredential(feedId: Int64) async throws -> Bool
  func saveBasicCredential(username: String, password: String, feedId: Int64) async throws
  func clearCredential(feedId: Int64) async throws
}

public struct NoOpNativeFeedManaging: NativeFeedManaging, Sendable {
  public init() {}
  public func unsubscribe(feedId: Int64) async throws {}
  public func hasCredential(feedId: Int64) async throws -> Bool { false }
  public func saveBasicCredential(username: String, password: String, feedId: Int64) async throws {}
  public func clearCredential(feedId: Int64) async throws {}
}

public struct RSSFeedManaging: NativeFeedManaging {
  private let store: RSSFeedStore
  private let credentialStore: (any PodcastFeedCredentialStoring)?
  private let credentialUpdateHandler: any FeedCredentialUpdateHandling
  private let refreshing: any PodcastRefreshing
  private let notificationLifecycle: any RSSNotificationLifecycleHandling
  private let downloadFileCleaner: (any RSSDownloadFileCleaning)?

  /// `downloadFileCleaner` is a separate parameter rather than a conditional cast of
  /// `credentialUpdateHandler`. The same actor serves both roles today, but a cast would silently
  /// drop file cleanup the moment that stops being true.
  public init(
    store: RSSFeedStore, credentialStore: (any PodcastFeedCredentialStoring)? = nil,
    credentialUpdateHandler: any FeedCredentialUpdateHandling = NoOpFeedCredentialUpdateHandler(),
    refreshing: any PodcastRefreshing = NoOpPodcastRefreshing(),
    notificationLifecycle: any RSSNotificationLifecycleHandling = NoOpRSSNotificationLifecycle(),
    downloadFileCleaner: (any RSSDownloadFileCleaning)? = nil
  ) {
    self.store = store
    self.credentialStore = credentialStore
    self.credentialUpdateHandler = credentialUpdateHandler
    self.refreshing = refreshing
    self.notificationLifecycle = notificationLifecycle
    self.downloadFileCleaner = downloadFileCleaner
  }

  public func unsubscribe(feedId: Int64) async throws {
    // Capture paths before any credential or database mutation. If the database delete fails,
    // this snapshot is never handed to the file-removal half.
    let downloadedFiles = try await downloadFileCleaner?.rssDownloadFiles(forFeedID: feedId) ?? []

    let existing: PodcastFeedCredential?
    if let credentialStore {
      // Clear first: if Keychain refuses the deletion, retain the subscription rather than orphan a
      // secret that no UI can reach. Restore the old value if the later database delete fails.
      existing = try credentialStore.load(forFeedID: feedId)
      try credentialStore.clear(forFeedID: feedId)
    } else {
      existing = nil
    }
    await notificationLifecycle.disarm(feedID: feedId)
    do {
      try await store.unsubscribe(feedId: feedId)
    } catch {
      if let existing, let credentialStore {
        try? credentialStore.save(existing, forFeedID: feedId)
      }
      throw error
    }

    // The feed delete cascades its RSS episode/download rows. Only now is it safe to remove the
    // snapshotted files; a failed unsubscribe above therefore leaves every enclosure intact.
    try await downloadFileCleaner?.removeRSSDownloadFiles(downloadedFiles)
  }

  public func hasCredential(feedId: Int64) async throws -> Bool {
    try credentialStore?.load(forFeedID: feedId) != nil
  }

  public func saveBasicCredential(username: String, password: String, feedId: Int64) async throws {
    guard let credentialStore else { throw NativeFeedCredentialPersistenceUnavailable() }
    let credential = try PodcastFeedCredential.basic(username: username, password: password)
    try credentialStore.save(credential, forFeedID: feedId)
    try Task.checkCancellation()
    try await store.clearRecovery(feedId: feedId)
    await credentialUpdateHandler.handleFeedCredentialUpdate(feedId: feedId)
    if let itemID = PodcastSourceIdentity.rss(feedId: feedId)?.itemId {
      _ = try? await refreshing.refresh(itemID: itemID)
    }
  }

  public func clearCredential(feedId: Int64) async throws {
    try credentialStore?.clear(forFeedID: feedId)
  }
}

private struct NativeFeedCredentialPersistenceUnavailable: Error {}
