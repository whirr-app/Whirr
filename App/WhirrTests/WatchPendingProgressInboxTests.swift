import Foundation
import Persistence
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch pending progress inbox and start gate")
struct WatchPendingProgressInboxTests {
  private let stamp = try! WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")
  private let otherStamp = try! WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "server")
  private let listenedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

  // MARK: Inbox fence

  @Test("a report for another account is dropped")
  func staleStampIsDropped() throws {
    let inbox = WatchPendingProgressInbox(currentStamp: { stamp })
    #expect(inbox.receive(try report(stamp: otherStamp, sequence: 1)) == false)
    #expect(inbox.report == nil)
  }

  @Test("a queued report no newer than the held one is dropped")
  func olderSequenceIsDropped() throws {
    let inbox = WatchPendingProgressInbox(currentStamp: { stamp })
    #expect(inbox.receive(try report(sequence: 5, position: 50)))
    #expect(inbox.receive(try report(sequence: 4, position: 40)) == false)
    #expect(inbox.receive(try report(sequence: 5, position: 45)) == false)
    #expect(inbox.report?.entry(itemID: "book", episodeID: nil)?.position == 50)
  }

  @Test("a query reply replaces the held report whatever its sequence")
  func replyAlwaysReplaces() throws {
    let inbox = WatchPendingProgressInbox(currentStamp: { stamp })
    inbox.receive(try report(sequence: 9, position: 90))
    #expect(inbox.receive(try report(sequence: 1, position: 10), isReply: true))
    #expect(inbox.report?.sequence == 1)
  }

  @Test("a held report is hidden once the account changes")
  func accountChangeHidesReport() throws {
    final class Current { var stamp: WatchAccountStamp? }
    let current = Current()
    current.stamp = stamp
    let inbox = WatchPendingProgressInbox(currentStamp: { current.stamp })
    inbox.receive(try report(sequence: 1))
    current.stamp = otherStamp
    #expect(inbox.report == nil)
  }

  @Test("a report arriving before bootstrap is dropped, not queued")
  func preBootstrapReportIsDropped() throws {
    let inbox = WatchPendingProgressInbox(currentStamp: { stamp })
    let data = try WatchWireCodec.encode(try report(sequence: 1))
    let cold = WatchPhoneBridge(bootstrap: {}, isDatabaseAvailable: { false })
    cold.pendingProgressInbox = { inbox }
    cold.receivePendingProgress(data)
    #expect(inbox.report == nil)
    let warm = WatchPhoneBridge(bootstrap: {}, isDatabaseAvailable: { true })
    warm.pendingProgressInbox = { inbox }
    warm.receivePendingProgress(data)
    #expect(inbox.report?.sequence == 1)
  }

  // MARK: Start gate

  @Test("a reachable Watch that uploaded leaves the normal start")
  func queryReplyWithoutEntryStartsNormally() async throws {
    let gate = try gate(reply: report(sequence: 2, entries: []))
    #expect(await gate.position(itemID: "book", episodeID: nil) == nil)
  }

  @Test("a reachable Watch that could not upload gives its position")
  func queryReplyWithEntryGivesWatchPosition() async throws {
    let gate = try gate(reply: report(sequence: 2, position: 240))
    #expect(await gate.position(itemID: "book", episodeID: nil) == 240)
  }

  @Test("without an answer the held report gives the Watch position")
  func fallbackGivesWatchPosition() async throws {
    let gate = try gate(reply: nil)
    #expect(await gate.position(itemID: "book", episodeID: nil) == 180)
  }

  @Test("a newer phone listen keeps the phone's position")
  func newerPhoneProgressWins() async throws {
    let gate = try gate(
      reply: nil, stored: StoredAudioProgress(position: 60, isFinished: false, changedAt: listenedAt + 600))
    #expect(await gate.position(itemID: "book", episodeID: nil) == nil)
  }

  @Test("an older phone listen gives the Watch position")
  func olderPhoneProgressLoses() async throws {
    let gate = try gate(
      reply: nil, stored: StoredAudioProgress(position: 60, isFinished: false, changedAt: listenedAt - 600))
    #expect(await gate.position(itemID: "book", episodeID: nil) == 180)
  }

  @Test("a title the Watch never reported, such as an RSS episode, is not queried")
  func unreportedTitleIsUntouched() async throws {
    var queries = 0
    let gate = try gate(reply: nil, onQuery: { queries += 1 })
    #expect(await gate.position(itemID: "rss-feed-1", episodeID: "episode") == nil)
    #expect(queries == 0)
  }

  @Test("the title already loaded on the phone is not queried")
  func activeTitleIsUntouched() async throws {
    var queries = 0
    let gate = try gate(reply: nil, active: true, onQuery: { queries += 1 })
    #expect(await gate.position(itemID: "book", episodeID: nil) == nil)
    #expect(queries == 0)
  }

  // MARK: Helpers

  private func gate(
    reply: WatchPendingProgressReport?, stored: StoredAudioProgress? = nil, active: Bool = false,
    onQuery: @escaping @MainActor () -> Void = {}
  ) throws -> WatchPendingProgressStartGate {
    let inbox = WatchPendingProgressInbox(currentStamp: { stamp })
    inbox.receive(try report(sequence: 1, position: 180))
    return WatchPendingProgressStartGate(
      inbox: inbox, isActive: { _, _ in active },
      query: { _ in
        onQuery()
        return reply
      },
      stored: { _, _ in stored }, now: { listenedAt + 3_600 })
  }

  private func report(
    stamp: WatchAccountStamp? = nil, sequence: UInt64, position: Double = 180,
    entries: [WatchPendingProgressEntry]? = nil
  ) throws -> WatchPendingProgressReport {
    let entry = try WatchPendingProgressEntry(
      selection: WatchABSSelection(itemID: "book", episodeID: nil), position: position,
      lastListenedAt: listenedAt, isFinished: false, duration: 3_600)
    return try WatchPendingProgressReport(
      accountStamp: stamp ?? self.stamp, sequence: sequence, entries: entries ?? [entry], downloaded: [])
  }
}
