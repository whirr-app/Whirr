import Foundation
import GRDB
import Persistence

/// The publication path: turns the v70 dirty log into stamped outbox records.
///
/// For each dirty entity it builds the synced register from the local tables, compares it with the
/// record this device last accepted, and publishes only a register difference. Descriptive
/// metadata such as titles never counts, so a feed refresh does not churn records. Remote
/// projection marks the same entities; the drain then finds local equal to accepted and publishes
/// nothing, which keeps projection from echoing.
///
/// Stamps:
///
/// - a register differing from an accepted value is a live edit, stamped by the installation
///   clock, which advances once per drain by the monotonic time since its server anchor was
///   observed, once it has one (`PodcastCloudMonotonicSource`);
/// - in the bootstrap backfill (`seedingUnaccepted`), a register with no accepted value is local
///   history the cloud has never seen and carries a seed stamp: the entity's own date, the
///   reserved migration author, and a mutation UUID derived from the record and its value. The
///   same facts seed the same stamp everywhere, and a real edit on the same millisecond outranks
///   it. Outside the backfill, such an entity was first touched while syncing: a live edit.
///
/// Entries drain in dependency order, subscriptions first, since every child record is filed under
/// the registry entry a subscription's drain may create.
///
/// Everything happens in the caller's transaction: the dirty entry, the registry, the accepted
/// value and the outbox row commit together.
public enum PodcastCloudLocalReconciler {
  public struct Outcome: Sendable, Equatable {
    /// Record names enqueued, for `PodcastCloudSyncCoordinator.outboxDidChange()`.
    public var published: [String] = []
    /// Entries cleared without a send: unchanged, or no longer describing an entity.
    public var settled = 0
    /// Entries left in the log because their record could not be built or published. The next
    /// drain tries them again, so a correction to the row, or a fixed build, still sends it.
    public var failed = 0
    /// True when nothing drained because the clock cannot stamp: no clock yet, or quarantined.
    public var deferred = false

    public init() {}
  }

  public static let defaultBatchLimit = 2_000

  public static func drain(
    in db: Database, recordNameKey: PodcastCloudRecordNameKey, now: Date,
    newMutationUUID: @escaping () -> UUID = UUID.init, limit: Int = defaultBatchLimit,
    seedingUnaccepted: Bool = false, monotonic: PodcastCloudMonotonicSource = .process
  ) throws -> Outcome {
    var outcome = Outcome()
    guard let clockFields = try PodcastCloudInstallationStore.clock(in: db) else {
      outcome.deferred = true
      return outcome
    }
    let clockState = try PodcastCloudClockState(clockFields)
    // A quarantined clock cannot stamp. The log is left as it is and drains after the repair,
    // which is why no republish debt is needed here.
    guard clockState.repairRequired == false else {
      outcome.deferred = true
      return outcome
    }

    var context = Context(
      db: db, key: recordNameKey, clock: monotonic.clock(clockState),
      wallClockMilliseconds: max(0, Int64((now.timeIntervalSince1970 * 1000).rounded(.down))),
      monotonicMilliseconds: monotonic.nowMilliseconds(),
      newMutationUUID: newMutationUUID, seedsUnaccepted: seedingUnaccepted)
    var handledSubscriptions: Set<String> = []

    let entries = try PodcastCloudDirtyLog.entries(in: db, limit: limit).sorted {
      (dependencyOrder[$0.kind] ?? 0, $0.key) < (dependencyOrder[$1.kind] ?? 0, $1.key)
    }
    for entry in entries {
      // An entity that cannot be expressed (an invalid stored value, a record the layout refuses)
      // must not stop the rest or roll back the caller's transaction. Its partial work is undone
      // and the failure is counted for status, but the entry stays: clearing it would lose the edit
      // until the same row happened to change again.
      var fields: PodcastCloudRecordFields?
      do {
        try db.inSavepoint {
          fields = try context.fields(for: entry, handledSubscriptions: &handledSubscriptions)
          if let fields { try PodcastCloudLocalPublication.publish(fields, in: db) }
          return .commit
        }
      } catch {
        outcome.failed += 1
        continue
      }
      if let fields {
        outcome.published.append(fields.recordName)
      } else {
        outcome.settled += 1
      }
      try PodcastCloudDirtyLog.clear(entry, in: db)
    }

    if context.advancedClock {
      try PodcastCloudInstallationStore.advance(in: db, clock: PodcastCloudClockFields(context.clock.state))
    }
    return outcome
  }

