import Foundation
import GRDB
import Persistence

/// Projects admitted remote values into the local tables the app reads, inside the coordinator's
/// admission transaction after the accepted value is recorded, so projection and bookkeeping
/// commit together.
///
/// Projection marks entities in the v70 dirty log; the drain then finds local equal to the value
/// just accepted and publishes nothing. That equality is the whole echo guard, so every
/// projection must reproduce the register as the reconciler reads it back.
///
/// Nothing here starts playback, downloads or notifications. A remote follow adds the catalogue
/// row and leaves episodes to the next refresh; a remote bookmark moves the marker only.
public struct PodcastCloudProjectingApplier: PodcastCloudRemoteApplying {
  private let recordNameKeys: PodcastCloudRecordNameKeyBox
  private let now: @Sendable () -> Date
  private let holding = PodcastCloudHoldingApplier()

  public init(
    recordNameKeys: PodcastCloudRecordNameKeyBox, now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.recordNameKeys = recordNameKeys
    self.now = now
  }

  public func apply(_ record: PodcastCloudAdmittedRecord, in db: Database) throws {
    let fields = record.fields
    switch fields.recordType {
    case PodcastCloudRecordLayout.subscription.name:
      try projectSubscription(fields, in: db)
    case PodcastCloudRecordLayout.feedSettings.name:
      guard let entry = try entry(forChildRecordName: fields.recordName, in: db) else { return }
      try projectFeedSettings(fields, entry: entry, in: db)
    case PodcastCloudRecordLayout.globalSettings.name:
      try projectGlobals(fields, in: db)
    case PodcastCloudRecordLayout.episodeState.name, PodcastCloudRecordLayout.savedEpisode.name:
      // Held first, then resolved at once against whatever the local feed already has. What
      // does not match stays held for the next refresh.
      try holding.apply(record, in: db)
      guard let key = recordNameKeys.current,
        let entry = try entry(forChildRecordName: fields.recordName, in: db),
        let feedId = try PodcastCloudLocalCatalogue.feedIDs(in: db, subscriptionUUID: entry.subscriptionUUID)
          .first
      else { return }
      _ = try PodcastCloudEpisodeStateResolution.resolve(
        in: db, feedId: feedId, recordNameKey: key, applier: self)
    case PodcastCloudRecordLayout.lastPlayed.name:
      try projectBookmark(fields, in: db)
    default:
      return
    }
  }

  // MARK: - Subscription

  private func projectSubscription(_ fields: PodcastCloudRecordFields, in db: Database) throws {
    let reader = PodcastCloudRecordReader(type: PodcastCloudRecordLayout.subscription, fields: fields)
    guard let normalized = try reader.string("normalizedURL"),
      let uuid = PodcastCloudIdentity.subscriptionUUID(feedURL: normalized),
      let fingerprint = PodcastFeedIdentity.fingerprint(normalized)
    else { return }
    let value = try PodcastCloudRecordCodec.decodeSubscription(fields, subscriptionUUID: uuid)
    let subscriptionUUID = uuid.uuidString.lowercased()

    // A registry entry held under another identity for the same fingerprint is a canonicalization
    // disagreement projection must not silently combine. The register throws and the coordinator
    // holds the record.
    try PodcastCloudRegistryStore.register(
      in: db,
      entry: PodcastCloudRegistryEntry(
        subscriptionUUID: subscriptionUUID, fingerprint: fingerprint, normalizedURL: value.normalizedURL,
        canonicalizationVersion: value.canonicalizationVersion,
        generationUUID: value.lifecycle.generationUUID.uuidString.lowercased(),
        isFollowed: value.lifecycle.isFollowed, followStamp: PodcastCloudStampFields(value.lifecycle.stamp)))

    var feedIDs = try PodcastCloudLocalCatalogue.feedIDs(in: db, subscriptionUUID: subscriptionUUID)
    if value.lifecycle.isFollowed == false {
      for feedId in feedIDs { try RSSFeedStore.unsubscribe(in: db, feedId: feedId) }
      return
    }
    if feedIDs.isEmpty {
      var feed = RSSFeedRecord(
        feedURL: value.normalizedURL, title: value.title, author: value.author, synopsis: nil,
        artworkURL: nil, subscribedAt: value.subscribedAt ?? now())
      try feed.insert(db)
      feedIDs = [db.lastInsertedRowID]
    }
    if let order = value.customOrder {
      for feedId in feedIDs {
        try db.execute(
          sql: "UPDATE rssFeed SET customSortIndex = ? WHERE id = ?", arguments: [order.value, feedId])
      }
    }
    // Feed settings can arrive before their subscription. They were accepted then and are
    // applied now that there is a feed to hold them.
    if let key = recordNameKeys.current,
      let entry = try PodcastCloudRegistryStore.entry(in: db, subscriptionUUID: subscriptionUUID)
    {
      let settingsName = try PodcastCloudIdentity.recordName(
        kind: "settings", components: [entry.subscriptionUUID, entry.generationUUID], key: key)
      if let payload = try PodcastCloudRegistryStore.acceptedPayload(in: db, recordName: settingsName),
        let settings = try? PodcastCloudRecordPayload.decode(payload)
      {
        try projectFeedSettings(settings, entry: entry, in: db)
      }
    }
  }

