import Foundation
import Testing
import WatchProtocol

@testable import Whirr

/// Before a phone start, a Watch playing a received RSS episode is asked to pause.
@MainActor
@Suite("Watch native start gate")
struct WatchNativeStartGateTests {
  private let account = try! WatchAccountStamp(
    accountIdentityHash: "account-hash", serverIdentityHash: "server-hash")
  private let now = Date(timeIntervalSinceReferenceDate: 5_000)

  @MainActor
  final class Link {
    var report: WatchPlayingReport?
    var sent: [(request: WatchNativePauseRequest, wait: Duration)] = []
    var replyFor: (WatchNativePauseRequest) -> WatchNativePauseReply? = { _ in nil }
    var rawReply: Data?
    var applied: [(selection: WatchNativeSelection, position: Double, lastListenedAt: Date)] = []
    var clock = Date(timeIntervalSinceReferenceDate: 5_000)

    func gate() -> WatchNativeStartGate {
      WatchNativeStartGate(
        report: { self.report },
        send: { data, wait in
          guard let request = try? WatchWireCodec.decode(WatchNativePauseRequest.self, from: data)
          else { return nil }
          self.sent.append((request, wait))
          if let raw = self.rawReply { return raw }
          return self.replyFor(request).flatMap { try? WatchWireCodec.encode($0) }
        },
        applyListen: { selection, position, lastListenedAt in
          self.applied.append((selection, position, lastListenedAt))
        },
        now: { self.clock })
    }
  }

  // MARK: Nothing to ask

  @Test("no report and a Watch that is not playing are never asked")
  func idleWatchIsNotAsked() async throws {
    let link = Link()
    let gate = link.gate()
    #expect(await gate.positionForStart(itemID: "rss:7", episodeID: "e1") == nil)

    link.report = try report(playing: false, native: nil)
    #expect(await gate.positionForStart(itemID: "rss:7", episodeID: "e1") == nil)

    #expect(link.sent.isEmpty)
  }

  @Test("an expired report is never asked, even though it still names an episode")
  func expiredReportIsNotAsked() async throws {
    let link = Link()
    link.report = try report(
      native: try selection(),
      observedAt: now.addingTimeInterval(-WatchPlayingReport.expiry - 1))

    #expect(await link.gate().positionForStart(itemID: "rss:7", episodeID: "e1") == nil)
    #expect(link.sent.isEmpty)
  }

  // MARK: The same episode

  @Test("the same episode is paused, its position applied to the phone row and returned")
  func sameEpisodeReturnsTheWatchPosition() async throws {
    let link = Link()
    let watchSelection = try selection()
    let listenedAt = now.addingTimeInterval(-60)
    link.report = try report(native: watchSelection)
    link.clock = now.addingTimeInterval(5)
    link.replyFor = { request in
      try? WatchNativePauseReply(
        selection: request.selection, paused: true, position: 321, lastListenedAt: listenedAt)
    }

    let position = await link.gate().positionForStart(itemID: "rss:7", episodeID: "e1")

    #expect(position == 321)
    #expect(link.applied.count == 1)
    #expect(link.applied.first?.selection == watchSelection)
    #expect(link.applied.first?.position == 321)
    #expect(link.applied.first?.lastListenedAt == listenedAt)
    #expect(link.sent.count == 1)
    #expect(link.sent.first?.request.selection == watchSelection)
    #expect(link.sent.first?.wait == .seconds(3))
  }

  @Test("a reply without a listen time still applies the position with the start's clock")
  func replyWithoutListenTimeUsesTheStartClock() async throws {
    let link = Link()
    link.report = try report(native: try selection())
    link.replyFor = { request in
      try? WatchNativePauseReply(selection: request.selection, paused: true, position: 88)
    }

    let position = await link.gate().positionForStart(itemID: "rss:7", episodeID: "e1")

    #expect(position == 88)
    #expect(link.applied.first?.lastListenedAt == link.clock)
  }

