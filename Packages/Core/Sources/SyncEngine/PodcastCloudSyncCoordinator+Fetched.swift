import Foundation
import GRDB
import Persistence

/// Fetched changes: what a remote record may change locally. Everything here runs inside the
/// admission transaction except the holds and status updates a failed admission raises.
extension PodcastCloudSyncCoordinator {
  enum FetchedOutcome: Sendable {
    case applied
    case ignored
    case republish
    case quarantined(repairRequired: Bool)
  }

  func handleFetched(_ changes: PodcastCloudFetchedChanges) async throws {
    guard let namespace else { return }
    var republish = false
    for record in changes.modifications {
      if try await applyFetched(record) { republish = true }
    }
    for recordName in changes.deletions {
      // A physical deletion is transport maintenance for an inactive generation, never a user
      // deletion: only the archive and any held copy go.
      try await database.writeAsync { db in
        try PodcastCloudTransportStore.forgetSystemFields(
          in: db, namespace: namespace, recordName: recordName)
        try PodcastCloudRegistryStore.resolveUnresolved(in: db, recordName: recordName)
      }
    }
    for recordName in changes.undeclaredRecordNames {
      try await hold(recordName, send: nil, category: .undeclaredType, outbox: false)
    }
    await settleAttention()
    if republish { await outboxDidChange() }
  }

  /// Admits one fetched record. Returns true when a merge re-enqueued local work.
  func applyFetched(_ record: PodcastCloudFetchedRecord) async throws -> Bool {
    guard let namespace else { return false }
    let fields = record.fields
    let recordName = fields.recordName

    // The plaintext audit: anything in the clear beyond the `schema` marker is a mapping defect
    // or tampering, and the record is not applied.
    let clear = record.plaintextFieldNames.subtracting(
      PodcastCloudRecordLayout.permittedPlaintextFieldNames)
    guard clear.isEmpty else {
      try await hold(recordName, send: nil, category: .plaintextViolation, outbox: false)
      return false
    }
    let stamp: PodcastCloudMutationStamp?
    do {
      stamp = try PodcastCloudRecordMerge.governingStamp(of: fields)
    } catch {
      try await hold(recordName, send: nil, category: .undecodable, outbox: false)
      return false
    }
    guard stamp == nil || record.serverModificationDate != nil else {
      try await hold(recordName, send: nil, category: .missingServerDate, outbox: false)
      return false
    }

    let applier = applier
    let receivedAt = now()
    let key = recordNameKeys.current
    // Snapshotted once, outside the transaction: admission only asks whether the episode this record
    // names is playing right now, not a value the write needs to observe transactionally.
    let activeEpisodeRowIDs = self.activeEpisodeRowIDs()
    let monotonic = monotonic
    let outcome: FetchedOutcome
    var drained = false
    do {
      (outcome, drained) = try await database.writeAsync { db -> (FetchedOutcome, Bool) in
        let drained = try Self.drainBeforeAdmission(in: db, key: key, now: receivedAt, monotonic: monotonic)
        return (
          try Self.admitFetched(
            in: db, record: record, stamp: stamp, namespace: namespace, receivedAt: receivedAt,
            applier: applier, key: key, activeEpisodeRowIDs: activeEpisodeRowIDs, monotonic: monotonic),
          drained
        )
      }
    } catch {
      try await hold(recordName, send: nil, category: .unmergeable, outbox: false)
      return false
    }

    switch outcome {
    case .quarantined(let repairRequired):
      Self.log.error("Podcast sync quarantined a stamp; repair required: \(repairRequired)")
      await setStatus(repairRequired ? .clockRepairRequired : .needsAttention)
      return drained
    case .republish:
      return true
    case .applied, .ignored:
      return drained
    }
  }

