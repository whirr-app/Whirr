import Foundation
import GRDB
import Synchronization
import TestSupport
import Testing

@testable import Persistence

enum LibraryReadingObservationFixtures {
  static func currentThreadIsMain() -> Bool { Thread.isMainThread }
}

private final class PersistenceObservationStorage<Value>: @unchecked Sendable {
  let mutex: Mutex<[Value]>

  init() {
    mutex = Mutex([])
  }
}

final class PersistenceObservationCollector<Value: Sendable>: @unchecked Sendable {
  private let valuesStorage: PersistenceObservationStorage<Value>
  private let task: Task<Void, Never>

  init(_ stream: AsyncStream<Value>, stopAfter: Int? = nil) {
    let valuesStorage = PersistenceObservationStorage<Value>()
    self.valuesStorage = valuesStorage
    task = Task {
      var received = 0
      for await value in stream {
        valuesStorage.mutex.withLock { $0.append(value) }
        received += 1
        if let stopAfter, received >= stopAfter { break }
      }
    }
  }

  var values: [Value] { valuesStorage.mutex.withLock { $0 } }

  func contains(where predicate: @Sendable (Value) -> Bool) -> Bool {
    valuesStorage.mutex.withLock { $0.contains(where: predicate) }
  }

  func last(where predicate: @Sendable (Value) -> Bool) -> Value? {
    valuesStorage.mutex.withLock { $0.last(where: predicate) }
  }

  deinit {
    task.cancel()
  }
}

extension LibraryReadingObservationTests {
  // MARK: - Helpers

  /// Drains until the snapshot carries `count` rows (see `settled`). A `ValueObservation`'s first
  /// value can predate the seeded writes.
  static func settledSnapshot(
    _ stream: AsyncStream<LibraryBrowseSnapshot>, count: Int
  ) async throws -> LibraryBrowseSnapshot {
    let observations = PersistenceObservationCollector(stream)
    #expect(await TestSupport.waitUntil { observations.contains { $0.items.count == count } })
    return try #require(observations.last { $0.items.count == count })
  }

