import Foundation
import GRDB
import Testing

@testable import Persistence

/// `AdSkipLocalEpisodeReader`: the presence rule decides which downloaded episodes the ad-skip
/// coordinator may analyse.
@Suite struct AdSkipLocalEpisodeReaderTests {
  private let root = URL(fileURLWithPath: "/tmp/whirr-downloads", isDirectory: true)

  // MARK: - Fixtures

  private func reader(_ database: AppDatabase) -> AdSkipLocalEpisodeReader {
    AdSkipLocalEpisodeReader(database: database, downloadsRootURL: root)
  }

  private func absAccount(_ database: AppDatabase, userId: String) async throws -> Int64 {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: userId, serverVersion: "2.10.0")
      try account.insert(db)
      return try #require(account.id)
    }
  }

  /// Seeds a show and episode (or an audiobook when `episodeID` is nil) with one download per
  /// state; returns the download row ids.
  @discardableResult
  private func seedABS(
    _ database: AppDatabase, accountId: Int64, itemID: String, episodeID: String?,
    states: [DownloadState], language: String? = nil
  ) async throws -> [Int64] {
    try await database.writeAsync { db in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: "lib-\(itemID)", mediaType: "podcast", name: "L")
      try library.insert(db)
      var item = ItemRecord(
        accountId: accountId, libraryId: try #require(library.id), serverItemId: itemID,
        mediaKind: episodeID == nil ? "book" : "podcast", title: "Show", sortTitle: "show",
        podcastLanguage: language)
      try item.insert(db)
      var episodeRowID: Int64?
      if let episodeID {
        var episode = PodcastEpisodeRecord(
          accountId: accountId, itemId: try #require(item.id), serverEpisodeId: episodeID,
          title: "Episode", lastSeenGeneration: 1)
        try episode.insert(db)
        episodeRowID = episode.id
      }
      var ids: [Int64] = []
      for (index, state) in states.enumerated() {
        var download = DownloadRecord(
          accountId: accountId, itemId: try #require(item.id), podcastEpisodeId: episodeRowID,
          serverFileIno: "ino-\(index)", orderIndex: index,
          destinationRelativePath: "\(accountId)/\(itemID)/\(episodeID ?? "book")-\(index).mp3",
          expectedBytes: 10, expectedMimeType: "audio/mpeg", fileDurationSeconds: 1,
          receivedBytes: 0, state: state, origin: .manual, mediaKind: .audio)
        try download.insert(db)
        ids.append(try #require(download.id))
      }
      return ids
    }
  }

  private struct RSSSeed {
    var feedID: Int64
    var episodeRowID: Int64
    var downloadID: Int64
  }

  private func seedRSS(
    _ database: AppDatabase, suffix: String, state: DownloadState, language: String? = nil
  ) async throws -> RSSSeed {
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/\(suffix).xml")!, title: suffix, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssFeed SET language = ? WHERE id = ?", arguments: [language, feedID])
    }
    let episodes = RSSEpisodeStore(database: database)
    _ = try await episodes.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: suffix, enclosureURL: URL(string: "https://example.com/\(suffix).mp3")!,
          enclosureType: "audio/mpeg", declaredBytes: 10)
      ])
    let episode = try #require(await episodes.fetchEpisode(feedId: feedID, identityKey: suffix))
    let episodeRowID = try #require(episode.id)
    let download = try await RSSDownloadStore(database: database).claimOrCreateAsync(
      episodeId: episodeRowID)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssDownload SET state = ? WHERE id = ?",
        arguments: [state.rawValue, download.id])
    }
    return RSSSeed(feedID: feedID, episodeRowID: episodeRowID, downloadID: try #require(download.id))
  }

  private func seedAttempt(
    _ database: AppDatabase, accountId: Int64, seed: RSSSeed, identityKey: String,
    serverItemID: String?, serverEpisodeID: String?
  ) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO nativeEpisodeServerSaveAttempt
            (accountId, accountClientUUID, accountServerIdentityFingerprint, feedId, episodeId,
             episodeIdentityKey, serverItemId, serverEpisodeId, state, createdAt, updatedAt)
          VALUES (?, 'uuid', ?, ?, ?, ?, ?, ?, 'confirmed', ?, ?)
          """,
        arguments: [
          accountId, String(repeating: "a", count: 64), seed.feedID, seed.episodeRowID,
          identityKey, serverItemID, serverEpisodeID, Date(), Date(),
        ])
    }
  }

  private func absIdentity(_ account: Int64, _ item: String, _ episode: String)
    -> AdSkipEpisodeIdentity
  {
    AdSkipEpisodeIdentity(source: .abs, accountId: account, itemID: item, episodeID: episode)
  }

  // MARK: - ABS

  @Test func aCompletedABSEpisodeIsIncluded() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    try await seedABS(
      database, accountId: account, itemID: "it1", episodeID: "ep1", states: [.completed],
      language: "en-GB")
    let result = try await reader(database).localEpisodes()
    #expect(
      result == [
        AdSkipLocalEpisode(
          identity: absIdentity(account, "it1", "ep1"),
          fileURL: root.appendingPathComponent("\(account)/it1/ep1-0.mp3"),
          languageTag: "en-GB", showTitle: "Show", linkedIdentities: [])
      ])
  }

  @Test func aPartialABSEpisodeIsExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    try await seedABS(
      database, accountId: account, itemID: "it1", episodeID: "ep1", states: [.downloading])
    #expect(try await reader(database).localEpisodes().isEmpty)
  }

  @Test func aDeletingOnlyEpisodeIsExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    try await seedABS(
      database, accountId: account, itemID: "it1", episodeID: "ep1", states: [.deleting])
    #expect(try await reader(database).localEpisodes().isEmpty)
  }

  @Test func aDeletingRowBesideACompletedRowIsIgnored() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    try await seedABS(
      database, accountId: account, itemID: "it1", episodeID: "ep1",
      states: [.deleting, .completed])
    let result = try await reader(database).localEpisodes()
    #expect(result.map(\.identity) == [absIdentity(account, "it1", "ep1")])
    #expect(result.first?.fileURL == root.appendingPathComponent("\(account)/it1/ep1-1.mp3"))
  }

  @Test func twoLiveCompletedRowsAreExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    try await seedABS(
      database, accountId: account, itemID: "it1", episodeID: "ep1",
      states: [.completed, .completed])
    #expect(try await reader(database).localEpisodes().isEmpty)
  }

  @Test func anAudiobookDownloadIsExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    try await seedABS(
      database, accountId: account, itemID: "book1", episodeID: nil, states: [.completed])
    #expect(try await reader(database).localEpisodes().isEmpty)
  }

  @Test func twoAccountsWithTheSameServerIdsGiveTwoIdentities() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await absAccount(database, userId: "u1")
    let second = try await absAccount(database, userId: "u2")
    try await seedABS(
      database, accountId: second, itemID: "it1", episodeID: "ep1", states: [.completed])
    try await seedABS(
      database, accountId: first, itemID: "it1", episodeID: "ep1", states: [.completed])
    let result = try await reader(database).localEpisodes()
    #expect(
      result.map(\.identity) == [absIdentity(first, "it1", "ep1"), absIdentity(second, "it1", "ep1")]
    )
    #expect(result[0].fileURL != result[1].fileURL)
  }

  // MARK: - RSS

  @Test func aCompletedRSSEpisodeIsIncludedWithLanguageTitleAndURL() async throws {
    let database = try AppDatabase.inMemory()
    let seed = try await seedRSS(database, suffix: "show", state: .completed, language: "de")
    let relativePath = try await database.readAsync { db in
      try String.fetchOne(
        db, sql: "SELECT relativePath FROM rssDownload WHERE id = ?", arguments: [seed.downloadID])
    }
    // Subscribing records the feed URL's fingerprint.
    let fingerprint = try await database.readAsync { db in
      try String.fetchOne(
        db, sql: "SELECT podcastFeedFingerprint FROM rssFeed WHERE id = ?", arguments: [seed.feedID])
    }
    #expect(fingerprint != nil)
    let result = try await reader(database).localEpisodes()
    #expect(
      result == [
        AdSkipLocalEpisode(
          identity: AdSkipEpisodeIdentity(
            source: .rss, accountId: nil,
            itemID: try #require(PodcastSourceIdentity.rss(feedId: seed.feedID)?.itemId),
            episodeID: "show"),
          fileURL: root.appendingPathComponent(try #require(relativePath)),
          languageTag: "de", showTitle: "show", linkedIdentities: [], feedFingerprint: fingerprint)
      ])
  }

  @Test func aNonCompletedRSSEpisodeIsExcluded() async throws {
    let database = try AppDatabase.inMemory()
    _ = try await seedRSS(database, suffix: "a", state: .downloading)
    _ = try await seedRSS(database, suffix: "b", state: .deleting)
    #expect(try await reader(database).localEpisodes().isEmpty)
  }

  @Test func saveAttemptsWithServerIdsLinkAndOthersDoNot() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await absAccount(database, userId: "u1")
    let second = try await absAccount(database, userId: "u2")
    let seed = try await seedRSS(database, suffix: "show", state: .completed)
    try await seedAttempt(
      database, accountId: second, seed: seed, identityKey: "show", serverItemID: "srv-item",
      serverEpisodeID: "srv-ep")
    try await seedAttempt(
      database, accountId: first, seed: seed, identityKey: "show", serverItemID: "srv-item",
      serverEpisodeID: "srv-ep")
    try await seedAttempt(
      database, accountId: first, seed: seed, identityKey: "show", serverItemID: "srv-item",
      serverEpisodeID: "srv-ep")
    try await seedAttempt(
      database, accountId: first, seed: seed, identityKey: "show", serverItemID: "other",
      serverEpisodeID: nil)
    let result = try await reader(database).localEpisodes()
    #expect(
      result.first?.linkedIdentities == [
        absIdentity(first, "srv-item", "srv-ep"), absIdentity(second, "srv-item", "srv-ep"),
      ])
  }

  @Test func anAttemptWithoutServerIdsDoesNotLink() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    let seed = try await seedRSS(database, suffix: "show", state: .completed)
    try await seedAttempt(
      database, accountId: account, seed: seed, identityKey: "show", serverItemID: nil,
      serverEpisodeID: nil)
    #expect(try await reader(database).localEpisodes().first?.linkedIdentities == [])
  }

  /// One show followed through both sources is one show, joined on the feed's fingerprint.
  /// A value that is not a fingerprint joins nothing.
  @Test func bothSourcesCarryTheirShowsFeedFingerprint() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    try await seedABS(database, accountId: account, itemID: "it1", episodeID: "ep1", states: [.completed])
    try await seedABS(database, accountId: account, itemID: "it2", episodeID: "ep2", states: [.completed])
    let seed = try await seedRSS(database, suffix: "show", state: .completed)
    let fingerprint = String(repeating: "0123456789abcdef", count: 4)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET podcastFeedFingerprint = ? WHERE serverItemId = 'it1'",
        arguments: [fingerprint])
      try db.execute(
        sql: "UPDATE item SET podcastFeedFingerprint = 'not-a-fingerprint' WHERE serverItemId = 'it2'")
      try db.execute(
        sql: "UPDATE rssFeed SET podcastFeedFingerprint = ? WHERE id = ?",
        arguments: [fingerprint, seed.feedID])
    }
    let result = try await reader(database).localEpisodes()
    #expect(result.map(\.feedFingerprint) == [fingerprint, nil, fingerprint])
  }

  @Test func absSortsBeforeRSS() async throws {
    let database = try AppDatabase.inMemory()
    _ = try await seedRSS(database, suffix: "show", state: .completed)
    let account = try await absAccount(database, userId: "u1")
    try await seedABS(
      database, accountId: account, itemID: "it1", episodeID: "ep1", states: [.completed])
    #expect(try await reader(database).localEpisodes().map(\.identity.source) == [.abs, .rss])
  }

  // MARK: - Observation

  @Test func observationEmitsAgainWhenADownloadCompletes() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    let ids = try await seedABS(
      database, accountId: account, itemID: "it1", episodeID: "ep1", states: [.downloading])
    var iterator = reader(database).observeLocalEpisodes().makeAsyncIterator()
    #expect(await iterator.next() == [])
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE download SET state = 'completed' WHERE id = ?", arguments: [ids[0]])
    }
    let updated = await iterator.next()
    #expect(updated?.map(\.identity) == [absIdentity(account, "it1", "ep1")])
  }

  // MARK: - Outstanding downloads

  @Test func outstandingDownloadsReportEachEpisodesLanguage() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    try await seedABS(
      database, accountId: account, itemID: "it1", episodeID: "ep1", states: [.pending],
      language: "en")
    try await seedABS(
      database, accountId: account, itemID: "it2", episodeID: "ep2", states: [.interrupted],
      language: "fr")
    _ = try await seedRSS(database, suffix: "a", state: .downloading, language: "en-GB")
    _ = try await seedRSS(database, suffix: "b", state: .pending)

    let tags = try await reader(database).outstandingDownloadLanguageTags()

    #expect(tags.sorted { ($0 ?? "") < ($1 ?? "") } == [nil, "en", "en-GB", "fr"])
  }

  @Test func finishedOrStoppedDownloadsAreNotOutstanding() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    try await seedABS(
      database, accountId: account, itemID: "it1", episodeID: "ep1",
      states: [.completed, .failed, .paused, .pausedAuth, .deleting])
    try await seedABS(
      database, accountId: account, itemID: "book", episodeID: nil, states: [.downloading])
    _ = try await seedRSS(database, suffix: "a", state: .completed)
    _ = try await seedRSS(database, suffix: "b", state: .failed)

    #expect(try await reader(database).outstandingDownloadLanguageTags().isEmpty)
  }

  /// A failed row waiting for its automatic retry is still on its way, so it keeps the same-night
  /// chain alive; a failed row with no deadline does not.
  @Test func aFailedDownloadAwaitingAnAutomaticRetryIsOutstanding() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await absAccount(database, userId: "u1")
    let deadline = Date(timeIntervalSince1970: 1_790_000_000)
    let waiting = try await seedABS(
      database, accountId: account, itemID: "it1", episodeID: "ep1", states: [.failed], language: "en")
    try await seedABS(
      database, accountId: account, itemID: "it2", episodeID: "ep2", states: [.failed], language: "fr")
    let rssWaiting = try await seedRSS(database, suffix: "a", state: .failed, language: "de")
    _ = try await seedRSS(database, suffix: "b", state: .failed, language: "es")
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE download SET autoRetryNotBefore = ? WHERE id = ?", arguments: [deadline, waiting[0]])
      try db.execute(
        sql: "UPDATE rssDownload SET autoRetryNotBefore = ? WHERE id = ?",
        arguments: [deadline, rssWaiting.downloadID])
    }

    let tags = try await reader(database).outstandingDownloadLanguageTags()

    #expect(tags.sorted { ($0 ?? "") < ($1 ?? "") } == ["de", "en"])
  }
}
