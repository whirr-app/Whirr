import ABSApi
import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

struct WatchOfflineReconciliationPlanTests {
  private let selection = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
  private let now = Date(timeIntervalSince1970: 10_000)

  @Test func newerWatchListenKeepsEverySessionAndUsesTheWatchPosition() throws {
    let first = try local(position: 20, listenedAt: 9_000)
    let latest = try local(position: 35, listenedAt: 9_900)
    let plan = plan([first, latest], [remote(position: 10, at: 9_000)])
    #expect(plan.decisions.map(\.sessionID) == [first.id, latest.id])
    #expect(plan.decisions.map(\.position) == [35, 35])
    #expect(plan.decisions.map(\.reason) == [.watchNewer, .watchNewer])
  }

  @Test func newerSharedValueWinsEvenWhenItIsARewind() throws {
    let session = try local(position: 60, listenedAt: 9_000)
    let plan = plan([session], [remote(position: 40, at: 9_900)])
    #expect(plan.decisions.first?.position == 40)
    #expect(plan.decisions.first?.reason == .sharedNewer)
  }

  @Test func tieWindowTakesTheFurtherPosition() throws {
    let session = try local(position: 60, listenedAt: 9_950)
    let plan = plan([session], [remote(position: 80, at: 9_900)])
    #expect(plan.decisions.first?.position == 80)
    #expect(plan.decisions.first?.reason == .tieFurther)
  }

  @Test func theWatchSideIsTheRowListenedToLastNotTheRowSavedLast() throws {
    // The earlier listen was saved later (a paused tick or a rewrite moves `updatedAt` only).
    let listenedLast = try local(position: 70, listenedAt: 9_900, savedAt: 9_900)
    let savedLast = try local(position: 30, listenedAt: 9_000, savedAt: 9_990)
    let plan = plan([listenedLast, savedLast], [remote(position: 10, at: 9_500)])
    #expect(Set(plan.decisions.map(\.position)) == [70])
  }

  @Test func legacyRowsWithoutAListenTimeUseTheirSaveTime() throws {
    let session = try local(position: 60, listenedAt: nil, savedAt: 9_900)
    let plan = plan([session], [remote(position: 40, at: 9_000)])
    #expect(plan.decisions.first?.position == 60)
  }

  @Test func nearZeroSharedPositionKeepsTheWatch() throws {
    let session = try local(position: 40, listenedAt: 9_000)
    let plan = plan([session], [remote(position: 0, at: 9_900)])
    #expect(plan.decisions.first?.position == 40)
    #expect(plan.decisions.first?.reason == .nearZeroShared)
  }

  /// The server keeps the newer of two saves, so a Watch row that wins against shared progress
  /// saved after it must be saved again before it uploads.
  @Test func aWinningRowOlderThanTheSharedSaveNeedsAFreshTimestamp() throws {
    let older = try local(position: 40, listenedAt: 9_000)
    #expect(plan([older], [remote(position: 0, at: 9_900)]).decisions.map(\.needsFreshTimestamp) == [true])
    let newer = try local(position: 40, listenedAt: 9_950)
    #expect(plan([newer], [remote(position: 10, at: 9_000)]).decisions.map(\.needsFreshTimestamp) == [false])
    let losing = try local(position: 60, listenedAt: 9_000)
    #expect(plan([losing], [remote(position: 40, at: 9_900)]).decisions.map(\.needsFreshTimestamp) == [false])
  }

  @Test func noSharedRowKeepsTheWatch() throws {
    let session = try local(position: 40, listenedAt: 9_000)
    let plan = plan([session], [])
    #expect(plan.decisions.first?.position == 40)
    #expect(plan.decisions.first?.reason == .sharedMissing)
  }

  /// An open row is still being written by playback. It is neither rewritten nor uploaded,
  /// and it does not hold back the title's closed rows.
  @Test func anOpenRowIsExcludedButItsTitlesClosedRowsAreNot() throws {
    let closed = try local(position: 25, listenedAt: 9_000)
    let open = try local(position: 90, listenedAt: 9_500)
    let plan = WatchOfflineReconciliationPlan(
      local: [closed, open], remote: [remote(position: 10, at: 8_000)], open: [open.id], now: now)
    #expect(plan.decisions.map(\.sessionID) == [closed.id])
    #expect(plan.decisions.first?.position == 25)
  }

  @Test func aTitleWithOnlyAnOpenRowHasNoDecision() throws {
    let open = try local(position: 25, listenedAt: 9_000)
    let plan = WatchOfflineReconciliationPlan(
      local: [open], remote: [remote(position: 10, at: 9_000)], open: [open.id], now: now)
    #expect(plan.decisions.isEmpty)
  }