  private static let dependencyOrder: [PodcastCloudDirtyEntry.Kind: Int] = [
    .subscription: 0, .feedSettings: 1, .globals: 2, .episodeState: 3, .saved: 4, .bookmark: 5,
  ]

  /// A seed stamp for a register the cloud has never accepted.
  static func seedStamp(at date: Date?, recordName: String, value: String) throws
    -> PodcastCloudMutationStamp
  {
    try PodcastCloudMutationStamp(
      physicalMilliseconds: max(0, Int64(((date?.timeIntervalSince1970 ?? 0) * 1000).rounded())),
      logicalCounter: 0,
      installationUUID: UUID(uuidString: PodcastCloudIdentity.migrationAuthorInstallationUUID)!,
      mutationUUID: PodcastCloudIdentity.seedMutationUUID(recordName: recordName, value: value))
  }

  // MARK: - Registers

  struct Context {
    let db: Database
    let key: PodcastCloudRecordNameKey
    var clock: PodcastCloudClock
    let wallClockMilliseconds: Int64
    let monotonicMilliseconds: Int64
    let newMutationUUID: () -> UUID
    let seedsUnaccepted: Bool
    var advancedClock = false

    /// The stamp for a register with no accepted value: a seed during the backfill, otherwise a
    /// live edit's fresh stamp.
    mutating func unacceptedStamp(at date: Date?, recordName: String, value: String) throws
      -> PodcastCloudMutationStamp
    {
      guard seedsUnaccepted else { return try fresh() }
      return try PodcastCloudLocalReconciler.seedStamp(at: date, recordName: recordName, value: value)
    }

    mutating func fresh() throws -> PodcastCloudMutationStamp {
      advancedClock = true
      return try clock.generate(
        wallClockMilliseconds: wallClockMilliseconds, monotonicMilliseconds: monotonicMilliseconds,
        mutationUUID: newMutationUUID())
    }

    /// The record a dirty entry should publish, or `nil` when it should settle without a send.
    /// A subscription reached twice in one drain (its catalogue URL and its registry URL) is
    /// handled once.
    mutating func fields(
      for entry: PodcastCloudDirtyEntry, handledSubscriptions: inout Set<String>
    ) throws -> PodcastCloudRecordFields? {
      switch entry.kind {
      case .subscription:
        guard let uuid = PodcastCloudIdentity.subscriptionUUID(feedURL: entry.key)?.uuidString.lowercased(),
          handledSubscriptions.insert(uuid).inserted
        else { return nil }
        return try subscription(feedURL: entry.key)
      case .feedSettings:
        guard let feedId = entry.rowID else { return nil }
        return try feedSettings(feedId: feedId)
      case .globals:
        return try globals()
      case .episodeState:
        guard let episodeId = entry.rowID else { return nil }
        return try episodeState(episodeId: episodeId)
      case .saved:
        guard let episodeId = entry.rowID else { return nil }
        return try saved(episodeId: episodeId)
      case .bookmark:
        return try bookmark()
      }
    }

    func accepted(_ recordName: String) throws -> PodcastCloudRecordFields? {
      guard let payload = try PodcastCloudRegistryStore.acceptedPayload(in: db, recordName: recordName),
        let fields = try? PodcastCloudRecordPayload.decode(payload), fields.recordName == recordName
      else { return nil }
      return fields
    }

    // MARK: Subscription

