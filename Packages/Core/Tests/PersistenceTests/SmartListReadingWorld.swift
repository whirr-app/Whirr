import Foundation
import GRDB
import Testing

@testable import Persistence

/// Seeds both sources for the smart list reading tests with raw durable rows, so each test names
/// only what it cares about. Dates are whole-second offsets from `epoch` for exact comparison.
struct SmartListReadingWorld {
  static let epoch = Date(timeIntervalSince1970: 1_900_000_000)

  let database: AppDatabase
  var accountId: Int64?
  var libraryId: Int64?

  static func make(signedIn: Bool = true, userID: String = "user-1") async throws -> Self {
    var world = Self(database: try AppDatabase.inMemory())
    if signedIn { try await world.signIn(userID: userID) }
    return world
  }

  mutating func signIn(userID: String = "user-1") async throws {
    let (account, library) = try await database.writeAsync { db -> (Int64, Int64) in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: userID, serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: try #require(account.id), serverLibraryId: "lib-\(userID)", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      return (try #require(account.id), try #require(library.id))
    }
    accountId = account
    libraryId = library
  }

  func reading(nativeEnabled: Bool = true, now: Date = epoch) -> SmartListEpisodesReading {
    SmartListEpisodesReading(database: database, nativeEnabled: nativeEnabled, now: { now })
  }

  func list(
    _ rules: SmartListRules = .default, shows: [SmartListShowSelection] = []
  ) async throws -> Int64 {
    try await SmartListStore(database: database).create(name: "L", rules: rules, shows: shows).id
  }

  static func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

  // MARK: Native

