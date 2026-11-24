import Foundation
import GRDB

public enum RSSEpisodeStateStoreError: Error, Equatable, Sendable {
  case episodeNotFound
  case staleLocalSequence(captured: Int64, current: Int64)
}

/// Outcome of one tick write. `.suppressedNearZeroReset` means the guard fired: nothing was
/// written and the stored row is unchanged.
public enum RSSTickOutcome: Equatable, Sendable {
  case applied(localSequence: Int64)
  case suppressedNearZeroReset(retainedPosition: Double)
}

/// Outcome of applying a listen the Watch reported. A rejection is not an error: the
/// phone's own row already wins under `RSSEpisodePeerListen`.
public enum RSSPeerListenOutcome: Equatable, Sendable {
  case applied(localSequence: Int64)
  case rejected(RSSEpisodePeerListen.Reason)
}

/// Local playback state for an RSS episode.
///
/// The single writer of `rssEpisodeState`. The monotonic sequence stops a superseded playback
/// task's late tick clobbering a newer local write. The near-zero thresholds are copied from
/// `ProgressMergePolicy` (ARCHITECTURE.md D33) because Persistence must not depend on SyncEngine.
///
/// Every write goes through `commit`, which applies the row and resolves the Saved-shelf
/// consequence in one transaction, so no writer can skip the resolver and cloud sync attaches at
/// construction, not per call site.
public struct RSSEpisodeStateStore: Sendable {
  private let database: AppDatabase
  private let savedIntent: any NativeSavedIntentResolving

  private static let zeroPositionCeiling: Double = 5
  private static let substantialLocalFloor: Double = 60
  private static let substantialLocalFraction: Double = 0.02

  /// `savedIntent` defaults to the local-only resolver. Composition attaches the cloud-aware one
  /// when sync is enabled.
  public init(
    database: AppDatabase,
    savedIntent: any NativeSavedIntentResolving = LocalNativeSavedIntentResolver()
  ) {
    self.database = database
    self.savedIntent = savedIntent
  }

  public func fetchState(episodeId: Int64) async throws -> RSSEpisodeStateRecord? {
    try await database.readAsync { db in
      try RSSEpisodeStateRecord.fetchOne(db, key: episodeId)
    }
  }

  public func recordTick(
    episodeId: Int64,
    position: Double,
    finished: Bool,
    capturedSequence: Int64,
    now: Date
  ) async throws -> RSSTickOutcome {
    let savedIntent = self.savedIntent
    return try await database.writeAsync { db in
      let episode = try Self.episode(episodeId: episodeId, in: db)
      guard episode.exists else { throw RSSEpisodeStateStoreError.episodeNotFound }

      let existing = try RSSEpisodeStateRecord.fetchOne(db, key: episodeId)

      if let existing {
        guard capturedSequence >= existing.localSequence else {
          throw RSSEpisodeStateStoreError.staleLocalSequence(
            captured: capturedSequence, current: existing.localSequence)
        }
        if Self.nearZeroResetGuardFires(
          storedPosition: existing.position, incomingPosition: position, duration: episode.duration)
        {
          return .suppressedNearZeroReset(retainedPosition: existing.position)
        }
      }

      let localSequence = (existing?.localSequence ?? 0) + 1
      // Progress clears the dismissal, the same way the account-owned progress writer does:
      // playing an episode again is the only way a listener asks for it back on the shelf.
      let record = RSSEpisodeStateRecord(
        episodeId: episodeId, position: position, finished: finished,
        hideFromContinueListening: false, localSequence: localSequence, updatedAt: now)
      try Self.commit(record, previous: existing, savedIntent: savedIntent, in: db)
      return .applied(localSequence: localSequence)
    }
  }