    /// The follow register lives in the registry and is changed here, as the drain observes the
    /// catalogue: a follow with no entry registers under the derived identity and the legacy
    /// stamp, so a first follow on two offline devices agrees; a re-follow mints a generation; an
    /// unfollow retires. Custom order is its own register inside the same record.
    mutating func subscription(feedURL: String) throws -> PodcastCloudRecordFields? {
      guard let uuid = PodcastCloudIdentity.subscriptionUUID(feedURL: feedURL),
        let normalized = PodcastCloudIdentity.normalizedFeedURL(feedURL),
        let fingerprint = PodcastFeedIdentity.fingerprint(feedURL)
      else { return nil }
      let subscriptionUUID = uuid.uuidString.lowercased()
      let feed = try PodcastCloudLocalCatalogue.feedIDs(in: db, subscriptionUUID: subscriptionUUID).first
        .flatMap { try Row.fetchOne(db, sql: "SELECT * FROM rssFeed WHERE id = ?", arguments: [$0]) }
      var entry = try PodcastCloudRegistryStore.entry(in: db, subscriptionUUID: subscriptionUUID)

      if let feed {
        if entry == nil {
          try PodcastCloudRegistryStore.register(
            in: db,
            entry: PodcastCloudRegistryEntry(
              subscriptionUUID: subscriptionUUID, fingerprint: fingerprint, normalizedURL: normalized,
              canonicalizationVersion: PodcastCloudRegistryBackfill.canonicalizationVersion,
              generationUUID: PodcastCloudIdentity.initialGenerationUUID(subscriptionUUID: uuid)
                .uuidString.lowercased(),
              isFollowed: true,
              followStamp: PodcastCloudRegistryBackfill.legacyStamp(
                subscriptionUUID: uuid, subscribedAt: feed["subscribedAt"])))
        } else if let retired = entry, retired.isFollowed == false {
          try PodcastCloudRegistryStore.register(
            in: db,
            entry: PodcastCloudRegistryEntry(
              subscriptionUUID: subscriptionUUID, fingerprint: retired.fingerprint,
              normalizedURL: retired.normalizedURL,
              canonicalizationVersion: retired.canonicalizationVersion,
              generationUUID: UUID().uuidString.lowercased(), isFollowed: true,
              followStamp: PodcastCloudStampFields(try fresh())))
        }
      } else if let followed = entry, followed.isFollowed {
        try PodcastCloudRegistryStore.retire(
          in: db, subscriptionUUID: subscriptionUUID, stamp: PodcastCloudStampFields(try fresh()))
      }
      entry = try PodcastCloudRegistryStore.entry(in: db, subscriptionUUID: subscriptionUUID)
      guard let entry, let generationUUID = UUID(uuidString: entry.generationUUID),
        let followStamp = PodcastCloudMutationStamp(entry.followStamp)
      else { return nil }

      let recordName = try PodcastCloudIdentity.recordName(kind: "sub", components: [subscriptionUUID], key: key)
      let accepted = try accepted(recordName).flatMap {
        try? PodcastCloudRecordCodec.decodeSubscription($0, subscriptionUUID: uuid)
      }
      let lifecycle = PodcastCloudFollowRegister(
        subscriptionUUID: uuid, generationUUID: generationUUID, isFollowed: entry.isFollowed,
        stamp: followStamp)

      let feedTitle: String? = feed?["title"]
      let feedAuthor: String? = feed?["author"]
      let subscribedAt: Date? = feed?["subscribedAt"]
      // An unfollowed subscription keeps the order it last had; the catalogue no longer holds one.
      let localOrder: Int?
      if let feed {
        localOrder = feed["customSortIndex"]
      } else {
        localOrder = accepted?.customOrder?.value
      }
      var customOrder: StampedCustomOrder?
      if let acceptedOrder = accepted?.customOrder {
        customOrder =
          acceptedOrder.value == localOrder
          ? acceptedOrder : StampedCustomOrder(value: localOrder, stamp: try fresh())
      } else if let localOrder {
        customOrder = StampedCustomOrder(
          value: localOrder,
          stamp: accepted == nil
            ? try unacceptedStamp(
              at: subscribedAt, recordName: recordName, value: "order:\(localOrder)")
            : try fresh())
      }

      if let accepted, accepted.lifecycle == lifecycle, accepted.customOrder == customOrder { return nil }
      return try PodcastCloudRecordCodec.encode(
        subscription: SubscriptionSnapshot(
          subscriptionUUID: uuid, canonicalizationVersion: entry.canonicalizationVersion,
          normalizedURL: entry.normalizedURL, title: feedTitle ?? accepted?.title ?? entry.normalizedURL,
          author: feedAuthor ?? accepted?.author, subscribedAt: subscribedAt ?? accepted?.subscribedAt,
          lifecycle: lifecycle,
          customOrder: customOrder),
        recordName: recordName)
    }