  // MARK: - Settings

  private func projectFeedSettings(
    _ fields: PodcastCloudRecordFields, entry: PodcastCloudRegistryEntry, in db: Database
  ) throws {
    let value = try PodcastCloudRecordCodec.decodeFeedSettings(fields)
    for feedId in try PodcastCloudLocalCatalogue.feedIDs(in: db, subscriptionUUID: entry.subscriptionUUID) {
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings (
            feedId, autoDownload, keepLatest, deleteAfterPlayed, rateStep, includeInLatest,
            notificationOverride, trimSilencesOverride, voiceBoostOverride)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (feedId) DO UPDATE SET
            autoDownload = excluded.autoDownload, keepLatest = excluded.keepLatest,
            deleteAfterPlayed = excluded.deleteAfterPlayed, rateStep = excluded.rateStep,
            includeInLatest = excluded.includeInLatest,
            notificationOverride = excluded.notificationOverride,
            trimSilencesOverride = COALESCE(?, trimSilencesOverride),
            voiceBoostOverride = COALESCE(?, voiceBoostOverride)
          """,
        // A record from a build without these fields leaves the local values alone; the
        // reconciler then republishes them.
        arguments: [
          feedId, value.autoDownload, value.keepLatest, value.deleteAfterPlayed, value.rateStep,
          value.includeInLatest, value.notificationOverride,
          value.trimSilencesOverride ?? TrimSilencesShowOverride.inherit.rawValue,
          value.voiceBoostOverride ?? VoiceBoostShowOverride.inherit.rawValue,
          value.trimSilencesOverride, value.voiceBoostOverride,
        ])
    }
  }

  private func projectGlobals(_ fields: PodcastCloudRecordFields, in db: Database) throws {
    let value = try PodcastCloudRecordCodec.decodeGlobalSettings(fields)
    var record =
      try NativePodcastSettingsRecord.fetchOne(db, key: NativePodcastSettingsRecord.singletonID)
      ?? NativePodcastSettingsRecord()
    record.autoDownloadEnabled = value.autoDownloadEnabled
    record.keepLatestCount = value.keepLatestCount
    record.deleteAfterPlayed = value.deleteAfterPlayed
    record.allowCellularAutoDownload = value.allowCellularAutoDownload
    record.enabledAt = value.enabledAt
    try record.save(db)
    // An unknown order mode is left alone rather than written into a column the show list
    // would then fail to read.
    if NativePodcastShowSortMode(rawValue: value.showOrderMode) != nil {
      try db.execute(
        sql: "INSERT INTO rssShowOrder (id, mode) VALUES (0, ?) ON CONFLICT(id) DO UPDATE SET mode = excluded.mode",
        arguments: [value.showOrderMode])
    }
  }

  // MARK: - Episode state and saved

  /// Projects the accepted value for the record, not the held copy: a copy held before a newer
  /// value was accepted would otherwise roll the episode back.
  public func applyResolvedEpisodeState(
    _ resolved: PodcastCloudResolvedEpisodeState, in db: Database
  ) throws -> Bool {
    var state = resolved.state
    if let payload = try PodcastCloudRegistryStore.acceptedPayload(in: db, recordName: resolved.recordName),
      let fields = try? PodcastCloudRecordPayload.decode(payload),
      let accepted = try? PodcastCloudRecordCodec.decodeEpisodeState(fields)
    {
      state = accepted.state
    }
    try RSSEpisodeStateStore.applyRemote(
      episodeId: resolved.episodeId, position: state.position, finished: state.isFinished,
      hideFromContinueListening: state.isDismissed, updatedAt: Self.date(of: state.writeStamp), in: db)
    try adoptUnderLocalName(resolved.recordName, kind: "state", episodeId: resolved.episodeId, in: db)
    return true
  }

  /// Remote saves never run the local saved-intent resolution: finishing removes the episode on
  /// the device that finished it, and that removal arrives as its own register.
  public func applyResolvedSaved(_ resolved: PodcastCloudResolvedSaved, in db: Database) throws -> Bool {
    var register = resolved.register
    if let payload = try PodcastCloudRegistryStore.acceptedPayload(in: db, recordName: resolved.recordName),
      let fields = try? PodcastCloudRecordPayload.decode(payload),
      let accepted = try? PodcastCloudRecordCodec.decodeSavedRegister(fields)
    {
      register = accepted
    }
    if register.isSaved {
      let exists =
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS (SELECT 1 FROM rssSavedShelfEntry WHERE rssEpisodeId = ?)",
          arguments: [resolved.episodeId]) ?? false
      if exists == false {
        guard
          let row = try Row.fetchOne(
            db,
            sql: """
              SELECT episode.title AS title, feed.title AS feedTitle
              FROM rssEpisode AS episode JOIN rssFeed AS feed ON feed.id = episode.feedId
              WHERE episode.id = ?
              """, arguments: [resolved.episodeId])
        else { return false }
        var entry = RSSSavedShelfEntryRecord(
          rssEpisodeId: resolved.episodeId, savedAt: register.savedAt ?? now(),
          subjectTitle: (row["title"] as String?) ?? "", contextTitle: row["feedTitle"])
        try entry.insert(db)
      }
    } else {
      try db.execute(
        sql: "DELETE FROM rssSavedShelfEntry WHERE rssEpisodeId = ?", arguments: [resolved.episodeId])
    }
    try adoptUnderLocalName(resolved.recordName, kind: "saved", episodeId: resolved.episodeId, in: db)
    return true
  }

  /// A remote record matched by GUID or enclosure rather than by digest names the episode under a
  /// different identity key than this device does. This device's own record for the episode is
  /// filed under its own name, so the projected value is recorded as accepted there too;
  /// otherwise the drain would see its local record differ from its accepted one, republish it,
  /// and the two devices would trade the same value back and forth under two names.
  private func adoptUnderLocalName(
    _ recordName: String, kind: String, episodeId: Int64, in db: Database
  ) throws {
    guard let key = recordNameKeys.current,
      let episode = try PodcastCloudLocalCatalogue.episodeIdentity(episodeId: episodeId, in: db),
      let subscriptionUUID = PodcastCloudIdentity.subscriptionUUID(feedURL: episode.feedURL)?
        .uuidString.lowercased(),
      let entry = try PodcastCloudRegistryStore.entry(in: db, subscriptionUUID: subscriptionUUID),
      let payload = try PodcastCloudRegistryStore.acceptedPayload(in: db, recordName: recordName),
      let fields = try? PodcastCloudRecordPayload.decode(payload)
    else { return }
    let localName = try PodcastCloudIdentity.recordName(
      kind: kind,
      components: [
        entry.subscriptionUUID, entry.generationUUID,
        PodcastCloudIdentity.episodeDigest(identityKey: episode.identityKey),
      ],
      key: key)
    guard localName != recordName else { return }
    try PodcastCloudLocalPublication.recordAccepted(fields.renamed(localName), in: db)
  }

  // MARK: - Bookmark

  private func projectBookmark(_ fields: PodcastCloudRecordFields, in db: Database) throws {
    let value = try PodcastCloudRecordCodec.decodeBookmark(fields)
    guard let reference = value.reference,
      let entry = try PodcastCloudRegistryStore.entry(
        in: db, subscriptionUUID: reference.subscriptionUUID.uuidString.lowercased()),
      let parent = PodcastCloudFollowRegister(entry),
      PodcastCloudChildReference(reference).isAdmitted(by: parent)
    else { return }
    let feedIDs = try PodcastCloudLocalCatalogue.feedIDs(in: db, subscriptionUUID: entry.subscriptionUUID)
    let episodes = try PodcastCloudEpisodeStateResolution.localEpisodes(in: db, feedIDs: feedIDs)
    let matches = episodes.filter { episode in
      [episode.identityKey, episode.alternateIdentityKey].compactMap { $0 }.contains {
        PodcastCloudIdentity.episodeDigest(identityKey: $0) == reference.representativeDigest
      }
    }
    // An episode this device's feed copy has not seen yet leaves the marker where it is.
    // Pointing the bookmark at a guess is worse than leaving it.
    guard matches.count == 1 else { return }
    try db.execute(
      sql: """
        INSERT INTO rssPlaybackBookmark (id, episodeId, updatedAt) VALUES (0, ?, ?)
        ON CONFLICT(id) DO UPDATE SET episodeId = excluded.episodeId, updatedAt = excluded.updatedAt
        """,
      arguments: [matches[0].id, Self.date(of: value.writeStamp)])
  }

  // MARK: - Helpers

  /// The followed registry entry whose keyed form names a child record. Child names carry keyed
  /// components that cannot be reversed, so each local entry's keyed form is computed and compared.
  /// This resolves a name to an entry; it is not a restatement of the subscription/generation
  /// fence, which `PodcastCloudChildReference.isAdmitted(by:)` decides for values that carry UUIDs.
  private func entry(forChildRecordName recordName: String, in db: Database) throws
    -> PodcastCloudRegistryEntry?
  {
    guard let key = recordNameKeys.current else { return nil }
    let parts = recordName.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 4, parts[0] == PodcastCloudIdentity.version else { return nil }
    for entry in try PodcastCloudRegistryStore.allEntries(in: db) where entry.isFollowed {
      guard
        let keyed = try PodcastCloudEpisodeStateResolution.keyedParent(
          subscriptionUUID: entry.subscriptionUUID, generationUUID: entry.generationUUID, key: key)
      else { continue }
      if keyed.subscription == parts[2], keyed.generation == parts[3] { return entry }
    }
    return nil
  }

  static func date(of stamp: PodcastCloudMutationStamp) -> Date {
    Date(timeIntervalSince1970: TimeInterval(stamp.physicalMilliseconds) / 1000)
  }
}

extension PodcastCloudRecordFields {
  /// The same record under another name.
  func renamed(_ recordName: String) -> PodcastCloudRecordFields {
    PodcastCloudRecordFields(
      recordType: recordType, recordName: recordName, plaintext: plaintext, encrypted: encrypted)
  }
}

extension PodcastCloudFollowRegister {
  /// The register a registry entry records, for admission only: `isAdmitted` reads the identity and
  /// follow state, never the stamp, so the stored follow stamp is not required to be parseable.
  /// `nil` when the entry's stored identity text is not a UUID, which admits nothing.
  init?(_ entry: PodcastCloudRegistryEntry) {
    guard let subscription = UUID(uuidString: entry.subscriptionUUID),
      let generation = UUID(uuidString: entry.generationUUID)
    else { return nil }
    self.init(
      subscriptionUUID: subscription, generationUUID: generation, isFollowed: entry.isFollowed,
      stamp: .bottom)
  }
}

extension PodcastCloudChildReference {
  /// The subscription and generation an episode reference names; the digest is the child's own.
  init(_ reference: EpisodeReference) {
    self.init(
      subscriptionUUID: reference.subscriptionUUID, generationUUID: reference.generationUUID)
  }
}