  /// The same drain keyed on the unfiltered count, for cases whose filtered list is legitimately
  /// empty and so cannot be waited on by row count.
  static func settledSnapshot(
    _ stream: AsyncStream<LibraryBrowseSnapshot>, unfilteredCount: Int
  ) async throws -> LibraryBrowseSnapshot {
    let observations = PersistenceObservationCollector(stream)
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.unfilteredItemCount == unfilteredCount }
      })
    return try #require(observations.last { $0.unfilteredItemCount == unfilteredCount })
  }

  static func settledIDs(
    _ reading: DefaultLibraryReading, _ filters: BrowseFilters, count: Int
  ) async throws -> [String] {
    try await settledSnapshot(reading.observeBrowseList(filters: filters), count: count)
      .items.map(\.serverItemId)
  }

  /// Drains `stream` until it yields a list of `count` items, returning their ids. The first
  /// value a `ValueObservation` emits can predate the seeded writes being visible to it.
  static func settled(
    _ stream: AsyncStream<[ItemSummary]>, count: Int
  ) async throws -> [String] {
    let observations = PersistenceObservationCollector(stream)
    #expect(await TestSupport.waitUntil { observations.contains { $0.count == count } })
    return try #require(observations.last { $0.count == count }).map(\.serverItemId)
  }

  static func seedAccountAndLibraries(
    _ database: AppDatabase, serverLibraryIds: [String]
  ) async throws -> (accountId: Int64, libraryRowIds: [Int64]) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)
      let accountId = account.id!

      let libraryRowIds = try serverLibraryIds.map { serverLibraryId in
        var library = LibraryRecord(
          accountId: accountId, serverLibraryId: serverLibraryId, mediaType: "book", name: serverLibraryId)
        try library.insert(db)
        return library.id!
      }
      return (accountId, libraryRowIds)
    }
  }

  /// One in-memory database plus the account/library rows, with row-id-returning seeds so a test
  /// can write directly to `download`/`mediaProgress` after the observation is already running.
  /// That is the only way to prove the tracked region reaches those tables.
  struct FilterFixture {
    let database: AppDatabase
    let reading: DefaultLibraryReading
    let accountId: Int64
    let libraryRowId: Int64

    init() async throws {
      database = try AppDatabase.inMemory()
      reading = DefaultLibraryReading(database: database)
      (accountId, libraryRowId) = try await LibraryReadingObservationTests.seedAccountAndLibrary(
        database, serverLibraryId: "lib1")
    }

    func book(
      _ serverItemId: String, numAudioFiles: Int? = nil, ebookFormat: String? = nil
    ) async throws -> Int64 {
      try await insertItem(
        serverItemId, mediaKind: "book", numAudioFiles: numAudioFiles, ebookFormat: ebookFormat)
    }

    func show(_ serverItemId: String) async throws -> Int64 {
      try await insertItem(serverItemId, mediaKind: "podcast", numAudioFiles: nil, ebookFormat: nil)
    }

    private func insertItem(
      _ serverItemId: String, mediaKind: String, numAudioFiles: Int?, ebookFormat: String?
    ) async throws -> Int64 {
      try await database.writeAsync { db in
        var item = PersistenceFixtures.item(
          accountId: accountId, libraryId: libraryRowId, serverItemId: serverItemId,
          mediaKind: mediaKind, title: serverItemId, sortTitle: serverItemId,
          numAudioFiles: numAudioFiles, ebookFormat: ebookFormat)
        try item.insert(db)
        return item.id!
      }
    }

    func episode(itemId: Int64, serverEpisodeId: String) async throws -> Int64 {
      try await database.writeAsync { db in
        var episode = PodcastEpisodeRecord(
          accountId: accountId, itemId: itemId, serverEpisodeId: serverEpisodeId,
          title: serverEpisodeId, lastSeenGeneration: 1)
        try episode.insert(db)
        return episode.id!
      }
    }

    @discardableResult
    func download(
      itemId: Int64,
      podcastEpisodeId: Int64? = nil,
      state: DownloadState,
      mediaKind: DownloadMediaKind = .audio
    ) async throws
      -> Int64
    {
      try await database.writeAsync { db in
        var download = DownloadRecord(
          accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId,
          serverFileIno: UUID().uuidString, orderIndex: 0,
          destinationRelativePath: "downloads/\(UUID().uuidString)", expectedBytes: 100,
          expectedMimeType: "audio/mp4", fileDurationSeconds: 60,
          receivedBytes: state == .completed ? 100 : 0, state: state, mediaKind: mediaKind)
        try download.insert(db)
        return download.id!
      }
    }

    @discardableResult
    func progress(itemId: Int64, podcastEpisodeId: Int64? = nil, isFinished: Bool) async throws -> Int64 {
      try await database.writeAsync { db in
        var progress = MediaProgressRecord(
          accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId,
          currentTime: isFinished ? 100 : 30, isFinished: isFinished, localSequence: 1,
          origin: .local, originKey: "client-uuid")
        try progress.insert(db)
        return progress.id!
      }
    }

    /// The first value of a fresh observation: a plain point-in-time read of the same query, for
    /// the assertions about snapshot equality rather than about re-emission.
    func snapshot(filters: BrowseFilters) async throws -> LibraryBrowseSnapshot {
      var iterator = reading.observeBrowseList(filters: filters).makeAsyncIterator()
      return try #require(await iterator.next())
    }

    func softDelete(itemId: Int64) async throws {
      try await database.writeAsync { db in
        try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [itemId])
      }
    }
  }

  static func seedAccountAndLibrary(
    _ database: AppDatabase, serverLibraryId: String
  ) async throws -> (accountId: Int64, libraryRowId: Int64) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)
      let accountId = account.id!

      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: serverLibraryId, mediaType: "book", name: "Library")
      try library.insert(db)
      let libraryRowId = library.id!

      return (accountId, libraryRowId)
    }
  }
}
