import Foundation
import GRDB

extension MediaProgressDAO {
  /// Applies only the server-pulled ebook fields. Audio position and the shared finish flag are
  /// untouched, matching the server's field-level PATCH merge.
  @discardableResult
  public func applyServerEbookResolutionAsync(
    accountId: Int64,
    identity: MediaProgressIdentity,
    ebookProgress: Double?,
    ebookLocation: String?,
    serverUpdatedAt: Date?
  ) async throws -> MediaProgressRecord {
    try await applyServerCompositeResolutionAsync(
      accountId: accountId,
      identity: identity,
      currentTime: nil,
      isFinished: false,
      ebookProgress: ebookProgress,
      ebookLocation: ebookLocation,
      // An ebook-only observation carries no visibility value; the `.keepLocal` resolution below
      // is what actually decides the field, so this argument is never read.
      hideFromContinueListening: false,
      serverUpdatedAt: serverUpdatedAt,
      resolution: .init(
        audioPosition: .keepLocal, ebookPosition: .applyServer, sharedFinish: .keepLocal)
    )
  }

  /// Applies independent audio-position, ebook-position, and shared-finish outcomes in one
  /// Persistence write. A losing or unresolved field is not copied from the server and therefore
  /// cannot erase the local value belonging to another medium. When the ebook position wins, its
  /// local Locator JSON is cleared: a server fraction is a valid resume target, but it is not a
  /// Locator and Persistence must not fabricate one.
  @discardableResult
  public func applyServerCompositeResolutionAsync(
    accountId: Int64,
    identity: MediaProgressIdentity,
    currentTime: Double?,
    isFinished: Bool,
    ebookProgress: Double?,
    ebookLocation: String?,
    hideFromContinueListening: Bool,
    serverUpdatedAt: Date?,
    resolution: CompositeResolution
  ) async throws -> MediaProgressRecord {
    try await database.writeAsync { db in
      try Self.applyServerCompositeResolution(
        db,
        accountId: accountId,
        identity: identity,
        currentTime: currentTime,
        isFinished: isFinished,
        ebookProgress: ebookProgress,
        ebookLocation: ebookLocation,
        hideFromContinueListening: hideFromContinueListening,
        serverUpdatedAt: serverUpdatedAt,
        resolution: resolution)
    }
  }

  /// Applies an already-decided `applyServer` resolution upserting by the
  /// item-level identity. `localSequence` is left untouched on an existing row: a server pull
  /// is not a local mutation, so it never advances the account's local-write ordering.
  @discardableResult
  public func applyServerResolution(
    accountId: Int64,
    identity: MediaProgressIdentity,
    currentTime: Double,
    isFinished: Bool,
    serverUpdatedAt: Date?
  ) throws -> MediaProgressRecord {
    try database.write { db in
      try Self.upsertServerProgress(
        db, accountId: accountId, identity: identity, currentTime: currentTime,
        isFinished: isFinished, serverUpdatedAt: serverUpdatedAt)
    }
  }

  @discardableResult
  public func applyServerResolutionAsync(
    accountId: Int64,
    identity: MediaProgressIdentity,
    currentTime: Double,
    isFinished: Bool,
    serverUpdatedAt: Date?
  ) async throws -> MediaProgressRecord {
    try await database.writeAsync { db in
      try Self.upsertServerProgress(
        db, accountId: accountId, identity: identity, currentTime: currentTime,
        isFinished: isFinished, serverUpdatedAt: serverUpdatedAt)
    }
  }

  /// Applies a page of already-decided pull outcomes in one transaction. A library pull must not
  /// loop the per-item calls above: every commit re-runs every open `ValueObservation` (the browse
  /// list re-fetches and re-diffs the whole library), so 100 items would cost 100 refetches.
  /// Decisions are keyed by distinct item ids and read nothing this write produces, so batching
  /// cannot change any individual outcome, and makes the page atomic.
  public func applyPulledProgressAsync(
    accountId: Int64,
    resolutions: [PulledProgressResolution],
    conflicts: [PulledProgressConflict]
  ) async throws {
    guard resolutions.isEmpty == false || conflicts.isEmpty == false else { return }
    try await database.writeAsync { db in
      for resolution in resolutions {
        try Self.upsertServerProgress(
          db, accountId: accountId, identity: resolution.identity,
          currentTime: resolution.currentTime,
          isFinished: resolution.isFinished, serverUpdatedAt: resolution.serverUpdatedAt)
      }
      for conflict in conflicts {
        try Self.upsertConflict(
          db, accountId: accountId, identity: conflict.identity,
          serverCurrentTime: conflict.serverCurrentTime, serverIsFinished: conflict.serverIsFinished,
          serverUpdatedAt: conflict.serverUpdatedAt, detectedAt: conflict.detectedAt)
      }
    }
  }

  /// Applies field-scoped pull decisions and any resulting conflict rows in one transaction.
  /// The field-scoped counterpart to `applyPulledProgressAsync`, which stays for audio-only
  /// callers and tests.
  public func applyPulledCompositeProgressAsync(
    accountId: Int64,
    resolutions: [PulledCompositeResolution],
    conflicts: [PulledCompositeConflict]
  ) async throws {
    guard resolutions.isEmpty == false || conflicts.isEmpty == false else { return }
    try await database.writeAsync { db in
      for resolution in resolutions {
        _ = try Self.applyServerCompositeResolution(
          db,
          accountId: accountId,
          identity: resolution.identity,
          currentTime: resolution.currentTime,
          isFinished: resolution.isFinished,
          ebookProgress: resolution.ebookProgress,
          ebookLocation: resolution.ebookLocation,
          hideFromContinueListening: resolution.hideFromContinueListening,
          serverUpdatedAt: resolution.serverUpdatedAt,
          serverProgressId: .observed(
            id: resolution.serverProgressId, updatedAt: resolution.serverUpdatedAt),
          resolution: resolution.resolution)
      }
      for conflict in conflicts {
        try Self.upsertConflict(
          db,
          accountId: accountId,
          identity: conflict.identity,
          serverCurrentTime: conflict.serverCurrentTime ?? 0,
          serverIsFinished: conflict.serverIsFinished,
          serverUpdatedAt: conflict.serverUpdatedAt,
          detectedAt: conflict.detectedAt,
          serverEbookProgress: conflict.serverEbookProgress,
          serverEbookLocation: conflict.serverEbookLocation)
      }
    }
  }
}
