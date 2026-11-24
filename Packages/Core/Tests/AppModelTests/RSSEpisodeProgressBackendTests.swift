import Foundation
import GRDB
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite("RSS episode progress backend")
struct RSSEpisodeProgressBackendTests {
  @Test func everyWriteFailsForAnEpisodeWithNoRowAndWritesNothing() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode-a")])
    let sut = Self.makeBackend(fixture: fixture)

    await #expect(throws: (any Error).self) {
      try await sut.resetProgress(itemID: "rss:999999", episodeID: "episode-a")
    }
    await #expect(throws: (any Error).self) {
      try await sut.markFinished(itemID: fixture.itemID, episodeID: "missing", duration: nil)
    }
    await #expect(throws: (any Error).self) {
      try await sut.hideFromContinueListening(itemID: fixture.itemID, episodeID: "missing")
    }
    await #expect(throws: (any Error).self) {
      try await sut.setFinished(
        itemID: fixture.itemID,
        episodes: [EpisodeProgressChange(episodeID: "missing", currentTime: 0)], isFinished: true)
    }
    await #expect(throws: (any Error).self) {
      try await sut.markFinished(itemID: "li_show", episodeID: "episode-a", duration: nil)
    }

    #expect(try await fixture.stateRowCount() == 0)
  }

  /// `duration` is the server's way of recording an end position. The device-owned state keeps
  /// `finished` as its own column, so the stored position is left where it was.
  @Test func markFinishedIgnoresTheSuppliedDuration() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode-a")])
    let stateStore = RSSEpisodeStateStore(database: fixture.database)
    let rowID = try #require(fixture.episodeIDs["episode-a"])
    _ = try await stateStore.recordTick(
      episodeId: rowID, position: 42, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    let sut = Self.makeBackend(fixture: fixture)

    try await sut.markFinished(itemID: fixture.itemID, episodeID: "episode-a", duration: 120)

    let state = try await stateStore.fetchState(episodeId: rowID)
    #expect(state?.finished == true)
    #expect(state?.position == 42)
  }

  @Test func hideFromContinueListeningDismissesOnlyTheNamedEpisode() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode-a"), Self.episode(identityKey: "episode-b")])
    let stateStore = RSSEpisodeStateStore(database: fixture.database)
    for key in ["episode-a", "episode-b"] {
      _ = try await stateStore.recordTick(
        episodeId: try #require(fixture.episodeIDs[key]), position: 42, finished: false,
        capturedSequence: 0, now: Date(timeIntervalSince1970: 100))
    }
    let sut = Self.makeBackend(fixture: fixture)

    try await sut.hideFromContinueListening(itemID: fixture.itemID, episodeID: "episode-a")

    let dismissed = try await stateStore.fetchState(
      episodeId: try #require(fixture.episodeIDs["episode-a"]))
    let sibling = try await stateStore.fetchState(
      episodeId: try #require(fixture.episodeIDs["episode-b"]))
    #expect(dismissed?.hideFromContinueListening == true)
    // The dismissal is not a progress edit: the position it was dismissed at is what a later
    // resume has to pick up from.
    #expect(dismissed?.position == 42)
    #expect(sibling?.hideFromContinueListening == false)
  }

  // MARK: - Finishing resolves Saved for Later

  @Test func markFinishedRemovesOnlyTheExactSavedEpisodeAtAnUnchangedPosition() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode-a"), Self.episode(identityKey: "episode-b")])
    try await fixture.savedShelf.save(.rssEpisode(itemID: fixture.itemID, episodeID: "episode-a"))
    try await fixture.savedShelf.save(.rssEpisode(itemID: fixture.itemID, episodeID: "episode-b"))
    let sut = Self.makeBackend(fixture: fixture)

    // Nothing has been played: the position stays at zero and only the finished flag moves.
    try await sut.markFinished(itemID: fixture.itemID, episodeID: "episode-a", duration: nil)
    #expect(try await fixture.savedEpisodeKeys() == ["episode-b"])

    // Marking it unplayed again never restores the save.
    try await sut.resetProgress(itemID: fixture.itemID, episodeID: "episode-a")
    #expect(try await fixture.savedEpisodeKeys() == ["episode-b"])

    // A deliberate re-save after the episode is already finished survives a repeated finish.
    try await sut.markFinished(itemID: fixture.itemID, episodeID: "episode-a", duration: nil)
    try await fixture.savedShelf.save(.rssEpisode(itemID: fixture.itemID, episodeID: "episode-a"))
    try await sut.markFinished(itemID: fixture.itemID, episodeID: "episode-a", duration: 120)
    #expect(try await fixture.savedEpisodeKeys() == ["episode-b", "episode-a"])
  }

  @Test func setFinishedClearsOnlyTheSuppliedSavedEpisodes() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [
        Self.episode(identityKey: "episode-a"), Self.episode(identityKey: "episode-b"),
        Self.episode(identityKey: "episode-c"),
      ])
    for key in ["episode-a", "episode-b", "episode-c"] {
      try await fixture.savedShelf.save(.rssEpisode(itemID: fixture.itemID, episodeID: key))
    }
    let sut = Self.makeBackend(fixture: fixture)
    let supplied = [
      EpisodeProgressChange(episodeID: "episode-a", currentTime: 0),
      EpisodeProgressChange(episodeID: "episode-b", currentTime: 0),
    ]

    try await sut.setFinished(itemID: fixture.itemID, episodes: supplied, isFinished: true)
    #expect(try await fixture.savedEpisodeKeys() == ["episode-c"])

    try await sut.setFinished(itemID: fixture.itemID, episodes: supplied, isFinished: false)
    #expect(try await fixture.savedEpisodeKeys() == ["episode-c"])
  }

  // MARK: - Delete After Playing

  /// The same rule `ItemProgressCoordinator` applies to account-owned episodes: only after the
  /// finished state has durably landed, once per finished identity, and only when the
  /// preference is on.
  @Test func explicitFinishAppliesDeleteAfterPlayingOnlyWhenEnabled() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode-a"), Self.episode(identityKey: "episode-b")])
    let retained = RSSFinishedDeletionRecorder()
    let retaining = Self.makeBackend(
      fixture: fixture,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: false),
      requestFinishedDownloadDeletion: { await retained.record(itemID: $0, episodeID: $1) })
    try await retaining.markFinished(itemID: fixture.itemID, episodeID: "episode-a", duration: 120)
    #expect(await retained.values.isEmpty)

    let deleted = RSSFinishedDeletionRecorder()
    let deleting = Self.makeBackend(
      fixture: fixture,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: true),
      requestFinishedDownloadDeletion: { await deleted.record(itemID: $0, episodeID: $1) })
    try await deleting.markFinished(itemID: fixture.itemID, episodeID: "episode-b", duration: nil)
    #expect(
      await deleted.values == [
        RSSFinishedDeletionIdentity(itemID: fixture.itemID, episodeID: "episode-b")
      ])
  }

  @Test func bulkFinishRequestsDeletionOncePerSuppliedEpisode() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [
        Self.episode(identityKey: "episode-a"), Self.episode(identityKey: "episode-b"),
        Self.episode(identityKey: "episode-c"),
      ])
    let deletions = RSSFinishedDeletionRecorder()
    let sut = Self.makeBackend(
      fixture: fixture,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: true),
      requestFinishedDownloadDeletion: { await deletions.record(itemID: $0, episodeID: $1) })
    let supplied = [
      EpisodeProgressChange(episodeID: "episode-a", currentTime: 0),
      EpisodeProgressChange(episodeID: "episode-b", currentTime: 0),
    ]

    try await sut.setFinished(itemID: fixture.itemID, episodes: supplied, isFinished: true)
    #expect(
      await deletions.values == [
        RSSFinishedDeletionIdentity(itemID: fixture.itemID, episodeID: "episode-a"),
        RSSFinishedDeletionIdentity(itemID: fixture.itemID, episodeID: "episode-b"),
      ])

    // Marking unplayed is not a finish; nothing more is deleted.
    try await sut.setFinished(itemID: fixture.itemID, episodes: supplied, isFinished: false)
    #expect(await deletions.values.count == 2)
  }

  @Test func aFinishThatFailsToPersistLeavesSavesAndDownloadsAlone() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode-a")])
    try await fixture.savedShelf.save(.rssEpisode(itemID: fixture.itemID, episodeID: "episode-a"))
    let deletions = RSSFinishedDeletionRecorder()
    let sut = Self.makeBackend(
      fixture: fixture,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: true),
      requestFinishedDownloadDeletion: { await deletions.record(itemID: $0, episodeID: $1) })

    await #expect(throws: (any Error).self) {
      try await sut.markFinished(itemID: fixture.itemID, episodeID: "missing", duration: nil)
    }
    await #expect(throws: (any Error).self) {
      try await sut.setFinished(
        itemID: fixture.itemID,
        episodes: [
          EpisodeProgressChange(episodeID: "episode-a", currentTime: 0),
          EpisodeProgressChange(episodeID: "missing", currentTime: 0),
        ], isFinished: true)
    }

    #expect(try await fixture.savedEpisodeKeys() == ["episode-a"])
    #expect(await deletions.values.isEmpty)
  }

  // MARK: - Fixture

  private struct Fixture {
    let database: AppDatabase
    let accountID: Int64
    let itemID: String
    let episodeIDs: [String: Int64]

    var savedShelf: SavedShelfStore {
      SavedShelfStore(database: database, accountId: accountID)
    }

    /// Identity keys of the saved device-owned episodes, in row order.
    func savedEpisodeKeys() async throws -> [String] {
      try await database.readAsync { db in
        try String.fetchAll(
          db,
          sql: """
            SELECT episode.identityKey
            FROM rssSavedShelfEntry AS saved
            JOIN rssEpisode AS episode ON episode.id = saved.rssEpisodeId
            ORDER BY saved.id
            """)
      }
    }

    func stateRowCount() async throws -> Int {
      try await database.readAsync { db in try RSSEpisodeStateRecord.fetchCount(db) }
    }
  }

  private static func makeBackend(
    fixture: Fixture,
    downloadPreferences: any DownloadPreferences = NoOpDownloadPreferences(),
    requestFinishedDownloadDeletion: @escaping @Sendable (String, String?) async -> Void = {
      _, _ in
    }
  ) -> RSSEpisodeProgressBackend {
    RSSEpisodeProgressBackend(
      episodeStore: RSSEpisodeStore(database: fixture.database),
      stateStore: RSSEpisodeStateStore(database: fixture.database),
      downloadPreferences: downloadPreferences,
      requestFinishedDownloadDeletion: requestFinishedDownloadDeletion)
  }

  private static func makeFixture(episodes: [RSSEpisodeUpsert]) async throws -> Fixture {
    let database = try AppDatabase.inMemory()
    let accountID = try await database.writeAsync { db -> Int64 in
      var account = AccountRecord(
        clientUUID: "rss-backend-\(UUID().uuidString)", serverBaseURL: "https://example.test",
        serverUserId: "user", serverVersion: "2.26.0")
      try account.insert(db)
      return try #require(account.id)
    }
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/feed-\(UUID().uuidString).xml")!,
      title: "Feed", author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    _ = try await RSSEpisodeStore(database: database).applyRefresh(feedId: feedID, episodes: episodes)
    let rows = try await database.readAsync { db in
      try RSSEpisodeRecord.fetchAll(
        db, sql: "SELECT * FROM rssEpisode WHERE feedId = ? ORDER BY id", arguments: [feedID])
    }
    let episodeIDs = Dictionary(
      uniqueKeysWithValues: rows.compactMap { row -> (String, Int64)? in
        guard let id = row.id else { return nil }
        return (row.identityKey, id)
      })
    return Fixture(
      database: database,
      accountID: accountID,
      itemID: try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId,
      episodeIDs: episodeIDs)
  }

  private static func episode(identityKey: String) -> RSSEpisodeUpsert {
    RSSEpisodeUpsert(
      identityKey: identityKey,
      title: identityKey,
      enclosureURL: URL(string: "https://media.example/\(identityKey).mp3")!,
      durationSeconds: 120)
  }
}

private struct RSSFinishedDeletionIdentity: Sendable, Equatable {
  let itemID: String
  let episodeID: String?
}

private actor RSSFinishedDeletionRecorder {
  private(set) var values: [RSSFinishedDeletionIdentity] = []

  func record(itemID: String, episodeID: String?) {
    values.append(RSSFinishedDeletionIdentity(itemID: itemID, episodeID: episodeID))
  }
}
