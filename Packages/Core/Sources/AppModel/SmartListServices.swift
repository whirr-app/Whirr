import Foundation
import Persistence

/// Which smart list sources are usable right now. Native is the device preference, Audiobookshelf
/// is a signed-in account. The feature shows when either is available.
public struct SmartListSourceState: Sendable, Equatable {
  public let nativeEnabled: Bool
  /// The signed-in account's row id, nil when signed out.
  public let accountID: Int64?

  public init(nativeEnabled: Bool, accountID: Int64?) {
    self.nativeEnabled = nativeEnabled
    self.accountID = accountID
  }

  public var isAvailable: Bool { nativeEnabled || accountID != nil }
}

/// How a list's Play reaches `PlaybackModel`. Composition binds it to
/// `PlaybackModel.startReportingSuccess(..., run: .begin(listID:))`. The run row is written there,
/// after the start succeeds; the smart list models never write it.
@MainActor
public protocol SmartListPlaybackStarting: AnyObject {
  /// True when playback started.
  func startFromList(listID: Int64, itemID: String, episodeID: String) async -> Bool
}

/// The durable stores, readings and seams the three smart list models share. One value, built once
/// by composition.
public struct SmartListServices: Sendable {
  public let store: SmartListStore
  public let runs: SmartListRunStore
  public let hiddenEpisodes: SmartListHiddenEpisodeStore
  public let expansionReading: SmartListExpansionReading
  public let showCatalog: any SmartListShowCatalogReading
  /// Builds the episodes reading for the native flag in force. Native-off makes the native half
  /// (and its twin rule) empty.
  public let makeReading: @Sendable (_ nativeEnabled: Bool) -> SmartListEpisodesReading
  /// Save-time expansion of one list's Audiobookshelf shows; bind to
  /// `SmartListShowExpansion.expand(listID:)`.
  public let expand: @Sendable (_ listID: Int64) async -> Void
  /// Optional observation of the active run's list id, for a composition that can offer one.
  /// Without it the models re-read `SmartListRunStore.current()` on each change they see.
  public let observeActiveRunListID: (@Sendable () -> AsyncStream<Int64?>)?
  /// Deletes a list. Bind to `SmartListDownloadReconciler.deleteList`, which releases the list's
  /// claimed downloads first: the delete cascades its claim rows, which would strand their files.
  /// Defaults to the store's plain delete.
  public let deleteList: @Sendable (_ listID: Int64) async throws -> Void

  let subscriptions: any NativePodcastSubscriptionsReading
  let accountIdentity: any AccountIdentityReading

  public init(
    database: AppDatabase,
    subscriptions: any NativePodcastSubscriptionsReading,
    accountIdentity: any AccountIdentityReading,
    showCatalog: (any SmartListShowCatalogReading)? = nil,
    expand: @escaping @Sendable (_ listID: Int64) async -> Void = { _ in },
    observeActiveRunListID: (@Sendable () -> AsyncStream<Int64?>)? = nil,
    deleteList: (@Sendable (_ listID: Int64) async throws -> Void)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    store = SmartListStore(database: database)
    runs = SmartListRunStore(database: database)
    hiddenEpisodes = SmartListHiddenEpisodeStore(database: database)
    expansionReading = SmartListExpansionReading(database: database)
    makeReading = { SmartListEpisodesReading(database: database, nativeEnabled: $0, now: now) }
    self.subscriptions = subscriptions
    self.accountIdentity = accountIdentity
    self.showCatalog = showCatalog ?? DefaultSmartListShowCatalogReading(database: database)
    self.expand = expand
    self.observeActiveRunListID = observeActiveRunListID
    let store = store
    self.deleteList = deleteList ?? { try await store.delete(id: $0) }
  }

  /// Native preference and account, combined. Yields once both have reported, then on change.
  func observeSources() -> AsyncStream<SmartListSourceState> {
    let subscriptions = subscriptions
    let accountIdentity = accountIdentity
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let combiner = SourceCombiner(continuation: continuation)
      let native = Task {
        for await enabled in subscriptions.observeEnabled() { combiner.native(enabled) }
        combiner.nativeFinished()
      }
      let account = Task {
        for await identity in accountIdentity.observeAccountIdentity() {
          combiner.account(identity?.id)
        }
        combiner.accountFinished()
      }
      continuation.onTermination = { _ in
        native.cancel()
        account.cancel()
      }
    }
  }

  /// Runs save-time expansion without holding the caller: it is a user-initiated network pass.
  @discardableResult
  func startExpansion(listID: Int64) -> Task<Void, Never> {
    let expand = expand
    return Task { await expand(listID) }
  }
}

private final class SourceCombiner: @unchecked Sendable {
  private let lock = NSLock()
  private let continuation: AsyncStream<SmartListSourceState>.Continuation
  private var nativeEnabled: Bool?
  private var accountID: Int64?
  private var accountReported = false
  private var last: SmartListSourceState?

  init(continuation: AsyncStream<SmartListSourceState>.Continuation) {
    self.continuation = continuation
  }

  func native(_ value: Bool) {
    lock.lock()
    nativeEnabled = value
    emitLocked()
    lock.unlock()
  }

  func account(_ value: Int64?) {
    lock.lock()
    accountID = value
    accountReported = true
    emitLocked()
    lock.unlock()
  }

  /// A source that never reports counts as unavailable rather than leaving the models loading.
  func nativeFinished() {
    lock.lock()
    if nativeEnabled == nil { nativeEnabled = false }
    emitLocked()
    lock.unlock()
  }

  func accountFinished() {
    lock.lock()
    accountReported = true
    emitLocked()
    lock.unlock()
  }

  private func emitLocked() {
    guard let nativeEnabled, accountReported else { return }
    let state = SmartListSourceState(nativeEnabled: nativeEnabled, accountID: accountID)
    guard state != last else { return }
    last = state
    continuation.yield(state)
  }
}