  static func admitFetched(
    in db: Database, record: PodcastCloudFetchedRecord, stamp: PodcastCloudMutationStamp?,
    namespace: Data, receivedAt: Date, applier: any PodcastCloudRemoteApplying,
    key: PodcastCloudRecordNameKey?, activeEpisodeRowIDs: Set<Int64>,
    monotonic: PodcastCloudMonotonicSource
  ) throws -> FetchedOutcome {
    let fields = record.fields
    if let quarantined = try observeFetchedStamp(
      in: db, record: record, stamp: stamp, namespace: namespace, receivedAt: receivedAt,
      monotonic: monotonic)
    {
      return quarantined
    }
    try recordFetchedArchive(in: db, namespace: namespace, record: record)
    if let outcome = try admitOverPendingSend(
      in: db, namespace: namespace, record: record, receivedAt: receivedAt, applier: applier,
      monotonic: monotonic)
    {
      return outcome
    }
    if let outcome = try admitOverAcceptedValue(
      in: db, fields: fields, record: record, receivedAt: receivedAt, applier: applier, key: key,
      activeEpisodeRowIDs: activeEpisodeRowIDs, monotonic: monotonic)
    {
      return outcome
    }
    return try admitNewestValue(
      in: db, fields: fields, stamp: stamp, receivedAt: receivedAt, applier: applier)
  }

  /// Advances the local HLC past the record's stamp. A stamp the clock quarantines is held, and
  /// nothing else about the record is recorded.
  private static func observeFetchedStamp(
    in db: Database, record: PodcastCloudFetchedRecord, stamp: PodcastCloudMutationStamp?,
    namespace: Data, receivedAt: Date, monotonic: PodcastCloudMonotonicSource
  ) throws -> FetchedOutcome? {
    let recordName = record.fields.recordName
    guard let stamp, let date = record.serverModificationDate,
      let clockFields = try PodcastCloudInstallationStore.clock(in: db)
    else { return nil }
    var clock = monotonic.clock(try PodcastCloudClockState(clockFields))
    do {
      try clock.observe(
        stamp,
        serverModificationMilliseconds: Int64((date.timeIntervalSince1970 * 1000).rounded(.down)),
        monotonicMilliseconds: monotonic.nowMilliseconds())
    } catch PodcastCloudClock.Error.quarantined {
      // Persist what `observe` decided (it may have marked the local clock for repair)
      // and hold the record. A rejected stamp never advances the local HLC.
      try PodcastCloudInstallationStore.advance(in: db, clock: PodcastCloudClockFields(clock.state))
      try PodcastCloudTransportStore.hold(
        in: db, namespace: namespace, recordName: recordName, generation: nil,
        category: PodcastCloudHoldCategory.quarantinedStamp.rawValue, observedAt: receivedAt)
      return .quarantined(repairRequired: clock.state.repairRequired)
    }
    try PodcastCloudInstallationStore.advance(in: db, clock: PodcastCloudClockFields(clock.state))
    monotonic.remember(clock)
    return nil
  }

  private static func recordFetchedArchive(
    in db: Database, namespace: Data, record: PodcastCloudFetchedRecord
  ) throws {
    let recordName = record.fields.recordName
    try PodcastCloudTransportStore.recordSystemFields(
      in: db, namespace: namespace, recordName: recordName, archive: record.systemFields)
    // Past every check that holds a fetched record. If the merge below throws, this goes with it.
    try PodcastCloudTransportStore.releaseFetchedHold(in: db, namespace: namespace, recordName: recordName)
  }

  /// Merges against an outstanding send for the same record. `nil` means there is none to merge
  /// against (or it is a deletion), so admission falls through to the accepted value.
  private static func admitOverPendingSend(
    in db: Database, namespace: Data, record: PodcastCloudFetchedRecord, receivedAt: Date,
    applier: any PodcastCloudRemoteApplying, monotonic: PodcastCloudMonotonicSource
  ) throws -> FetchedOutcome? {
    let fields = record.fields
    let recordName = fields.recordName
    guard
      let pending = try PodcastCloudTransportStore.pendingSend(
        in: db, namespace: namespace, recordName: recordName),
      pending.isPhysicalDeletion == false
    else { return nil }
    let local = try PodcastCloudRecordPayload.decode(pending.payload)
    let hasUnsentListening = Self.isUnsentListeningPending(local: local, server: fields)
    switch try PodcastCloudRecordMerge.merge(
      local: local, server: fields, hasUnsentListening: hasUnsentListening)
    {
    case .keepServer:
      try PodcastCloudTransportStore.supersede(
        in: db, namespace: namespace, recordName: recordName, generation: pending.generation)
      try Self.accept(fields, receivedAt: receivedAt, applier: applier, in: db)
      return .applied
    case .publish(let merged):
      guard merged != local else { return .ignored }
      try Self.accept(merged, receivedAt: receivedAt, applier: applier, in: db)
      try PodcastCloudTransportStore.enqueue(
        in: db, recordName: recordName, payload: try PodcastCloudRecordPayload.encode(merged))
      return .republish
    case .adoptLocalAsExplicit(let localFields):
      // Leave the local row untouched (`fields`, the reset, is never accepted here) and
      // republish this device's own value as a fresh explicit action.
      try Self.republishAsExplicit(
        localFields, over: record, receivedAt: receivedAt, monotonic: monotonic, in: db)
      return .republish
    }
  }