  /// Applies a listen the Watch reported as a listen on this phone.
  ///
  /// It writes through `commit`, the same path a local tick takes, so the Saved-shelf resolver runs
  /// and the cloud dirty-log triggers queue the change for the iPad. `updatedAt` is the chosen
  /// listen time, not the wall clock: that is what the merge across devices compares.
  public func applyPeerListen(
    episodeId: Int64, position: Double, finished: Bool, listenedAt: Date,
    duration: Double?, now: Date
  ) async throws -> RSSPeerListenOutcome {
    let savedIntent = self.savedIntent
    return try await database.writeAsync { db in
      let episode = try Self.episode(episodeId: episodeId, in: db)
      guard episode.exists else { throw RSSEpisodeStateStoreError.episodeNotFound }

      let existing = try RSSEpisodeStateRecord.fetchOne(db, key: episodeId)
      let outcome = RSSEpisodePeerListen.resolve(
        watchPosition: position, watchFinished: finished, watchListenedAt: listenedAt,
        phone: existing.map {
          (position: $0.position, finished: $0.finished, updatedAt: $0.updatedAt)
        },
        duration: duration ?? episode.duration, now: now)

      let updatedAt: Date
      switch outcome {
      case .apply(let chosen): updatedAt = chosen
      case .reject(let reason): return .rejected(reason)
      }

      let localSequence = (existing?.localSequence ?? 0) + 1
      // A listen is progress, so it clears the Continue Listening dismissal exactly as a local
      // tick does.
      let record = RSSEpisodeStateRecord(
        episodeId: episodeId, position: position, finished: finished,
        hideFromContinueListening: false, localSequence: localSequence, updatedAt: updatedAt)
      try Self.commit(record, previous: existing, savedIntent: savedIntent, in: db)
      return .applied(localSequence: localSequence)
    }
  }

  /// Explicitly marking an episode unplayed restarts it; this legitimate reset path bypasses the
  /// near-zero tick guard by construction.
  public func setFinished(episodeId: Int64, finished: Bool, now: Date) async throws -> Int64 {
    let savedIntent = self.savedIntent
    return try await database.writeAsync { db in
      try Self.writeExplicit(
        episodeId: episodeId, positionOverride: finished ? nil : 0, finished: finished,
        now: now, savedIntent: savedIntent, in: db)
    }
  }

  /// Explicitly starts the episode over; this legitimate reset path bypasses the near-zero tick
  /// guard by construction.
  public func resetProgress(episodeId: Int64, now: Date) async throws -> Int64 {
    let savedIntent = self.savedIntent
    return try await database.writeAsync { db in
      try Self.writeExplicit(
        episodeId: episodeId, positionOverride: 0, finished: false, now: now,
        savedIntent: savedIntent, in: db)
    }
  }

  /// Marks a whole set of episodes in one transaction, so a show-level "mark all played" either
  /// lands completely or not at all. Looping `setFinished` instead would open one transaction per
  /// episode and could leave a forty-episode show half-marked behind a single failure message.
  public func setFinished(
    episodeIds: [Int64], finished: Bool, now: Date
  ) async throws {
    guard episodeIds.isEmpty == false else { return }
    let savedIntent = self.savedIntent
    try await database.writeAsync { db in
      for episodeId in episodeIds {
        _ = try Self.writeExplicit(
          episodeId: episodeId, positionOverride: finished ? nil : 0, finished: finished,
          now: now, savedIntent: savedIntent, in: db)
      }
    }
  }

  /// Dismisses the episode from Continue Listening, or restores it, without touching position or
  /// finish. Not a progress edit, so the near-zero tick guard does not apply, and it never removes
  /// a Saved-shelf entry.
  ///
  /// A missing state row is created, not rejected: an episode with no progress is already off the
  /// shelf, and recording the dismissal saves the caller distinguishing the cases.
  public func setHiddenFromContinueListening(
    episodeId: Int64, isHidden: Bool, now: Date
  ) async throws -> Int64 {
    let savedIntent = self.savedIntent
    return try await database.writeAsync { db in
      guard try Self.episode(episodeId: episodeId, in: db).exists else {
        throw RSSEpisodeStateStoreError.episodeNotFound
      }
      let existing = try RSSEpisodeStateRecord.fetchOne(db, key: episodeId)
      let localSequence = (existing?.localSequence ?? 0) + 1
      let record = RSSEpisodeStateRecord(
        episodeId: episodeId, position: existing?.position ?? 0,
        finished: existing?.finished ?? false, hideFromContinueListening: isHidden,
        localSequence: localSequence, updatedAt: now)
      try Self.commit(record, previous: existing, savedIntent: savedIntent, in: db)
      return localSequence
    }
  }

