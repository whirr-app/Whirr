import ABSApi
import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// A start or resume weighs the Watch's own positions against the server's full progress.
@Suite struct WatchResumeCandidatesTests {
  private let now = Date(timeIntervalSince1970: 10_000)
  private let book = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)

  private func row(
    itemID: String = "book", episodeID: String? = nil, position: Double? = 300, at: TimeInterval? = 9_000,
    finished: Bool = false, hidden: Bool = false
  ) -> MediaProgress {
    MediaProgress(
      libraryItemID: itemID, episodeID: episodeID, mediaItemID: nil, mediaItemType: nil,
      duration: 600, progress: nil, currentTime: position, isFinished: finished,
      hideFromContinueListening: hidden, ebookLocation: nil, ebookProgress: nil,
      lastUpdate: at.map { Date(timeIntervalSince1970: $0) }, startedAt: nil, finishedAt: nil)
  }

  private func session(position: Double, listenedAt: TimeInterval, itemID: String = "book") throws
    -> WatchOfflineProgressSession
  {
    let record = try WatchAccountRecord(serverURL: URL(string: "https://example.invalid")!, userID: "user")
    return WatchOfflineProgressSession(
      id: UUID(), accountStamp: try record.authenticatedStamp(),
      selection: .audiobookshelf(itemID: itemID, episodeID: nil),
      startedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: listenedAt),
      startPosition: 0, currentPosition: position, duration: 600, timeListening: 7, isFinished: false,
      lastKnownSharedPosition: nil, lastListenedAt: Date(timeIntervalSince1970: listenedAt))
  }

  private func bookmark(_ position: Double, at: TimeInterval?) -> WatchResumeCandidates.Bookmark {
    .init(selection: book, position: position, listenedAt: at.map { Date(timeIntervalSince1970: $0) })
  }

  private func start(
    handoff: Double? = nil, rows: [WatchOfflineProgressSession] = [],
    bookmark: WatchResumeCandidates.Bookmark? = nil, server: [MediaProgress]
  ) -> Double {
    WatchResumeCandidates.start(
      for: book, handoff: handoff, rows: rows, bookmark: bookmark, serverRows: server, now: now)
  }

  /// P2: the Continue list drops finished and hidden titles and keeps ten; the snapshot does not.
  @Test func finishedAndHiddenRowsAreCandidates() {
    #expect(start(bookmark: bookmark(120, at: 8_000), server: [row(position: 600, finished: true)]) == 0)
    #expect(start(bookmark: bookmark(120, at: 8_000), server: [row(position: 400, hidden: true)]) == 400)
  }

  @Test func newerWatchListeningKeepsTheWatchPosition() throws {
    #expect(start(rows: [try session(position: 120, listenedAt: 9_500)], server: [row(position: 300)]) == 120)
  }

  /// Newer listening elsewhere may move the Watch backwards.
  @Test func newerSharedListeningMayMoveBackwards() {
    #expect(start(bookmark: bookmark(400, at: 8_000), server: [row(position: 100, at: 9_000)]) == 100)
  }

  @Test func sameNeighbourhoodIsTheWatchsOwnUpload() {
    #expect(start(bookmark: bookmark(299, at: 8_000), server: [row(position: 300.5, at: 9_000)]) == 299)
  }

  @Test func aHandoffAlwaysWins() {
    #expect(start(handoff: 42, bookmark: bookmark(120, at: 9_900), server: [row(position: 300)]) == 42)
  }

  /// P3: a date from a fast clock cannot win, though it still supplies a position on its own.
  @Test func aFutureDatedRowCannotSupersede() {
    let fast = row(position: 500, at: 10_000 + WatchOfflineConflictPolicy.futureClockAllowance + 1)
    #expect(start(bookmark: bookmark(120, at: 8_000), server: [fast]) == 120)
    #expect(start(server: [fast]) == 500)
    let inside = row(position: 500, at: 10_000 + WatchOfflineConflictPolicy.futureClockAllowance)
    #expect(start(bookmark: bookmark(120, at: 8_000), server: [inside]) == 500)
  }

  @Test func aRowWithoutPositionOrDateIsNoCandidate() {
    #expect(WatchResumeCandidates.shared(for: book, in: [row(position: nil)], now: now) == nil)
    #expect(WatchResumeCandidates.shared(for: book, in: [row(at: nil)], now: now) == nil)
    #expect(start(bookmark: bookmark(120, at: nil), server: [row(position: nil)]) == 120)
  }

  @Test func onlyTheSelectionsNewestRowCounts() {
    let rows = [row(itemID: "other", position: 50, at: 9_900), row(position: 200, at: 8_500), row(position: 300)]
    #expect(WatchResumeCandidates.shared(for: book, in: rows, now: now)?.position == 300)
    let episode = WatchSelection.audiobookshelf(itemID: "show", episodeID: "two")
    let episodes = [
      row(itemID: "show", episodeID: "one", position: 10), row(itemID: "show", episodeID: "two", position: 20),
    ]
    #expect(WatchResumeCandidates.shared(for: episode, in: episodes, now: now)?.position == 20)
    #expect(WatchResumeCandidates.shared(for: .nativeFeed(feedID: "f", episodeID: "e"), in: episodes, now: now) == nil)
  }

  @Test func theBookmarkCountsOnlyForItsTitle() throws {
    let other = WatchResumeCandidates.Bookmark(
      selection: .audiobookshelf(itemID: "other", episodeID: nil), position: 50, listenedAt: nil)
    let rows = [
      try session(position: 80, listenedAt: 9_000), try session(position: 90, listenedAt: 9_100, itemID: "x"),
    ]
    let local = WatchResumeCandidates.local(for: book, rows: rows, bookmark: other)
    #expect(local.map(\.position) == [80])
  }
}
