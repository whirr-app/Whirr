import Foundation
import GRDB
import Testing

@testable import Persistence

/// A Watch listen is applied as a listen on this phone: the rule's cases, then the
/// same-writer consequences through `RSSEpisodeStateStore`.
@Suite struct RSSEpisodePeerListenTests {

  private static let base = Date(timeIntervalSince1970: 1_700_000_000)

  private static func at(_ offset: TimeInterval) -> Date {
    base.addingTimeInterval(offset)
  }

  // MARK: - The rule

  struct Case: Sendable {
    let name: String
    let position: Double
    let finished: Bool
    let listenedAt: Date
    let phone: (position: Double, finished: Bool, updatedAt: Date)?
    let duration: Double?
    let expected: RSSEpisodePeerListen.Outcome

    init(
      _ name: String, position: Double, finished: Bool = false, listenedAt: Date,
      phone: (position: Double, finished: Bool, updatedAt: Date)? = nil,
      duration: Double? = 3_600, expected: RSSEpisodePeerListen.Outcome
    ) {
      self.name = name
      self.position = position
      self.finished = finished
      self.listenedAt = listenedAt
      self.phone = phone
      self.duration = duration
      self.expected = expected
    }
  }

  private static let now = at(1_000)

  static let cases: [Case] = [
    Case("NaN position", position: .nan, listenedAt: at(900), expected: .reject(.invalid)),
    Case("infinite position", position: .infinity, listenedAt: at(900), expected: .reject(.invalid)),
    Case("negative position", position: -1, listenedAt: at(900), expected: .reject(.invalid)),
    Case(
      "position beyond the duration plus the tolerance", position: 3_602, listenedAt: at(900),
      duration: 3_600, expected: .reject(.invalid)),
    Case(
      "position exactly at the duration plus the tolerance", position: 3_601,
      listenedAt: at(900), duration: 3_600, expected: .apply(updatedAt: at(900))),
    Case(
      "non-finite listen date", position: 300,
      listenedAt: Date(timeIntervalSince1970: .infinity), expected: .reject(.invalid)),
    Case(
      "a zero position with no finish is not a listen", position: 0, listenedAt: at(900),
      expected: .reject(.noListening)),
    Case(
      "a sub-second position with no finish is not a listen", position: 0.5,
      listenedAt: at(900), expected: .reject(.noListening)),
    Case(
      "a finish at a zero position is a listen", position: 0, finished: true,
      listenedAt: at(900), expected: .apply(updatedAt: at(900))),
    Case(
      "no phone row applies the watch time", position: 300, listenedAt: at(900),
      expected: .apply(updatedAt: at(900))),
    Case(
      "same position and finish has converged", position: 300, listenedAt: at(900),
      phone: (300, false, at(100)), expected: .reject(.converged)),
    Case(
      "within the position tolerance has converged", position: 300.5, listenedAt: at(900),
      phone: (300, false, at(100)), expected: .reject(.converged)),
    Case(
      "a phone listen after the window wins", position: 1_000, listenedAt: at(100),
      phone: (300, false, at(500)), expected: .reject(.phoneNewer)),
    Case(
      "a phone reset after the watch listen holds", position: 300, listenedAt: at(100),
      phone: (0, false, at(500)), expected: .reject(.phoneNewer)),
    Case(
      "a tie goes to the further position", position: 600, listenedAt: at(500),
      phone: (300, false, at(480)), expected: .apply(updatedAt: at(500))),
    Case(
      "a tie won by an older watch listen keeps the row's newer time", position: 600,
      listenedAt: at(480), phone: (300, false, at(500)), expected: .apply(updatedAt: at(500))),
    Case(
      "a tie goes to the phone when it is further", position: 300, listenedAt: at(500),
      phone: (600, false, at(480)), expected: .reject(.phoneFurther)),
    Case(
      "a finish is the furthest inside the tie window", position: 300, finished: true,
      listenedAt: at(500), phone: (320, false, at(480)), expected: .apply(updatedAt: at(500))),
    Case(
      "a finished phone beats an unfinished watch in the tie window", position: 320,
      listenedAt: at(500), phone: (300, true, at(480)), expected: .reject(.phoneFurther)),
    Case(
      "a future watch clock is a tie stamped with this device's clock", position: 600,
      listenedAt: at(1_200), phone: (300, false, at(100)), expected: .apply(updatedAt: now)),
    Case(
      "a future watch clock still loses when the phone is further", position: 200,
      listenedAt: at(1_200), phone: (600, false, at(100)), expected: .reject(.phoneFurther)),
    Case(
      "a newer watch listen wins even at a nearer position", position: 300,
      listenedAt: at(900), phone: (600, false, at(100)),
      expected: .apply(updatedAt: at(900))),
    Case(
      "a newer watch listen at the very edge of the window wins", position: 300,
      listenedAt: at(500), phone: (600, false, at(439)),
      expected: .apply(updatedAt: at(500))),
    Case(
      "a just-inside-window watch listen is a tie", position: 700, listenedAt: at(500),
      phone: (600, false, at(441)), expected: .apply(updatedAt: at(500))),
  ]

