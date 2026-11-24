import Foundation
import GRDB

/// Errors `DownloadStore` raises. Illegal transitions, unknown ids, and a duplicate identity are
/// programmer/caller errors, not retryable transfer conditions.
public enum DownloadStoreError: Error, Equatable, Sendable {
  /// (account, item, episode-or-null, server file) already has a row.
  case duplicateDownload(
    accountId: Int64, itemId: Int64, podcastEpisodeId: Int64?, serverFileIno: String)
  case downloadNotFound(Int64)
  case illegalTransition(from: DownloadState, to: DownloadState)
  /// `complete(downloadId:finalSizeBytes:)` was called without a verified (positive) final size.
  case completionRequiresVerifiedFinalSize
  /// `complete(downloadId:finalSizeBytes:)` was called on a row with no relative path.
  case completionRequiresRelativePath
  /// `finalizeDeletion(downloadId:)` was called on a row not yet marked `deleting`. Row removal
  /// is only legal once the row is `deleting` and its file handled.
  case finalizeDeletionRequiresDeletingState(Int64)
}

/// DB-facing download store: per-file download identity, transition enforcement, launch recovery,
/// and the per-item aggregate/observation surface. No file I/O or scheduling/network logic; like
/// `OutboxStore`, it only tracks state.
public struct DownloadStore: Sendable {
  let database: AppDatabase

  /// The allowed-transition matrix for `transition(downloadId:to:...)`; any other pair throws
  /// `.illegalTransition`.
  ///
  /// - `pending -> downloading`: the scheduler starts a transfer. `pending -> deleting`: cancelled
  ///   before starting.
  /// - `downloading -> pending`: requeued, including a Wi-Fi hold (`holdReason ==
  ///   .waitingForWiFi`), a durable non-error state rather than a paused one.
  /// - `downloading -> paused`: user pause. `downloading -> pausedAuth`: a `401` mid-transfer.
  /// - `downloading -> failed` / `-> deleting`: terminal transport/validation failure, or cancel.
  /// - `paused -> pending`: user resume (always via `pending`). `paused -> deleting`: cancelled.
  /// - `pausedAuth -> pending`: the only automatic exit, after re-authentication (no
  ///   `pausedAuth -> downloading` edge). `pausedAuth -> deleting`: cancelled.
  /// - `interrupted -> pending`: retried after a force-quit is found on launch.
  ///   `interrupted -> failed` / `-> deleting`: given up on, or cancelled.
  /// - `failed -> pending`: retried. `failed -> deleting`: removed.
  /// - `completed -> deleting`: the user removes it. `completed -> failed`: only
  ///   `DownloadIntegritySweep`, when the file went missing outside `DownloadFileStore`'s deletion
  ///   protocol.
  ///
  /// `completed` never appears as a `to` value: the only path is `complete(downloadId:
  /// finalSizeBytes:)`, which enforces the verified-size/relative-path guard. Nor does
  /// `interrupted`: only `init`'s launch reconciliation (a bulk `UPDATE`, like
  /// `OutboxStore.recoverStaleSendingRows`) produces it. `deleting` has no outgoing edges; the
  /// deletion protocol removes the row once the file is gone.
  static let legalTransitions: [DownloadState: Set<DownloadState>] = [
    .pending: [.downloading, .deleting],
    .downloading: [.pending, .paused, .pausedAuth, .failed, .deleting],
    .paused: [.pending, .deleting],
    .pausedAuth: [.pending, .deleting],
    .interrupted: [.pending, .failed, .deleting],
    .failed: [.pending, .deleting],
    .completed: [.deleting, .failed],
    .deleting: [],
  ]

  public init(database: AppDatabase) throws {
    self.database = database
    try Self.reconcileAfterLaunch(on: database)
  }

  /// Force-quit cancels an in-flight background transfer, so a row still `downloading` at the
  /// last clean shutdown is inferred `interrupted`. Every store construction (every app launch)
  /// does this bulk reconciliation before anything else uses the store, like
  /// `OutboxStore.recoverStaleSendingRows`. `paused`, `pausedAuth` and `deleting` rows are left
  /// for their own recovery paths.
  private static func reconcileAfterLaunch(on database: AppDatabase) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE download SET state = ? WHERE state = ?",
        arguments: [DownloadState.interrupted.rawValue, DownloadState.downloading.rawValue])
    }
  }
}
