import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Records every resolution the store asks for, so the funnel itself can be asserted rather than
/// only its effect. A writer that bypassed `commit` would still delete the right shelf row under
/// the local resolver and look correct; it would silently stop reaching the cloud outbox once one
/// is attached. These tests fail in that case.
private struct RecordingSavedIntentResolver: NativeSavedIntentResolving {
  struct Resolution: Equatable {
    let accepted: RSSEpisodeStateRecord
    let previous: RSSEpisodeStateRecord?
  }

  let resolutions = Locked<[Resolution]>([])

  func resolveNativeSavedIntent(
    in db: Database, acceptedState: RSSEpisodeStateRecord, previousState: RSSEpisodeStateRecord?
  ) throws {
    resolutions.withValue { $0.append(Resolution(accepted: acceptedState, previous: previousState)) }
  }
}

@Suite struct NativeSavedIntentResolutionTests {

  // MARK: - The predicate

  /// Each case is transposed from the v60 trigger `WHEN` clauses this replaces. The insert cases
  /// are the `_ai` trigger; the rest are `_au`.
  @Test(arguments: [
    // (previous, accepted position, accepted finished, qualifies)
    (nil as (Double, Bool)?, 12.0, false, true),
    (nil, 0.0, true, true),
    (nil, 0.0, false, false),
    ((10.0, false), 20.0, false, true),
    ((10.0, false), 10.0, false, false),
    ((10.0, false), 10.0, true, true),
    ((10.0, true), 10.0, true, false),
    ((10.0, true), 0.0, false, false),
    ((0.0, false), 0.0, true, true),
  ])
  func removalPredicateMatchesTheRetiredTriggers(
    previous: (Double, Bool)?, position: Double, finished: Bool, qualifies: Bool
  ) {
    let previousState = previous.map {
      RSSEpisodeStateRecord(
        episodeId: 1, position: $0.0, finished: $0.1, localSequence: 1,
        updatedAt: Date(timeIntervalSince1970: 0))
    }
    let accepted = RSSEpisodeStateRecord(
      episodeId: 1, position: position, finished: finished, localSequence: 2,
      updatedAt: Date(timeIntervalSince1970: 1))

    #expect(
      NativeSavedIntent.removalQualifies(acceptedState: accepted, previousState: previousState)
        == qualifies)
  }

  /// A dismissal write carries the stored position and finish forward unchanged, so it can never
  /// qualify. The `_au` trigger fired for it (GRDB's `update` names every column) and was then
  /// rejected by its own `WHEN` clause. Here it is not a candidate at all.
  @Test func dismissalNeverQualifies() {
    let stored = RSSEpisodeStateRecord(
      episodeId: 1, position: 42, finished: false, hideFromContinueListening: false,
      localSequence: 1, updatedAt: Date(timeIntervalSince1970: 0))
    var dismissed = stored
    dismissed.hideFromContinueListening = true
    dismissed.localSequence = 2

    #expect(
      NativeSavedIntent.removalQualifies(acceptedState: dismissed, previousState: stored) == false)
  }

  // MARK: - The retired triggers

  @Test func theRSSResolutionTriggersAreGoneAndTheAccountOnesRemain() async throws {
    let database = try AppDatabase.inMemory()
    let triggers = try await database.readAsync { db in
      try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"))
    }

    #expect(triggers.contains("savedShelfRSSProgress_ai") == false)
    #expect(triggers.contains("savedShelfRSSProgress_au") == false)
    // ABS progress is server-owned; its shelf resolution stays in SQL.
    #expect(triggers.contains("savedShelfProgress_ai"))
    #expect(triggers.contains("savedShelfProgress_au"))
  }

  // MARK: - Behaviour through the store

  @Test func aProgressTickRemovesTheSavedEntry() async throws {
    let (database, episodeId, _) = try await seedSavedEpisode()
    let store = RSSEpisodeStateStore(database: database)

    _ = try await store.recordTick(
      episodeId: episodeId, position: 30, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))

    #expect(try await savedCount(database) == 0)
  }

  @Test func finishingAtAnUntouchedPositionRemovesTheSavedEntry() async throws {
    let (database, episodeId, _) = try await seedSavedEpisode()
    let store = RSSEpisodeStateStore(database: database)

    _ = try await store.setFinished(
      episodeId: episodeId, finished: true, now: Date(timeIntervalSince1970: 100))

    #expect(try await savedCount(database) == 0)
  }

  /// v56's rule: a repeated finish is not a new decision, so it must not overturn a save the
  /// listener made after finishing the episode.
  @Test func aRepeatedFinishPreservesALaterReSave() async throws {
    let (database, episodeId, _) = try await seedSavedEpisode()
    let store = RSSEpisodeStateStore(database: database)
    _ = try await store.setFinished(
      episodeId: episodeId, finished: true, now: Date(timeIntervalSince1970: 100))
    #expect(try await savedCount(database) == 0)
    try await save(episodeId: episodeId, in: database)

    _ = try await store.setFinished(
      episodeId: episodeId, finished: true, now: Date(timeIntervalSince1970: 200))

    #expect(try await savedCount(database) == 1)
  }

  @Test func dismissingFromContinueListeningKeepsTheSavedEntry() async throws {
    let (database, episodeId, _) = try await seedSavedEpisode()
    let store = RSSEpisodeStateStore(database: database)

    _ = try await store.setHiddenFromContinueListening(
      episodeId: episodeId, isHidden: true, now: Date(timeIntervalSince1970: 100))

    #expect(try await savedCount(database) == 1)
  }

  @Test func aSuppressedNearZeroTickResolvesNothing() async throws {
    let (database, episodeId, _) = try await seedSavedEpisode(duration: 3_600)
    let resolver = RecordingSavedIntentResolver()
    let store = RSSEpisodeStateStore(database: database, savedIntent: resolver)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 600, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    resolver.resolutions.withValue { $0.removeAll() }

    let outcome = try await store.recordTick(
      episodeId: episodeId, position: 1, finished: false, capturedSequence: 1,
      now: Date(timeIntervalSince1970: 200))

    #expect(outcome == .suppressedNearZeroReset(retainedPosition: 600))
    // Nothing was written, so there is no accepted mutation to resolve and, once sync is
    // attached, nothing to send.
    #expect(resolver.resolutions.withValue { $0.isEmpty })
  }

  @Test func aRejectedStaleTickResolvesNothing() async throws {
    let (database, episodeId, _) = try await seedSavedEpisode()
    let resolver = RecordingSavedIntentResolver()
    let store = RSSEpisodeStateStore(database: database, savedIntent: resolver)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 10, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    _ = try await store.recordTick(
      episodeId: episodeId, position: 20, finished: false, capturedSequence: 1,
      now: Date(timeIntervalSince1970: 200))
    resolver.resolutions.withValue { $0.removeAll() }

    await #expect(throws: RSSEpisodeStateStoreError.staleLocalSequence(captured: 1, current: 2)) {
      try await store.recordTick(
        episodeId: episodeId, position: 5, finished: false, capturedSequence: 1,
        now: Date(timeIntervalSince1970: 300))
    }

    #expect(resolver.resolutions.withValue { $0.isEmpty })
  }

  // MARK: - Every writer reaches the seam

  @Test func everyStateWriterResolvesExactlyOnceWithTheAcceptedAndPreviousRow() async throws {
    let (database, episodeId, secondEpisodeId) = try await seedSavedEpisode()
    let resolver = RecordingSavedIntentResolver()
    let store = RSSEpisodeStateStore(database: database, savedIntent: resolver)

    func resolutionsOfLastWrite() -> [RecordingSavedIntentResolver.Resolution] {
      resolver.resolutions.withValue {
        let taken = $0
        $0.removeAll()
        return taken
      }
    }

    _ = try await store.recordTick(
      episodeId: episodeId, position: 10, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    var seen = resolutionsOfLastWrite()
    #expect(seen.count == 1)
    #expect(seen.first?.previous == nil)
    #expect(seen.first?.accepted.position == 10)

    _ = try await store.setFinished(
      episodeId: episodeId, finished: true, now: Date(timeIntervalSince1970: 200))
    seen = resolutionsOfLastWrite()
    #expect(seen.count == 1)
    #expect(seen.first?.previous?.finished == false)
    #expect(seen.first?.accepted.finished == true)

    _ = try await store.resetProgress(episodeId: episodeId, now: Date(timeIntervalSince1970: 300))
    seen = resolutionsOfLastWrite()
    #expect(seen.count == 1)
    #expect(seen.first?.previous?.finished == true)
    #expect(seen.first?.accepted.position == 0)

    _ = try await store.setHiddenFromContinueListening(
      episodeId: episodeId, isHidden: true, now: Date(timeIntervalSince1970: 400))
    seen = resolutionsOfLastWrite()
    #expect(seen.count == 1)
    #expect(seen.first?.accepted.hideFromContinueListening == true)

    // The batch writer is one transaction over many episodes, so it must resolve once per episode
    // rather than once per call.
    try await store.setFinished(
      episodeIds: [episodeId, secondEpisodeId], finished: true,
      now: Date(timeIntervalSince1970: 500))
    seen = resolutionsOfLastWrite()
    #expect(seen.count == 2)
    #expect(seen.map(\.accepted.episodeId).sorted() == [episodeId, secondEpisodeId].sorted())
    #expect(seen.allSatisfy { $0.accepted.finished })
  }

  /// The resolution runs inside the caller's transaction, so its failure must take the state write
  /// with it. Otherwise a crash-equivalent leaves state committed that no outbox row describes.
  @Test func aFailedResolutionRollsBackTheStateWrite() async throws {
    struct Refusing: NativeSavedIntentResolving {
      struct Failure: Error, Equatable {}
      func resolveNativeSavedIntent(
        in db: Database, acceptedState: RSSEpisodeStateRecord, previousState: RSSEpisodeStateRecord?
      ) throws { throw Failure() }
    }

    let (database, episodeId, _) = try await seedSavedEpisode()
    let store = RSSEpisodeStateStore(database: database, savedIntent: Refusing())

    await #expect(throws: Refusing.Failure()) {
      try await store.recordTick(
        episodeId: episodeId, position: 30, finished: false, capturedSequence: 0,
        now: Date(timeIntervalSince1970: 100))
    }

    #expect(try await RSSEpisodeStateStore(database: database).fetchState(episodeId: episodeId) == nil)
    #expect(try await savedCount(database) == 1)
  }

  // MARK: - Fixtures

  private func savedCount(_ database: AppDatabase) async throws -> Int {
    try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssSavedShelfEntry") ?? -1
    }
  }

  private func save(episodeId: Int64, in database: AppDatabase) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO rssSavedShelfEntry (rssEpisodeId, savedAt, subjectTitle, contextTitle)
          VALUES (?, ?, 'Episode', 'Feed')
          """, arguments: [episodeId, Date(timeIntervalSince1970: 150)])
    }
  }

  /// Two episodes, the first already on the Saved shelf.
  private func seedSavedEpisode(duration: Double? = nil) async throws -> (AppDatabase, Int64, Int64) {
    let database = try AppDatabase.inMemory()
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/feed.xml")!, title: "Feed", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date(timeIntervalSince1970: 1))
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:one", enclosureURL: URL(string: "https://example.com/1.mp3")!,
          durationSeconds: duration),
        RSSEpisodeUpsert(
          identityKey: "guid:two", enclosureURL: URL(string: "https://example.com/2.mp3")!,
          durationSeconds: duration),
      ])
    let ids = try await database.readAsync { db in
      try Int64.fetchAll(
        db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? ORDER BY identityKey",
        arguments: [feedId])
    }
    try #require(ids.count == 2)
    try await save(episodeId: ids[0], in: database)
    return (database, ids[0], ids[1])
  }
}
