import Foundation
import Testing

@testable import Persistence

@Suite struct RSSEpisodeStateStoreTests {
  @Test func firstTickCreatesTheRow() async throws {
    let (database, episodeId) = try await seedEpisode(duration: nil)
    let now = Date(timeIntervalSince1970: 100)
    let outcome = try await RSSEpisodeStateStore(database: database).recordTick(
      episodeId: episodeId, position: 12.5, finished: false, capturedSequence: 99, now: now)

    #expect(outcome == .applied(localSequence: 1))
    #expect(
      try await RSSEpisodeStateStore(database: database).fetchState(episodeId: episodeId)
        == RSSEpisodeStateRecord(
          episodeId: episodeId, position: 12.5, finished: false, localSequence: 1, updatedAt: now))
  }

  @Test func ticksAdvanceTheSequence() async throws {
    let (database, episodeId) = try await seedEpisode(duration: nil)
    let store = RSSEpisodeStateStore(database: database)
    let first = try await store.recordTick(
      episodeId: episodeId, position: 10, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    let second = try await store.recordTick(
      episodeId: episodeId, position: 20, finished: false, capturedSequence: 1,
      now: Date(timeIntervalSince1970: 200))

    #expect(first == .applied(localSequence: 1))
    #expect(second == .applied(localSequence: 2))
    #expect(try await store.fetchState(episodeId: episodeId)?.position == 20)
    #expect(try await store.fetchState(episodeId: episodeId)?.localSequence == 2)
  }

  @Test func everyRSSStateMutationLeavesTheABSOutboxEmpty() async throws {
    let (database, episodeId) = try await seedEpisode(duration: nil)
    let store = RSSEpisodeStateStore(database: database)

    func outboxCount() throws -> Int {
      try database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outboxOperation") ?? -1
      }
    }

    _ = try await store.recordTick(
      episodeId: episodeId, position: 10, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    #expect(try outboxCount() == 0)

    _ = try await store.setFinished(
      episodeId: episodeId, finished: true, now: Date(timeIntervalSince1970: 200))
    #expect(try outboxCount() == 0)

    _ = try await store.resetProgress(
      episodeId: episodeId, now: Date(timeIntervalSince1970: 300))
    #expect(try outboxCount() == 0)
  }

  @Test func staleTickIsRejectedWithoutChangingTheRow() async throws {
    let (database, episodeId) = try await seedEpisode(duration: nil)
    let store = RSSEpisodeStateStore(database: database)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 10, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    _ = try await store.setFinished(episodeId: episodeId, finished: true, now: Date(timeIntervalSince1970: 200))
    let before = try #require(try await store.fetchState(episodeId: episodeId))

    await #expect(throws: RSSEpisodeStateStoreError.staleLocalSequence(captured: 1, current: 2)) {
      try await store.recordTick(
        episodeId: episodeId, position: 1, finished: false, capturedSequence: 1,
        now: Date(timeIntervalSince1970: 300))
    }
    #expect(try await store.fetchState(episodeId: episodeId) == before)
  }

  @Test func unknownEpisodeIsRejectedByEveryMutation() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSEpisodeStateStore(database: database)
    await #expect(throws: RSSEpisodeStateStoreError.episodeNotFound) {
      try await store.recordTick(
        episodeId: 999, position: 1, finished: false, capturedSequence: 0,
        now: Date(timeIntervalSince1970: 100))
    }
    await #expect(throws: RSSEpisodeStateStoreError.episodeNotFound) {
      try await store.setFinished(episodeId: 999, finished: true, now: Date(timeIntervalSince1970: 100))
    }
    await #expect(throws: RSSEpisodeStateStoreError.episodeNotFound) {
      try await store.resetProgress(episodeId: 999, now: Date(timeIntervalSince1970: 100))
    }
    #expect(try await store.fetchState(episodeId: 999) == nil)
  }

  @Test func nearZeroGuardRetainsSubstantialUnknownDurationProgress() async throws {
    let (database, episodeId) = try await seedEpisode(duration: nil)
    let store = RSSEpisodeStateStore(database: database)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 300, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    let before = try #require(try await store.fetchState(episodeId: episodeId))
    let outcome = try await store.recordTick(
      episodeId: episodeId, position: 2, finished: true, capturedSequence: 1,
      now: Date(timeIntervalSince1970: 200))

    #expect(outcome == .suppressedNearZeroReset(retainedPosition: 300))
    #expect(try await store.fetchState(episodeId: episodeId) == before)
  }

  @Test func nearZeroGuardRespectsDurationFraction() async throws {
    let (database, episodeId) = try await seedEpisode(duration: 10_000)
    let store = RSSEpisodeStateStore(database: database)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 90, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    let outcome = try await store.recordTick(
      episodeId: episodeId, position: 2, finished: false, capturedSequence: 1,
      now: Date(timeIntervalSince1970: 200))

    #expect(outcome == .applied(localSequence: 2))
  }

  @Test func nearZeroGuardUsesMeasuredDurationWhenDeclaredDurationIsMissing() async throws {
    let (largeDatabase, largeEpisodeId) = try await seedEpisode(duration: nil)
    try await RSSEpisodeStore(database: largeDatabase).recordMeasuredDuration(
      episodeId: largeEpisodeId, seconds: 10_000)
    let largeStateStore = RSSEpisodeStateStore(database: largeDatabase)
    _ = try await largeStateStore.recordTick(
      episodeId: largeEpisodeId, position: 3_000, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    let suppressed = try await largeStateStore.recordTick(
      episodeId: largeEpisodeId, position: 2, finished: false, capturedSequence: 1,
      now: Date(timeIntervalSince1970: 200))

    #expect(suppressed == .suppressedNearZeroReset(retainedPosition: 3_000))

    let (smallDatabase, smallEpisodeId) = try await seedEpisode(duration: nil)
    try await RSSEpisodeStore(database: smallDatabase).recordMeasuredDuration(
      episodeId: smallEpisodeId, seconds: 10_000)
    let smallStateStore = RSSEpisodeStateStore(database: smallDatabase)
    _ = try await smallStateStore.recordTick(
      episodeId: smallEpisodeId, position: 100, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    let applied = try await smallStateStore.recordTick(
      episodeId: smallEpisodeId, position: 2, finished: false, capturedSequence: 1,
      now: Date(timeIntervalSince1970: 200))

    #expect(applied == .applied(localSequence: 2))
    #expect(try await smallStateStore.fetchState(episodeId: smallEpisodeId)?.position == 2)
  }

  /// The guard weighs the stored position as a fraction of the length it was measured on, which
  /// for a download is the file's. 150 s is 3% of a 5_000 s file but 1.5% of a 10_000 s feed.
  @Test func nearZeroGuardUsesTheDownloadedFilesLength() async throws {
    let (database, episodeId) = try await seedEpisode(duration: 10_000)
    try await RSSDownloadDurationStoreTests.downloadAndMeasure(
      database, episodeID: episodeId, seconds: 5_000)
    let store = RSSEpisodeStateStore(database: database)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 150, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))

    let outcome = try await store.recordTick(
      episodeId: episodeId, position: 2, finished: false, capturedSequence: 1,
      now: Date(timeIntervalSince1970: 200))

    #expect(outcome == .suppressedNearZeroReset(retainedPosition: 150))
  }

  @Test func nearZeroGuardNeedsSubstantialAbsoluteProgress() async throws {
    let (database, episodeId) = try await seedEpisode(duration: nil)
    let store = RSSEpisodeStateStore(database: database)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 30, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    let outcome = try await store.recordTick(
      episodeId: episodeId, position: 2, finished: false, capturedSequence: 1,
      now: Date(timeIntervalSince1970: 200))

    #expect(outcome == .applied(localSequence: 2))
  }

  @Test func positionsAboveTheCeilingAlwaysApply() async throws {
    let (database, episodeId) = try await seedEpisode(duration: nil)
    let store = RSSEpisodeStateStore(database: database)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 300, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    let outcome = try await store.recordTick(
      episodeId: episodeId, position: 6, finished: false, capturedSequence: 1,
      now: Date(timeIntervalSince1970: 200))

    #expect(outcome == .applied(localSequence: 2))
    #expect(try await store.fetchState(episodeId: episodeId)?.position == 6)
  }

  @Test func explicitResetsAndFinishIntentsWin() async throws {
    let (database, episodeId) = try await seedEpisode(duration: nil)
    let store = RSSEpisodeStateStore(database: database)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 300, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    #expect(try await store.resetProgress(episodeId: episodeId, now: Date(timeIntervalSince1970: 200)) == 2)
    #expect(try await store.fetchState(episodeId: episodeId)?.position == 0)
    #expect(try await store.fetchState(episodeId: episodeId)?.finished == false)
    #expect(
      try await store.setFinished(episodeId: episodeId, finished: false, now: Date(timeIntervalSince1970: 300)) == 3)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 300, finished: false, capturedSequence: 3,
      now: Date(timeIntervalSince1970: 400))
    #expect(
      try await store.setFinished(episodeId: episodeId, finished: true, now: Date(timeIntervalSince1970: 500)) == 5)
    #expect(try await store.fetchState(episodeId: episodeId)?.position == 300)
    #expect(try await store.fetchState(episodeId: episodeId)?.finished == true)
    #expect(
      try await store.setFinished(episodeId: episodeId, finished: false, now: Date(timeIntervalSince1970: 600)) == 6)
    #expect(try await store.fetchState(episodeId: episodeId)?.position == 0)
    #expect(try await store.fetchState(episodeId: episodeId)?.finished == false)
  }

  @Test func tickPredatingExplicitResetIsStale() async throws {
    let (database, episodeId) = try await seedEpisode(duration: nil)
    let store = RSSEpisodeStateStore(database: database)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 300, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    _ = try await store.resetProgress(episodeId: episodeId, now: Date(timeIntervalSince1970: 200))

    await #expect(throws: RSSEpisodeStateStoreError.staleLocalSequence(captured: 1, current: 2)) {
      try await store.recordTick(
        episodeId: episodeId, position: 1, finished: false, capturedSequence: 1,
        now: Date(timeIntervalSince1970: 300))
    }
  }

  @Test func deletingTheFeedCascadesState() async throws {
    let (database, episodeId, feedId) = try await seedEpisodeWithFeed(duration: nil)
    let stateStore = RSSEpisodeStateStore(database: database)
    _ = try await stateStore.recordTick(
      episodeId: episodeId, position: 20, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    try await RSSFeedStore(database: database).unsubscribe(feedId: feedId)

    #expect(try await stateStore.fetchState(episodeId: episodeId) == nil)
  }

  @Test func nearZeroGuardDoesNotApplyOnRowCreation() async throws {
    let (database, episodeId) = try await seedEpisode(duration: nil)
    let now = Date(timeIntervalSince1970: 100)
    let outcome = try await RSSEpisodeStateStore(database: database).recordTick(
      episodeId: episodeId, position: 0, finished: false, capturedSequence: 42, now: now)

    #expect(outcome == .applied(localSequence: 1))
    #expect(try await RSSEpisodeStateStore(database: database).fetchState(episodeId: episodeId)?.updatedAt == now)
  }

  @Test func bulkFinishAppliesToEveryEpisodeInOneTransaction() async throws {
    let (database, firstEpisodeId, feedId) = try await seedEpisodeWithFeed(duration: 600)
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:episode", enclosureURL: URL(string: "https://example.com/e.mp3")!,
          durationSeconds: 600),
        RSSEpisodeUpsert(
          identityKey: "guid:episode-2", enclosureURL: URL(string: "https://example.com/e2.mp3")!,
          durationSeconds: 600),
      ])
    let secondEpisodeId = try #require(
      try await database.readAsync { db in
        try Int64.fetchOne(
          db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
          arguments: [feedId, "guid:episode-2"])
      })
    let store = RSSEpisodeStateStore(database: database)

    try await store.setFinished(
      episodeIds: [firstEpisodeId, secondEpisodeId], finished: true,
      now: Date(timeIntervalSince1970: 100))

    #expect(try await store.fetchState(episodeId: firstEpisodeId)?.finished == true)
    #expect(try await store.fetchState(episodeId: secondEpisodeId)?.finished == true)
  }

  /// The whole point of the bulk write: one unknown row must not leave the show half-marked.
  @Test func bulkFinishWritesNothingWhenAnyEpisodeIsUnknown() async throws {
    let (database, episodeId) = try await seedEpisode(duration: 600)
    let store = RSSEpisodeStateStore(database: database)

    await #expect(throws: RSSEpisodeStateStoreError.episodeNotFound) {
      try await store.setFinished(
        episodeIds: [episodeId, 999], finished: true, now: Date(timeIntervalSince1970: 100))
    }

    #expect(try await store.fetchState(episodeId: episodeId) == nil)
  }

  @Test func dismissalIsRecordedWithoutDisturbingProgress() async throws {
    let (database, episodeId) = try await seedEpisode(duration: 600)
    let store = RSSEpisodeStateStore(database: database)
    _ = try await store.recordTick(
      episodeId: episodeId, position: 120, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))

    let sequence = try await store.setHiddenFromContinueListening(
      episodeId: episodeId, isHidden: true, now: Date(timeIntervalSince1970: 200))

    let state = try #require(try await store.fetchState(episodeId: episodeId))
    #expect(sequence == 2)
    #expect(state.hideFromContinueListening)
    #expect(state.position == 120)
    #expect(state.finished == false)
  }

  /// The dismissal's undo. Resuming the episode is the only gesture that restores it, so every
  /// write that means "the listener touched this again" has to clear the flag.
  @Test func everyProgressWriteClearsTheDismissal() async throws {
    let (database, episodeId) = try await seedEpisode(duration: 600)
    let store = RSSEpisodeStateStore(database: database)

    func hideThenRun(
      _ body: () async throws -> Void
    ) async throws -> Bool {
      _ = try await store.setHiddenFromContinueListening(
        episodeId: episodeId, isHidden: true, now: Date(timeIntervalSince1970: 200))
      #expect(try await store.fetchState(episodeId: episodeId)?.hideFromContinueListening == true)
      try await body()
      return try #require(try await store.fetchState(episodeId: episodeId))
        .hideFromContinueListening
    }

    #expect(
      try await hideThenRun {
        _ = try await store.recordTick(
          episodeId: episodeId, position: 130, finished: false,
          capturedSequence: .max, now: Date(timeIntervalSince1970: 300))
      } == false)
    #expect(
      try await hideThenRun {
        _ = try await store.setFinished(
          episodeId: episodeId, finished: true, now: Date(timeIntervalSince1970: 400))
      } == false)
    #expect(
      try await hideThenRun {
        _ = try await store.resetProgress(
          episodeId: episodeId, now: Date(timeIntervalSince1970: 500))
      } == false)
    #expect(
      try await hideThenRun {
        try await store.setFinished(
          episodeIds: [episodeId], finished: true, now: Date(timeIntervalSince1970: 600))
      } == false)
  }

  @Test func dismissingAnEpisodeWithNoStateRowCreatesOne() async throws {
    let (database, episodeId) = try await seedEpisode(duration: 600)
    let store = RSSEpisodeStateStore(database: database)

    _ = try await store.setHiddenFromContinueListening(
      episodeId: episodeId, isHidden: true, now: Date(timeIntervalSince1970: 100))

    let state = try #require(try await store.fetchState(episodeId: episodeId))
    #expect(state.hideFromContinueListening)
    #expect(state.position == 0)
    #expect(state.localSequence == 1)
  }

  @Test func dismissingAnUnknownEpisodeFails() async throws {
    let (database, _) = try await seedEpisode(duration: 600)
    let store = RSSEpisodeStateStore(database: database)

    await #expect(throws: RSSEpisodeStateStoreError.episodeNotFound) {
      try await store.setHiddenFromContinueListening(
        episodeId: 999, isHidden: false, now: Date(timeIntervalSince1970: 100))
    }
  }

  @Test func dismissalWritesNoABSOutboxOperation() async throws {
    let (database, episodeId) = try await seedEpisode(duration: 600)

    _ = try await RSSEpisodeStateStore(database: database).setHiddenFromContinueListening(
      episodeId: episodeId, isHidden: true, now: Date(timeIntervalSince1970: 100))

    #expect(
      try database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outboxOperation")
      } == 0)
  }

  private func seedEpisode(duration: Double?) async throws -> (AppDatabase, Int64) {
    let (database, episodeId, _) = try await seedEpisodeWithFeed(duration: duration)
    return (database, episodeId)
  }

  private func seedEpisodeWithFeed(duration: Double?) async throws -> (AppDatabase, Int64, Int64) {
    let database = try AppDatabase.inMemory()
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/feed.xml")!, title: "Feed", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date(timeIntervalSince1970: 1))
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:episode", enclosureURL: URL(string: "https://example.com/e.mp3")!,
          durationSeconds: duration)
      ])
    let episodeId = try #require(
      try await database.readAsync { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM rssEpisode WHERE feedId = ?", arguments: [feedId])
      })
    return (database, episodeId, feedId)
  }
}
