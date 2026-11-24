import Foundation
import GRDB
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel
@testable import Persistence

/// The universal Up Next journey, end to end, over a real `v14 -> v15/v16` migration of an
/// on-disk store. The harness is a file-private environment owning the database and building the
/// composed models (each journey file seeds its own fixture graph).
///
/// Fakes only at the true boundaries: the player transport and `PlaybackSyncing`. The rest (queue
/// store and model, playback state machine, migration, account removal) is real, so the ordering
/// claims below ("the former session closes before the next start", "a failed preparation
/// consumes nothing") are about production code.
@MainActor
@Suite("Listening queue journey", .timeLimit(.minutes(1)))
struct ListeningQueueJourneyTests {

  @Test("a migrated podcast queue carries an audiobook, survives relaunch, and plays down to empty")
  func mixedQueueJourneyFromMigrationToAccountRemoval() async throws {
    let environment = try await ListeningQueueJourneyEnvironment()
    let episode1 = try environment.episode(1)
    let episode2 = try environment.episode(2)
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))

    // MARK: 1 - a real v14 -> v15 migration of two queued podcast episodes

    var harness = try environment.openIncarnation()
    #expect(
      await harness.store.fetchQueue().map(\.identity) == [
        episode1, episode2,
      ],
      "the pre-v15 podcastQueueEntry rows migrate across in their exact order")

    // MARK: 2 - start an audiobook, then append another between the two episodes

    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await harness.playback.start(itemID: "book-1")
    #expect(harness.playback.nowPlayingIdentity == book1)
    #expect(
      await harness.store.fetchQueue().count == 2,
      "starting an unqueued audiobook consumes nothing")

    await harness.queue.append(identity: book2)
    await harness.queue.move(rowID: try await harness.store.rowID(of: book2), to: 1)
    #expect(harness.queue.actionErrorMessage == nil)

    // MARK: 3 - relaunch: the identical mixed order

    environment.close(harness)
    harness = try environment.openIncarnation()
    let afterRelaunch = await harness.store.fetchQueue()
    #expect(
      afterRelaunch.map(\.identity) == [
        episode1, book2, episode2,
      ])
    #expect(afterRelaunch.map(\.position) == [0, 1, 2])
    #expect(afterRelaunch.map(\.category) == [.podcast, .audiobook, .podcast])

    // MARK: 4 - opening Up Next changes no navigation and leaves the player expanded

    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await harness.playback.start(itemID: "book-1")
    harness.navigation.enterShell()
    harness.navigation.navigate(to: .podcastShow(itemID: "show-1"))
    harness.navigation.expandPlayer()
    let destinationBeforeOpening = harness.navigation.current
    let playerPresentationBeforeOpening = harness.navigation.playerPresentation

    // Presenting the sheet is constructing this model (`RootModel.makeListeningQueueModel`) and
    // letting it observe; nothing in that path can see `NavigationModel` at all.
    let presented = ListeningQueueModel(reading: harness.store, storing: harness.store)
    await environment.waitForRows(presented, count: 3)
    #expect(harness.navigation.current == destinationBeforeOpening)
    #expect(harness.navigation.playerPresentation == playerPresentationBeforeOpening)
    #expect(harness.navigation.playerPresentation == .expanded)

    // MARK: 5 - reorder, remove, Clear, and Undo back to the exact prior order

    await presented.move(rowID: try presented.rowID(of: episode2), to: 0)
    await environment.waitForOrder(
      presented,
      [episode2, episode1, book2])

    await presented.remove(rowID: try presented.rowID(of: book2))
    await environment.waitForOrder(
      presented, [episode2, episode1])

    await presented.append(identity: book2)
    await environment.waitForOrder(
      presented,
      [episode2, episode1, book2])

    await presented.move(rowID: try presented.rowID(of: episode2), to: 2)
    await environment.waitForOrder(
      presented,
      [episode1, book2, episode2])
    let orderBeforeClear = presented.items.map(\.identity)

    await presented.clear()
    await environment.waitForOrder(presented, [])
    #expect(presented.canUndoClear)
    #expect(harness.playback.nowPlayingIdentity == book1)
    #expect(
      harness.sync.calls.contains(.stopSession) == false,
      "Clear never stops Now Playing")

    await presented.undoClear()
    await environment.waitForOrder(presented, orderBeforeClear)
    #expect(presented.canUndoClear == false, "a consumed offer is retired")
    #expect(presented.actionErrorMessage == nil)

    // MARK: 6 - tapping the first episode removes it only once preparation succeeded

    harness.sync.stubStartSession(
      .success(Self.prepared(itemID: "show-1", episodeID: "episode-1")))
    await harness.playback.start(itemID: "show-1", episodeID: "episode-1")
    #expect(harness.playback.startFailureMessage == nil)
    #expect(harness.playback.nowPlayingIdentity == episode1)
    await environment.waitForOrder(
      presented, [book2, episode2])

    // MARK: 7 - completion closes before the queued audiobook starts, and consumes it

    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    harness.player.pushProgress(Self.ended(itemID: "show-1", episodeID: "episode-1"))
    await environment.waitForLoaded(harness.playback, itemID: "book-2", episodeID: nil)
    await environment.waitForOrder(presented, [episode2])

    let stopIndex = try #require(harness.sync.calls.firstIndex(of: .stopSession))
    let nextStartIndex = try #require(
      harness.sync.calls.firstIndex(of: .startSession(itemID: "book-2", episodeID: nil)))
    #expect(stopIndex < nextStartIndex, "the former session closes before the next one starts")

    // MARK: 8 - a failed preparation of the next row consumes nothing and stays recoverable

    harness.sync.stubStartSession(.failure(ListeningQueueJourneyFailure.unreachable))
    harness.player.pushProgress(Self.ended(itemID: "book-2"))
    await waitUntil { harness.playback.startFailureMessage != nil }
    // The failed title remains the active player projection so its explanation and Retry remain
    // visible while the queue row stays in place.
    #expect(harness.playback.phase == .recoverableError)
    #expect(harness.playback.activeItemID == "show-1")
    #expect(harness.playback.activeEpisodeID == "episode-2")
    #expect(harness.playback.startFailureMessage == PlaybackCopy.genericStartFailure)
    #expect(
      await harness.store.fetchQueue().map(\.identity) == [episode2],
      "a failed start leaves the row exactly where it was, still first")

    // MARK: 9 - a soft-deleted row is skipped by completion and retained as a tombstone

    try await environment.setEpisodeSoftDeleted(true, episodeID: "episode-2", in: harness)
    await environment.waitForTombstone(presented, identity: episode2)

    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-3")))
    await harness.playback.start(itemID: "book-3")
    harness.player.pushProgress(Self.ended(itemID: "book-3"))
    await environment.waitForPhase(harness.playback, .idle)
    let afterSkip = await harness.store.fetchQueue()
    #expect(afterSkip.map(\.identity) == [episode2])
    #expect(afterSkip.map(\.isTombstone) == [true], "the skipped row keeps its tombstone")
    #expect(harness.playback.loadedItemID == nil, "nothing live is left to advance to")

    // MARK: 10 - removing the account takes the rows and the transient restore state with it

    #expect(try await environment.queueRowCount(harness) == 1)
    await presented.clear()
    #expect(presented.canUndoClear, "an Undo offer is outstanding at the moment of removal")
    #expect(try await environment.revisionRowCount(harness) == 1)

    try AccountRemover(database: harness.database).removeAccount(accountId: environment.accountId)

    #expect(try await environment.queueRowCount(harness) == 0)
    #expect(
      try await environment.revisionRowCount(harness) == 1,
      "the shared native revision survives removal and invalidates the old restore token")
    await presented.undoClear()
    #expect(presented.actionErrorMessage == ListeningQueueCopy.undoFailed)
    #expect(try await environment.queueRowCount(harness) == 0, "nothing comes back")
  }

  /// Account/logout replacement while the queue sheet is presented. The
  /// presented model observes account-owned rows; the account disappearing underneath it must
  /// re-emit an empty queue and turn further edits into one bounded message, never a crash or a
  /// stale list the user can still act on.
  @Test("an account removed while the queue is presented empties it and fails further edits")
  func accountRemovalWhilePresentedEmptiesTheQueue() async throws {
    let environment = try await ListeningQueueJourneyEnvironment()
    let harness = try environment.openIncarnation()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await harness.queue.append(identity: book1)
    await environment.waitForRows(harness.queue, count: 3)

    try AccountRemover(database: harness.database).removeAccount(accountId: environment.accountId)
    await environment.waitForOrder(harness.queue, [])
    #expect(harness.queue.state == .empty)

    await harness.queue.append(identity: book1)
    #expect(harness.queue.actionErrorMessage == ListeningQueueCopy.editFailed)
    #expect(harness.queue.items.isEmpty)
  }

  /// Tombstone revival while the sheet is open. Soft deletion is reversible, so a sheet that
  /// latched `isTombstone` once would keep telling the user an item is unavailable after sync
  /// brought it back.
  @Test("a revived tombstone becomes playable again in an open queue without any user action")
  func tombstoneRevivalReachesThePresentedQueue() async throws {
    let environment = try await ListeningQueueJourneyEnvironment()
    let harness = try environment.openIncarnation()
    let episode1 = try environment.episode(1)
    let episode2 = try environment.episode(2)
    await environment.waitForRows(harness.queue, count: 2)

    try await environment.setEpisodeSoftDeleted(true, episodeID: "episode-1", in: harness)
    await environment.waitForTombstone(harness.queue, identity: episode1)
    #expect(await harness.store.peekNextLive()?.identity == episode2)

    try await environment.setEpisodeSoftDeleted(false, episodeID: "episode-1", in: harness)
    await waitUntil { harness.queue.items.first?.isTombstone == false }
    #expect(harness.queue.items.map(\.identity) == [episode1, episode2])
    #expect(await harness.store.peekNextLive()?.identity == episode1)
  }

  /// Clear committed before restore-token publication (model half). If the clear never commits
  /// there is no token to publish, and offering an Undo that could only fail would be worse than
  /// offering none.
  @Test("a clear that fails publishes no undo offer at all")
  func failedClearPublishesNoUndoOffer() async {
    let store = FakeListeningQueueStoring()
    // A `clear()` that never commits, so no token can exist to publish.
    store.stubFailure(ListeningQueueJourneyFailure.unreachable)
    let model = ListeningQueueModel(storing: store)

    await model.clear()

    #expect(model.canUndoClear == false)
    #expect(model.actionErrorMessage == ListeningQueueCopy.editFailed)

    await model.undoClear()
    #expect(model.actionErrorMessage == ListeningQueueCopy.undoFailed)
    #expect(
      store.calls.contains(.restore) == false,
      "nothing is ever restored from an offer that never existed")
  }

  // MARK: - Fixtures

  private static func prepared(itemID: String, episodeID: String? = nil) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: episodeID, startPosition: 0, duration: 100,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 100,
          url: URL(string: "https://listening-queue-journey.example.test/audio.mp3")!,
          mimeType: "audio/mpeg", title: itemID)
      ],
      chapters: [])
  }

  private static func ended(itemID: String, episodeID: String? = nil) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: 1, itemId: itemID, episodeID: episodeID, phase: .ended, currentTime: 100,
      listenedDelta: 1)
  }
}

