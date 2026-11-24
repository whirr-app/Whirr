import Foundation
import Persistence

public enum AudioBookmarkIntentError: Error, Equatable, Sendable {
  case notAuthenticated
}

/// The listener's Audiobookshelf audio bookmarks for one item.
/// Every write persists the local row and its outbox row before returning, then asks for a drain.
public protocol AudioBookmarkIntents: Sendable {
  /// The item's bookmarks for the signed-in account, earliest first, re-emitted on every change.
  /// Empty and finished when no account is signed in.
  func observeBookmarks(itemID: String) -> AsyncStream<[AudioBookmark]>
  /// Adds a bookmark at the whole second at or before `time`.
  func addBookmark(itemID: String, at time: Double, title: String) async throws
    -> AudioBookmarkCreation
  func renameBookmark(itemID: String, time: Double, to title: String) async throws
  func deleteBookmark(itemID: String, time: Double) async throws
}

/// Bookmark intents for previews, harnesses and compositions before sign-in.
public struct NoOpAudioBookmarkIntents: AudioBookmarkIntents {
  public init() {}
  public func observeBookmarks(itemID: String) -> AsyncStream<[AudioBookmark]> {
    AsyncStream { $0.finish() }
  }
  public func addBookmark(itemID: String, at time: Double, title: String) async throws
    -> AudioBookmarkCreation
  {
    .created(AudioBookmark(serverItemID: itemID, time: time.rounded(.down), title: title, createdAt: nil))
  }
  public func renameBookmark(itemID: String, time: Double, to title: String) async throws {}
  public func deleteBookmark(itemID: String, time: Double) async throws {}
}

/// Resolves the signed-in account for `AudioBookmarkStore` and requests a drain after each
/// committed write, as `ItemProgressCoordinator` does for progress.
public actor AudioBookmarkCoordinator: AudioBookmarkIntents {
  private let accountDAO: AccountDAO
  private let store: AudioBookmarkStore
  private let requestDrain: @Sendable () async -> Void
  private let now: @Sendable () -> Date

  public init(
    database: AppDatabase,
    requestDrain: @escaping @Sendable () async -> Void = {},
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    accountDAO = AccountDAO(database: database)
    store = AudioBookmarkStore(database: database)
    self.requestDrain = requestDrain
    self.now = now
  }

  public nonisolated func observeBookmarks(itemID: String) -> AsyncStream<[AudioBookmark]> {
    let accountDAO = accountDAO
    let store = store
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        guard let accountId = try? await accountDAO.fetchAsync()?.id else {
          continuation.yield([])
          continuation.finish()
          return
        }
        for await bookmarks in store.observeBookmarks(accountId: accountId, serverItemId: itemID) {
          continuation.yield(bookmarks)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func addBookmark(itemID: String, at time: Double, title: String) async throws
    -> AudioBookmarkCreation
  {
    let accountId = try await signedInAccountId()
    // `rounded(.down)` of a NaN or infinity is itself, so the store's validation still sees it.
    let outcome = try await store.create(
      accountId: accountId, serverItemId: itemID, time: time.rounded(.down), title: title,
      createdAt: now())
    if case .created = outcome {
      await requestDrain()
    }
    return outcome
  }

  public func renameBookmark(itemID: String, time: Double, to title: String) async throws {
    let accountId = try await signedInAccountId()
    if try await store.rename(accountId: accountId, serverItemId: itemID, time: time, title: title) {
      await requestDrain()
    }
  }

  public func deleteBookmark(itemID: String, time: Double) async throws {
    let accountId = try await signedInAccountId()
    if try await store.delete(accountId: accountId, serverItemId: itemID, time: time) {
      await requestDrain()
    }
  }

  private func signedInAccountId() async throws -> Int64 {
    guard let accountId = try await accountDAO.fetchAsync()?.id else {
      throw AudioBookmarkIntentError.notAuthenticated
    }
    return accountId
  }
}
