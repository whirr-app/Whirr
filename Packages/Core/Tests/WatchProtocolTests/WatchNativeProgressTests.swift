import Foundation
import Testing

@testable import WatchProtocol

/// Native-RSS progress from the Watch and the bounded pause request a phone start sends first.
struct WatchNativeProgressTests {
  private let listenedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private let installID = "a1b2c3d4-0000-4000-8000-000000000001"

  @Test func reportRoundTripsThroughTheWireCodec() throws {
    let report = try report(entries: [try entry(0, position: 180), try entry(1, position: 0)])
    let decoded = try WatchProtocolFixtures.roundTrip(report)
    #expect(decoded == report)
    #expect(decoded.entries.map(\.position) == [180, 0])
    #expect(WatchNativeProgressReport.transportKey == "whirr.watch.native-progress.report.v1")
  }

  @Test func decodeRejectsAnotherProtocolVersion() throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(try report())) as? [String: Any])
    object["version"] = WatchProtocolVersion.current + 1
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WatchProtocolCodingError.unsupportedVersion(WatchProtocolVersion.current + 1)) {
      try WatchWireCodec.decode(WatchNativeProgressReport.self, from: data)
    }
  }

  @Test func reportRequiresACanonicalInstallIdentity() throws {
    for bad in ["", "not-a-uuid", installID.uppercased()] {
      #expect(throws: WatchProtocolCodingError.invalidValue) { try report(installID: bad) }
    }
  }

  @Test func reportRejectsMoreEntriesThanTheUploadBatch() throws {
    let entries = try (0...WatchPendingProgressLimits.maxEntries).map { try entry($0, position: 10) }
    #expect(throws: WatchProtocolCodingError.tooManyRows) { try report(entries: entries) }
  }

  @Test func reportRejectsTwoEntriesForOneEpisode() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try report(entries: [try entry(0, position: 10), try entry(0, position: 20)])
    }
  }

  @Test func entryRejectsAnImpossiblePositionOrDuration() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, position: -.infinity) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, position: -1) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, position: WatchHandoffLimits.maxPositionSeconds + 1)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, position: 1, duration: 0) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, position: 1, duration: .nan) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchNativeProgressEntry(
        selection: try selection(0), position: 1,
        lastListenedAt: Date(timeIntervalSinceReferenceDate: .nan), isFinished: false, duration: nil)
    }
  }

  @Test func entryUsesTheSelectionIdentifierRules() throws {
    #expect(throws: WatchProtocolCodingError.invalidSelection) {
      try WatchNativeProgressEntry(
        selection: try WatchNativeSelection(feedID: "feed", episodeID: ""), position: 1,
        lastListenedAt: listenedAt, isFinished: false, duration: nil)
    }
  }

  @Test func anOversizedReportIsRejectedByTheCodec() throws {
    let long = String(repeating: "x", count: 200)
    let entries = try (0..<WatchPendingProgressLimits.maxEntries).map { index in
      try WatchNativeProgressEntry(
        selection: try WatchNativeSelection(feedID: long, episodeID: "\(long)-\(index)"), position: 12_345.678_9,
        lastListenedAt: listenedAt, isFinished: false, duration: 3_600)
    }
    let report = try report(entries: entries)
    #expect(throws: WatchProtocolCodingError.tooLarge) { try WatchWireCodec.encode(report) }
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchWireCodec.decode(
        WatchNativeProgressReport.self, from: Data(repeating: 0x20, count: WatchNativeProgressReport.maxWireBytes + 1))
    }
  }

  // MARK: Pause request and reply

  @Test func thePausePairRoundTripsUnderOneKey() throws {
    let request = try WatchNativePauseRequest(selection: selection(0), sentAt: listenedAt)
    #expect(WatchNativePauseRequest.transportKey == "whirr.watch.native-pause.v1")
    #expect(WatchNativePauseRequest.transportKey == WatchNativePauseReply.transportKey)
    #expect(try WatchProtocolFixtures.roundTrip(request) == request)

    let reply = try WatchNativePauseReply(
      selection: selection(0), paused: true, position: 42, lastListenedAt: listenedAt)
    #expect(try WatchProtocolFixtures.roundTrip(reply) == reply)
    #expect(reply.position == 42)
  }

  @Test func aWatchThatWasNotPlayingCarriesNoPosition() throws {
    let reply = try WatchNativePauseReply(selection: selection(0), paused: false)
    #expect(try WatchProtocolFixtures.roundTrip(reply) == reply)
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchNativePauseReply(selection: selection(0), paused: false, position: 42)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchNativePauseReply(selection: selection(0), paused: false, lastListenedAt: listenedAt)
    }
  }

  @Test func pauseValuesRejectImpossiblePositionsAndDates() throws {
    for position in [Double.infinity, -1, WatchHandoffLimits.maxPositionSeconds + 1] {
      #expect(throws: WatchProtocolCodingError.invalidValue) {
        try WatchNativePauseReply(selection: selection(0), paused: true, position: position)
      }
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchNativePauseRequest(
        selection: selection(0), sentAt: Date(timeIntervalSinceReferenceDate: .nan))
    }
  }

  @Test func pauseValuesRejectAnotherVersionAndAnOversizedPayload() throws {
    var object = try #require(
      JSONSerialization.jsonObject(
        with: WatchWireCodec.encode(try WatchNativePauseRequest(selection: selection(0), sentAt: listenedAt)))
        as? [String: Any])
    object["version"] = WatchProtocolVersion.current + 1
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WatchProtocolCodingError.unsupportedVersion(WatchProtocolVersion.current + 1)) {
      try WatchWireCodec.decode(WatchNativePauseRequest.self, from: data)
    }
    let huge = Data(repeating: 0x20, count: WatchHandoffLimits.maxWireBytes + 1)
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchWireCodec.decode(WatchNativePauseRequest.self, from: huge)
    }
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchWireCodec.decode(WatchNativePauseReply.self, from: huge)
    }
  }

  // MARK: Helpers

  private func selection(_ index: Int = 0) throws -> WatchNativeSelection {
    try WatchNativeSelection(feedID: "feed-\(index)", episodeID: "episode-\(index)")
  }

  private func entry(
    _ index: Int, position: Double, duration: Double? = 3_600
  ) throws -> WatchNativeProgressEntry {
    try WatchNativeProgressEntry(
      selection: selection(index), position: position, lastListenedAt: listenedAt, isFinished: false,
      duration: duration)
  }

  private func report(
    installID: String = "a1b2c3d4-0000-4000-8000-000000000001",
    entries: [WatchNativeProgressEntry] = []
  ) throws -> WatchNativeProgressReport {
    try WatchNativeProgressReport(watchInstallID: installID, sequence: 7, entries: entries)
  }
}