  @Test("a timeout, a malformed reply, a refusal and a reply for another episode leave the phone's start")
  func failuresLeaveThePhoneStart() async throws {
    let link = Link()
    link.report = try report(native: try selection())
    let gate = link.gate()

    #expect(await gate.positionForStart(itemID: "rss:7", episodeID: "e1") == nil)
    link.rawReply = Data("not a reply".utf8)
    #expect(await gate.positionForStart(itemID: "rss:7", episodeID: "e1") == nil)
    link.rawReply = nil
    link.replyFor = { request in try? WatchNativePauseReply(selection: request.selection, paused: false) }
    #expect(await gate.positionForStart(itemID: "rss:7", episodeID: "e1") == nil)
    let other = try selection(episode: "e9")
    link.replyFor = { _ in
      try? WatchNativePauseReply(
        selection: other, paused: true, position: 9, lastListenedAt: self.now)
    }
    #expect(await gate.positionForStart(itemID: "rss:7", episodeID: "e1") == nil)

    #expect(link.sent.count == 4)
    #expect(link.applied.isEmpty)
  }

  // MARK: Another title

  @Test("another native episode pauses the Watch without waiting")
  func anotherEpisodeIsFireAndForget() async throws {
    let link = Link()
    let watchSelection = try selection()
    link.report = try report(native: watchSelection)
    let gate = link.gate()

    let position = await gate.positionForStart(itemID: "rss:7", episodeID: "e2")
    await gate.unawaitedSend?.value

    #expect(position == nil)
    #expect(link.sent.count == 1)
    #expect(link.sent.first?.request.selection == watchSelection)
    #expect(link.applied.isEmpty)
  }

  @Test("an ABS start pauses a Watch playing a native episode without waiting")
  func absStartPausesTheWatch() async throws {
    let link = Link()
    let watchSelection = try selection()
    link.report = try report(native: watchSelection)
    let gate = link.gate()

    let position = await gate.positionForStart(itemID: "book", episodeID: nil)
    await gate.unawaitedSend?.value

    #expect(position == nil)
    #expect(link.sent.count == 1)
    #expect(link.sent.first?.request.selection == watchSelection)
    #expect(link.applied.isEmpty)
  }

  // MARK: Resume

  @Test("a resume pauses a Watch playing a native episode without waiting or applying a listen")
  func resumePausesTheWatchWithoutWaiting() async throws {
    let link = Link()
    let watchSelection = try selection()
    link.report = try report(native: watchSelection)
    let gate = link.gate()

    let task: Task<Void, Never>? = gate.askOnResume()
    #expect(task != nil)
    await task?.value

    #expect(link.sent.count == 1)
    #expect(link.sent.first?.request.selection == watchSelection)
    #expect(link.applied.isEmpty)
  }

  @Test("a resume with nothing native playing, or an ABS title, sends nothing")
  func resumeWithoutANativeEpisodeSendsNothing() async throws {
    let link = Link()
    let gate = link.gate()
    #expect(gate.askOnResume() == nil)

    link.report = try report(playing: false, native: try selection())
    #expect(gate.askOnResume() == nil)

    link.report = try report(
      native: nil, selection: try WatchABSSelection(itemID: "book", episodeID: nil))
    #expect(gate.askOnResume() == nil)

    #expect(link.sent.isEmpty)
    #expect(link.applied.isEmpty)
  }

  // MARK: Helpers

  private func selection(feed: String = "7", episode: String = "e1") throws -> WatchNativeSelection {
    try WatchNativeSelection(feedID: feed, episodeID: episode)
  }

  private func report(
    playing: Bool = true, native: WatchNativeSelection?, observedAt: Date? = nil,
    selection: WatchABSSelection? = nil
  ) throws -> WatchPlayingReport {
    try WatchPlayingReport(
      accountStamp: account, selection: selection, playing: playing, observedAt: observedAt ?? now,
      nativeSelection: native)
  }
}