enum ListeningQueueJourneyFailure: Error { case unreachable }

// MARK: - Environment

/// One journey's on-disk store, seeded before `v15` exists and migrated forward for real by the
/// first incarnation. This is the shape of every device that already used the podcast-only queue.
private final class ListeningQueueJourneyEnvironment: @unchecked Sendable {
  let databaseURL: URL
  let accountId: Int64 = 1

  private let fixture: SuiteOnDiskDatabases

  init() async throws {
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "ListeningQueueJourneyTests")
    self.fixture = fixture
    databaseURL = fixture.scope.url()

    try await Self.seedPreV15Store(at: databaseURL)
  }

  func episode(_ number: Int) throws -> ListeningIdentity {
    try #require(
      ListeningIdentity.podcastEpisode(
        itemID: "show-1", episodeID: "episode-\(number)"))
  }

  struct Incarnation {
    let database: AppDatabase
    let store: ListeningQueueStore
    let queue: ListeningQueueModel
    let playback: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
    let navigation: NavigationModel
  }

  /// One "process lifetime": a fresh `AppDatabase` over the same file (which runs any migration
  /// not yet applied), a fresh store/model graph and a fresh playback state machine. This is the
  /// relaunch boundary the journey's step 3 cuts across.
  @MainActor
  func openIncarnation() throws -> Incarnation {
    let database = try fixture.scope.open(at: databaseURL, fileAttributes: InertFileAttributes())
    let store = ListeningQueueStore(database: database, accountId: accountId)
    let playback = PlaybackModelHarness(listeningQueue: store)
    return Incarnation(
      database: database,
      store: store,
      queue: ListeningQueueModel(reading: store, storing: store),
      playback: playback.model,
      player: playback.player,
      sync: playback.sync,
      navigation: NavigationModel())
  }

  func close(_ incarnation: Incarnation) {
    fixture.scope.close(incarnation.database)
  }

  // MARK: - Direct row access

  func queueRowCount(_ incarnation: Incarnation) async throws -> Int {
    try await incarnation.database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry") ?? -1
    }
  }

  func revisionRowCount(_ incarnation: Incarnation) async throws -> Int {
    try await incarnation.database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nativeListeningQueueRevision") ?? -1
    }
  }

  func setEpisodeSoftDeleted(
    _ softDeleted: Bool, episodeID: String, in incarnation: Incarnation
  ) async throws {
    try await incarnation.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = ? WHERE serverEpisodeId = ?",
        arguments: [softDeleted, episodeID])
    }
  }

  // MARK: - Waits

  /// A real on-disk `ValueObservation`-backed stream with no mutation hook to register a waiter
  /// against. The shared waiter owns the scheduler-aware bounded wait and turns a never-satisfied
  /// condition into a clean issue.
  @MainActor
  func waitForRows(_ model: ListeningQueueModel, count: Int) async {
    await waitUntil { model.items.count == count }
  }

  @MainActor
  func waitForOrder(_ model: ListeningQueueModel, _ identities: [ListeningIdentity]) async {
    await waitUntil { model.items.map(\.identity) == identities }
  }

  @MainActor
  func waitForTombstone(_ model: ListeningQueueModel, identity: ListeningIdentity) async {
    await waitUntil {
      model.items.first(where: { $0.identity == identity })?.isTombstone == true
    }
  }

  @MainActor
  func waitForLoaded(_ model: PlaybackModel, itemID: String, episodeID: String?) async {
    await waitUntil { model.loadedItemID == itemID && model.loadedEpisodeID == episodeID }
  }

  @MainActor
  func waitForPhase(_ model: PlaybackModel, _ phase: PlaybackModel.Phase) async {
    await waitUntil { model.phase == phase }
  }

  // MARK: - Pre-v15 seed

  /// Migrates a raw on-disk queue through every migration released before `v15`, seeds the
  /// account graph plus two `podcastQueueEntry` rows, and closes it, so the first `AppDatabase`
  /// opened over this file performs the real `v15`/`v16` migration.
  private static func seedPreV15Store(at url: URL) async throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(path: url.path, configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v14")
    try await queue.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO account (id, clientUUID, serverBaseURL, serverUserId, serverVersion)
          VALUES (1, 'journey-client', 'https://listening-queue-journey.example.test', 'user-1',
            '2.35.1')
          """)
      try db.execute(
        sql: """
          INSERT INTO library (id, accountId, serverLibraryId, mediaType, name, lastSeenGeneration)
          VALUES (1, 1, 'lib-1', 'book', 'Library', 1)
          """)
      try db.execute(
        sql: """
          INSERT INTO item (id, accountId, libraryId, serverItemId, mediaKind, title, sortTitle,
            lastSeenGeneration, softDeleted)
          VALUES (1, 1, 1, 'show-1', 'podcast', 'The Show', 'the show', 1, 0)
          """)
      for number in 1...3 {
        try db.execute(
          sql: """
            INSERT INTO item (id, accountId, libraryId, serverItemId, mediaKind, title, sortTitle,
              author, numAudioFiles, lastSeenGeneration, softDeleted)
            VALUES (?, 1, 1, ?, 'book', ?, ?, ?, 4, 1, 0)
            """,
          arguments: [
            number + 1, "book-\(number)", "Book \(number)", "book \(number)", "Author \(number)",
          ])
      }
      for number in 1...2 {
        try db.execute(
          sql: """
            INSERT INTO podcastEpisode (id, accountId, itemId, serverEpisodeId, title,
              lastSeenGeneration, softDeleted)
            VALUES (?, 1, 1, ?, ?, 1, 0)
            """,
          arguments: [number, "episode-\(number)", "Episode \(number)"])
      }
      try db.execute(
        sql: """
          INSERT INTO podcastQueueEntry (id, accountId, podcastEpisodeId, position)
          VALUES (10, 1, 1, 0), (20, 1, 2, 1)
          """)
    }
    try queue.close()
  }
}

extension DatabaseQueue {
  fileprivate func writeAsync<T: Sendable>(
    _ updates: @Sendable (Database) throws -> T
  ) async throws -> T {
    try await (self as any DatabaseWriter).write(updates)
  }
}

extension ListeningQueueStore {
  fileprivate func rowID(of identity: ListeningIdentity) async throws -> Int64 {
    try #require(await fetchQueue().first { $0.identity == identity }?.id)
  }
}

extension ListeningQueueModel {
  @MainActor
  fileprivate func rowID(of identity: ListeningIdentity) throws -> Int64 {
    try #require(items.first { $0.identity == identity }?.id)
  }
}
