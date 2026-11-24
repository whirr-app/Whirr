import Foundation
import Testing

@testable import WatchProtocol

/// The Watch's report of progress it has not uploaded yet, and the phone's use of it at start.
struct WatchPendingProgressTests {
  private let listenedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

  @Test func reportRoundTripsThroughTheWireCodec() throws {
    let report = try report(entries: [entry(position: 180)], downloaded: [WatchProtocolFixtures.absSelection()])
    let decoded = try WatchProtocolFixtures.roundTrip(report)
    #expect(decoded == report)
    #expect(decoded.entry(itemID: "book", episodeID: "episode")?.position == 180)
  }

  @Test func reportRejectsMoreEntriesThanTheUploadBatch() throws {
    let entries = try (0...WatchPendingProgressLimits.maxEntries).map {
      try entry(itemID: "book-\($0)", position: 10)
    }
    #expect(throws: WatchProtocolCodingError.tooManyRows) { try report(entries: entries) }
  }

  @Test func reportRejectsMoreDownloadsThanTheRowLimit() throws {
    let downloaded = (0...WatchProtocolVersion.maxRows).map {
      WatchProtocolFixtures.absSelection(itemID: "book-\($0)", episodeID: nil)
    }
    #expect(throws: WatchProtocolCodingError.tooManyRows) { try report(downloaded: downloaded) }
  }

  @Test func reportRejectsTwoEntriesForOneTitle() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try report(entries: [entry(position: 10), entry(position: 20)])
    }
  }

  @Test func entryRejectsAnImpossiblePosition() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(position: -.infinity) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(position: -1) }
  }

  @Test func aFullReportFitsTheWireLimit() throws {
    let long = String(repeating: "x", count: 36)
    let entries = try (0..<WatchPendingProgressLimits.maxEntries).map {
      try entry(itemID: "\(long)-\($0)", episodeID: "\(long)-\($0)", position: 12_345.678_9)
    }
    let downloaded = (0..<WatchProtocolVersion.maxRows).map {
      WatchProtocolFixtures.absSelection(itemID: "\(long)-\($0)", episodeID: nil)
    }
    let data = try WatchWireCodec.encode(try report(entries: entries, downloaded: downloaded))
    #expect(data.count <= WatchPendingProgressReport.maxWireBytes)
  }

  @Test func decodeRejectsAnotherProtocolVersion() throws {
    var object =
      try JSONSerialization.jsonObject(with: WatchWireCodec.encode(try report())) as? [String: Any] ?? [:]
    object["version"] = WatchProtocolVersion.current + 1
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WatchProtocolCodingError.unsupportedVersion(WatchProtocolVersion.current + 1)) {
      try WatchWireCodec.decode(WatchPendingProgressReport.self, from: data)
    }
  }

  @Test func queryRoundTrips() throws {
    let query = try WatchPendingProgressQuery(
      accountStamp: WatchProtocolFixtures.accountStamp(), selection: WatchProtocolFixtures.absSelection())
    #expect(try WatchProtocolFixtures.roundTrip(query) == query)
  }

  // MARK: Start position

  @Test func newerWatchListenGivesTheWatchPosition() throws {
    let report = try report(entries: [entry(position: 180)])
    let position = report.startPosition(
      itemID: "book", episodeID: "episode", sharedPosition: 40,
      sharedUpdatedAt: listenedAt.addingTimeInterval(-600), now: listenedAt.addingTimeInterval(60))
    #expect(position == 180)
  }

  @Test func aTitleFinishedOnTheWatchStartsFromTheBeginning() throws {
    let report = try report(entries: [entry(position: 180, isFinished: true)])
    let position = report.startPosition(
      itemID: "book", episodeID: "episode", sharedPosition: 40,
      sharedUpdatedAt: listenedAt.addingTimeInterval(-600), now: listenedAt.addingTimeInterval(60))
    #expect(position == 0)
  }

  @Test func newerPhoneListenKeepsThePhonePosition() throws {
    let report = try report(entries: [entry(position: 180)])
    let position = report.startPosition(
      itemID: "book", episodeID: "episode", sharedPosition: 40,
      sharedUpdatedAt: listenedAt.addingTimeInterval(600), now: listenedAt.addingTimeInterval(700))
    #expect(position == nil)
  }

  @Test func listensCloseInTimeGiveTheFurtherPosition() throws {
    let report = try report(entries: [entry(position: 180)])
    #expect(
      report.startPosition(
        itemID: "book", episodeID: "episode", sharedPosition: 40,
        sharedUpdatedAt: listenedAt.addingTimeInterval(20), now: listenedAt.addingTimeInterval(60)) == 180)
    #expect(
      report.startPosition(
        itemID: "book", episodeID: "episode", sharedPosition: 300,
        sharedUpdatedAt: listenedAt.addingTimeInterval(20), now: listenedAt.addingTimeInterval(60)) == nil)
  }

  @Test func noPhoneProgressGivesTheWatchPosition() throws {
    let report = try report(entries: [entry(position: 180)])
    #expect(
      report.startPosition(
        itemID: "book", episodeID: "episode", sharedPosition: nil, sharedUpdatedAt: nil, now: listenedAt) == 180)
  }

  @Test func titleAbsentFromTheReportGivesNothing() throws {
    let report = try report(entries: [entry(position: 180)])
    #expect(
      report.startPosition(
        itemID: "other", episodeID: nil, sharedPosition: nil, sharedUpdatedAt: nil, now: listenedAt) == nil)
    #expect(
      report.startPosition(
        itemID: "book", episodeID: nil, sharedPosition: nil, sharedUpdatedAt: nil, now: listenedAt) == nil)
  }

  @Test func convergedPositionsGiveNothing() throws {
    let report = try report(entries: [entry(position: 180)])
    #expect(
      report.startPosition(
        itemID: "book", episodeID: "episode", sharedPosition: 180.5,
        sharedUpdatedAt: listenedAt.addingTimeInterval(-600), now: listenedAt) == nil)
  }

  private func entry(
    itemID: String = "book", episodeID: String? = "episode", position: Double, isFinished: Bool = false
  ) throws -> WatchPendingProgressEntry {
    try WatchPendingProgressEntry(
      selection: WatchABSSelection(itemID: itemID, episodeID: episodeID), position: position,
      lastListenedAt: listenedAt, isFinished: isFinished, duration: 3_600)
  }

  private func report(
    entries: [WatchPendingProgressEntry] = [], downloaded: [WatchABSSelection] = []
  ) throws -> WatchPendingProgressReport {
    try WatchPendingProgressReport(
      accountStamp: WatchProtocolFixtures.accountStamp(), sequence: 7, entries: entries, downloaded: downloaded)
  }
}
