import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The two-pass soft/hard deletion rule: a completed traversal tombstones the rows it did not
/// see, and the traversal after that hard-deletes the tombstones nothing still references.
@Suite("Library pull: two-pass soft/hard deletion")
struct LibraryRefreshDeletionTests {

  @Test("only a fully successful traversal soft-deletes rows it did not see")
  func onlyACompletedTraversalSoftDeletesUnseenRows() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowId = try #require(library.id)
    try await h.seedItem(libraryRowId: libraryRowId, serverItemId: "missing-item", generation: 1)

    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "present-item", title: "Present", author: nil)], total: 1, limit: 100, page: 0)

    await h.engine.refresh()

    let missing = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "missing-item"))
    #expect(missing.softDeleted == true)
    let present = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "present-item"))
    #expect(present.softDeleted == false)
  }

  @Test("a decode-diagnostic page does not soft-delete unseen rows")
  func decodeDiagnosticPageDoesNotSoftDeleteUnseenRows() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowId = try #require(library.id)
    try await h.seedItem(libraryRowId: libraryRowId, serverItemId: "missing-item", generation: 1)

    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.http.enqueue(
      Harness.jsonResponse(object: [
        "results": [
          ["id": "present-item", "media": ["metadata": ["title": "Present"]]],
          ["media": ["metadata": ["title": "Malformed"]]],
        ],
        "total": 2,
        "limit": 100,
        "page": 0,
      ]))

    await h.engine.refresh()

    let missing = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "missing-item"))
    #expect(missing.softDeleted == false)
  }

  @Test("a clean short page still soft-deletes unseen rows")
  func cleanShortPageStillSoftDeletesUnseenRows() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowId = try #require(library.id)
    try await h.seedItem(libraryRowId: libraryRowId, serverItemId: "missing-item", generation: 1)

    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(
      items: [(id: "present-item", title: "Present", author: nil)], total: 2, limit: 100, page: 0)

    await h.engine.refresh()

    let missing = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "missing-item"))
    #expect(missing.softDeleted)
  }

  @Test("a second completed traversal hard-deletes an unreferenced tombstoned row")
  func aSecondCompletedTraversalHardDeletesUnreferencedRows() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowId = try #require(library.id)
    try await h.seedItem(libraryRowId: libraryRowId, serverItemId: "missing-item", generation: 1)

    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    await h.engine.refresh()

    let afterFirst = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "missing-item"))
    #expect(afterFirst.softDeleted == true)

    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    await h.engine.refresh()

    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "missing-item") == nil)
  }

  @Test("a referenced tombstone survives hard-delete as a minimal tombstone")
  func aReferencedTombstoneSurvivesAsAMinimalTombstone() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowId = try #require(library.id)
    let seeded = try await h.seedItem(
      libraryRowId: libraryRowId, serverItemId: "missing-item", title: "Keep Me", generation: 1)
    try await h.seedProgress(itemRowId: try #require(seeded.id))

    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    await h.engine.refresh()

    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    await h.engine.refresh()

    let tombstone = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "missing-item"))
    #expect(tombstone.softDeleted == true)
    #expect(tombstone.title == "")
    #expect(tombstone.author == nil)
  }

  @Test(arguments: DeletionReferenceKind.allCases)
  func everyProtectedReferencePreservesItsTombstoneAndDeletesAnUnreferencedSibling(
    referenceKind: DeletionReferenceKind
  ) async throws {
    let h = try await ReferenceProtectionHarness()
    let seeded = try await h.seedItems()
    try await h.seedReference(
      referenceKind, itemRowId: try #require(seeded.referenced.id), serverItemId: "referenced-item")

    for _ in 0..<2 {
      h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
      h.enqueueEmptyProgress()
      h.enqueueEmptyPage()
      await h.engine.refresh()
    }

    let tombstone = try #require(
      try h.fetchItem(serverItemId: "referenced-item"),
      "the referenced item remains as a tombstone for \(referenceKind.rawValue)")
    #expect(tombstone.softDeleted == true)
    #expect(tombstone.title == "")
    #expect(tombstone.author == nil)
    #expect(
      try h.fetchItem(serverItemId: "unreferenced-sibling") == nil,
      "an unreferenced sibling is hard-deleted")
  }

  @Test("explicit library removal follows the same two-pass tombstone rule")
  func explicitLibraryRemovalFollowsTheSameTwoPassRule() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "removed-lib")
    let libraryRowId = try #require(library.id)
    try await h.seedItem(libraryRowId: libraryRowId, serverItemId: "item1", generation: 1)

    // The server's library list no longer mentions this library at all.
    h.enqueueLibraries([])
    await h.engine.refresh()

    let afterFirst = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "item1"))
    #expect(afterFirst.softDeleted == true)

    h.enqueueLibraries([])
    await h.engine.refresh()

    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "item1") == nil)
  }
}

enum DeletionReferenceKind: String, CaseIterable, Sendable {
  case progress
  case outbox
  case playbackSession
  case download
  case listeningQueue
}

