import Foundation
import GRDB
import Persistence

/// Local catalogue lookups by cloud subscription identity. The catalogue stores feed URLs, the
/// cloud stores derived UUIDs, and the derivation is `PodcastCloudIdentity.subscriptionUUID`, so
/// the match is made the same way the resolver makes it rather than through a stored column that
/// could disagree with it.
enum PodcastCloudLocalCatalogue {
  static func feedIDs(in db: Database, subscriptionUUID: String) throws -> [Int64] {
    try Row.fetchAll(db, sql: "SELECT id, feedURL FROM rssFeed ORDER BY id").compactMap { row -> Int64? in
      let feedURL: String = row["feedURL"]
      guard
        PodcastCloudIdentity.subscriptionUUID(feedURL: feedURL)?.uuidString.lowercased()
          == subscriptionUUID
      else { return nil }
      let id: Int64 = row["id"]
      return id
    }
  }

  static func isSaved(in db: Database, feedIDs: [Int64], identityKey: String) throws -> Bool {
    guard feedIDs.isEmpty == false else { return false }
    let placeholders = Array(repeating: "?", count: feedIDs.count).joined(separator: ", ")
    var arguments: [(any DatabaseValueConvertible)?] = [identityKey]
    arguments += feedIDs.map { $0 as (any DatabaseValueConvertible)? }
    return try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS (
          SELECT 1 FROM rssSavedShelfEntry AS shelf
          JOIN rssEpisode AS episode ON episode.id = shelf.rssEpisodeId
          WHERE episode.identityKey = ? AND episode.feedId IN (\(placeholders)))
        """, arguments: StatementArguments(arguments)) ?? false
  }
}

/// The explicit clock repair and the republish it owes.
///
/// While the clock is quarantined nothing can be stamped, so a Saved-shelf removal commits locally
/// and records a debt instead of a send (`PodcastCloudSavedIntentResolver`). Repair clears the
/// quarantine and, in the same transaction, re-stamps every debt from current local state and
/// enqueues it; a debt whose episode was saved again since is settled without a removal.
public enum PodcastCloudClockRepair {
  public struct Outcome: Sendable, Equatable {
    /// Record names enqueued, for `PodcastCloudSyncCoordinator.outboxDidChange()`.
    public let republished: [String]
    /// Debts settled without a send: a vanished subscription, or an episode saved again since.
    public let settledWithoutSend: Int
  }

  public enum Failure: Error, Sendable, Equatable {
    /// No installation clock: sync was never enabled, so nothing can be owed.
    case noClock
  }

  public static func repair(
    database: AppDatabase, recordNameKey: PodcastCloudRecordNameKey, now: Date,
    newMutationUUID: @escaping @Sendable () -> UUID = UUID.init
  ) async throws -> Outcome {
    try await database.writeAsync { db in
      guard let fields = try PodcastCloudInstallationStore.clock(in: db) else {
        throw Failure.noClock
      }
      var clock = PodcastCloudClock(state: try PodcastCloudClockState(fields))
      let wallClock = max(0, Int64((now.timeIntervalSince1970 * 1000).rounded(.down)))
      if clock.state.repairRequired {
        try clock.repair(wallClockMilliseconds: wallClock)
      }

      var republished: [String] = []
      var settledWithoutSend = 0
      for debt in try PodcastCloudRepublishDebtStore.all(in: db) {
        guard debt.recordKind == "saved",
          let entry = try PodcastCloudRegistryStore.entry(in: db, subscriptionUUID: debt.subscriptionUUID)
        else {
          try PodcastCloudRepublishDebtStore.settle(in: db, debt)
          settledWithoutSend += 1
          continue
        }
        let feedIDs = try PodcastCloudLocalCatalogue.feedIDs(
          in: db, subscriptionUUID: debt.subscriptionUUID)
        if try PodcastCloudLocalCatalogue.isSaved(
          in: db, feedIDs: feedIDs, identityKey: debt.identityKey)
        {
          try PodcastCloudRepublishDebtStore.settle(in: db, debt)
          settledWithoutSend += 1
          continue
        }

        let stamp = try clock.generate(wallClockMilliseconds: wallClock, mutationUUID: newMutationUUID())
        let recordName = try PodcastCloudIdentity.recordName(
          kind: "saved",
          components: [
            entry.subscriptionUUID, entry.generationUUID,
            PodcastCloudIdentity.episodeDigest(identityKey: debt.identityKey),
          ],
          key: recordNameKey)
        let record = try PodcastCloudRecordCodec.encode(
          savedRegister: try PodcastCloudSavedRegister(isSaved: false, savedAt: nil, stamp: stamp),
          identity: PodcastCloudEpisodeIdentityFields(
            identityKey: debt.identityKey, alternateIdentityKey: debt.alternateIdentityKey,
            guid: debt.guid, enclosureURL: debt.enclosureURL),
          recordName: recordName)
        try PodcastCloudLocalPublication.publish(record, in: db)
        try PodcastCloudRepublishDebtStore.settle(in: db, debt)
        republished.append(recordName)
      }

      try PodcastCloudInstallationStore.advance(in: db, clock: PodcastCloudClockFields(clock.state))
      return Outcome(republished: republished, settledWithoutSend: settledWithoutSend)
    }
  }
}