  /// Merges against the value this device last accepted. A stamp alone cannot decide this: an
  /// explicit "finished" outranks a later playback tick, and a subscription record's follow and
  /// order registers win independently. The accepted record is kept for this comparison.
  /// `nil` means there is no accepted value for this record.
  private static func admitOverAcceptedValue(
    in db: Database, fields: PodcastCloudRecordFields, record: PodcastCloudFetchedRecord,
    receivedAt: Date, applier: any PodcastCloudRemoteApplying, key: PodcastCloudRecordNameKey?,
    activeEpisodeRowIDs: Set<Int64>, monotonic: PodcastCloudMonotonicSource
  ) throws -> FetchedOutcome? {
    let recordName = fields.recordName
    guard
      let acceptedPayload = try PodcastCloudRegistryStore.acceptedPayload(
        in: db, recordName: recordName),
      let accepted = try? PodcastCloudRecordPayload.decode(acceptedPayload),
      accepted.recordName == recordName, accepted.recordType == fields.recordType
    else { return nil }
    // An exact echo of this device's own write, or a duplicate delivery.
    if accepted == fields { return .ignored }
    // No pending send, so the only way this device has unsent listening is
    // the episode playing right now. `accepted` already equals the local episode-state row when
    // nothing is dirty, so it is what gets re-stamped.
    let hasUnsentListening = try Self.isActivelyPlayingEpisode(
      accepted: accepted, key: key, activeEpisodeRowIDs: activeEpisodeRowIDs, in: db)
    switch try PodcastCloudRecordMerge.merge(
      local: accepted, server: fields, hasUnsentListening: hasUnsentListening)
    {
    case .keepServer:
      try Self.accept(fields, receivedAt: receivedAt, applier: applier, in: db)
      return .applied
    case .publish(let merged):
      // The delivery is older than what this device already holds.
      guard merged != accepted else { return .ignored }
      // A union neither side holds, such as one device's follow with the other's order:
      // apply it here and publish it, so the server reaches it too.
      try Self.accept(merged, receivedAt: receivedAt, applier: applier, in: db)
      try PodcastCloudTransportStore.enqueue(
        in: db, recordName: recordName, payload: try PodcastCloudRecordPayload.encode(merged))
      return .republish
    case .adoptLocalAsExplicit(let localFields):
      try Self.republishAsExplicit(
        localFields, over: record, receivedAt: receivedAt, monotonic: monotonic, in: db)
      return .republish
    }
  }

  /// No accepted value, only a stamp (a row from before v69): newer applies, and an equal
  /// stamp is this device's own echo.
  private static func admitNewestValue(
    in db: Database, fields: PodcastCloudRecordFields, stamp: PodcastCloudMutationStamp?,
    receivedAt: Date, applier: any PodcastCloudRemoteApplying
  ) throws -> FetchedOutcome {
    let recordName = fields.recordName
    let accepted = try PodcastCloudRegistryStore.acceptedStamp(in: db, recordName: recordName)
      .flatMap { PodcastCloudMutationStamp($0) }
    if let stamp, let accepted, stamp <= accepted { return .ignored }
    try Self.accept(fields, receivedAt: receivedAt, applier: applier, in: db)
    return .applied
  }

