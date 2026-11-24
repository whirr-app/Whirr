import AppModel
import Foundation
import Persistence
import Testing
import WatchProtocol

@testable import Whirr

/// On the phone: ask a playing Watch to pause, wait only for the same title, never deny.
@MainActor
@Suite("Watch phone handoff asker")
struct WatchPhoneHandoffAskerTests {
  private let account = try! WatchAccountStamp(
    accountIdentityHash: "account-hash", serverIdentityHash: "server-hash")
  private let now = Date(timeIntervalSinceReferenceDate: 5_000)

  @MainActor
  final class Link {
    var report: WatchPlayingReport?
    var stored: [String: Date] = [:]
    var sent: [(request: WatchHandoffRequest, wait: Duration)] = []
    var replyFor: (WatchHandoffRequest) -> WatchHandoffReply? = { _ in nil }
    var clock = Date(timeIntervalSinceReferenceDate: 5_000)

    func asker(stamp: WatchAccountStamp?) -> WatchPhoneHandoffAsker {
      WatchPhoneHandoffAsker(
        report: { self.report }, authenticatedStamp: { stamp },
        send: { data, wait in
          let request = try! WatchWireCodec.decode(WatchHandoffRequest.self, from: data)
          self.sent.append((request, wait))
          return self.replyFor(request).flatMap { try? WatchWireCodec.encode($0) }
        },
        storedListen: { item, _ in self.stored[item] }, now: { self.clock })
    }
  }

  private func report(playing: Bool, item: String = "book", observedAt: Date? = nil) throws -> WatchPlayingReport {
    try WatchPlayingReport(
      accountStamp: account, selection: WatchABSSelection(itemID: item, episodeID: nil), playing: playing,
      observedAt: observedAt ?? now)
  }

  private func paused(
    _ request: WatchHandoffRequest, item: String = "book", position: Double = 120, listened: Date?
  ) throws -> WatchHandoffReply {
    try .paused(
      request, selection: WatchABSSelection(itemID: item, episodeID: nil), position: position,
      lastListenedAt: listened)
  }

  @Test("a Watch that is not playing is never asked")
  func idleWatchIsNotAsked() async throws {
    let link = Link()
    link.report = try report(playing: false)
    let position = await link.asker(stamp: account).positionForStart(itemID: "book", episodeID: nil)

    #expect(position == nil)
    #expect(link.sent.isEmpty)
  }

  @Test("no report, a stale report and another account's report are never asked")
  func absentStaleOrForeignReportIsNotAsked() async throws {
    let link = Link()
    let asker = link.asker(stamp: account)
    _ = await asker.positionForStart(itemID: "book", episodeID: nil)
    link.report = try report(playing: true, observedAt: now.addingTimeInterval(-WatchPlayingReport.expiry - 1))
    _ = await asker.positionForStart(itemID: "book", episodeID: nil)
    let other = try WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "server-hash")
    link.report = try report(playing: true)
    _ = await link.asker(stamp: other).positionForStart(itemID: "book", episodeID: nil)

