import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// Validation of a finished enclosure download against the bytes and the final response's own
/// length, never against the feed's declared length (ADR 0020 Decisions 2 and 4).
struct WatchEnclosureResponseCheckTests {
  private let cap = WatchEpisodeSendLimits.maxEpisodeBytes

  private func evaluate(
    status: Int, received: Int64, contentLength: Int64? = nil, contentRangeTotal: Int64? = nil
  ) -> Result<Int64, WatchEpisodeInventoryEntry.FailureReason> {
    WatchEnclosureResponseCheck.evaluate(
      statusCode: status, receivedBytes: received, contentLength: contentLength,
      contentRangeTotal: contentRangeTotal)
  }

  @Test func aTwoHundredWithTheRightBytesIsAccepted() {
    #expect(evaluate(status: 200, received: 1_000) == .success(1_000))
    #expect(evaluate(status: 200, received: 1_000, contentLength: 1_000) == .success(1_000))
    // A 200 whose length differs from the served bytes is a truncated or over-long body.
    #expect(evaluate(status: 200, received: 1_000, contentLength: 999) == .failure(.invalidResponse))
    #expect(evaluate(status: 200, received: 1_000, contentLength: 1_001) == .failure(.invalidResponse))
  }

  /// A resumed transfer finishes with 206 only as the completion of the whole file.
  @Test func aTwoHundredSixNeedsAWholeFileContentRange() {
    #expect(evaluate(status: 206, received: 1_000, contentRangeTotal: 1_000) == .success(1_000))
    #expect(evaluate(status: 206, received: 1_000) == .failure(.invalidResponse))
    #expect(evaluate(status: 206, received: 1_000, contentRangeTotal: 2_000) == .failure(.invalidResponse))
  }

  @Test func anotherStatusIsAnHTTPFailure() {
    for status in [100, 204, 301, 304, 403, 404, 416, 500] {
      #expect(evaluate(status: status, received: 1_000) == .failure(.httpStatus))
    }
  }

  @Test func theReceivedByteCountIsBounded() {
    #expect(evaluate(status: 200, received: 0) == .failure(.invalidResponse))
    #expect(evaluate(status: 200, received: -1) == .failure(.invalidResponse))
    #expect(evaluate(status: 200, received: cap + 1) == .failure(.tooLarge))
    #expect(evaluate(status: 200, received: cap) == .success(cap))
    #expect(evaluate(status: 200, received: 1) == .success(1))
  }

  @Test func dynamicAdInsertionIsNotComparedWithAnyDeclaredLength() throws {
    // The Watch measured 44,137,426 bytes for an enclosure the phone's feed declared as
    // 40,769,512; the check only knows the received bytes, so it accepts them.
    #expect(evaluate(status: 200, received: 44_137_426, contentLength: 44_137_426) == .success(44_137_426))
  }

  // MARK: Content-Range

  @Test func contentRangeTotalParsesTheWholeFileLength() {
    #expect(WatchEnclosureResponseCheck.contentRangeTotal(from: "bytes 0-99/100") == 100)
    #expect(WatchEnclosureResponseCheck.contentRangeTotal(from: "bytes 0-0/1") == 1)
    #expect(WatchEnclosureResponseCheck.contentRangeTotal(from: "BYTES 100-199/200") == 200)
    #expect(WatchEnclosureResponseCheck.contentRangeTotal(from: "  bytes 0-99/100  ") == 100)
    #expect(WatchEnclosureResponseCheck.contentRangeTotal(from: "bytes 0-999999999/1000000000") == 1_000_000_000)
  }

  @Test func aMalformedContentRangeHasNoTotal() {
    for value in [
      "",
      "bytes",
      "bytes 0-99",
      "bytes 0-99/",
      "bytes */100",
      "bytes 0-99/*",
      "bytes 100-99/100",
      "bytes 0-99/0",
      "bytes 0-99/99",
      "0-99/100",
      "items 0-99/100",
      "bytes a-b/100",
      "bytes 0-99/100, bytes 200-299/400",
    ] {
      #expect(
        WatchEnclosureResponseCheck.contentRangeTotal(from: value) == nil,
        "\(value) should have no total")
    }
  }
}
