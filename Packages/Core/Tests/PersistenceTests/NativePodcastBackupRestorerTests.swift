import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct NativePodcastBackupRestorerTests {
  typealias Contents = NativePodcastBackupContents
  private typealias Seed = NativePodcastBackupReaderTests

  @Test func aCleanDeviceRestoresEverythingAndReadsBackTheSame() async throws {
    let database = try AppDatabase.inMemory()
    let outcome = try await NativePodcastBackupRestorer(database: database).restore(Self.backup())
    #expect(outcome.showsAdded == 2 && outcome.showsAlreadyFollowed == 0)
    #expect(outcome.statesApplied == 2 && outcome.savesAdded == 1)
    #expect(outcome.bookmarkApplied && outcome.globalSettingsApplied)
    #expect(outcome.episodesUnmatched == 0)
    #expect(outcome.addedFeedIDs.count == 2)

    let read = try await NativePodcastBackupReader(database: database).contents()
    #expect(read.globalSettings == Self.backup().globalSettings)
    #expect(read.showOrderMode == "custom")
    #expect(read.feeds == Self.backup().feeds)
    #expect(Set(read.episodes.map(\.identityKey)) == ["played", "finished", "saved"])
    for episode in read.episodes {
      let original = try #require(Self.backup().episodes.first { $0.identityKey == episode.identityKey })
      #expect(episode.state == original.state)
      #expect(episode.savedAt == original.savedAt)
      #expect(episode.enclosureURL == original.enclosureURL && episode.guid == original.guid)
    }
    #expect(read.bookmark == Self.backup().bookmark)
    let fingerprints = try await database.readAsync { db in
      try String?.fetchAll(db, sql: "SELECT podcastFeedFingerprint FROM rssFeed")
    }
    #expect(fingerprints.allSatisfy { $0 != nil })
  }

  /// A show already followed under an equivalent address is not duplicated and keeps its own
  /// settings; restored custom positions follow the device's own.
  @Test func anAlreadyFollowedShowKeepsItsSettingsAndNewShowsOrderAfterLocalOnes() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      let feed = try Seed.insertFeed(db, url: "HTTPS://Example.com:443/a", title: "Mine", order: 4)
      try db.execute(
        sql: "INSERT INTO rssFeedSettings (feedId, autoDownload) VALUES (?, 'disabled')", arguments: [feed])
    }
    let outcome = try await NativePodcastBackupRestorer(database: database).restore(Self.backup())
    #expect(outcome.showsAdded == 1 && outcome.showsAlreadyFollowed == 1)

    let read = try await NativePodcastBackupReader(database: database).contents()
    #expect(read.feeds.count == 2)
    #expect(read.feeds[0].title == "Mine" && read.feeds[0].settings?.autoDownload == "disabled")
    #expect(read.feeds[1].feedURL == "https://example.com/b" && read.feeds[1].customSortIndex == 5)
  }

  @Test func theLaterEpisodeStateWinsAndLocalSavesAndBookmarkStay() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      let feed = try Seed.insertFeed(db, url: "https://example.com/a", title: "A", order: nil)
      let played = try Seed.insertEpisode(db, feed: feed, key: "played")
      let finished = try Seed.insertEpisode(db, feed: feed, key: "finished")
      let local = try Seed.insertEpisode(db, feed: feed, key: "local")
      // Newer than the backup's 200: kept.
      try db.execute(
        sql: """
          INSERT INTO rssEpisodeState (episodeId, position, finished, localSequence, updatedAt)
          VALUES (?, 99, 0, 3, ?)
          """, arguments: [played, Date(timeIntervalSince1970: 500)])
      // Older than the backup's 210: replaced.
      try db.execute(
        sql: """
          INSERT INTO rssEpisodeState (episodeId, position, finished, localSequence, updatedAt)
          VALUES (?, 5, 0, 7, ?)
          """, arguments: [finished, Date(timeIntervalSince1970: 1)])
      try db.execute(
        sql: "INSERT INTO rssSavedShelfEntry (rssEpisodeId, savedAt) VALUES (?, ?)",
        arguments: [local, Date(timeIntervalSince1970: 50)])
      try db.execute(
        sql: "INSERT INTO rssPlaybackBookmark (id, episodeId, updatedAt) VALUES (0, ?, ?)",
        arguments: [local, Date(timeIntervalSince1970: 60)])
    }
    let outcome = try await NativePodcastBackupRestorer(database: database).restore(Self.backup())
    #expect(outcome.statesApplied == 1 && outcome.statesKeptLocal == 1)
    #expect(outcome.bookmarkApplied == false)

    let read = try await NativePodcastBackupReader(database: database).contents()
    let byKey = Dictionary(uniqueKeysWithValues: read.episodes.map { ($0.identityKey, $0) })
    #expect(byKey["played"]?.state?.position == 99)
    #expect(byKey["finished"]?.state?.finished == true)
    #expect(byKey["local"]?.savedAt == Date(timeIntervalSince1970: 50))
    #expect(byKey["saved"]?.savedAt == Date(timeIntervalSince1970: 300))
    #expect(read.bookmark?.identityKey == "local")
    let sequence = try await database.readAsync { db in
      try Int64.fetchOne(
        db,
        sql: """
          SELECT state.localSequence FROM rssEpisodeState AS state
          JOIN rssEpisode AS episode ON episode.id = state.episodeId WHERE episode.identityKey = 'finished'
          """)
    }
    #expect(sequence == 8)
  }

  @Test func changedGlobalSettingsAndOrderModeAreKept() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      try NativePodcastSettingsRecord(keepLatestCount: 9).save(db)
      try db.execute(sql: "INSERT INTO rssShowOrder (id, mode) VALUES (0, 'mostRecent')")
    }
    let outcome = try await NativePodcastBackupRestorer(database: database).restore(Self.backup())
    #expect(outcome.globalSettingsApplied == false)
    let read = try await NativePodcastBackupReader(database: database).contents()
    #expect(read.globalSettings.keepLatestCount == 9)
    #expect(read.showOrderMode == "mostRecent")
  }

  /// The four identity comparisons, then GUID, then enclosure. An episode with none of these on
  /// the device and no enclosure to add it by is counted, not invented.
  @Test func matchesByAlternateKeyGuidAndEnclosureAndCountsTheUnmatchable() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      let feed = try Seed.insertFeed(db, url: "https://example.com/a", title: "A", order: nil)
      try db.execute(
        sql: """
          INSERT INTO rssEpisode (feedId, identityKey, alternateIdentityKey, guid, enclosureURL, lastSeenGeneration)
          VALUES (?, 'new-key', 'old-key', NULL, 'https://example.com/x.mp3', 0),
                 (?, 'other', NULL, 'the-guid', 'https://example.com/y.mp3', 0),
                 (?, 'third', NULL, NULL, 'https://example.com/z.mp3', 0)
          """, arguments: [feed, feed, feed])
    }
    var backup = Self.backup()
    backup.bookmark = nil
    backup.episodes = [
      Self.episode("old-key", state: Self.state(10, at: 200)),
      Self.episode("gone", guid: "the-guid", state: Self.state(20, at: 200)),
      Self.episode("moved", guid: .some(nil), enclosure: "https://example.com/z.mp3", state: Self.state(30, at: 200)),
      Self.episode("lost", guid: .some(nil), enclosure: .some(nil), state: Self.state(40, at: 200)),
    ]
    let outcome = try await NativePodcastBackupRestorer(database: database).restore(backup)
    #expect(outcome.statesApplied == 3 && outcome.episodesUnmatched == 1)

    let positions = try await database.readAsync { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT episode.identityKey, state.position FROM rssEpisodeState AS state
          JOIN rssEpisode AS episode ON episode.id = state.episodeId
          """
      ).reduce(into: [String: Double]()) { $0[$1["identityKey"]] = $1["position"] }
    }
    #expect(positions == ["new-key": 10, "other": 20, "third": 30])
  }

  @Test func previewReportsTheOutcomeAndChangesNothing() async throws {
    let database = try AppDatabase.inMemory()
    let restorer = NativePodcastBackupRestorer(database: database)
    let preview = try await restorer.preview(Self.backup())
    #expect(preview.showsAdded == 2 && preview.statesApplied == 2 && preview.savesAdded == 1)
    #expect(preview.addedFeedIDs.isEmpty)
    let read = try await NativePodcastBackupReader(database: database).contents()
    #expect(read.feeds.isEmpty && read.episodes.isEmpty && read.bookmark == nil)
    #expect(read.globalSettings == NativePodcastSettingsRecord())
  }

  /// Restored values are ordinary local edits: every kind lands in the dirty log sync drains.
  @Test func restoredValuesAreMarkedForSync() async throws {
    let database = try AppDatabase.inMemory()
    _ = try await NativePodcastBackupRestorer(database: database).restore(Self.backup())
    let kinds = try await database.readAsync { db in Set(try PodcastCloudDirtyLog.entries(in: db).map(\.kind)) }
    #expect(kinds == Set(PodcastCloudDirtyEntry.Kind.allCases))
  }

  /// A second restore of the same file adds nothing.
  @Test func restoringTwiceIsANoOp() async throws {
    let database = try AppDatabase.inMemory()
    let restorer = NativePodcastBackupRestorer(database: database)
    _ = try await restorer.restore(Self.backup())
    let second = try await restorer.restore(Self.backup())
    #expect(second.showsAdded == 0 && second.showsAlreadyFollowed == 2)
    #expect(second.statesApplied == 0 && second.statesKeptLocal == 2 && second.savesAdded == 0)
    #expect(second.bookmarkApplied == false && second.globalSettingsApplied == false)
  }

  // MARK: - Fixture

  static func state(_ position: Double, finished: Bool = false, at seconds: TimeInterval) -> Contents.EpisodeState {
    Contents.EpisodeState(
      position: position, finished: finished, dismissed: false, updatedAt: Date(timeIntervalSince1970: seconds))
  }

  /// `guid` and `enclosure` default to values derived from the key; pass `.some(nil)` for none.
  static func episode(
    _ key: String, feed: String = "https://example.com/a", guid: String?? = nil, enclosure: String?? = nil,
    state: Contents.EpisodeState?, savedAt: Date? = nil
  ) -> Contents.Episode {
    Contents.Episode(
      feedURL: feed, identityKey: key, alternateIdentityKey: nil, guid: guid ?? "guid-\(key)",
      enclosureURL: enclosure ?? "https://example.com/\(key).mp3", title: key,
      publishedAt: Date(timeIntervalSince1970: 40), duration: 600, state: state, savedAt: savedAt)
  }

  static func backup() -> Contents {
    Contents(
      globalSettings: NativePodcastSettingsRecord(autoDownloadEnabled: true, keepLatestCount: 7),
      showOrderMode: "custom",
      feeds: [
        Contents.Feed(
          feedURL: "https://example.com/a", title: "A", author: "Author",
          subscribedAt: Date(timeIntervalSince1970: 100),
          customSortIndex: 0,
          settings: Contents.FeedSettings(
            autoDownload: "enabled", keepLatest: 5, deleteAfterPlayed: true, rateStep: nil, includeInLatest: true,
            notificationOverride: "disabled", trimSilencesOverride: "maximum", voiceBoostOverride: "on")),
        Contents.Feed(
          feedURL: "https://example.com/b", title: "B", author: nil, subscribedAt: Date(timeIntervalSince1970: 110),
          customSortIndex: 1, settings: nil),
      ],
      episodes: [
        episode("played", state: state(120, at: 200)),
        episode("finished", state: state(600, finished: true, at: 210)),
        episode("saved", feed: "https://example.com/b", state: nil, savedAt: Date(timeIntervalSince1970: 300)),
      ],
      bookmark: Contents.Bookmark(
        feedURL: "https://example.com/b", identityKey: "saved", updatedAt: Date(timeIntervalSince1970: 400)),
      followedGenerations: [:])
  }
}
