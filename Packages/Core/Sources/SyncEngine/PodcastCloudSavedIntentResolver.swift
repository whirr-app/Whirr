import Foundation
import GRDB
import Persistence

/// The cloud-aware half of `NativeSavedIntentResolving`: performs the same local Saved-shelf
/// removal as the local-only resolver and, in the same transaction, stamps it and hands it to the
/// outbox.
///
/// Not a SQLite trigger: the removal is a user mutation that must carry the stamp of the mutation
/// that caused it (the other device orders it against its own edits), and a trigger has no access
/// to the clock, registry or outbox.
///
/// Runs inside the caller's transaction. A crash may repeat an idempotent cloud send but must not
/// leave state committed locally and invisible to the outbox: shelf deletion, clock advance,
/// last-accepted stamp and outbox row commit together, and a throw rolls back the progress write.
///
/// The clock is read from the database, so there is no lock or in-memory clock state. The
/// process-local monotonic anchor is not persisted and comes from `PodcastCloudMonotonicSource`.
public struct PodcastCloudSavedIntentResolver: NativeSavedIntentResolving {
  private let recordNameKey: @Sendable () -> PodcastCloudRecordNameKey?
  private let local: LocalNativeSavedIntentResolver
  private let now: @Sendable () -> Date
  private let newMutationUUID: @Sendable () -> UUID
  private let monotonic: PodcastCloudMonotonicSource

  /// The key is a closure because `RSSEpisodeStateStore` is built once at launch while the key
  /// exists only once the keyring resolves for a signed-in account's fence; asked per mutation, so
  /// the store is not rebuilt on account change. `nil` (sync off, not activated, signed out) is
  /// skipped like the other cases in `publishRemoval`.
  public init(
    recordNameKey: @escaping @Sendable () -> PodcastCloudRecordNameKey?,
    now: @escaping @Sendable () -> Date = Date.init,
    newMutationUUID: @escaping @Sendable () -> UUID = UUID.init,
    monotonic: PodcastCloudMonotonicSource = .process
  ) {
    self.recordNameKey = recordNameKey
    self.local = LocalNativeSavedIntentResolver()
    self.now = now
    self.newMutationUUID = newMutationUUID
    self.monotonic = monotonic
  }

  /// For a key already in hand, such as one activation's fixed key.
  public init(
    recordNameKey key: PodcastCloudRecordNameKey,
    now: @escaping @Sendable () -> Date = Date.init,
    newMutationUUID: @escaping @Sendable () -> UUID = UUID.init
  ) {
    self.init(recordNameKey: { key }, now: now, newMutationUUID: newMutationUUID)
  }

  public func resolveNativeSavedIntent(
    in db: Database, acceptedState: RSSEpisodeStateRecord, previousState: RSSEpisodeStateRecord?
  ) throws {
    guard
      NativeSavedIntent.removalQualifies(
        acceptedState: acceptedState, previousState: previousState)
    else { return }
    try local.resolveNativeSavedIntent(
      in: db, acceptedState: acceptedState, previousState: previousState)
    try publishRemoval(episodeId: acceptedState.episodeId, in: db)
  }

  /// Stamps the removal and enqueues it, or does nothing when the cloud cannot name or stamp this
  /// mutation yet.
  ///
  /// Never refuses the transaction: playback progress outranks sync bookkeeping.
  ///
  /// Three skips need no follow-up (nothing published could be contradicted, and first
  /// publication reads local state): no registry entry for the feed, no minted clock, no
  /// record-name key.
  ///
  /// A quarantined clock is a real gap: `generate` mints nothing, so the removal commits locally
  /// with a republish debt, and `PodcastCloudClockRepair` re-stamps and sends it after repair.
  private func publishRemoval(episodeId: Int64, in db: Database) throws {
    guard let recordNameKey = recordNameKey(),
      let identity = try Self.episodeIdentity(episodeId: episodeId, in: db),
      let subscriptionUUID = PodcastCloudIdentity.subscriptionUUID(feedURL: identity.feedURL),
      let entry = try PodcastCloudRegistryStore.entry(
        in: db, subscriptionUUID: subscriptionUUID.uuidString.lowercased()),
      let clockFields = try PodcastCloudInstallationStore.clock(in: db)
    else { return }

    var clock = monotonic.clock(try PodcastCloudClockState(clockFields))
    let stamp: PodcastCloudMutationStamp
    do {
      stamp = try clock.generate(
        wallClockMilliseconds: Int64(now().timeIntervalSince1970 * 1000),
        monotonicMilliseconds: monotonic.nowMilliseconds(),
        mutationUUID: newMutationUUID())
    } catch PodcastCloudClock.Error.quarantined {
      try PodcastCloudRepublishDebtStore.record(
        in: db,
        PodcastCloudRepublishDebt(
          recordKind: "saved", subscriptionUUID: entry.subscriptionUUID,
          identityKey: identity.identityKey,
          alternateIdentityKey: identity.fields.alternateIdentityKey, guid: identity.fields.guid,
          enclosureURL: identity.fields.enclosureURL, recordedAt: now()))
      return
    }

    let recordName = try PodcastCloudIdentity.recordName(
      kind: "saved",
      components: [
        entry.subscriptionUUID, entry.generationUUID,
        PodcastCloudIdentity.episodeDigest(identityKey: identity.identityKey),
      ],
      key: recordNameKey)
    // A save carrying a durable `isSaved: false` register, never a physical deletion: a tombstone
    // is indistinguishable from a record that never existed, so a remote device could not order it
    // against its own re-save.
    let fields = try PodcastCloudRecordCodec.encode(
      savedRegister: try PodcastCloudSavedRegister(isSaved: false, savedAt: nil, stamp: stamp),
      identity: identity.fields, recordName: recordName)

    try PodcastCloudInstallationStore.advance(in: db, clock: PodcastCloudClockFields(clock.state))
    try PodcastCloudLocalPublication.publish(fields, in: db)
  }

  private struct EpisodeIdentity {
    let feedURL: String
    let identityKey: String
    let fields: PodcastCloudEpisodeIdentityFields
  }

  /// The identity material a remote device needs to match the same episode in its own copy of the
  /// feed. It travels with the register because the record name is an opaque keyed digest.
  private static func episodeIdentity(episodeId: Int64, in db: Database) throws -> EpisodeIdentity? {
    guard let identity = try PodcastCloudLocalCatalogue.episodeIdentity(episodeId: episodeId, in: db)
    else { return nil }
    return EpisodeIdentity(
      feedURL: identity.feedURL, identityKey: identity.identityKey,
      fields: PodcastCloudEpisodeIdentityFields(
        identityKey: identity.identityKey, alternateIdentityKey: identity.alternateIdentityKey,
        guid: identity.guid, enclosureURL: identity.enclosureURL))
  }
}