  // MARK: - Unsent listening beats a reset

  enum AdmissionError: Error, Sendable, Equatable {
    /// A fresh explicit stamp was needed but no installation clock exists yet. This should not
    /// happen: the clock is established before any record can be fetched. Held like any other
    /// unmergeable record rather than guessed at.
    case clockUnavailable
    /// The fresh stamp did not outrank the remote value it was minted to beat.
    case restampNotNewer
  }

  /// Condition (a): `local` is a pending episode-state send produced as a tick (not itself an
  /// explicit action) whose position differs from the incoming value. `false`, harmlessly, for
  /// every other record type or an undecodable value.
  static func isUnsentListeningPending(
    local: PodcastCloudRecordFields, server: PodcastCloudRecordFields
  ) -> Bool {
    guard local.recordType == PodcastCloudRecordLayout.episodeState.name,
      let localState = try? PodcastCloudRecordCodec.decodeEpisodeState(local).state,
      let serverState = try? PodcastCloudRecordCodec.decodeEpisodeState(server).state
    else { return false }
    return PodcastCloudRecordMerge.isUnsentTick(local: localState, server: serverState)
  }

  /// Condition (b): no pending send exists, so the only way `accepted`'s episode counts as unsent
  /// listening is that it is playing right now, per the row ids `activeEpisodeRowIDs` snapshotted
  /// before this transaction opened.
  static func isActivelyPlayingEpisode(
    accepted: PodcastCloudRecordFields, key: PodcastCloudRecordNameKey?,
    activeEpisodeRowIDs: Set<Int64>, in db: Database
  ) throws -> Bool {
    guard activeEpisodeRowIDs.isEmpty == false, let key,
      accepted.recordType == PodcastCloudRecordLayout.episodeState.name,
      let identity = try? PodcastCloudRecordCodec.decodeEpisodeState(accepted).identity
    else { return false }
    guard
      let episodeId = try resolveLocalEpisodeId(
        recordName: accepted.recordName, identityKey: identity.identityKey, key: key, in: db)
    else { return false }
    return activeEpisodeRowIDs.contains(episodeId)
  }

  /// The local `rssEpisode.id` a followed episode-state record name resolves to, matched by the
  /// identity key the record itself carries (the same key the local reconciler used to name it),
  /// scoped to the followed subscription the record name's keyed parent identifies. `nil` when the
  /// name does not resolve to any followed subscription or local episode, in which case the
  /// active-playback check does not apply, as if the episode were not playing.
  private static func resolveLocalEpisodeId(
    recordName: String, identityKey: String, key: PodcastCloudRecordNameKey, in db: Database
  ) throws -> Int64? {
    let parts = recordName.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 4, parts[0] == PodcastCloudIdentity.version else { return nil }
    for entry in try PodcastCloudRegistryStore.allEntries(in: db) where entry.isFollowed {
      guard
        let keyed = try PodcastCloudEpisodeStateResolution.keyedParent(
          subscriptionUUID: entry.subscriptionUUID, generationUUID: entry.generationUUID, key: key),
        keyed.subscription == parts[2], keyed.generation == parts[3]
      else { continue }
      let feedIDs = try PodcastCloudLocalCatalogue.feedIDs(in: db, subscriptionUUID: entry.subscriptionUUID)
      guard feedIDs.isEmpty == false else { return nil }
      let placeholders = Array(repeating: "?", count: feedIDs.count).joined(separator: ", ")
      return try Int64.fetchOne(
        db,
        sql: """
          SELECT id FROM rssEpisode
          WHERE feedId IN (\(placeholders)) AND (identityKey = ? OR alternateIdentityKey = ?)
          """,
        arguments: StatementArguments(feedIDs) + StatementArguments([identityKey, identityKey]))
    }
    return nil
  }

  /// Publishes this device's own episode state as a fresh explicit action over `remote`, leaving
  /// the local row untouched.
  static func republishAsExplicit(
    _ localFields: PodcastCloudRecordFields, over remote: PodcastCloudFetchedRecord,
    receivedAt: Date, monotonic: PodcastCloudMonotonicSource, in db: Database
  ) throws {
    let restamped = try restampedEpisodeState(
      localFields, over: remote, receivedAt: receivedAt, monotonic: monotonic, in: db)
    try PodcastCloudLocalPublication.publish(restamped, in: db)
  }

