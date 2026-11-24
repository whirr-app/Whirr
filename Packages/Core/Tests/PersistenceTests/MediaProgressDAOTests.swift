import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// `hasUnacknowledgedLocalOperation` must match the `entityKey` shape production writes for a
/// `progress`-kind row: the real server item id, as used by
/// `PlaybackSessionStore.markSessionGone`'s preserved-position row and
/// `OutboxDrainer.sendProgress`'s wire `libraryItemID` (API-CONVENTIONS rule 11). A local-row-id
/// shape (`"item:<rowId>"`) is never written, so matching it would disengage the guard protecting
/// an unacknowledged local write from a concurrent pull.
@Suite struct MediaProgressDAOTests {

  @Test func detectsTheRealMarkSessionGonePreservedPositionRowAsUnacknowledged() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, serverItemId) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    let mediaProgressDAO = MediaProgressDAO(database: database)

    let session = try sessionStore.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try sessionStore.setServerSessionId(sessionId: session.id!, serverSessionId: "server-session-1")
    _ = try sessionStore.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 42, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))

    #expect(
      try mediaProgressDAO.hasUnacknowledgedLocalOperation(
        accountId: accountId, identity: .item(itemId: itemId)) == false,
      "a live session's own ticks are session-keyed, not item-keyed - nothing to detect yet")

    _ = try sessionStore.markSessionGone(sessionId: session.id!, now: Date(timeIntervalSince1970: 1_700_000_020))

    #expect(
      try mediaProgressDAO.hasUnacknowledgedLocalOperation(
        accountId: accountId, identity: .item(itemId: itemId)) == true,
      "the preserved-position progress row markSessionGone just enqueued must be visible")

    // Confirm it really is keyed by the server item id, not the local row id.
    let queued = try outbox.fetchQueued(accountId: accountId, entityKey: serverItemId)
    #expect(queued.count == 1)
    #expect(queued.first?.operationKind == OutboxOperationKind.progress.rawValue)
  }

  @Test func returnsFalseForAnItemWithNoQueuedProgressOperation() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let mediaProgressDAO = MediaProgressDAO(database: database)

    #expect(
      try mediaProgressDAO.hasUnacknowledgedLocalOperation(
        accountId: accountId, identity: .item(itemId: itemId)) == false)
  }

  @Test func returnsFalseOnceThePreservedPositionRowIsAcknowledged() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, serverItemId) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    let mediaProgressDAO = MediaProgressDAO(database: database)

    let session = try sessionStore.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try sessionStore.setServerSessionId(sessionId: session.id!, serverSessionId: "server-session-1")
    _ = try sessionStore.markSessionGone(sessionId: session.id!, now: Date(timeIntervalSince1970: 1_700_000_020))

    let queued = try outbox.fetchQueued(accountId: accountId, entityKey: serverItemId)
    let operationId = try #require(queued.first?.id)
    try outbox.acknowledge(operationId: operationId) { _ in }

    #expect(
      try mediaProgressDAO.hasUnacknowledgedLocalOperation(
        accountId: accountId, identity: .item(itemId: itemId)) == false)
  }

  // MARK: - Item / episode identity

  @Test func itemAndEpisodeProgressOnTheSameShowAreFetchedAndAppliedIndependently() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, mediaKind: "podcast")
    let episodeId = try await Self.insertEpisode(database, accountId: accountId, itemId: itemId)
    let dao = MediaProgressDAO(database: database)
    let itemIdentity = MediaProgressIdentity.item(itemId: itemId)
    let episodeIdentity = MediaProgressIdentity.episode(
      itemId: itemId, podcastEpisodeId: episodeId)

    _ = try dao.applyServerResolution(
      accountId: accountId, identity: itemIdentity, currentTime: 10, isFinished: false,
      serverUpdatedAt: nil)
    _ = try dao.applyServerResolution(
      accountId: accountId, identity: episodeIdentity, currentTime: 20, isFinished: false,
      serverUpdatedAt: nil)

    #expect(try dao.fetchCurrent(accountId: accountId, identity: itemIdentity)?.currentTime == 10)
    #expect(
      try dao.fetchCurrent(accountId: accountId, identity: episodeIdentity)?.currentTime == 20)
    #expect(
      try dao.fetchCurrent(accountId: accountId, identity: itemIdentity)?.podcastEpisodeId == nil)
    #expect(
      try dao.fetchCurrent(accountId: accountId, identity: episodeIdentity)?.podcastEpisodeId
        == episodeId)

    _ = try dao.applyServerResolution(
      accountId: accountId, identity: episodeIdentity, currentTime: 30, isFinished: true,
      serverUpdatedAt: nil)

    #expect(try dao.fetchCurrent(accountId: accountId, identity: itemIdentity)?.currentTime == 10)
    let episode = try #require(
      try dao.fetchCurrent(accountId: accountId, identity: episodeIdentity))
    #expect(episode.currentTime == 30)
    #expect(episode.isFinished)
  }

  @Test func itemAndEpisodeConflictsOnTheSameShowResolveOnlyTheirOwnProgressRows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, serverItemId) = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, mediaKind: "podcast")
    let episodeId = try await Self.insertEpisode(database, accountId: accountId, itemId: itemId)
    let dao = MediaProgressDAO(database: database)
    let itemIdentity = MediaProgressIdentity.item(itemId: itemId)
    let episodeIdentity = MediaProgressIdentity.episode(
      itemId: itemId, podcastEpisodeId: episodeId)
    let detectedAt = Date(timeIntervalSince1970: 1_700_000_000)

    _ = try dao.applyServerResolution(
      accountId: accountId, identity: itemIdentity, currentTime: 100, isFinished: false,
      serverUpdatedAt: nil)
    _ = try dao.applyServerResolution(
      accountId: accountId, identity: episodeIdentity, currentTime: 200, isFinished: false,
      serverUpdatedAt: nil)
    let itemConflict = try dao.recordConflict(
      accountId: accountId, identity: itemIdentity, serverCurrentTime: 1,
      serverIsFinished: false, serverUpdatedAt: nil, detectedAt: detectedAt)
    let episodeConflict = try dao.recordConflict(
      accountId: accountId, identity: episodeIdentity, serverCurrentTime: 2,
      serverIsFinished: true, serverUpdatedAt: nil, detectedAt: detectedAt)

    #expect(itemConflict.podcastEpisodeId == nil)
    #expect(episodeConflict.podcastEpisodeId == episodeId)
    #expect(try dao.fetchOpenConflicts(accountId: accountId).count == 2)

    try dao.resolveConflictTakingServer(conflictId: try #require(itemConflict.id))

    #expect(try dao.fetchCurrent(accountId: accountId, identity: itemIdentity)?.currentTime == 1)
    #expect(
      try dao.fetchCurrent(accountId: accountId, identity: episodeIdentity)?.currentTime == 200)
    #expect(
      try dao.fetchConflict(id: try #require(episodeConflict.id))?.podcastEpisodeId == episodeId)

    try dao.resolveConflictKeepingLocal(
      conflictId: try #require(episodeConflict.id), entityKey: serverItemId)

    let episode = try #require(
      try dao.fetchCurrent(accountId: accountId, identity: episodeIdentity))
    #expect(episode.currentTime == 200)
    let queued = try OutboxStore(database: database).fetchQueued(
      accountId: accountId, entityKey: serverItemId)
    #expect(queued.count == 1)
    #expect(queued[0].podcastEpisodeId == episodeId)

    let replacementConflict = try dao.recordConflict(
      accountId: accountId, identity: episodeIdentity, serverCurrentTime: 2,
      serverIsFinished: true, serverUpdatedAt: nil, detectedAt: detectedAt)
    try dao.resolveConflictTakingServer(conflictId: try #require(replacementConflict.id))
    let serverEpisode = try #require(
      try dao.fetchCurrent(accountId: accountId, identity: episodeIdentity))
    #expect(serverEpisode.currentTime == 2)
    #expect(serverEpisode.isFinished)
  }

  @Test func anEpisodePreservedPositionIsDetectedUsingEpisodeIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, mediaKind: "podcast")
    let episodeId = try await Self.insertEpisode(database, accountId: accountId, itemId: itemId)
    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    let dao = MediaProgressDAO(database: database)
    let identity = MediaProgressIdentity.episode(
      itemId: itemId, podcastEpisodeId: episodeId)

    let session = try sessionStore.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      podcastEpisodeId: episodeId, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try sessionStore.markSessionGone(
      sessionId: try #require(session.id), now: Date(timeIntervalSince1970: 1_700_000_020))

    #expect(try dao.hasUnacknowledgedLocalOperation(accountId: accountId, identity: identity))
    #expect(
      try dao.hasUnacknowledgedLocalOperation(
        accountId: accountId, identity: .item(itemId: itemId)) == false,
      "an episode operation must not block the show's independent item-level progress")
  }

  @Test func fetchOpenConflictsAsyncMatchesTheSyncTwin() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let first = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId)
    let second = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId)
    let dao = MediaProgressDAO(database: database)
    let detectedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let firstConflict = try await dao.recordConflictAsync(
      accountId: accountId, identity: .item(itemId: first.itemId), serverCurrentTime: 1,
      serverIsFinished: false, serverUpdatedAt: nil, detectedAt: detectedAt)
    let secondConflict = try await dao.recordConflictAsync(
      accountId: accountId, identity: .item(itemId: second.itemId), serverCurrentTime: 2,
      serverIsFinished: true, serverUpdatedAt: nil, detectedAt: detectedAt)

    let syncResult = try dao.fetchOpenConflicts(accountId: accountId)
    let asyncResult = try await dao.fetchOpenConflictsAsync(accountId: accountId)

    #expect(asyncResult == syncResult)
    #expect(asyncResult.count == 2)
    #expect(asyncResult.contains(firstConflict))
    #expect(asyncResult.contains(secondConflict))
  }

  @Test func fetchConflictAsyncMatchesTheSyncTwin() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId)
    let dao = MediaProgressDAO(database: database)
    let conflict = try await dao.recordConflictAsync(
      accountId: accountId, identity: .item(itemId: itemId), serverCurrentTime: 12,
      serverIsFinished: false, serverUpdatedAt: nil,
      detectedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let conflictId = try #require(conflict.id)

    let syncResult = try dao.fetchConflict(id: conflictId)
    let asyncResult = try await dao.fetchConflictAsync(id: conflictId)

    #expect(asyncResult == syncResult)
    #expect(asyncResult == conflict)
  }

  @Test func resolveConflictKeepingLocalAsyncMatchesTheSyncResolution() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, serverItemId) = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId)
    let dao = MediaProgressDAO(database: database)
    let identity = MediaProgressIdentity.item(itemId: itemId)
    _ = try await dao.applyServerResolutionAsync(
      accountId: accountId, identity: identity, currentTime: 120, isFinished: false,
      serverUpdatedAt: nil)
    let conflict = try await dao.recordConflictAsync(
      accountId: accountId, identity: identity, serverCurrentTime: 1,
      serverIsFinished: false, serverUpdatedAt: nil,
      detectedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let conflictId = try #require(conflict.id)

    try await dao.resolveConflictKeepingLocalAsync(
      conflictId: conflictId, entityKey: serverItemId)

    #expect(try await dao.fetchConflictAsync(id: conflictId) == nil)
    let local = try #require(await dao.fetchCurrentAsync(accountId: accountId, identity: identity))
    #expect(local.currentTime == 120)
    #expect(local.isFinished == false)
    let queued = try OutboxStore(database: database).fetchQueued(
      accountId: accountId, entityKey: serverItemId)
    #expect(queued.count == 1)
    #expect(queued.first?.operationKind == OutboxOperationKind.progress.rawValue)
    #expect(queued.first?.payloadCurrentTime == 120)
    #expect(queued.first?.payloadIsFinished == false)
  }

  @Test func resolveConflictTakingServerAsyncMatchesTheSyncResolution() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId)
    let dao = MediaProgressDAO(database: database)
    let identity = MediaProgressIdentity.item(itemId: itemId)
    _ = try await dao.applyServerResolutionAsync(
      accountId: accountId, identity: identity, currentTime: 120, isFinished: false,
      serverUpdatedAt: nil)
    let serverUpdatedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let conflict = try await dao.recordConflictAsync(
      accountId: accountId, identity: identity, serverCurrentTime: 12,
      serverIsFinished: true, serverUpdatedAt: serverUpdatedAt,
      detectedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let conflictId = try #require(conflict.id)

    try await dao.resolveConflictTakingServerAsync(conflictId: conflictId)

    #expect(try await dao.fetchConflictAsync(id: conflictId) == nil)
    let server = try #require(await dao.fetchCurrentAsync(accountId: accountId, identity: identity))
    #expect(server.currentTime == 12)
    #expect(server.isFinished)
    #expect(server.serverUpdatedAt == serverUpdatedAt)
    #expect(server.origin == .server)
    #expect(server.originKey == ProgressOrigin.serverOriginKey)
  }

  // MARK: - Batched pull application

  /// A library pull resolves `/api/me` progress for every item on a page. Applying each decision
  /// through its own `applyServerResolutionAsync`/`recordConflictAsync` call commits one
  /// transaction per item, and every commit re-runs every open `ValueObservation`, including the
  /// unbounded browse list. One page must cost one commit.
  @Test func appliesAWholePageOfPulledProgressInOneTransaction() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    var items = [(itemId: Int64, serverItemId: String)]()
    for _ in 0..<6 {
      items.append(try await Self.insertItem(database, accountId: accountId, libraryId: libraryId))
    }
    let dao = MediaProgressDAO(database: database)
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let detectedAt = Date(timeIntervalSince1970: 1_700_000_500)

    let resolutions = items.prefix(4).enumerated().map { index, item in
      MediaProgressDAO.PulledProgressResolution(
        identity: .item(itemId: item.itemId), currentTime: Double(index) * 10, isFinished: index == 3,
        serverUpdatedAt: updatedAt)
    }
    let conflicts = items.suffix(2).map { item in
      MediaProgressDAO.PulledProgressConflict(
        identity: .item(itemId: item.itemId), serverCurrentTime: 99, serverIsFinished: false,
        serverUpdatedAt: updatedAt, detectedAt: detectedAt)
    }

    let counter = CommitCounter()
    database.dbWriter.add(transactionObserver: counter, extent: .observerLifetime)

    try await dao.applyPulledProgressAsync(
      accountId: accountId, resolutions: resolutions, conflicts: conflicts)

    #expect(counter.count == 1, "a page's progress decisions must commit together, not one per item")

    let stored = try database.read { db in
      try MediaProgressRecord.filter(Column("accountId") == accountId).fetchAll(db)
    }
    #expect(stored.count == 4)
    #expect(stored.allSatisfy { $0.origin == .server })
    #expect(Set(stored.map(\.currentTime)) == [0, 10, 20, 30])
    #expect(stored.filter(\.isFinished).map(\.itemId) == [items[3].itemId])

    let openConflicts = try dao.fetchOpenConflicts(accountId: accountId)
    #expect(Set(openConflicts.map(\.itemId)) == Set(items.suffix(2).map(\.itemId)))
    #expect(openConflicts.allSatisfy { $0.serverCurrentTime == 99 && $0.detectedAt == detectedAt })
  }

  /// Nothing to apply must not open a transaction at all, as most pages carry no progress changes.
  @Test func applyingAnEmptyPageOfPulledProgressCommitsNothing() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, _) = try await Self.insertAccountAndLibrary(database)
    let dao = MediaProgressDAO(database: database)

    let counter = CommitCounter()
    database.dbWriter.add(transactionObserver: counter, extent: .observerLifetime)

    try await dao.applyPulledProgressAsync(accountId: accountId, resolutions: [], conflicts: [])

    #expect(counter.count == 0)
  }

  // MARK: - Ebook position dimension

  @Test func ebookPositionWritesDoNotTouchAudioPositionOrPulledLocation() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let identity = MediaProgressIdentity.item(itemId: itemId)
    let dao = MediaProgressDAO(database: database)

    _ = try await dao.applyServerEbookResolutionAsync(
      accountId: accountId, identity: identity, ebookProgress: 0.12,
      ebookLocation: "epubcfi(/6/4!/4/2/1:0)", serverUpdatedAt: nil)
    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: identity,
      field: .audio(currentTime: 321.25, isFinished: false), originKey: "device")
    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: identity,
      field: .ebook(readingPositionJSON: "{\"href\":\"chapter.xhtml\"}", ebookProgress: 0.42),
      originKey: "device")

    let stored = try #require(
      await dao.fetchCurrentAsync(accountId: accountId, identity: identity))
    #expect(stored.currentTime == 321.25)
    #expect(stored.isFinished == false)
    #expect(stored.readingPositionJSON == "{\"href\":\"chapter.xhtml\"}")
    #expect(stored.ebookProgress == 0.42)
    #expect(stored.ebookLocation == "epubcfi(/6/4!/4/2/1:0)")
  }

  @Test func audioPositionWritesDoNotTouchConcurrentEbookProgress() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let identity = MediaProgressIdentity.item(itemId: itemId)
    let dao = MediaProgressDAO(database: database)

    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: identity,
      field: .ebook(readingPositionJSON: "{\"href\":\"book.xhtml\"}", ebookProgress: 0.73),
      originKey: "device")
    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: identity,
      field: .audio(currentTime: 987.5, isFinished: true), originKey: "device")

    let stored = try #require(
      await dao.fetchCurrentAsync(accountId: accountId, identity: identity))
    #expect(stored.currentTime == 987.5)
    #expect(stored.isFinished)
    #expect(stored.readingPositionJSON == "{\"href\":\"book.xhtml\"}")
    #expect(stored.ebookProgress == 0.73)
  }

  @Test func ebookSafeFinishSetsSharedFinishedWithoutChangingCurrentTime() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let identity = MediaProgressIdentity.item(itemId: itemId)
    let dao = MediaProgressDAO(database: database)

    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: identity,
      field: .audio(currentTime: 456.75, isFinished: false), originKey: "device")
    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: identity,
      field: .ebook(readingPositionJSON: "{\"href\":\"end.xhtml\"}", ebookProgress: 1),
      originKey: "device")
    let before = try #require(
      await dao.fetchCurrentAsync(accountId: accountId, identity: identity))

    _ = try await dao.markEbookAsFinishedAsync(
      accountId: accountId, identity: identity, originKey: "device")

    let after = try #require(
      await dao.fetchCurrentAsync(accountId: accountId, identity: identity))
    #expect(before.currentTime == 456.75)
    #expect(after.currentTime == before.currentTime)
    #expect(after.isFinished)
    #expect(after.readingPositionJSON == before.readingPositionJSON)
    #expect(after.ebookProgress == before.ebookProgress)
  }

  @Test func ebookJSONAndServerLocationWritesAreBounded() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let identity = MediaProgressIdentity.item(itemId: itemId)
    let dao = MediaProgressDAO(database: database)

    await #expect(throws: MediaProgressDAOError.ebookPositionJSONTooLarge) {
      try await dao.writeLocalAsync(
        accountId: accountId, identity: identity,
        field: .ebook(
          readingPositionJSON: String(repeating: "x", count: MediaProgressDAO.maximumEbookJSONBytes + 1),
          ebookProgress: 0.1),
        originKey: "device")
    }
    await #expect(throws: MediaProgressDAOError.ebookLocationTooLarge) {
      try await dao.applyServerEbookResolutionAsync(
        accountId: accountId, identity: identity, ebookProgress: 0.1,
        ebookLocation: String(repeating: "x", count: MediaProgressDAO.maximumEbookStringBytes + 1),
        serverUpdatedAt: nil)
    }
  }

  @Test func localWinningEbookPositionKeepsItsReadingPositionJSON() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let identity = MediaProgressIdentity.item(itemId: itemId)
    let dao = MediaProgressDAO(database: database)

    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: identity,
      field: .ebook(readingPositionJSON: "{\"href\":\"chapter.xhtml\"}", ebookProgress: 0.42),
      originKey: "device")

    try await dao.applyServerCompositeResolutionAsync(
      accountId: accountId,
      identity: identity,
      currentTime: 321,
      isFinished: false,
      ebookProgress: 0.1,
      ebookLocation: nil,
      hideFromContinueListening: false,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
      resolution: .init(
        audioPosition: .keepLocal, ebookPosition: .keepLocal, sharedFinish: .keepLocal)
    )

    let stored = try #require(await dao.fetchCurrentAsync(accountId: accountId, identity: identity))
    #expect(stored.readingPositionJSON == "{\"href\":\"chapter.xhtml\"}")
    #expect(stored.ebookProgress == 0.42)
  }

  @Test func winningEbookPullClearsResumeTargetWithoutFabricatingALocator() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let identity = MediaProgressIdentity.item(itemId: itemId)
    let dao = MediaProgressDAO(database: database)

    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: identity,
      field: .ebook(readingPositionJSON: "{\"href\":\"local.xhtml\"}", ebookProgress: 0.42),
      originKey: "device")

    try await dao.applyServerCompositeResolutionAsync(
      accountId: accountId,
      identity: identity,
      currentTime: 321,
      isFinished: false,
      ebookProgress: 0.65,
      ebookLocation: nil,
      hideFromContinueListening: false,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
      resolution: .init(
        audioPosition: .keepLocal, ebookPosition: .applyServer, sharedFinish: .keepLocal)
    )

    let stored = try #require(await dao.fetchCurrentAsync(accountId: accountId, identity: identity))
    #expect(stored.readingPositionJSON == nil)
    #expect(stored.ebookProgress == 0.65)
    #expect(stored.ebookLocation == nil)
  }

  @Test func completeEbookProgressDoesNotInferTheSharedFinishedFlag() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let identity = MediaProgressIdentity.item(itemId: itemId)
    let dao = MediaProgressDAO(database: database)

    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: identity,
      field: .audio(currentTime: 321, isFinished: false), originKey: "device")

    try await dao.applyServerCompositeResolutionAsync(
      accountId: accountId,
      identity: identity,
      currentTime: 321,
      isFinished: false,
      ebookProgress: 1,
      ebookLocation: nil,
      hideFromContinueListening: false,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
      resolution: .init(
        audioPosition: .keepLocal, ebookPosition: .applyServer, sharedFinish: .applyServer)
    )

    let stored = try #require(await dao.fetchCurrentAsync(accountId: accountId, identity: identity))
    #expect(stored.ebookProgress == 1)
    #expect(stored.isFinished == false)
    #expect(stored.currentTime == 321)
  }

  @Test func compositeDifferentSidesApplyAtomically() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let identity = MediaProgressIdentity.item(itemId: itemId)
    let dao = MediaProgressDAO(database: database)

    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: identity,
      field: .audio(currentTime: 120, isFinished: false), originKey: "device")
    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: identity,
      field: .ebook(readingPositionJSON: "{\"href\":\"local.xhtml\"}", ebookProgress: 0.4),
      originKey: "device")

    let counter = CommitCounter()
    database.dbWriter.add(transactionObserver: counter, extent: .observerLifetime)

    try await dao.applyServerCompositeResolutionAsync(
      accountId: accountId,
      identity: identity,
      currentTime: 240,
      isFinished: true,
      ebookProgress: 0.8,
      ebookLocation: "epubcfi(/6/4!/4/2/1:0)",
      hideFromContinueListening: false,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
      resolution: .init(
        audioPosition: .applyServer, ebookPosition: .keepLocal, sharedFinish: .applyServer)
    )

    #expect(counter.count == 1)
    let stored = try #require(await dao.fetchCurrentAsync(accountId: accountId, identity: identity))
    #expect(stored.currentTime == 240)
    #expect(stored.isFinished)
    #expect(stored.ebookProgress == 0.4)
    #expect(stored.readingPositionJSON == "{\"href\":\"local.xhtml\"}")
  }

  @Test("a composite book pull applies the server Continue Listening visibility")
  func compositeBookPullAppliesVisibility() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let dao = MediaProgressDAO(database: database)

    try await dao.applyServerCompositeResolutionAsync(
      accountId: accountId,
      identity: .item(itemId: itemId),
      currentTime: 240,
      isFinished: false,
      ebookProgress: nil,
      ebookLocation: nil,
      hideFromContinueListening: true,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
      resolution: .init(
        audioPosition: .applyServer, ebookPosition: .keepLocal, sharedFinish: .keepLocal,
        continueListeningVisibility: .applyServer))

    let stored = try #require(
      await dao.fetchCurrentAsync(accountId: accountId, identity: .item(itemId: itemId)))
    #expect(stored.currentTime == 240)
    #expect(stored.hideFromContinueListening)
  }

  @Test("an unacknowledged visibility operation keeps the local book flag during a pull")
  func compositeBookPullKeepsVisibilityWithPendingLocalWrite() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, serverItemId) = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId)
    let dao = MediaProgressDAO(database: database)
    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: .item(itemId: itemId),
      field: .audio(currentTime: 120, isFinished: false), originKey: "device")
    try await database.writeAsync { db in
      try MediaProgressRecord
        .filter(Column("itemId") == itemId)
        .filter(Column("podcastEpisodeId") == nil)
        .updateAll(db, Column("hideFromContinueListening").set(to: true))
    }
    _ = try OutboxStore(database: database).enqueueContinueListeningVisibility(
      accountId: accountId, entityKey: serverItemId, podcastEpisodeId: nil,
      localSequence: 2, hideFromContinueListening: true)

    #expect(
      try dao.hasUnacknowledgedLocalOperation(
        accountId: accountId, identity: .item(itemId: itemId),
        field: .continueListeningVisibility))
    try await dao.applyServerCompositeResolutionAsync(
      accountId: accountId,
      identity: .item(itemId: itemId),
      currentTime: 240,
      isFinished: false,
      ebookProgress: nil,
      ebookLocation: nil,
      hideFromContinueListening: false,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
      resolution: .init(
        audioPosition: .applyServer, ebookPosition: .keepLocal, sharedFinish: .keepLocal,
        continueListeningVisibility: .keepLocal))

    let stored = try #require(
      await dao.fetchCurrentAsync(accountId: accountId, identity: .item(itemId: itemId)))
    #expect(stored.currentTime == 240)
    #expect(stored.hideFromContinueListening)
  }

  /// The batch entry point is the one the real library pull uses
  /// (`SyncEngine+LibraryPull`); the single-item tests above cannot catch a field it forgets to
  /// forward, because they pass every field themselves.
  @Test("the batched composite pull applies the server Continue Listening visibility")
  func batchedCompositePullAppliesVisibility() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let dao = MediaProgressDAO(database: database)

    try await dao.applyPulledCompositeProgressAsync(
      accountId: accountId,
      resolutions: [
        MediaProgressDAO.PulledCompositeResolution(
          identity: .item(itemId: itemId),
          currentTime: 240,
          isFinished: false,
          ebookProgress: nil,
          ebookLocation: nil,
          hideFromContinueListening: true,
          serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
          serverProgressId: nil,
          resolution: .init(
            audioPosition: .applyServer, ebookPosition: .keepLocal, sharedFinish: .keepLocal,
            continueListeningVisibility: .applyServer))
      ],
      conflicts: [])

    let stored = try #require(
      await dao.fetchCurrentAsync(accountId: accountId, identity: .item(itemId: itemId)))
    #expect(stored.currentTime == 240)
    #expect(stored.hideFromContinueListening)
  }

  /// The drain has already acknowledged the hide, so the pull legitimately reaches `.applyServer`
  /// and must then apply the value the server reported, not a defaulted `false`.
  @Test("a batched pull does not clear a locally-hidden book the server still reports as hidden")
  func batchedCompositePullKeepsAcknowledgedHide() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let dao = MediaProgressDAO(database: database)
    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: .item(itemId: itemId),
      field: .audio(currentTime: 120, isFinished: false), originKey: "device")
    try await database.writeAsync { db in
      try MediaProgressRecord
        .filter(Column("itemId") == itemId)
        .filter(Column("podcastEpisodeId") == nil)
        .updateAll(db, Column("hideFromContinueListening").set(to: true))
    }

    try await dao.applyPulledCompositeProgressAsync(
      accountId: accountId,
      resolutions: [
        MediaProgressDAO.PulledCompositeResolution(
          identity: .item(itemId: itemId),
          currentTime: 240,
          isFinished: false,
          ebookProgress: nil,
          ebookLocation: nil,
          hideFromContinueListening: true,
          serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
          serverProgressId: nil,
          resolution: .init(
            audioPosition: .applyServer, ebookPosition: .keepLocal, sharedFinish: .keepLocal,
            continueListeningVisibility: .applyServer))
      ],
      conflicts: [])

    let stored = try #require(
      await dao.fetchCurrentAsync(accountId: accountId, identity: .item(itemId: itemId)))
    #expect(stored.hideFromContinueListening)
  }

  /// The other direction: a genuine server unhide must still reach the local row.
  @Test("the batched composite pull applies a server unhide")
  func batchedCompositePullAppliesUnhide() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let dao = MediaProgressDAO(database: database)
    _ = try await dao.writeLocalAsync(
      accountId: accountId, identity: .item(itemId: itemId),
      field: .audio(currentTime: 120, isFinished: false), originKey: "device")
    try await database.writeAsync { db in
      try MediaProgressRecord
        .filter(Column("itemId") == itemId)
        .filter(Column("podcastEpisodeId") == nil)
        .updateAll(db, Column("hideFromContinueListening").set(to: true))
    }

    try await dao.applyPulledCompositeProgressAsync(
      accountId: accountId,
      resolutions: [
        MediaProgressDAO.PulledCompositeResolution(
          identity: .item(itemId: itemId),
          currentTime: 240,
          isFinished: false,
          ebookProgress: nil,
          ebookLocation: nil,
          hideFromContinueListening: false,
          serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
          serverProgressId: nil,
          resolution: .init(
            audioPosition: .applyServer, ebookPosition: .keepLocal, sharedFinish: .keepLocal,
            continueListeningVisibility: .applyServer))
      ],
      conflicts: [])

    let stored = try #require(
      await dao.fetchCurrentAsync(accountId: accountId, identity: .item(itemId: itemId)))
    #expect(stored.hideFromContinueListening == false)
  }

  // MARK: - Helpers

  private static func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)

      return (account.id!, library.id!)
    }
  }

  private static func insertItem(_ database: AppDatabase, accountId: Int64, libraryId: Int64) async throws -> (
    itemId: Int64, serverItemId: String
  ) {
    try await insertItem(
      database, accountId: accountId, libraryId: libraryId, mediaKind: "book")
  }

  private static func insertItem(
    _ database: AppDatabase, accountId: Int64, libraryId: Int64, mediaKind: String
  ) async throws -> (
    itemId: Int64, serverItemId: String
  ) {
    try await database.writeAsync { db in
      let serverItemId = "server-item-\(UUID().uuidString)"
      var item = PersistenceFixtures.item(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemId, mediaKind: mediaKind,
        title: "Title", sortTitle: "title")
      try item.insert(db)
      return (item.id!, serverItemId)
    }
  }

  private static func insertEpisode(
    _ database: AppDatabase, accountId: Int64, itemId: Int64
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = PersistenceFixtures.episode(
        accountId: accountId, itemId: itemId, serverEpisodeId: "episode-\(UUID().uuidString)",
        title: "Episode", lastSeenGeneration: 1)
      try episode.insert(db)
      return try #require(episode.id)
    }
  }
}

/// Counts committed write transactions on a `DatabaseWriter`, so a test can assert that a batched
/// API really batches rather than merely producing the same end state.
private final class CommitCounter: TransactionObserver, @unchecked Sendable {
  private let lock = NSLock()
  private var commits = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return commits
  }

  func observes(eventsOfKind kind: DatabaseEventKind) -> Bool { true }
  func databaseDidChange(with event: DatabaseEvent) {}
  func databaseDidRollback(_ db: Database) {}

  func databaseDidCommit(_ db: Database) {
    lock.lock()
    defer { lock.unlock() }
    commits += 1
  }
}