    #expect(link.sent.isEmpty)
  }

  @Test("the same title waits up to 3 s and uses the reply position when it is newer than the phone's listen")
  func sameTitleUsesANewerReplyPosition() async throws {
    let link = Link()
    link.report = try report(playing: true)
    link.stored["book"] = now.addingTimeInterval(-600)
    link.replyFor = { try? self.paused($0, position: 321, listened: self.now) }

    let position = await link.asker(stamp: account).positionForStart(itemID: "book", episodeID: nil)

    #expect(position == 321)
    #expect(link.sent.count == 1)
    #expect(link.sent.first?.wait == .seconds(3))
  }

  @Test("a reply that is not newer than the phone's own listen is not used")
  func olderReplyIsIgnored() async throws {
    let link = Link()
    link.report = try report(playing: true)
    link.stored["book"] = now
    link.replyFor = { try? self.paused($0, position: 321, listened: self.now.addingTimeInterval(-5)) }

    let position = await link.asker(stamp: account).positionForStart(itemID: "book", episodeID: nil)

    #expect(position == nil)
  }

  @Test("a reply with no listen time is not used")
  func replyWithoutListenTimeIsIgnored() async throws {
    let link = Link()
    link.report = try report(playing: true)
    link.replyFor = { try? self.paused($0, listened: nil) }

    let position = await link.asker(stamp: account).positionForStart(itemID: "book", episodeID: nil)

    #expect(position == nil)
  }

  @Test("no answer, an idle answer or a reply to another request plays on without a position")
  func failuresPlayAnyway() async throws {
    let link = Link()
    link.report = try report(playing: true)
    let asker = link.asker(stamp: account)
    #expect(await asker.positionForStart(itemID: "book", episodeID: nil) == nil)
    link.replyFor = { .idle($0) }
    #expect(await asker.positionForStart(itemID: "book", episodeID: nil) == nil)
    link.replyFor = { _ in
      try? self.paused(try! WatchHandoffRequest(accountStamp: self.account, selection: nil), listened: self.now)
    }
    #expect(await asker.positionForStart(itemID: "book", episodeID: nil) == nil)
    #expect(link.sent.count == 3)
  }

  @Test("another title is asked without waiting for a position")
  func otherTitleIsFireAndForget() async throws {
    let link = Link()
    link.report = try report(playing: true, item: "book")
    link.replyFor = { try? self.paused($0, item: "book", position: 77, listened: self.now) }
    let asker = link.asker(stamp: account)

    let position = await asker.positionForStart(itemID: "different", episodeID: nil)
    await asker.unawaitedSend?.value

    #expect(position == nil)
    #expect(link.sent.count == 1)
    #expect(link.sent.first?.request.selection == (try WatchABSSelection(itemID: "different", episodeID: nil)))
  }

  @Test("a native feed title asks with no selection and does not wait")
  func nativeFeedTitleAsksWithoutASelection() async throws {
    let link = Link()
    link.report = try report(playing: true)
    let asker = link.asker(stamp: account)

    let position = await asker.positionForStart(itemID: "rss:7", episodeID: "e")
    await asker.unawaitedSend?.value

    #expect(position == nil)
    #expect(link.sent.count == 1)
    #expect(link.sent.first?.request.selection == nil)
  }

  @Test("a resume asks once when the Watch is playing and not again right after")
  func resumeAsksOnceWithinTheRepeatWindow() async throws {
    let link = Link()
    link.report = try report(playing: true)
    let asker = link.asker(stamp: account)
    let selection = try WatchABSSelection(itemID: "book", episodeID: nil)

    let first = asker.askOnResume(selection: selection)
    await first?.value
    link.clock = now.addingTimeInterval(WatchPhoneHandoffAsker.repeatWindow - 1)
    let second = asker.askOnResume(selection: selection)
    link.clock = now.addingTimeInterval(WatchPhoneHandoffAsker.repeatWindow + 1)
    link.report = try report(playing: true, observedAt: link.clock)
    let third = asker.askOnResume(selection: selection)
    await third?.value

    #expect(first != nil)
    #expect(second == nil)
    #expect(third != nil)
    #expect(link.sent.count == 2)
  }

  @Test("a resume right after a start does not ask again")
  func startThenResumeAsksOnce() async throws {
    let link = Link()
    link.report = try report(playing: true)
    let asker = link.asker(stamp: account)

    _ = await asker.positionForStart(itemID: "book", episodeID: nil)
    let resume = asker.askOnResume(selection: try WatchABSSelection(itemID: "book", episodeID: nil))

    #expect(resume == nil)
    #expect(link.sent.count == 1)
  }

  @Test("a Watch playing a received RSS episode is left to the native ask, for a start and a resume")
  func watchPlayingANativeEpisodeIsNotAskedForAHandoff() async throws {
    let link = Link()
    link.report = try WatchPlayingReport(
      accountStamp: account, selection: nil, playing: true, observedAt: now,
      nativeSelection: WatchNativeSelection(feedID: "7", episodeID: "e"))
    let asker = link.asker(stamp: account)

    let position = await asker.positionForStart(itemID: "book", episodeID: nil)
    await asker.unawaitedSend?.value
    let resume = asker.askOnResume(selection: try WatchABSSelection(itemID: "book", episodeID: nil))

    #expect(position == nil)
    #expect(resume == nil)
    #expect(link.sent.isEmpty)
  }

  @Test("a resume while the Watch is not playing asks nothing")
  func resumeWithIdleWatchAsksNothing() async throws {
    let link = Link()
    link.report = try report(playing: false)

    let resume = link.asker(stamp: account).askOnResume(selection: nil)

    #expect(resume == nil)
    #expect(link.sent.isEmpty)
  }
}

@MainActor
@Suite("Watch command scope")
struct WatchCommandScopeTests {
  @Test("work run for a Watch command is executing, and recent for a short while afterwards")
  func scopeCoversExecutionAndItsAftermath() async {
    var clock = Date(timeIntervalSinceReferenceDate: 100)
    let scope = WatchCommandScope(now: { clock })
    #expect(scope.isExecuting == false)
    #expect(scope.isRecent == false)

    var during: (Bool, Bool)?
    await scope.run { during = (scope.isExecuting, scope.isRecent) }
    #expect(during?.0 == true)
    #expect(during?.1 == true)
    #expect(scope.isExecuting == false)
    #expect(scope.isRecent)

    clock = clock.addingTimeInterval(WatchCommandScope.grace + 1)
    #expect(scope.isRecent == false)
  }

  @Test("overlapping commands keep the scope open until the last one ends")
  func nestedRunsStayOpen() async {
    let scope = WatchCommandScope()
    var innerSawExecuting = false
    await scope.run {
      await scope.run {}
      innerSawExecuting = scope.isExecuting
    }
    #expect(innerSawExecuting)
    #expect(scope.isExecuting == false)
  }
}

/// A Watch `.play` hands its paused position to the phone's start for that title only.
@MainActor
struct WatchCommandScopeHandoverTests {
  @Test func aHandedPositionAppliesOnlyToItsTitleWhileTheCommandRuns() async {
    let scope = WatchCommandScope()
    let seen = await scope.run(handing: ("book", nil, 61.5)) {
      (scope.handedPosition(itemID: "book", episodeID: nil), scope.handedPosition(itemID: "other", episodeID: nil))
    }
    #expect(seen.0 == 61.5)
    #expect(seen.1 == nil)
    #expect(scope.handedPosition(itemID: "book", episodeID: nil) == nil)
  }
}