  @Test("the peer-listen rule, one case at a time", arguments: RSSEpisodePeerListenTests.cases)
  private func resolvesEachCase(_ testCase: Case) {
    let outcome = RSSEpisodePeerListen.resolve(
      watchPosition: testCase.position,
      watchFinished: testCase.finished,
      watchListenedAt: testCase.listenedAt,
      phone: testCase.phone,
      duration: testCase.duration,
      now: Self.now)

    #expect(outcome == testCase.expected, "\(testCase.name)")
  }

  // MARK: - Through the store

  @Test func applyingAListenWritesThroughTheSameCommitPath() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID
    try await fixture.writeState(
      position: 10, finished: false, hide: true, localSequence: 3, updatedAt: Self.at(100))

    let outcome = try await RSSEpisodeStateStore(database: fixture.database).applyPeerListen(
      episodeId: episodeId, position: 300, finished: false, listenedAt: Self.at(900),
      duration: 3_600, now: Self.now)

    #expect(outcome == .applied(localSequence: 4))
    let state = try #require(try await fixture.state(episodeId))
    #expect(state.position == 300)
    #expect(state.finished == false)
    #expect(state.localSequence == 4)
    #expect(state.updatedAt == Self.at(900), "the watch's listen time, not the wall clock")
    #expect(state.hideFromContinueListening == false, "a listen clears the dismissal")
  }

  @Test func aPhoneResetMadeAfterTheWatchListenHolds() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID
    try await fixture.writeState(
      position: 0, finished: false, hide: false, localSequence: 5, updatedAt: Self.at(500))

    let outcome = try await RSSEpisodeStateStore(database: fixture.database).applyPeerListen(
      episodeId: episodeId, position: 300, finished: false, listenedAt: Self.at(100),
      duration: 3_600, now: Self.now)

    #expect(outcome == .rejected(.phoneNewer))
    let state = try #require(try await fixture.state(episodeId))
    #expect(state.position == 0)
    #expect(state.localSequence == 5, "a rejection writes nothing")
    #expect(state.updatedAt == Self.at(500))
  }

  @Test func aRejectedListenLeavesNoRowBehind() async throws {
    let fixture = try await Fixture()

    let outcome = try await RSSEpisodeStateStore(database: fixture.database).applyPeerListen(
      episodeId: fixture.episodeID, position: 0.2, finished: false, listenedAt: Self.at(900),
      duration: 3_600, now: Self.now)

    #expect(outcome == .rejected(.noListening))
    #expect(try await fixture.state(fixture.episodeID) == nil)
  }

  @Test func anUnknownEpisodeThrows() async throws {
    let fixture = try await Fixture()

    await #expect(throws: RSSEpisodeStateStoreError.episodeNotFound) {
      try await RSSEpisodeStateStore(database: fixture.database).applyPeerListen(
        episodeId: 9_999, position: 300, finished: false, listenedAt: Self.at(900),
        duration: 3_600, now: Self.now)
    }
  }

  /// The Saved shelf is resolved by the same funnel a local finish uses: finishing on the Watch
  /// takes the episode off it, exactly as finishing on the phone would
  /// (`NativeSavedIntentResolutionTests` pins the local side).
  @Test func aFinishedWatchListenResolvesTheSavedShelfLikeALocalFinish() async throws {
    let fixture = try await Fixture(saved: true)
    try #require(try await fixture.savedCount() == 1)

    let outcome = try await RSSEpisodeStateStore(database: fixture.database).applyPeerListen(
      episodeId: fixture.episodeID, position: 3_500, finished: true,
      listenedAt: Self.at(900), duration: 3_600, now: Self.now)

    #expect(outcome == .applied(localSequence: 1))
    #expect(try await fixture.savedCount() == 0)
  }

  /// A watch listen is a local write, so the dirty log queues the row for the iPad, as any phone
  /// listen does.
  @Test func anAppliedListenQueuesTheEpisodeForCloudSync() async throws {
    let fixture = try await Fixture(saved: false)

    _ = try await RSSEpisodeStateStore(database: fixture.database).applyPeerListen(
      episodeId: fixture.episodeID, position: 300, finished: false,
      listenedAt: Self.at(900), duration: 3_600, now: Self.now)

    let entries = try await fixture.database.readAsync { db in
      try PodcastCloudDirtyLog.entries(in: db)
    }
    #expect(entries.contains(.init(kind: .episodeState, key: "\(fixture.episodeID)")))
  }

  // MARK: - Fixture

  private struct Fixture {
    let database: AppDatabase
    let episodeID: Int64

    init(saved: Bool = false) async throws {
      let database = try AppDatabase.inMemory()
      self.database = database
      let feedID = try await RSSFeedStore(database: database).subscribe(
        feedURL: URL(string: "https://feeds.invalid/peer.xml")!, title: "Peer",
        author: nil, synopsis: nil, artworkURL: nil,
        subscribedAt: RSSEpisodePeerListenTests.at(0))
      _ = try await RSSEpisodeStore(database: database).applyRefresh(
        feedId: feedID,
        episodes: [
          RSSEpisodeUpsert(
            identityKey: "guid:one",
            enclosureURL: URL(string: "https://cdn.invalid/one.mp3")!, durationSeconds: 3_600)
        ])
      let episodeID = try await database.readAsync { db in
        try Int64.fetchOne(
          db, sql: "SELECT id FROM rssEpisode WHERE feedId = ?", arguments: [feedID])
      }
      let createdEpisodeID = try #require(episodeID)
      self.episodeID = createdEpisodeID
      try await database.writeAsync { db in
        try db.execute(sql: "DELETE FROM podcastCloudDirty")
        guard saved else { return }
        try db.execute(
          sql: """
            INSERT INTO rssSavedShelfEntry (rssEpisodeId, savedAt, subjectTitle, contextTitle)
            VALUES (?, ?, 'Episode', 'Show')
            """, arguments: [createdEpisodeID, RSSEpisodePeerListenTests.at(50)])
      }
    }

    func writeState(
      position: Double, finished: Bool, hide: Bool, localSequence: Int64, updatedAt: Date
    ) async throws {
      try await database.writeAsync { db in
        try RSSEpisodeStateRecord(
          episodeId: episodeID, position: position, finished: finished,
          hideFromContinueListening: hide, localSequence: localSequence, updatedAt: updatedAt
        ).save(db)
        try db.execute(sql: "DELETE FROM podcastCloudDirty")
      }
    }

    func state(_ episodeId: Int64) async throws -> RSSEpisodeStateRecord? {
      try await database.readAsync { db in
        try RSSEpisodeStateRecord.fetchOne(db, key: episodeId)
      }
    }

    func savedCount() async throws -> Int {
      try await database.readAsync { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssSavedShelfEntry") ?? -1
      }
    }
  }
}