  /// Writes a remote device's episode state, inside the cloud admission transaction.
  ///
  /// The sequence advances like any write, so a session holding the previous one has its next tick
  /// refused as stale: a tick captured before a newer remote action must not undo it. No
  /// Saved-shelf consequence runs: the finishing device resolved its own shelf, and that removal
  /// arrives as its own register.
  public static func applyRemote(
    episodeId: Int64, position: Double, finished: Bool, hideFromContinueListening: Bool,
    updatedAt: Date, in db: Database
  ) throws {
    guard try episode(episodeId: episodeId, in: db).exists else {
      throw RSSEpisodeStateStoreError.episodeNotFound
    }
    let existing = try RSSEpisodeStateRecord.fetchOne(db, key: episodeId)
    let record = RSSEpisodeStateRecord(
      episodeId: episodeId, position: position, finished: finished,
      hideFromContinueListening: hideFromContinueListening,
      localSequence: (existing?.localSequence ?? 0) + 1, updatedAt: updatedAt)
    if existing == nil {
      try record.insert(db)
    } else {
      try record.update(db)
    }
  }

  /// `positionOverride` nil keeps the stored position (0 for a fresh row).
  private static func writeExplicit(
    episodeId: Int64,
    positionOverride: Double?,
    finished: Bool,
    now: Date,
    savedIntent: any NativeSavedIntentResolving,
    in db: Database
  ) throws -> Int64 {
    guard try episode(episodeId: episodeId, in: db).exists else {
      throw RSSEpisodeStateStoreError.episodeNotFound
    }
    let existing = try RSSEpisodeStateRecord.fetchOne(db, key: episodeId)
    let localSequence = (existing?.localSequence ?? 0) + 1
    let position = positionOverride ?? existing?.position ?? 0
    let record = RSSEpisodeStateRecord(
      episodeId: episodeId, position: position, finished: finished,
      hideFromContinueListening: false, localSequence: localSequence, updatedAt: now)
    try commit(record, previous: existing, savedIntent: savedIntent, in: db)
    return localSequence
  }

  /// Applies the row and resolves its Saved-shelf consequence, in that order, in one transaction.
  private static func commit(
    _ record: RSSEpisodeStateRecord,
    previous: RSSEpisodeStateRecord?,
    savedIntent: any NativeSavedIntentResolving,
    in db: Database
  ) throws {
    if previous == nil {
      try record.insert(db)
    } else {
      try record.update(db)
    }
    try savedIntent.resolveNativeSavedIntent(
      in: db, acceptedState: record, previousState: previous)
  }

  private static func episode(episodeId: Int64, in db: Database) throws -> (exists: Bool, duration: Double?) {
    guard
      let row = try Row.fetchOne(
        db,
        // The downloaded file's length where there is one: positions are on its timeline.
        sql: """
          SELECT \(RSSDownloadDurationStore.preferredDurationSQL(episode: "episode", download: "download"))
            AS duration
          FROM rssEpisode AS episode
          LEFT JOIN rssDownload AS download ON download.episodeId = episode.id
          WHERE episode.id = ?
          """,
        arguments: [episodeId])
    else { return (false, nil) }
    return (true, row["duration"])
  }

  private static func nearZeroResetGuardFires(
    storedPosition: Double, incomingPosition: Double, duration: Double?
  ) -> Bool {
    guard incomingPosition <= zeroPositionCeiling,
      storedPosition > substantialLocalFloor
    else { return false }
    guard let duration, duration > 0 else { return true }
    return storedPosition / duration > substantialLocalFraction
  }
}