  /// Re-stamps `localFields`, decoded as episode state, with a fresh HLC stamp as both explicit
  /// epoch and write stamp, strictly newer than `remote`'s.
  ///
  /// A conflict retry has not admitted `remote` into the clock (the fetch path has), so it is
  /// observed here; observing is idempotent and `generate` then advances past it. A stamp that
  /// still fails to outrank it is thrown, since publishing it would hand the episode to the reset.
  static func restampedEpisodeState(
    _ localFields: PodcastCloudRecordFields, over remote: PodcastCloudFetchedRecord,
    receivedAt: Date, monotonic: PodcastCloudMonotonicSource = .process, in db: Database
  ) throws -> PodcastCloudRecordFields {
    guard let clockFields = try PodcastCloudInstallationStore.clock(in: db) else {
      throw AdmissionError.clockUnavailable
    }
    let remoteState = try PodcastCloudRecordCodec.decodeEpisodeState(remote.fields).state
    var clock = monotonic.clock(try PodcastCloudClockState(clockFields))
    let monotonicMilliseconds = monotonic.nowMilliseconds()
    let serverModification =
      remote.serverModificationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) }
      ?? remoteState.writeStamp.physicalMilliseconds
    try clock.observe(
      remoteState.writeStamp, serverModificationMilliseconds: serverModification,
      monotonicMilliseconds: monotonicMilliseconds)
    let stamp = try clock.generate(
      wallClockMilliseconds: max(0, Int64((receivedAt.timeIntervalSince1970 * 1000).rounded(.down))),
      monotonicMilliseconds: monotonicMilliseconds)
    guard stamp > remoteState.explicitEpoch, stamp > remoteState.writeStamp else {
      throw AdmissionError.restampNotNewer
    }
    try PodcastCloudInstallationStore.advance(in: db, clock: PodcastCloudClockFields(clock.state))
    monotonic.remember(clock)
    let decoded = try PodcastCloudRecordCodec.decodeEpisodeState(localFields)
    let restamped = try PodcastCloudEpisodeState(
      position: decoded.state.position, isFinished: decoded.state.isFinished,
      isDismissed: decoded.state.isDismissed, explicitEpoch: stamp, writeStamp: stamp)
    return try PodcastCloudRecordCodec.encode(
      episodeState: restamped, identity: decoded.identity, recordName: localFields.recordName)
  }

  // MARK: - Account and zone

  /// Sign-out and switch fence everything: sends stop, the ledger is dropped, and this
  /// namespace's outbox is quarantined so no old-account payload is ever sent implicitly.
  /// The engine stays constructed, so a later sign-in is heard. Resuming is `enable` with the new
  /// fence, after the user's merge choice; local intent is rebased with fresh mutations then.
  func handleAccountChange(_ change: PodcastCloudAccountChange) async throws {
    inFlight = [:]
    switch change {
    case .signIn:
      if phase == .signedOut { await setStatus(.accountUnavailable) }
    case .signOut, .switchAccounts:
      guard let namespace else { return }
      phase = .signedOut
      try await transport.quarantine(namespace: namespace)
      recordNameKeys.set(nil)
      await setStatus(.accountUnavailable)
    }
  }

  /// Zone loss. `zoneNotFound` before this namespace ever established a zone is the creation still
  /// under way; every other loss stops sends and waits for the user. The zone is
  /// never recreated here, and `zoneEstablished` stays set so the next launch reaches the
  /// same conclusion instead of creating a fresh zone.
  func handleZoneLoss(_ loss: PodcastCloudZoneLoss) async throws {
    guard let namespace else { return }
    let established = try await transport.state().zoneEstablished
    if loss == .zoneNotFound, established == false, zoneIntent == .create { return }
    phase = .zoneLost
    inFlight = [:]
    try await transport.discardEngineState(namespace: namespace)
    await setStatus(.zoneLost(loss))
  }
}
