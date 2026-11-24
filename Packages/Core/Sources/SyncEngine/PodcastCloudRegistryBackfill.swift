import Foundation
import GRDB
import Persistence

/// Gives every feed this device already follows a cloud identity, so that an install which
/// predates the registry enters sync with the same subscription UUIDs a fresh install would derive.
///
/// Not a GRDB migration: the derivation lives in `SyncEngine`, which `Persistence` must not reach,
/// and the work is idempotent and cheap enough to run at every sync enable. Every row lands in one
/// transaction, and it takes the caller's `Database` so the caller can widen that transaction.
public enum PodcastCloudRegistryBackfill {
  public struct Summary: Sendable, Equatable {
    /// Feeds given a registry entry by this run.
    public let registered: Int
    /// Feeds whose fingerprint the registry already held. Left as they were, so a second run
    /// cannot resurrect a subscription the user has since unfollowed.
    public let alreadyRegistered: Int
    /// Extra `rssFeed` rows that normalized onto a feed this run had already handled. The registry
    /// is keyed by fingerprint, so these collapse; the duplicate catalogue rows remain.
    public let collapsedDuplicates: Int
    /// Fingerprints the registry holds under a different subscription UUID than today's
    /// canonicalization derives. Nothing is rewritten: a changed identity for an existing entry is
    /// a reconciliation decision, not a backfill one.
    public let identityMismatches: Int
    /// `rssFeed.id` values whose URL does not normalize, so no stable identity can be derived.
    public let skippedFeedIDs: [Int64]

    public var isEmpty: Bool {
      registered == 0 && alreadyRegistered == 0 && collapsedDuplicates == 0
        && identityMismatches == 0 && skippedFeedIDs.isEmpty
    }
  }

  /// The canonicalization these identities were derived under. Stored per entry so a later
  /// canonicalization change can find the entries that predate it instead of guessing.
  public static let canonicalizationVersion = 1

  public static func run(in db: Database) throws -> Summary {
    var registered = 0
    var alreadyRegistered = 0
    var collapsedDuplicates = 0
    var identityMismatches = 0
    var skipped: [Int64] = []
    var handled: Set<String> = []

    for feed in try candidates(in: db) {
      guard let normalized = PodcastCloudIdentity.normalizedFeedURL(feed.feedURL),
        let fingerprint = PodcastFeedIdentity.fingerprint(feed.feedURL),
        let subscriptionUUID = PodcastCloudIdentity.subscriptionUUID(feedURL: feed.feedURL)
      else {
        skipped.append(feed.id)
        continue
      }

      if handled.contains(fingerprint) {
        collapsedDuplicates += 1
        continue
      }
      handled.insert(fingerprint)

      if let existing = try storedSubscriptionUUID(in: db, fingerprint: fingerprint) {
        alreadyRegistered += 1
        if existing != subscriptionUUID.uuidString.lowercased() { identityMismatches += 1 }
        continue
      }

      try PodcastCloudRegistryStore.register(
        in: db,
        entry: PodcastCloudRegistryEntry(
          subscriptionUUID: subscriptionUUID.uuidString.lowercased(), fingerprint: fingerprint,
          normalizedURL: normalized, canonicalizationVersion: canonicalizationVersion,
          generationUUID: PodcastCloudIdentity.initialGenerationUUID(
            subscriptionUUID: subscriptionUUID
          ).uuidString.lowercased(),
          isFollowed: true,
          followStamp: legacyStamp(subscriptionUUID: subscriptionUUID, subscribedAt: feed.subscribedAt)))
      registered += 1
    }

    return Summary(
      registered: registered, alreadyRegistered: alreadyRegistered,
      collapsedDuplicates: collapsedDuplicates, identityMismatches: identityMismatches,
      skippedFeedIDs: skipped)
  }

  public static func run(database: AppDatabase) async throws -> Summary {
    try await database.writeAsync { db in try run(in: db) }
  }

  /// A follow this device has no stamp for, because it happened before stamps existed. Seeded from
  /// the subscription date and the derived identity, with the reserved author token, so the same
  /// catalogue produces the same stamp on every device and on every re-run. Two devices that
  /// subscribed to one feed on different days still disagree here. That is a genuine difference
  /// in the facts, and last-writer-wins settles it.
  static func legacyStamp(subscriptionUUID: UUID, subscribedAt: Date) -> PodcastCloudStampFields {
    PodcastCloudStampFields(
      physicalMilliseconds: max(0, Int64((subscribedAt.timeIntervalSince1970 * 1000).rounded())),
      logicalCounter: 0,
      installationUUID: PodcastCloudIdentity.migrationAuthorInstallationUUID,
      mutationUUID: PodcastCloudIdentity.legacyMutationUUID(subscriptionUUID: subscriptionUUID)
        .uuidString.lowercased())
  }

  private struct Candidate {
    let id: Int64
    let feedURL: String
    let subscribedAt: Date
  }

  /// Ordered by the facts rather than by `rowid`, so that when duplicate catalogue rows normalize
  /// onto one identity the surviving stamp is the same on a device that subscribed in a different
  /// order. Earliest subscription wins, because the earliest is when the follow actually happened.
  private static func candidates(in db: Database) throws -> [Candidate] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT id, feedURL, subscribedAt FROM rssFeed
        ORDER BY subscribedAt ASC, feedURL ASC, id ASC
        """
    ).map { Candidate(id: $0["id"], feedURL: $0["feedURL"], subscribedAt: $0["subscribedAt"]) }
  }

  private static func storedSubscriptionUUID(in db: Database, fingerprint: String) throws -> String? {
    try String.fetchOne(
      db, sql: "SELECT subscriptionUUID FROM podcastCloudSubscriptionRegistry WHERE fingerprint = ?",
      arguments: [fingerprint])
  }
}
