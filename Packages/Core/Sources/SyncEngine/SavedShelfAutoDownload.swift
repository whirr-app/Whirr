import Foundation
import Persistence

// MARK: - Download request boundary

/// The three ordinary download intents the Saved for Later policy can reach. Wider than
/// `QueueAutoDownloadRequesting` by exactly one method: a saved identity may be an EPUB, which
/// Up Next rejects outright.
public protocol SavedShelfAutoDownloadRequesting: Sendable {
  func requestDownload(itemID: String) async throws
  func requestEbookDownload(itemID: String) async throws
  func requestEpisodeDownload(itemID: String, episodeID: String) async throws
}

extension DownloadCoordinator: SavedShelfAutoDownloadRequesting {}

/// Default request boundary for compositions that have not wired a download coordinator yet.
public struct NoOpSavedShelfAutoDownloadRequesting: SavedShelfAutoDownloadRequesting, Sendable {
  public init() {}
  public func requestDownload(itemID: String) async throws {}
  public func requestEbookDownload(itemID: String) async throws {}
  public func requestEpisodeDownload(itemID: String, episodeID: String) async throws {}
}

/// Explicit no-op policy provider for callers that do not yet have a device preference store.
public struct NoOpSavedShelfAutoDownloadPolicyProviding: SavedShelfAutoDownloadPolicyProviding,
  Sendable
{
  public init() {}
  public var savedShelfAutoDownloadPolicy: SavedShelfAutoDownloadPolicy { .never }
}

// MARK: - Saved shelf decorator

/// Adds best-effort download requests to successful Saved for Later saves. The wrapped store
/// commits first; a request failure is recorded as a bounded download diagnostic and never
/// changes the already-committed save.
///
/// Event-driven only: `wifiOnly` is best-effort at save time and a cellular save is never retried.
/// A saved download is an eviction candidate (`StorageEvictionStore.fetchCandidates` never joins
/// `savedShelfEntry`), so an Up Next-style reconciler would keep re-requesting what the storage
/// ceiling just evicted.
///
/// Additive only: `remove` deletes nothing. The storage ceiling and the podcast reaper are the
/// only evictors.
public struct SavedShelfAutoDownload: SavedShelfStoring, Sendable {
  private let store: any SavedShelfStoring
  private let targets: any SavedShelfDownloadTargetReading
  private let requesting: any SavedShelfAutoDownloadRequesting
  private let preferences: any SavedShelfAutoDownloadPolicyProviding
  private let networkConditions: any NetworkConditions
  private let diagnostics: any DiagnosticsRecording
  private let accountId: Int64?
  private let now: @Sendable () -> Date

  public init(
    store: any SavedShelfStoring,
    targets: any SavedShelfDownloadTargetReading = NoOpSavedShelfStore(),
    requesting: any SavedShelfAutoDownloadRequesting = NoOpSavedShelfAutoDownloadRequesting(),
    preferences: any SavedShelfAutoDownloadPolicyProviding =
      NoOpSavedShelfAutoDownloadPolicyProviding(),
    networkConditions: any NetworkConditions,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    accountId: Int64? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.targets = targets
    self.requesting = requesting
    self.preferences = preferences
    self.networkConditions = networkConditions
    self.diagnostics = diagnostics
    self.accountId = accountId
    self.now = now
  }

  @discardableResult
  public func save(_ identity: SavedShelfIdentity) async throws -> SavedShelfSaveOutcome {
    let outcome = try await store.save(identity)
    if outcome == .saved {
      await requestIfAllowed(identity: identity)
    }
    return outcome
  }

  public func remove(_ identity: SavedShelfIdentity) async throws {
    try await store.remove(identity)
  }

  /// `.saved` only: re-saving a still-saved identity is an idempotent no-op in the store, so it
  /// must not re-request either.
  private func requestIfAllowed(identity: SavedShelfIdentity) async {
    guard admissionAllowed else { return }
    let startedAt = now()

    let resolved: [SavedShelfDownloadTarget]
    do {
      resolved = try await targets.downloadTargets(for: identity)
    } catch {
      await recordDiagnostic(statusClass: .clientError, startedAt: startedAt)
      return
    }

    var failureCount = 0
    for target in resolved {
      // Each medium is requested independently so one failure cannot suppress the other.
      do {
        switch target {
        case .audio(let itemID):
          try await requesting.requestDownload(itemID: itemID)
        case .ebook(let itemID):
          try await requesting.requestEbookDownload(itemID: itemID)
        case .episode(let itemID, let episodeID):
          try await requesting.requestEpisodeDownload(itemID: itemID, episodeID: episodeID)
        }
      } catch {
        failureCount += 1
      }
    }

    if failureCount > 0 {
      await recordDiagnostic(statusClass: .clientError, startedAt: startedAt)
    }
  }

  private var admissionAllowed: Bool {
    switch preferences.savedShelfAutoDownloadPolicy {
    case .never: false
    case .wifiOnly: networkConditions.isConstrainedOrCellular == false
    case .always: true
    }
  }

  private func recordDiagnostic(statusClass: DiagnosticsStatusClass, startedAt: Date) async {
    guard let accountId else { return }
    await diagnostics.record(
      DiagnosticsEvent(
        category: .download, statusClass: statusClass,
        durationMilliseconds: SyncEngine.durationMilliseconds(startedAt: startedAt, endedAt: now())),
      accountId: accountId)
  }
}
