import Foundation
import Testing

@testable import WatchProtocol

/// The handoff on the wire: one pause-and-position request, its reply, and the Watch's playing
/// report.
@Suite struct WatchHandoffWireTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  @Test func theRequestAndReplyRoundTripUnderTheNewKey() throws {
    let stamp = try fixtureStamp()
    let selection = try WatchABSSelection(itemID: "book-1", episodeID: nil)
    let request = try WatchHandoffRequest(accountStamp: stamp, selection: selection, issuedAt: now)
    #expect(WatchHandoffRequest.transportKey == "whirr.watch.handoff.v2")
    #expect(try WatchWireCodec.decode(WatchHandoffRequest.self, from: WatchWireCodec.encode(request)) == request)

    let reply = try WatchHandoffReply.paused(request, selection: selection, position: 42, lastListenedAt: now)
    #expect(try WatchWireCodec.decode(WatchHandoffReply.self, from: WatchWireCodec.encode(reply)) == reply)
    #expect(reply.position(for: selection) == 42)
  }

  /// A native feed episode cannot be named, but it still asks the other device to pause.
  @Test func aRequestMayNameNoTitle() throws {
    let request = try WatchHandoffRequest(accountStamp: fixtureStamp(), selection: nil, issuedAt: now)
    #expect(try WatchWireCodec.decode(WatchHandoffRequest.self, from: WatchWireCodec.encode(request)) == request)
  }

  /// The position is only for the same title; another title keeps its own position.
  @Test func aReplyAboutAnotherTitleGivesNoPosition() throws {
    let request = try WatchHandoffRequest(accountStamp: fixtureStamp(), selection: nil, issuedAt: now)
    let playing = try WatchABSSelection(itemID: "book-1", episodeID: nil)
    let other = try WatchABSSelection(itemID: "book-2", episodeID: nil)
    let reply = try WatchHandoffReply.paused(request, selection: playing, position: 42, lastListenedAt: nil)
    #expect(reply.position(for: other) == nil)
    #expect(reply.position(for: nil) == nil)
    #expect(WatchHandoffReply.idle(request).position(for: playing) == nil)
  }

  @Test func inconsistentRepliesAreRefused() throws {
    let id = UUID()
    let selection = try WatchABSSelection(itemID: "book-1", episodeID: nil)
    #expect(throws: WatchHandoffError.self) {
      try WatchHandoffReply(handoffID: id, status: .paused, selection: selection)
    }
    #expect(throws: WatchHandoffError.self) {
      try WatchHandoffReply(handoffID: id, status: .idle, selection: selection, positionSeconds: 1)
    }
    #expect(throws: WatchHandoffError.self) { try WatchHandoffReply(handoffID: id, status: .rejected) }
    #expect(throws: WatchHandoffError.self) {
      try WatchHandoffReply(handoffID: id, status: .paused, selection: selection, positionSeconds: .infinity)
    }
    #expect(throws: WatchHandoffError.self) {
      try WatchHandoffReply(
        handoffID: id, status: .paused, selection: selection,
        positionSeconds: WatchHandoffLimits.maxPositionSeconds + 1)
    }
  }

  @Test func anOversizedPayloadIsRefused() throws {
    let huge = Data(repeating: 0x20, count: WatchHandoffLimits.maxWireBytes + 1)
    #expect(throws: (any Error).self) { try WatchWireCodec.decode(WatchHandoffRequest.self, from: huge) }
    #expect(throws: (any Error).self) { try WatchWireCodec.decode(WatchHandoffReply.self, from: huge) }
  }

  /// The protocol version stays 1, so a skewed pair still exchanges everything else.
  @Test func theProtocolVersionIsUnchanged() {
    #expect(WatchProtocolVersion.current == 1)
  }

  @Test func aPlayingReportIsFreshForThreeMinutesForItsAccountOnly() throws {
    let stamp = try fixtureStamp()
    let other = try WatchAccountStamp(accountIdentityHash: "other-account", serverIdentityHash: "server-hash")
    let report = try WatchPlayingReport(
      accountStamp: stamp, selection: WatchABSSelection(itemID: "book-1", episodeID: nil), playing: true,
      observedAt: now)
    #expect(try WatchWireCodec.decode(WatchPlayingReport.self, from: WatchWireCodec.encode(report)) == report)
    #expect(report.isPlaying(for: stamp, at: now.addingTimeInterval(179)))
    #expect(!report.isPlaying(for: stamp, at: now.addingTimeInterval(180)))
    #expect(!report.isPlaying(for: other, at: now))
    #expect(!report.isPlaying(for: stamp, at: now.addingTimeInterval(-31)))
    let paused = try WatchPlayingReport(accountStamp: stamp, selection: nil, playing: false, observedAt: now)
    #expect(!paused.isPlaying(for: stamp, at: now))
    #expect(throws: WatchHandoffError.self) {
      try WatchPlayingReport(accountStamp: stamp, selection: nil, playing: true, observedAt: now)
    }
  }

  @Test func aWatchThatKeepsPlayingRepeatsItsReportBeforeItLapses() {
    #expect(WatchPlayingReport.refreshInterval < WatchPlayingReport.expiry - 30)
    #expect(WatchPlayingReport.refreshDue(lastPublished: nil, now: now))
    #expect(!WatchPlayingReport.refreshDue(lastPublished: now, now: now.addingTimeInterval(119)))
    #expect(WatchPlayingReport.refreshDue(lastPublished: now, now: now.addingTimeInterval(120)))
    // A clock set back must not silence the report until it catches up.
    #expect(WatchPlayingReport.refreshDue(lastPublished: now, now: now.addingTimeInterval(-1)))
  }

  private func fixtureStamp() throws -> WatchAccountStamp {
    try WatchAccountStamp(accountIdentityHash: "account-hash", serverIdentityHash: "server-hash")
  }
}

