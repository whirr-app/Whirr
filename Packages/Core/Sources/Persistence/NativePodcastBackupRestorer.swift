import Foundation
import GRDB

/// What a restore did, or (from `preview`) would do.
public struct NativePodcastRestoreOutcome: Sendable, Equatable {
  public var showsAdded = 0
  public var showsAlreadyFollowed = 0
  public var statesApplied = 0
  /// Episode state the device already had at the same age or newer.
  public var statesKeptLocal = 0
  public var savesAdded = 0
  /// Episodes the device does not have and the backup cannot describe well enough to add: no
  /// usable enclosure address. The show's next refresh does not bring their state back.
  public var episodesUnmatched = 0
  public var bookmarkApplied = false
  public var globalSettingsApplied = false
  /// Feed IDs of the shows this restore followed, which need a refresh to fill their catalogue.
  public var addedFeedIDs: [Int64] = []
  /// Learned ads and undone skips the device did not have.
  public var learnedAdsAdded = 0
  /// Learned ads the device already had that gained a teacher or an audio print. Not shown: it
  /// tells the ad-skip coordinator the store changed although nothing was added.
  public var learnedAdsChanged = 0

  public init() {}
}

/// Applies backup contents by filling in what the device is missing.
///
/// Nothing local is deleted and no save is removed. Every write goes through the ordinary native
/// tables in one transaction, so when sync is on the dirty log publishes the restored values as
/// fresh local edits.
public struct NativePodcastBackupRestorer: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// The outcome `restore` would have now, computed by applying and rolling back.
  public func preview(_ contents: NativePodcastBackupContents) async throws -> NativePodcastRestoreOutcome {
    try await database.writeAsync { db in
      var outcome = NativePodcastRestoreOutcome()
      try db.inSavepoint {
        outcome = try Self.apply(contents, in: db)
        return .rollback
      }
      outcome.addedFeedIDs = []
      return outcome
    }
  }

  public func restore(_ contents: NativePodcastBackupContents) async throws -> NativePodcastRestoreOutcome {
    try await database.writeAsync { db in try Self.apply(contents, in: db) }
  }

  static func apply(_ contents: NativePodcastBackupContents, in db: Database) throws -> NativePodcastRestoreOutcome {
    var outcome = NativePodcastRestoreOutcome()
    try applyGlobals(contents, in: db, outcome: &outcome)
    let feedIDs = try applyFeeds(contents.feeds, in: db, outcome: &outcome)

    var episodeIDs: [String: Int64] = [:]
    for episode in contents.episodes {
      guard let feedID = feedIDs[episode.feedURL] else {
        outcome.episodesUnmatched += 1
        continue
      }
      guard let episodeID = try matchOrInsert(episode, feedID: feedID, in: db) else {
        outcome.episodesUnmatched += 1
        continue
      }
      episodeIDs[key(episode.feedURL, episode.identityKey)] = episodeID
      try applyState(episode.state, episodeID: episodeID, in: db, outcome: &outcome)
      if let savedAt = episode.savedAt {
        try applySave(savedAt, episodeID: episodeID, feedID: feedID, in: db, outcome: &outcome)
      }
    }

    if let bookmark = contents.bookmark, let episodeID = episodeIDs[key(bookmark.feedURL, bookmark.identityKey)],
      try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM rssPlaybackBookmark WHERE id = 0)") == false
    {
      try db.execute(
        sql: "INSERT INTO rssPlaybackBookmark (id, episodeId, updatedAt) VALUES (0, ?, ?)",
        arguments: [episodeID, bookmark.updatedAt])
      outcome.bookmarkApplied = true
    }
    try applyLearnedAds(contents.learnedAds, feedIDs: feedIDs, in: db, outcome: &outcome)
    return outcome
  }

  // MARK: - Globals

  /// Backed-up global settings replace only values the user has never changed on this device.
  private static func applyGlobals(
    _ contents: NativePodcastBackupContents, in db: Database, outcome: inout NativePodcastRestoreOutcome
  ) throws {
    let defaults = NativePodcastSettingsRecord()
    let local = try NativePodcastSettingsRecord.fetchOne(db, key: NativePodcastSettingsRecord.singletonID)
    if local == nil || local == defaults, contents.globalSettings != defaults {
      var record = contents.globalSettings
      record.id = NativePodcastSettingsRecord.singletonID
      try record.save(db)
      outcome.globalSettingsApplied = true
    }
    let mode = try String.fetchOne(db, sql: "SELECT mode FROM rssShowOrder WHERE id = 0")
    if mode == nil || mode == NativePodcastShowSortMode.alphabetical.rawValue,
      contents.showOrderMode != NativePodcastShowSortMode.alphabetical.rawValue,
      NativePodcastShowSortMode(rawValue: contents.showOrderMode) != nil
    {
      try db.execute(
        sql: "INSERT INTO rssShowOrder (id, mode) VALUES (0, ?) ON CONFLICT(id) DO UPDATE SET mode = excluded.mode",
        arguments: [contents.showOrderMode])
      outcome.globalSettingsApplied = true
    }
  }

  // MARK: - Feeds

  /// Local feed IDs by the backup's feed address, following the shows the device lacks. A show is
  /// matched by its normalized address, so a scheme-case or default-port difference is the same
  /// show. Restored custom positions follow any the device already has, in backed-up order.
  private static func applyFeeds(
    _ feeds: [NativePodcastBackupContents.Feed], in db: Database, outcome: inout NativePodcastRestoreOutcome
  ) throws -> [String: Int64] {
    var local: [String: Int64] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT id, feedURL FROM rssFeed") {
      if let normalized = PodcastFeedIdentity.normalized(row["feedURL"]) { local[normalized] = row["id"] }
    }
    var nextOrder = (try Int.fetchOne(db, sql: "SELECT MAX(customSortIndex) FROM rssFeed") ?? -1) + 1
    var result: [String: Int64] = [:]
    let ordered = feeds.enumerated().sorted {
      ($0.element.customSortIndex ?? Int.max, $0.offset) < ($1.element.customSortIndex ?? Int.max, $1.offset)
    }
    for (_, feed) in ordered {
      guard let normalized = PodcastFeedIdentity.normalized(feed.feedURL) else { continue }
      if let existing = local[normalized] {
        result[feed.feedURL] = existing
        outcome.showsAlreadyFollowed += 1
        continue
      }
      var order: Int?
      if feed.customSortIndex != nil {
        order = nextOrder
        nextOrder += 1
      }
      // Through the record, as a follow does, so the show gets its feed fingerprint.
      var record = RSSFeedRecord(
        feedURL: normalized, title: feed.title, author: feed.author, subscribedAt: feed.subscribedAt,
        customSortIndex: order)
      try record.insert(db)
      let feedID = db.lastInsertedRowID
      if let settings = feed.settings {
        try db.execute(
          sql: """
            INSERT INTO rssFeedSettings
              (feedId, autoDownload, keepLatest, deleteAfterPlayed, rateStep, includeInLatest, notificationOverride,
               trimSilencesOverride, voiceBoostOverride)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            feedID, settings.autoDownload, settings.keepLatest, settings.deleteAfterPlayed, settings.rateStep,
            settings.includeInLatest, settings.notificationOverride, settings.trimSilencesOverride,
            settings.voiceBoostOverride,
          ])
      }
      local[normalized] = feedID
      result[feed.feedURL] = feedID
      outcome.showsAdded += 1
      outcome.addedFeedIDs.append(feedID)
    }
    return result
  }

  // MARK: - Episodes

  /// The refresh matcher's four identity comparisons in its order, then GUID, then enclosure
  /// Never title. An unmatched episode is added as a catalogue row so its state has
  /// somewhere to live before the show refreshes; the refresh then matches it by identity.
  private static func matchOrInsert(
    _ episode: NativePodcastBackupContents.Episode, feedID: Int64, in db: Database
  ) throws -> Int64? {
    if let id = try Int64.fetchOne(
      db,
      sql: """
        SELECT id FROM rssEpisode
        WHERE feedId = :feed AND (
          identityKey = :key OR alternateIdentityKey = :key
          OR (:alternate IS NOT NULL AND (identityKey = :alternate OR alternateIdentityKey = :alternate))
          OR (:guid IS NOT NULL AND guid = :guid)
          OR (:enclosure IS NOT NULL AND enclosureURL = :enclosure))
        ORDER BY CASE
          WHEN identityKey = :key THEN 1
          WHEN alternateIdentityKey = :key THEN 2
          WHEN identityKey = :alternate THEN 3
          WHEN alternateIdentityKey = :alternate THEN 4
          WHEN guid = :guid THEN 5
          ELSE 6 END, id
        LIMIT 1
        """,
      arguments: [
        "feed": feedID, "key": episode.identityKey, "alternate": episode.alternateIdentityKey,
        "guid": episode.guid, "enclosure": episode.enclosureURL,
      ])
    {
      return id
    }
    guard let enclosure = episode.enclosureURL else { return nil }
    let generation =
      try Int64.fetchOne(db, sql: "SELECT refreshGeneration FROM rssFeed WHERE id = ?", arguments: [feedID]) ?? 0
    try db.execute(
      sql: """
        INSERT INTO rssEpisode
          (feedId, identityKey, alternateIdentityKey, guid, title, enclosureURL, publishedAt, durationSeconds,
           lastSeenGeneration)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        feedID, episode.identityKey, episode.alternateIdentityKey, episode.guid, episode.title, enclosure,
        episode.publishedAt, episode.duration, generation,
      ])
    return db.lastInsertedRowID
  }

  /// Absent locally means applied; present on both sides means the later `updatedAt` wins.
  /// Written as a remote-style state write: it advances the sequence, so a playback tick captured
  /// before the restore is refused, and it runs no Saved-shelf consequence, because restore
  /// removes no save.
  private static func applyState(
    _ state: NativePodcastBackupContents.EpisodeState?, episodeID: Int64, in db: Database,
    outcome: inout NativePodcastRestoreOutcome
  ) throws {
    guard let state else { return }
    if let local = try RSSEpisodeStateRecord.fetchOne(db, key: episodeID), local.updatedAt >= state.updatedAt {
      outcome.statesKeptLocal += 1
      return
    }
    try RSSEpisodeStateStore.applyRemote(
      episodeId: episodeID, position: state.position, finished: state.finished,
      hideFromContinueListening: state.dismissed, updatedAt: state.updatedAt, in: db)
    outcome.statesApplied += 1
  }

  private static func applySave(
    _ savedAt: Date, episodeID: Int64, feedID: Int64, in db: Database, outcome: inout NativePodcastRestoreOutcome
  ) throws {
    guard
      try Bool.fetchOne(
        db, sql: "SELECT EXISTS (SELECT 1 FROM rssSavedShelfEntry WHERE rssEpisodeId = ?)", arguments: [episodeID])
        == false
    else { return }
    try db.execute(
      sql: """
        INSERT INTO rssSavedShelfEntry (rssEpisodeId, savedAt, subjectTitle, contextTitle)
        VALUES (?, ?, COALESCE((SELECT title FROM rssEpisode WHERE id = ?), ''), (SELECT title FROM rssFeed WHERE id = ?))
        """, arguments: [episodeID, savedAt, episodeID, feedID])
    outcome.savesAdded += 1
  }

  private static func key(_ feedURL: String, _ identityKey: String) -> String {
    feedURL + "\u{0}" + identityKey
  }
}
