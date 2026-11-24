import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// The journal a received RSS episode's progress lives in: one row per play, one entry per episode
/// on the wire, and rows that go when the copy does.
struct WatchNativeJournalTests {
  private let start = Date(timeIntervalSince1970: 100)

  @Test func rejectsAudiobookshelfSelections() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let start = self.start
    let journal = try openJournal(at: root, now: { start })
    await #expect(throws: WatchNativeProgressJournalError.absSelection) {
      try await journal.openRow(
        selection: .audiobookshelf(itemID: "book", episodeID: nil), startPosition: 0,
        duration: 100, lastKnownSharedPosition: nil, lastKnownSharedObservedAt: nil)
    }
    #expect(await journal.rowCount == 0)
  }

  @Test func aListenBecomesOnePendingEntry() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, lifecycle, root) = try fixture(now: { clock.date })
    defer { try? FileManager.default.removeItem(at: root) }
    let native = try episode()

    try await lifecycle.play(at: 10)
    clock.date = Date(timeIntervalSince1970: 120)
    try await lifecycle.record(position: 40, listened: 30)
    clock.date = Date(timeIntervalSince1970: 130)
    #expect(try await lifecycle.pause(at: 50, listened: 10) == .upload)

    let entries = try await journal.pendingReport(excluding: [])
    #expect(entries.count == 1)
    let entry = try #require(entries.first)
    #expect(entry.selection == native)
    #expect(entry.position == 50)
    #expect(entry.lastListenedAt == Date(timeIntervalSince1970: 130))
    #expect(!entry.isFinished)
    #expect(entry.duration == 100)
  }

  /// The journal cannot know which row the lifecycle is still writing, so the caller names it: an
  /// open row's position is partial and the next tick supersedes it.
  @Test func anOpenRowIsNotReported() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, lifecycle, root) = try fixture(now: { clock.date })
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    clock.date = Date(timeIntervalSince1970: 110)
    try await lifecycle.record(position: 20, listened: 10)
    let open = try #require(await lifecycle.openRowID)

    #expect(try await journal.pendingReport(excluding: [open]).isEmpty)
    #expect(try await journal.pendingReport(excluding: []).count == 1)
  }

  @Test func aSeekWhilePausedCountsAsAListen() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, lifecycle, root) = try fixture(now: { clock.date })
    defer { try? FileManager.default.removeItem(at: root) }
    let native = try episode()

    #expect(try await lifecycle.seek(to: 50) == .upload)

    let listen = try #require(await journal.latest(for: native))
    #expect(listen.position == 50)
    #expect(listen.lastListenedAt == start)
    let entries = try await journal.pendingReport(excluding: [])
    #expect(entries.count == 1)
    #expect(entries.first?.lastListenedAt == start)
  }

  @Test func aReportedEntryIsNotReportedAgainUntilMoreListening() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, lifecycle, root) = try fixture(now: { clock.date })
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    clock.date = Date(timeIntervalSince1970: 110)
    try await lifecycle.record(position: 30, listened: 20)
    #expect(try await lifecycle.pause(at: 30, listened: 0) == .upload)
    let entries = try await journal.pendingReport(excluding: [])

    try await journal.markReported(entries)
    #expect(try await journal.pendingReport(excluding: []).isEmpty)

    clock.date = Date(timeIntervalSince1970: 300)
    try await lifecycle.play(at: 30)
    try await lifecycle.record(position: 60, listened: 30)
    #expect(try await lifecycle.pause(at: 60, listened: 0) == .upload)
    let next = try await journal.pendingReport(excluding: [])
    #expect(next.count == 1)
    #expect(next.first?.position == 60)
    #expect(next.first?.lastListenedAt == Date(timeIntervalSince1970: 300))
  }

  @Test func severalClosedRowsReportOnlyTheNewest() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, _, root) = try fixture(now: { clock.date })
    defer { try? FileManager.default.removeItem(at: root) }
    let native = try episode()

    let first = try await journal.openRow(
      selection: native.selection, startPosition: 0, duration: 100,
      lastKnownSharedPosition: nil, lastKnownSharedObservedAt: nil)
    try await journal.recordRow(
      id: first, currentPosition: 20, listenedDelta: 20, isFinished: false, userSeek: false)
    clock.date = Date(timeIntervalSince1970: 200)
    let second = try await journal.openRow(
      selection: native.selection, startPosition: 20, duration: 100,
      lastKnownSharedPosition: nil, lastKnownSharedObservedAt: nil)
    try await journal.recordRow(
      id: second, currentPosition: 40, listenedDelta: 20, isFinished: false, userSeek: false)

    let entries = try await journal.pendingReport(excluding: [])
    #expect(entries.count == 1)
    #expect(entries.first?.position == 40)
    #expect(entries.first?.lastListenedAt == Date(timeIntervalSince1970: 200))

    // Reporting the newest leaves the older row unreported, but it is behind what the phone heard.
    try await journal.markReported(entries)
    #expect(try await journal.pendingReport(excluding: []).isEmpty)
  }

  @Test func aFinishedListenIsReportedAtTheEnd() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, lifecycle, root) = try fixture(now: { clock.date })
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    clock.date = Date(timeIntervalSince1970: 110)
    try await lifecycle.record(position: 80, listened: 70)
    clock.date = Date(timeIntervalSince1970: 200)
    #expect(try await lifecycle.stop(at: 90, listened: 10, finished: true) == .upload)

    let entry = try #require(try await journal.pendingReport(excluding: []).first)
    #expect(entry.isFinished)
    #expect(entry.position == 100)
    #expect(entry.lastListenedAt == Date(timeIntervalSince1970: 200))
  }

  /// A played-and-removed episode must still tell the phone it was finished, so that row
  /// outlives its copy until it has been reported.
  @Test func retainOnlyKeepsAnUnreportedFinish() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, _, root) = try fixture(now: { clock.date })
    defer { try? FileManager.default.removeItem(at: root) }
    let played = try episode("ep-played")
    let finished = try episode("ep-finished")

    let playedID = try await journal.openRow(
      selection: played.selection, startPosition: 0, duration: 100,
      lastKnownSharedPosition: nil, lastKnownSharedObservedAt: nil)
    try await journal.recordRow(
      id: playedID, currentPosition: 40, listenedDelta: 40, isFinished: false, userSeek: false)
    let finishedID = try await journal.openRow(
      selection: finished.selection, startPosition: 0, duration: 100,
      lastKnownSharedPosition: nil, lastKnownSharedObservedAt: nil)
    try await journal.recordRow(
      id: finishedID, currentPosition: 100, listenedDelta: 100, isFinished: true, userSeek: false)
    clock.date = Date(timeIntervalSince1970: 200)
    try await journal.retainOnly([finished])

    #expect(await journal.latest(for: played) == nil)
    #expect(await journal.rowCount(for: finished) == 1)
    let entries = try await journal.pendingReport(excluding: [])
    #expect(entries.map(\.selection) == [finished])

    try await journal.markReported(entries)
    try await journal.retainOnly([])
    #expect(await journal.rowCount == 0)
  }

  @Test func compactionKeepsTheNewestTwoRowsPerEpisode() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, _, root) = try fixture(now: { clock.date })
    defer { try? FileManager.default.removeItem(at: root) }
    let native = try episode()

    for position in 1...3 {
      clock.date = Date(timeIntervalSince1970: TimeInterval(100 * position))
      let id = try await journal.openRow(
        selection: native.selection, startPosition: Double(position - 1), duration: 100,
        lastKnownSharedPosition: nil, lastKnownSharedObservedAt: nil)
      try await journal.recordRow(
        id: id, currentPosition: Double(position), listenedDelta: 1, isFinished: false,
        userSeek: false)
    }

    #expect(await journal.rowCount(for: native) == 2)
    #expect(await journal.latest(for: native)?.position == 3)
  }

  @Test func theJournalIsBoundedInTotal() async throws {
    let start = self.start
    let (journal, _, root) = try fixture(now: { start })
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<(WatchNativeProgressJournal.maximumRows + 5) {
      let selection = try WatchNativeSelection(feedID: "feed-1", episodeID: "ep-\(index)")
      _ = try await journal.openRow(
        selection: selection.selection, startPosition: 0, duration: 100,
        lastKnownSharedPosition: nil, lastKnownSharedObservedAt: nil)
    }
    #expect(await journal.rowCount == WatchNativeProgressJournal.maximumRows)
  }

  @Test func aListenSurvivesARelaunch() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, lifecycle, root) = try fixture(now: { clock.date })
    defer { try? FileManager.default.removeItem(at: root) }
    let native = try episode()
    try await lifecycle.play(at: 10)
    clock.date = Date(timeIntervalSince1970: 120)
    try await lifecycle.record(position: 40, listened: 30)
    clock.date = Date(timeIntervalSince1970: 140)
    #expect(try await lifecycle.pause(at: 50, listened: 10) == .upload)
    try await journal.markReported(try await journal.pendingReport(excluding: []))
    clock.date = Date(timeIntervalSince1970: 150)
    try await lifecycle.play(at: 50)
    try await lifecycle.record(position: 70, listened: 20)
    #expect(try await lifecycle.pause(at: 70, listened: 0) == .upload)

    let reopened = try openJournal(at: root, now: { clock.date })
    let listen = try #require(await reopened.latest(for: native))
    #expect(listen.position == 70)
    #expect(listen.lastListenedAt == Date(timeIntervalSince1970: 150))
    let entries = try await reopened.pendingReport(excluding: [])
    #expect(entries.count == 1)
    #expect(entries.first?.position == 70)
  }

  @Test func aForeignAccountsFileReadsAsEmptyAndIsLeftAlone() async throws {
    let clock = ProgressStoreClock(start)
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let native = try episode()
    let mine = try openJournal(at: root, account: "a", now: { clock.date })
    let id = try await mine.openRow(
      selection: native.selection, startPosition: 0, duration: 100,
      lastKnownSharedPosition: nil, lastKnownSharedObservedAt: nil)
    try await mine.recordRow(
      id: id, currentPosition: 40, listenedDelta: 40, isFinished: false, userSeek: false)

    let other = try openJournal(at: root, account: "b", now: { clock.date })
    #expect(await other.rowCount == 0)
    #expect(await other.latest(for: native) == nil)
    #expect(try await other.pendingReport(excluding: []).isEmpty)

    let reopened = try openJournal(at: root, account: "a", now: { clock.date })
    #expect(await reopened.latest(for: native)?.position == 40)
  }

  @Test func aFailedWriteAppliesNothingAndTheLifecycleCarriesIt() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, lifecycle, root) = try fixture(now: { clock.date })
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
      try? FileManager.default.removeItem(at: root)
    }
    let native = try episode()
    try await lifecycle.play(at: 10)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    await #expect(throws: WatchNativeProgressJournalError.storageFailure) {
      try await lifecycle.record(position: 20, listened: 3)
    }
    let unchanged = try #require(await journal.latest(for: native))
    #expect(unchanged.position == 10)
    #expect(unchanged.lastListenedAt == nil)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    clock.date = Date(timeIntervalSince1970: 200)
    #expect(try await lifecycle.pause(at: 25, listened: 2) == .upload)
    let entry = try #require(try await journal.pendingReport(excluding: []).first)
    #expect(entry.position == 25)
    #expect(entry.lastListenedAt == Date(timeIntervalSince1970: 200))
  }

  @Test func latestPrefersTheNewestListenOverANewerWrite() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, _, root) = try fixture(now: { clock.date })
    defer { try? FileManager.default.removeItem(at: root) }
    let native = try episode()
    let listened = try await journal.openRow(
      selection: native.selection, startPosition: 0, duration: 100,
      lastKnownSharedPosition: nil, lastKnownSharedObservedAt: nil)
    try await journal.recordRow(
      id: listened, currentPosition: 20, listenedDelta: 20, isFinished: false, userSeek: false)

    clock.date = Date(timeIntervalSince1970: 200)
    let written = try await journal.openRow(
      selection: native.selection, startPosition: 20, duration: 100,
      lastKnownSharedPosition: nil, lastKnownSharedObservedAt: nil)
    try await journal.recordRow(
      id: written, currentPosition: 60, listenedDelta: 0, isFinished: false, userSeek: false)

    let listen = try #require(await journal.latest(for: native))
    #expect(listen.position == 20)
    #expect(listen.lastListenedAt == start)
  }

  @Test func latestUsesTheNewestWriteWhenNothingWasListenedTo() async throws {
    let clock = ProgressStoreClock(start)
    let (journal, _, root) = try fixture(now: { clock.date })
    defer { try? FileManager.default.removeItem(at: root) }
    let native = try episode()
    for position in [10.0, 20.0] {
      clock.date = Date(timeIntervalSince1970: 100 * position)
      let id = try await journal.openRow(
        selection: native.selection, startPosition: position, duration: 100,
        lastKnownSharedPosition: nil, lastKnownSharedObservedAt: nil)
      try await journal.recordRow(
        id: id, currentPosition: position, listenedDelta: 0, isFinished: false, userSeek: false)
    }
    let listen = try #require(await journal.latest(for: native))
    #expect(listen.position == 20)
    #expect(listen.lastListenedAt == nil)
  }

  private func openJournal(
    at root: URL, account: String = "a", now: @escaping @Sendable () -> Date
  ) throws -> WatchNativeProgressJournal {
    try WatchNativeProgressJournal(
      fileURL: root.appendingPathComponent("native-progress.json"),
      accountStamp: try accountStamp(account: account, server: "s"), now: now)
  }

  private func fixture(
    now: @escaping @Sendable () -> Date
  ) throws -> (WatchNativeProgressJournal, WatchLocalProgressLifecycle, URL) {
    let root = try temporaryDirectory()
    let journal = try openJournal(at: root, now: now)
    let lifecycle = WatchLocalProgressLifecycle(
      store: journal, selection: try episode().selection, duration: 100, sharedPosition: nil,
      sharedObservedAt: nil)
    return (journal, lifecycle, root)
  }

  private func episode(_ id: String = "ep-1") throws -> WatchNativeSelection {
    try WatchNativeSelection(feedID: "feed-1", episodeID: id)
  }
}