/// The shared `Harness` hides its database because most library-pull tests only
/// need read assertions. This local fixture keeps reference seeding in this file while driving the
/// real `SyncEngine.refresh()` and `SyncRunDAO` deletion path.
private final class ReferenceProtectionHarness: @unchecked Sendable {
  let database: AppDatabase
  let http: FakeHTTPClient
  let engine: SyncEngine
  let accountId: Int64
  let libraryId: Int64

  init() async throws {
    let server = try ABSServerConfig(url: URL(string: "https://sync-deletion.example.test")!)
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    let database = try AppDatabase.inMemory()
    let ids = try await database.writeAsync { db -> (accountId: Int64, libraryId: Int64) in
      var accountRecord = AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture",
        serverVersion: "2.35.1")
      try accountRecord.insert(db)

      var library = LibraryRecord(
        accountId: accountRecord.id!, serverLibraryId: "lib1", mediaType: "book", name: "Seeded")
      try library.insert(db)
      return (accountRecord.id!, library.id!)
    }

    let http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let diagnostics = FakeDiagnosticsRecording()
    let appLifecycle = FakeAppLifecycle()
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000))

    self.database = database
    self.http = http
    accountId = ids.accountId
    libraryId = ids.libraryId
    engine = SyncEngine.make(
      client: client,
      database: database,
      diagnostics: diagnostics,
      appLifecycle: appLifecycle,
      clock: clock,
      randomSource: { 1 },
      pageLimit: 100)
  }

  func seedItems() async throws -> (referenced: ItemRecord, sibling: ItemRecord) {
    try await database.writeAsync { db in
      var referenced = ItemRecord(
        accountId: accountId,
        libraryId: libraryId,
        serverItemId: "referenced-item",
        mediaKind: "book",
        title: "Keep Me",
        sortTitle: "keep me")
      try referenced.insert(db)

      var sibling = ItemRecord(
        accountId: accountId,
        libraryId: libraryId,
        serverItemId: "unreferenced-sibling",
        mediaKind: "book",
        title: "Delete Me",
        sortTitle: "delete me")
      try sibling.insert(db)
      return (referenced: referenced, sibling: sibling)
    }
  }

  func seedReference(
    _ referenceKind: DeletionReferenceKind, itemRowId: Int64, serverItemId: String
  ) async throws {
    try await database.writeAsync { db in
      switch referenceKind {
      case .progress:
        var progress = MediaProgressRecord(
          accountId: accountId,
          itemId: itemRowId,
          currentTime: 10,
          isFinished: false,
          localSequence: 1,
          origin: .server,
          originKey: ProgressOrigin.serverOriginKey)
        try progress.insert(db)

      case .outbox:
        var operation = OutboxOperationRecord(
          accountId: accountId,
          clientOperationId: "protected-outbox-operation",
          entityKey: serverItemId,
          podcastEpisodeId: nil,
          operationKind: OutboxOperationKind.progress.rawValue,
          coalescingKey: "protected-outbox",
          payloadVersion: 1,
          localSequence: 1,
          payloadCurrentTime: 10,
          payloadIsFinished: false,
          payloadAccumulatedDeltaSeconds: 0)
        try operation.insert(db)

      case .playbackSession:
        var session = PlaybackSessionRecord(
          accountId: accountId,
          clientSessionId: "protected-playback-session",
          itemId: itemRowId,
          startedAt: Date(timeIntervalSince1970: 1_700_000_000),
          updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try session.insert(db)

      case .download:
        var download = DownloadRecord(
          accountId: accountId,
          itemId: itemRowId,
          serverFileIno: "protected-file",
          orderIndex: 0,
          destinationRelativePath: "protected.mp3",
          expectedBytes: 1,
          expectedMimeType: "audio/mpeg",
          fileDurationSeconds: 1,
          receivedBytes: 1,
          state: .completed)
        try download.insert(db)

      case .listeningQueue:
        var entry = ListeningQueueEntryRecord(accountId: accountId, itemId: itemRowId, position: 0)
        try entry.insert(db)
      }
    }
  }

  func enqueueLibraries(_ libraries: [(id: String, name: String, mediaType: String)]) {
    let object: [String: Any] = [
      "libraries": libraries.map {
        ["id": $0.id, "name": $0.name, "mediaType": $0.mediaType]
      }
    ]
    http.enqueue(Harness.jsonResponse(object: object))
  }

  func enqueueEmptyProgress() {
    http.enqueue(Harness.jsonResponse(object: ["mediaProgresses": []]))
  }

  func enqueueEmptyPage() {
    http.enqueue(
      Harness.jsonResponse(
        object: ["results": [], "total": 0, "limit": 100, "page": 0]))
  }

  func fetchItem(serverItemId: String) throws -> ItemRecord? {
    try database.read { db in
      try ItemRecord.fetchAll(db).first {
        $0.libraryId == libraryId && $0.serverItemId == serverItemId
      }
    }
  }
}
