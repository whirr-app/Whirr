import Foundation
import GRDB
import Testing

@testable import Persistence

/// v74: per-episode chapters. Separate from `itemChapter`, which books own.
@Suite struct PodcastEpisodeChapterStoreTests {
  private static func chapters(_ count: Int, titlePrefix: String = "Chapter") -> [StoredItemChapter] {
    (0..<count).map {
      StoredItemChapter(
        serverChapterId: $0, position: $0, start: Double($0) * 60, end: Double($0 + 1) * 60,
        title: "\(titlePrefix) \($0)")
    }
  }

  private static func seed(_ database: AppDatabase) async throws -> (
    accountId: Int64, itemId: Int64, episodeA: Int64, episodeB: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "fixture-client", serverBaseURL: "fixture-server",
        serverUserId: "fixture-user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "podcasts", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "show-1",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try item.insert(db)
      var a = PodcastEpisodeRecord(
        accountId: account.id!, itemId: item.id!, serverEpisodeId: "a", title: "A",
        lastSeenGeneration: 1)
      try a.insert(db)
      var b = PodcastEpisodeRecord(
        accountId: account.id!, itemId: item.id!, serverEpisodeId: "b", title: "B",
        lastSeenGeneration: 1)
      try b.insert(db)
      return (account.id!, item.id!, a.id!, b.id!)
    }
  }

  @Test func v74CreatesTheTableAndKeepsItemChapterUntouched() throws {
    let database = try AppDatabase.inMemory()
    let tables = try database.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(tables.contains("podcastEpisodeChapter"))
    #expect(tables.contains("itemChapter"))
  }

  @Test func replaceStoresOrderedChaptersAndReplacesOnlyThatEpisode() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seed(database)
    let store = PodcastEpisodeChapterStore(database: database)

    try store.replace(
      accountId: seeded.accountId, podcastEpisodeId: seeded.episodeA, chapters: Self.chapters(3))
    try store.replace(
      accountId: seeded.accountId, podcastEpisodeId: seeded.episodeB,
      chapters: Self.chapters(1, titlePrefix: "B"))
    try store.replace(
      accountId: seeded.accountId, podcastEpisodeId: seeded.episodeA,
      chapters: Self.chapters(2, titlePrefix: "New"))

    let a = try store.fetch(accountId: seeded.accountId, podcastEpisodeId: seeded.episodeA)
    #expect(a.map(\.title) == ["New 0", "New 1"])
    #expect(a.map(\.end) == [60, 120])
    let b = try await store.fetchAsync(
      accountId: seeded.accountId, podcastEpisodeId: seeded.episodeB)
    #expect(b.map(\.title) == ["B 0"])

    try store.replace(accountId: seeded.accountId, podcastEpisodeId: seeded.episodeA, chapters: [])
    #expect(
      try store.fetch(accountId: seeded.accountId, podcastEpisodeId: seeded.episodeA).isEmpty)
  }

  @Test func deletingTheEpisodeRowCascadesItsChaptersOnly() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seed(database)
    let store = PodcastEpisodeChapterStore(database: database)
    try store.replace(
      accountId: seeded.accountId, podcastEpisodeId: seeded.episodeA, chapters: Self.chapters(2))
    try store.replace(
      accountId: seeded.accountId, podcastEpisodeId: seeded.episodeB, chapters: Self.chapters(2))

    try await database.writeAsync { db in
      _ = try PodcastEpisodeRecord.deleteOne(db, key: seeded.episodeA)
    }

    #expect(
      try store.fetch(accountId: seeded.accountId, podcastEpisodeId: seeded.episodeA).isEmpty)
    #expect(
      try store.fetch(accountId: seeded.accountId, podcastEpisodeId: seeded.episodeB).count == 2)
  }

  @Test func refreshWritesReplacesAndLeavesAbsentEpisodesAlone() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seed(database)
    let store = PodcastEpisodeChapterStore(database: database)
    let refresh = PodcastRefreshStore(database: database)
    func record(_ id: String) -> PodcastEpisodeRecord {
      PodcastEpisodeRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeId: id, title: id,
        lastSeenGeneration: 0)
    }
    try store.replace(
      accountId: seeded.accountId, podcastEpisodeId: seeded.episodeB,
      chapters: Self.chapters(2, titlePrefix: "Kept"))

    try refresh.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId,
        episodes: [record("a"), record("b")],
        episodeChapters: ["a": Self.chapters(3)],
        responseIsComplete: true)
    ) { _ in .keepLocal }
    #expect(
      try store.fetch(accountId: seeded.accountId, podcastEpisodeId: seeded.episodeA).count == 3)
    #expect(
      try store.fetch(accountId: seeded.accountId, podcastEpisodeId: seeded.episodeB).map(\.title)
        == ["Kept 0", "Kept 1"])

    try refresh.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId,
        episodes: [record("a")],
        episodeChapters: ["a": Self.chapters(1, titlePrefix: "Fresh")],
        responseIsComplete: false)
    ) { _ in .keepLocal }
    #expect(
      try store.fetch(accountId: seeded.accountId, podcastEpisodeId: seeded.episodeA).map(\.title)
        == ["Fresh 0"])

    try refresh.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId,
        episodes: [record("a")],
        episodeChapters: ["a": []],
        responseIsComplete: false)
    ) { _ in .keepLocal }
    #expect(
      try store.fetch(accountId: seeded.accountId, podcastEpisodeId: seeded.episodeA).isEmpty)
  }
}