/// Admission, the 120 s window with its 30 s future-skew bound, and the replay cache.
@Suite struct WatchHandoffResponderTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  @Test func theFirstDeliveryPausesAndARepeatOnlyReports() throws {
    var responder = WatchHandoffResponder()
    let request = try makeRequest(issuedAt: now)
    #expect(responder.admit(request, authenticatedAccountStamp: request.accountStamp, now: now) == .pause(request))
    #expect(
      responder.admit(request, authenticatedAccountStamp: request.accountStamp, now: now.addingTimeInterval(5))
        == .report(request))
  }

  @Test func anotherAccountIsRejected() throws {
    var responder = WatchHandoffResponder()
    let request = try makeRequest(issuedAt: now)
    let other = try WatchAccountStamp(accountIdentityHash: "other-account", serverIdentityHash: "server-hash")
    #expect(
      responder.admit(request, authenticatedAccountStamp: other, now: now)
        == .reject(.rejected(handoffID: request.handoffID, .wrongAccount)))
    #expect(
      responder.admit(request, authenticatedAccountStamp: nil, now: now)
        == .reject(.rejected(handoffID: request.handoffID, .wrongAccount)))
  }

  /// A delayed request cannot pause a later listen.
  @Test func aRequestOutsideTheWindowIsRejected() throws {
    var responder = WatchHandoffResponder()
    let old = try makeRequest(issuedAt: now.addingTimeInterval(-120))
    #expect(
      responder.admit(old, authenticatedAccountStamp: old.accountStamp, now: now)
        == .reject(.rejected(handoffID: old.handoffID, .expired)))
    let future = try makeRequest(issuedAt: now.addingTimeInterval(31))
    #expect(
      responder.admit(future, authenticatedAccountStamp: future.accountStamp, now: now)
        == .reject(.rejected(handoffID: future.handoffID, .expired)))
    let skewed = try makeRequest(issuedAt: now.addingTimeInterval(30))
    #expect(responder.admit(skewed, authenticatedAccountStamp: skewed.accountStamp, now: now) == .pause(skewed))
    let late = try makeRequest(issuedAt: now.addingTimeInterval(-119))
    #expect(responder.admit(late, authenticatedAccountStamp: late.accountStamp, now: now) == .pause(late))
  }

  @Test func theReplayCacheIsBounded() throws {
    var responder = WatchHandoffResponder()
    let first = try makeRequest(issuedAt: now.addingTimeInterval(-100))
    _ = responder.admit(first, authenticatedAccountStamp: first.accountStamp, now: now)
    for offset in 1...WatchHandoffResponder.capacity {
      let request = try makeRequest(issuedAt: now.addingTimeInterval(-Double(offset)))
      #expect(
        responder.admit(request, authenticatedAccountStamp: request.accountStamp, now: now) == .pause(request))
    }
    // The oldest entry made room for the newest, so it is admitted as new.
    #expect(responder.admit(first, authenticatedAccountStamp: first.accountStamp, now: now) == .pause(first))
  }

  @Test func resetForgetsAdmittedRequests() throws {
    var responder = WatchHandoffResponder()
    let request = try makeRequest(issuedAt: now)
    _ = responder.admit(request, authenticatedAccountStamp: request.accountStamp, now: now)
    responder.reset()
    #expect(responder.admit(request, authenticatedAccountStamp: request.accountStamp, now: now) == .pause(request))
  }

  private func makeRequest(issuedAt: Date) throws -> WatchHandoffRequest {
    try WatchHandoffRequest(
      accountStamp: WatchAccountStamp(accountIdentityHash: "account-hash", serverIdentityHash: "server-hash"),
      selection: WatchABSSelection(itemID: "book-1", episodeID: nil), issuedAt: issuedAt)
  }
}