  @discardableResult
  func feed(
    _ url: String, title: String = "Feed", fingerprint: String? = nil, generation: Int = 1
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var feed = RSSFeedRecord(
        feedURL: url, title: title, subscribedAt: Self.epoch, refreshGeneration: generation,
        podcastFeedFingerprint: fingerprint)
      try feed.insert(db)
      return try #require(feed.id)
    }
  }

  @discardableResult
  func native(
    feed: Int64, _ key: String, published: Date? = nil, duration: Double? = 1_800,
    measured: Double? = nil, generation: Int = 1, alternateKey: String? = nil
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = RSSEpisodeRecord(
        feedId: feed, identityKey: key, alternateIdentityKey: alternateKey, title: "T-\(key)",
        enclosureURL: "https://audio.example/\(key).mp3", publishedAt: published,
        durationSeconds: duration, measuredDurationSeconds: measured, lastSeenGeneration: generation)
      try episode.insert(db)
      return try #require(episode.id)
    }
  }

  func nativeProgress(_ episode: Int64, position: Double, finished: Bool = false) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO rssEpisodeState (episodeId, position, finished, localSequence, updatedAt)
          VALUES (?, ?, ?, 1, ?)
          """,
        arguments: [episode, position, finished, Self.epoch])
    }
  }

  func nativeDownload(_ episode: Int64, state: DownloadState = .completed) async throws {
    try await database.writeAsync { db in
      var record = RSSDownloadRecord(
        episodeId: episode, state: state, relativePath: "e\(episode).mp3", decidedStamp: Self.epoch,
        createdAt: Self.epoch, updatedAt: Self.epoch)
      try record.insert(db)
    }
  }

  func nativeSave(_ episode: Int64) async throws {
    try await database.writeAsync { db in
      var record = RSSSavedShelfEntryRecord(rssEpisodeId: episode, savedAt: Self.epoch)
      try record.insert(db)
    }
  }

  // MARK: Server

  @discardableResult
  func show(
    _ serverItemID: String, title: String = "Show", fingerprint: String? = nil
  ) async throws -> Int64 {
    let accountId = try #require(accountId)
    let libraryId = try #require(libraryId)
    return try await database.writeAsync { db in
      var item = HomeReadingFixtures.podcast(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemID)
      item.title = title
      item.podcastFeedFingerprint = fingerprint
      try item.insert(db)
      return try #require(item.id)
    }
  }

  @discardableResult
  func server(
    show: Int64, _ serverEpisodeID: String, published: Date? = nil, duration: Double? = 1_800
  ) async throws -> Int64 {
    let accountId = try #require(accountId)
    return try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: show, serverEpisodeId: serverEpisodeID,
        title: "T-\(serverEpisodeID)", durationSeconds: duration, publishedAt: published,
        lastSeenGeneration: 1)
      try episode.insert(db)
      return try #require(episode.id)
    }
  }

  func serverProgress(
    show: Int64, episode: Int64, position: Double, finished: Bool = false
  ) async throws {
    let accountId = try #require(accountId)
    try await database.writeAsync { db in
      var record = MediaProgressRecord(
        accountId: accountId, itemId: show, podcastEpisodeId: episode, currentTime: position,
        isFinished: finished, localSequence: 1, origin: .local, originKey: "client",
        lastActivityAt: Self.epoch)
      try record.insert(db)
    }
  }

  func serverDownload(show: Int64, episode: Int64) async throws {
    let accountId = try #require(accountId)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO download (accountId, itemId, podcastEpisodeId, serverFileIno, orderIndex,
            destinationRelativePath, expectedBytes, expectedMimeType, fileDurationSeconds,
            receivedBytes, state)
          VALUES (?, ?, ?, 'ino', 0, 'x.mp3', 100, 'audio/mpeg', 10, 0, 'completed')
          """,
        arguments: [accountId, show, episode])
    }
  }

  func serverSave(show: Int64, episode: Int64) async throws {
    let accountId = try #require(accountId)
    try await database.writeAsync { db in
      var record = SavedShelfEntryRecord(
        accountId: accountId, itemId: show, podcastEpisodeId: episode, savedAt: Self.epoch)
      try record.insert(db)
    }
  }

  func setSoftDeleted(item: Int64? = nil, episode: Int64? = nil) async throws {
    try await database.writeAsync { db in
      if let item { try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [item]) }
      if let episode {
        try db.execute(sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?", arguments: [episode])
      }
    }
  }

  /// The save-attempt link Home's `nativePreferred` rule joins.
  func link(
    feed: Int64, nativeEpisode: Int64, identityKey: String, serverItemID: String,
    serverEpisodeID: String
  ) async throws {
    try await database.writeAsync { db in
      let account = try #require(try AccountRecord.fetchOne(db))
      var attempt = NativeEpisodeServerSaveAttemptRecord(
        accountId: try #require(account.id), accountClientUUID: account.clientUUID,
        accountServerIdentityFingerprint: account.serverIdentityFingerprint, feedId: feed,
        episodeId: nativeEpisode, episodeIdentityKey: identityKey, serverItemId: serverItemID,
        serverEpisodeId: serverEpisodeID, state: .confirmed, createdAt: Self.epoch)
      try attempt.insert(db)
    }
  }

  // MARK: Reading

  func ids(
    _ listID: Int64, nativeEnabled: Bool = true, limit: Int = 1_000
  ) async throws -> [String] {
    let snapshot = try await snapshot(listID, nativeEnabled: nativeEnabled, limit: limit)
    return snapshot.episodes.map { "\($0.source == .native ? "n" : "s"):\($0.episodeID)" }
  }

  /// One-shot, so a SQL error throws instead of hanging inside observation's retry loop.
  func snapshot(_ listID: Int64, nativeEnabled: Bool = true, limit: Int = 1_000) async throws
    -> SmartListSnapshot
  {
    try await reading(nativeEnabled: nativeEnabled).fetchSnapshot(listID: listID, limit: limit)
  }

  /// The first emission of the observation, bounded so a failing query fails the test.
  func firstEmission(_ listID: Int64, nativeEnabled: Bool = true, limit: Int = 1_000) async throws
    -> SmartListSnapshot
  {
    var iterator = reading(nativeEnabled: nativeEnabled).observeEpisodes(
      listID: listID, limit: limit
    ).makeAsyncIterator()
    return try #require(await iterator.next())
  }
}

extension SmartListShowSelection {
  static func native(_ feedURL: String, _ role: SmartListShowRole) -> SmartListShowSelection {
    SmartListShowSelection(ref: .native(feedURL: feedURL), role: role, titleSnapshot: feedURL)
  }

  static func server(_ itemID: String, _ role: SmartListShowRole) -> SmartListShowSelection {
    server(user: "user-1", itemID, role)
  }

  static func server(user userID: String, _ itemID: String, _ role: SmartListShowRole)
    -> SmartListShowSelection
  {
    SmartListShowSelection(
      ref: .server(serverUserID: userID, serverItemID: itemID), role: role, titleSnapshot: itemID)
  }
}