  @Test func shuffledSelectionsPreserveFirstSeenGroupOrderAcrossRepeatedPlans() throws {
    let cFirst = try local(position: 20, listenedAt: 9_000, itemID: "c")
    let aFirst = try local(position: 25, listenedAt: 9_001, itemID: "a")
    let bFirst = try local(position: 30, listenedAt: 9_002, itemID: "b")
    let cLatest = try local(position: 35, listenedAt: 9_900, itemID: "c")
    let aLatest = try local(position: 5, listenedAt: 9_000, itemID: "a")
    let bLatest = try local(position: 30, listenedAt: 9_003, itemID: "b")
    let sessions = [cFirst, aFirst, bFirst, aLatest, cLatest, bLatest]
    let shared = [
      remote(position: 30, at: 9_000, itemID: "b"), remote(position: 40, at: 9_900, itemID: "a"),
      remote(position: 10, at: 9_000, itemID: "c"),
    ]
    let first = plan(sessions, shared)
    let second = plan(sessions, shared)
    #expect(first == second)
    #expect(first.decisions.map(\.sessionID) == [cFirst.id, cLatest.id, aFirst.id, aLatest.id, bFirst.id, bLatest.id])
    #expect(first.decisions.map(\.position) == [35, 35, 40, 40, 30, 30])
  }

  @Test func theDecidedPositionIsClampedToEachRowsOwnDuration() throws {
    let long = try local(position: 90, listenedAt: 9_900, duration: 100)
    let short = try local(position: 20, listenedAt: 9_000, duration: 50)
    let plan = plan([long, short], [])
    #expect(plan.decisions.map(\.sessionID) == [long.id, short.id])
    #expect(plan.decisions.map(\.position) == [90, 50])
  }

  /// One rewrite the store refuses leaves that row waiting; the others still upload.
  @Test func oneRefusedRewriteDoesNotHoldBackTheOthers() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WatchOfflineProgressStore(rootURL: root, accountStamp: accountStamp(account: "a", server: "s"))
    let refused = try await store.startSession(selection: selection, startPosition: 10, duration: 100)
    let moved = try await store.startSession(
      selection: .audiobookshelf(itemID: "other", episodeID: nil), startPosition: 10, duration: 100)
    let unchanged = try await store.startSession(
      selection: .audiobookshelf(itemID: "third", episodeID: nil), startPosition: 30, duration: 100)
    let plan = WatchOfflineReconciliationPlan(decisions: [
      .init(sessionID: refused.id, position: 500, reason: .sharedNewer),
      .init(sessionID: moved.id, position: 40, reason: .sharedNewer),
      .init(sessionID: unchanged.id, position: 30, reason: .converged),
      .init(sessionID: UUID(), position: 5, reason: .watchNewer),
    ])
    #expect(await store.apply(plan) == [moved.id, unchanged.id])
    #expect(await store.session(id: refused.id)?.currentPosition == 10)
    #expect(await store.session(id: moved.id)?.currentPosition == 40)
  }

  private func plan(_ local: [WatchOfflineProgressSession], _ remote: [MediaProgress])
    -> WatchOfflineReconciliationPlan
  {
    WatchOfflineReconciliationPlan(local: local, remote: remote, now: now)
  }

  private func local(
    position: Double, listenedAt: TimeInterval?, savedAt: TimeInterval? = nil, itemID: String = "book",
    duration: Double = 100
  ) throws -> WatchOfflineProgressSession {
    let record = try WatchAccountRecord(serverURL: URL(string: "https://example.invalid")!, userID: "user")
    return WatchOfflineProgressSession(
      id: UUID(), accountStamp: try record.authenticatedStamp(),
      selection: .audiobookshelf(itemID: itemID, episodeID: nil),
      startedAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: savedAt ?? listenedAt ?? 2),
      startPosition: 10, currentPosition: position, duration: duration, timeListening: 7, isFinished: false,
      lastKnownSharedPosition: 10, lastListenedAt: listenedAt.map { Date(timeIntervalSince1970: $0) })
  }

  private func remote(position: Double?, at: TimeInterval, itemID: String = "book") -> MediaProgress {
    MediaProgress(
      libraryItemID: itemID, episodeID: nil, mediaItemID: nil, mediaItemType: nil,
      duration: 100, progress: nil, currentTime: position, isFinished: false,
      hideFromContinueListening: false, ebookLocation: nil, ebookProgress: nil,
      lastUpdate: Date(timeIntervalSince1970: at), startedAt: nil, finishedAt: nil)
  }
}