    /// The registry entry a feed's child records are filed under, while it is followed.
    func followedEntry(feedURL: String) throws -> PodcastCloudRegistryEntry? {
      guard let uuid = PodcastCloudIdentity.subscriptionUUID(feedURL: feedURL)?.uuidString.lowercased(),
        let entry = try PodcastCloudRegistryStore.entry(in: db, subscriptionUUID: uuid), entry.isFollowed
      else { return nil }
      return entry
    }

    // MARK: Feed settings

    mutating func feedSettings(feedId: Int64) throws -> PodcastCloudRecordFields? {
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT feed.feedURL AS feedURL, feed.subscribedAt AS subscribedAt, settings.*
            FROM rssFeedSettings AS settings JOIN rssFeed AS feed ON feed.id = settings.feedId
            WHERE settings.feedId = ?
            """, arguments: [feedId]),
        let entry = try followedEntry(feedURL: row["feedURL"])
      else { return nil }
      let recordName = try PodcastCloudIdentity.recordName(
        kind: "settings", components: [entry.subscriptionUUID, entry.generationUUID], key: key)
      let autoDownload: String = row["autoDownload"]
      let keepLatest: Int? = row["keepLatest"]
      let deleteAfterPlayed: Bool? = row["deleteAfterPlayed"]
      let rateStep: Int? = row["rateStep"]
      let includeInLatest: Bool = row["includeInLatest"]
      let notificationOverride: String = row["notificationOverride"]
      let trimSilences: String = row["trimSilencesOverride"]
      let voiceBoost: String = row["voiceBoostOverride"]
      let inherit = TrimSilencesShowOverride.inherit.rawValue
      // The Trim Silences and Voice Boost parts join only when set, so an unaccepted stamp derived
      // from a row that predates them is unchanged.
      let value =
        "\(autoDownload)|\(keepLatest.map(String.init) ?? "-")|\(deleteAfterPlayed.map(String.init) ?? "-")|"
        + "\(rateStep.map(String.init) ?? "-")|\(includeInLatest)|\(notificationOverride)"
        + (trimSilences != inherit || voiceBoost != inherit ? "|\(trimSilences)|\(voiceBoost)" : "")

      let stamp: PodcastCloudMutationStamp
      if let accepted = try accepted(recordName).flatMap({ try? PodcastCloudRecordCodec.decodeFeedSettings($0) }) {
        if accepted.autoDownload == autoDownload, accepted.keepLatest == keepLatest,
          accepted.deleteAfterPlayed == deleteAfterPlayed, accepted.rateStep == rateStep,
          accepted.includeInLatest == includeInLatest, accepted.notificationOverride == notificationOverride,
          (accepted.trimSilencesOverride ?? inherit) == trimSilences,
          (accepted.voiceBoostOverride ?? inherit) == voiceBoost
        {
          return nil
        }
        stamp = try fresh()
      } else {
        // Defaults assert nothing: publishing them unaccepted could only overwrite a real choice.
        guard
          autoDownload != "inherit" || keepLatest != nil || deleteAfterPlayed != nil || rateStep != nil
            || includeInLatest == false || notificationOverride != "inherit"
            || trimSilences != inherit || voiceBoost != inherit
        else { return nil }
        stamp = try unacceptedStamp(
          at: row["subscribedAt"], recordName: recordName, value: value)
      }
      return try PodcastCloudRecordCodec.encode(
        feedSettings: FeedSettingsSnapshot(
          autoDownload: autoDownload, keepLatest: keepLatest, deleteAfterPlayed: deleteAfterPlayed,
          rateStep: rateStep, includeInLatest: includeInLatest, notificationOverride: notificationOverride,
          trimSilencesOverride: trimSilences, voiceBoostOverride: voiceBoost, stamp: stamp),
        recordName: recordName)
    }

    // MARK: Globals

    mutating func globals() throws -> PodcastCloudRecordFields? {
      let record =
        try NativePodcastSettingsRecord.fetchOne(db, key: NativePodcastSettingsRecord.singletonID)
        ?? NativePodcastSettingsRecord()
      let mode =
        try String.fetchOne(db, sql: "SELECT mode FROM rssShowOrder WHERE id = 0")
        ?? NativePodcastShowSortMode.alphabetical.rawValue
      let recordName = try PodcastCloudIdentity.recordName(kind: "globals", components: [], key: key)
      let value =
        "\(record.autoDownloadEnabled)|\(record.keepLatestCount)|\(record.deleteAfterPlayed)|"
        + "\(record.allowCellularAutoDownload)|\(record.enabledAt?.timeIntervalSince1970 ?? -1)|\(mode)"

      let stamp: PodcastCloudMutationStamp
      if let accepted = try accepted(recordName).flatMap({
        try? PodcastCloudRecordCodec.decodeGlobalSettings($0)
      }) {
        if accepted.autoDownloadEnabled == record.autoDownloadEnabled,
          accepted.keepLatestCount == record.keepLatestCount,
          accepted.deleteAfterPlayed == record.deleteAfterPlayed,
          accepted.allowCellularAutoDownload == record.allowCellularAutoDownload,
          accepted.enabledAt == record.enabledAt, accepted.showOrderMode == mode
        {
          return nil
        }
        stamp = try fresh()
      } else {
        let defaults = NativePodcastSettingsRecord()
        guard
          record.autoDownloadEnabled != defaults.autoDownloadEnabled
            || record.keepLatestCount != defaults.keepLatestCount
            || record.deleteAfterPlayed != defaults.deleteAfterPlayed
            || record.allowCellularAutoDownload != defaults.allowCellularAutoDownload
            || mode != NativePodcastShowSortMode.alphabetical.rawValue
        else { return nil }
        stamp = try unacceptedStamp(
          at: record.enabledAt, recordName: recordName, value: value)
      }
      return try PodcastCloudRecordCodec.encode(
        globalSettings: StampedGlobalSettings(
          autoDownloadEnabled: record.autoDownloadEnabled, keepLatestCount: record.keepLatestCount,
          deleteAfterPlayed: record.deleteAfterPlayed,
          allowCellularAutoDownload: record.allowCellularAutoDownload, enabledAt: record.enabledAt,
          showOrderMode: mode, writeStamp: stamp),
        recordName: recordName)
    }

    // MARK: Episode state

    struct Episode {
      let entry: PodcastCloudRegistryEntry
      let identityKey: String
      let identity: PodcastCloudEpisodeIdentityFields
    }

    func episode(_ episodeId: Int64) throws -> Episode? {
      guard
        let identity = try PodcastCloudLocalCatalogue.episodeIdentity(episodeId: episodeId, in: db),
        let entry = try followedEntry(feedURL: identity.feedURL)
      else { return nil }
      return Episode(
        entry: entry, identityKey: identity.identityKey, identity: identity.fields)
    }

    func childRecordName(_ kind: String, _ episode: Episode) throws -> String {
      try PodcastCloudIdentity.recordName(
        kind: kind,
        components: [
          episode.entry.subscriptionUUID, episode.entry.generationUUID,
          PodcastCloudIdentity.episodeDigest(identityKey: episode.identityKey),
        ],
        key: key)
    }

    /// A change to only the position is a playback tick and keeps the accepted explicit epoch. A
    /// change to finished or dismissed (completion included) or a drop to zero while unfinished,
    /// which is a reset, is an explicit action and opens a new epoch at its own stamp.
    mutating func episodeState(episodeId: Int64) throws -> PodcastCloudRecordFields? {
      guard let episode = try episode(episodeId),
        let row = try Row.fetchOne(
          db,
          sql:
            "SELECT position, finished, hideFromContinueListening, updatedAt FROM rssEpisodeState WHERE episodeId = ?",
          arguments: [episodeId])
      else { return nil }
      let position: Double = row["position"]
      let finished: Bool = row["finished"]
      let dismissed: Bool = row["hideFromContinueListening"]
      let updatedAt: Date = row["updatedAt"]
      let recordName = try childRecordName("state", episode)

      let state: PodcastCloudEpisodeState
      if let accepted = try accepted(recordName).flatMap({ try? PodcastCloudRecordCodec.decodeEpisodeState($0) }) {
        let prior = accepted.state
        if prior.position == position, prior.isFinished == finished, prior.isDismissed == dismissed {
          return nil
        }
        let stamp = try fresh()
        let explicit =
          prior.isFinished != finished || prior.isDismissed != dismissed
          || (position == 0 && prior.position > 0 && finished == false)
        state = try PodcastCloudEpisodeState(
          position: position, isFinished: finished, isDismissed: dismissed,
          explicitEpoch: explicit ? stamp : prior.explicitEpoch, writeStamp: stamp)
      } else {
        guard position > 0 || finished || dismissed else { return nil }
        let stamp = try unacceptedStamp(
          at: updatedAt, recordName: recordName, value: "\(position)|\(finished)|\(dismissed)")
        state = try PodcastCloudEpisodeState(
          position: position, isFinished: finished, isDismissed: dismissed,
          explicitEpoch: finished || dismissed ? stamp : .bottom, writeStamp: stamp)
      }
      let identity = episode.identity
      return try PodcastCloudRecordCodec.encode(
        episodeState: state,
        identity: PodcastCloudEpisodeIdentityFields(
          identityKey: identity.identityKey, alternateIdentityKey: identity.alternateIdentityKey,
          guid: identity.guid, enclosureURL: identity.enclosureURL, title: identity.title,
          publishedAt: identity.publishedAt, duration: identity.duration, updatedAt: updatedAt),
        recordName: recordName)
    }

    // MARK: Saved

    /// A shelf entry deleted with its episode (a reaped episode or an unsubscribe) is not an
    /// unsave, and `episode` finding nothing is how that case ends here.
    mutating func saved(episodeId: Int64) throws -> PodcastCloudRecordFields? {
      guard let episode = try episode(episodeId) else { return nil }
      let savedAt = try Date.fetchOne(
        db, sql: "SELECT savedAt FROM rssSavedShelfEntry WHERE rssEpisodeId = ?", arguments: [episodeId])
      let recordName = try childRecordName("saved", episode)

      let stamp: PodcastCloudMutationStamp
      if let accepted = try accepted(recordName).flatMap({ try? PodcastCloudRecordCodec.decodeSavedRegister($0) }) {
        if accepted.isSaved == (savedAt != nil) { return nil }
        stamp = try fresh()
      } else {
        guard let savedAt else { return nil }
        stamp = try unacceptedStamp(at: savedAt, recordName: recordName, value: "saved")
      }
      let identity = episode.identity
      return try PodcastCloudRecordCodec.encode(
        savedRegister: try PodcastCloudSavedRegister(isSaved: savedAt != nil, savedAt: savedAt, stamp: stamp),
        identity: PodcastCloudEpisodeIdentityFields(
          identityKey: identity.identityKey, alternateIdentityKey: identity.alternateIdentityKey,
          guid: identity.guid, enclosureURL: identity.enclosureURL),
        recordName: recordName)
    }

    // MARK: Bookmark

    /// A bookmark that disappeared with its episode is not a clear, so only a present bookmark is
    /// ever published.
    mutating func bookmark() throws -> PodcastCloudRecordFields? {
      guard
        let row = try Row.fetchOne(db, sql: "SELECT episodeId, updatedAt FROM rssPlaybackBookmark WHERE id = 0"),
        let episode = try episode(row["episodeId"]),
        let subscriptionUUID = UUID(uuidString: episode.entry.subscriptionUUID),
        let generationUUID = UUID(uuidString: episode.entry.generationUUID)
      else { return nil }
      let reference = EpisodeReference(
        subscriptionUUID: subscriptionUUID, generationUUID: generationUUID,
        representativeDigest: PodcastCloudIdentity.episodeDigest(identityKey: episode.identityKey))
      let recordName = try PodcastCloudIdentity.recordName(kind: "bookmark", components: [], key: key)

      let stamp: PodcastCloudMutationStamp
      if let accepted = try accepted(recordName).flatMap({ try? PodcastCloudRecordCodec.decodeBookmark($0) }) {
        if accepted.reference == reference { return nil }
        stamp = try fresh()
      } else {
        stamp = try unacceptedStamp(
          at: row["updatedAt"], recordName: recordName,
          value: "\(reference.subscriptionUUID)|\(reference.generationUUID)|\(reference.representativeDigest)")
      }
      return try PodcastCloudRecordCodec.encode(
        bookmark: StampedBookmark(reference: reference, writeStamp: stamp), recordName: recordName)
    }
  }
}
