import Foundation
import Persistence
import Testing
import WatchProtocol

@testable import Whirr

/// A Watch listen of a received RSS episode becomes a listen on this phone.
@MainActor
@Suite("Watch native progress inbox")
struct WatchNativeProgressInboxTests {
  private let clock = Date(timeIntervalSinceReferenceDate: 800_000_000)

  @MainActor
  final class Link {
    var install: String? = "11111111-2222-3333-4444-555555555555"
    var episodeIDs: [Int64: [String: Int64]] = [:]
    var outcome: RSSPeerListenOutcome? = .applied(localSequence: 1)
    var playingHere: Set<Int64> = []
    var applied:
      [(episodeId: Int64, position: Double, finished: Bool, listenedAt: Date, duration: Double?, now: Date)] = []
    var removed: [Int64] = []
    var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func inbox() -> WatchNativeProgressInbox {
      WatchNativeProgressInbox(
        activeInstallID: { self.install },
        episodeIDs: { feedId, keys in
          (self.episodeIDs[feedId] ?? [:]).filter { keys.contains($0.key) }
        },
        apply: { episodeId, position, finished, listenedAt, duration, now in
          self.applied.append((episodeId, position, finished, listenedAt, duration, now))
          return self.outcome
        },
        isPlayingHere: { self.playingHere.contains($0) },
        removeFromWatch: { self.removed.append($0) },
        now: { self.clock })
    }
  }

  // MARK: Wire fence

  @Test("an oversize or undecodable report is dropped")
  func oversizeAndUndecodableAreDropped() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    let inbox = link.inbox()

    await inbox.receive(Data(count: WatchNativeProgressReport.maxWireBytes + 1))
    await inbox.receive(Data("not a report".utf8))

    #expect(link.applied.isEmpty)
  }

  @Test("a report from another install, or with no install known here, is dropped")
  func foreignOrUnknownInstallIsDropped() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    let inbox = link.inbox()

    await inbox.receive(try data(sequence: 1, entries: [try entry()], install: "99999999-8888-7777-6666-555555555555"))
    link.install = nil
    await inbox.receive(try data(sequence: 1, entries: [try entry()]))

    #expect(link.applied.isEmpty)
  }

  @Test("a replayed sequence is ignored and a higher one is applied")
  func replayedSequenceIsIgnored() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    let inbox = link.inbox()

    await inbox.receive(try data(sequence: 5, entries: [try entry(position: 100)]))
    await inbox.receive(try data(sequence: 5, entries: [try entry(position: 200)]))
    await inbox.receive(try data(sequence: 4, entries: [try entry(position: 300)]))
    #expect(link.applied.count == 1)
    #expect(link.applied.first?.position == 100)

    await inbox.receive(try data(sequence: 6, entries: [try entry(position: 400)]))
    #expect(link.applied.count == 2)
    #expect(link.applied.last?.position == 400)
  }

  @Test("an unknown feed or an unknown episode is dropped")
  func unknownEpisodeIsDropped() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    let inbox = link.inbox()

    await inbox.receive(
      try data(
        sequence: 1,
        entries: [
          try entry(feed: "9", episode: "e1"),
          try entry(feed: "7", episode: "missing"),
          try entry(feed: "not-a-number", episode: "e1"),
        ]))

    #expect(link.applied.isEmpty)
  }

  // MARK: Application

  @Test("a known entry is applied with the entry's values")
  func knownEntryIsApplied() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    link.clock = clock.addingTimeInterval(30)
    let inbox = link.inbox()
    let listenedAt = clock.addingTimeInterval(-120)

    await inbox.receive(
      try data(sequence: 1, entries: [try entry(position: 321, listenedAt: listenedAt, duration: 1_800)]))

    let applied = try #require(link.applied.first)
    #expect(applied.episodeId == 42)
    #expect(applied.position == 321)
    #expect(applied.finished == false)
    #expect(applied.listenedAt == listenedAt)
    #expect(applied.duration == 1_800)
    #expect(applied.now == link.clock)
  }

  @Test("an entry for the episode playing here waits for the phone session to end")
  func playingEpisodeWaits() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    link.playingHere = [42]
    let inbox = link.inbox()

    await inbox.receive(try data(sequence: 1, entries: [try entry(position: 200)]))
    #expect(inbox.pendingCount == 1)
    #expect(link.applied.isEmpty)

    link.playingHere = []
    await inbox.phoneSessionEnded()

    #expect(inbox.pendingCount == 0)
    #expect(link.applied.count == 1)
    #expect(link.applied.first?.position == 200)
  }

  @Test("an entry still playing here when the session ends keeps waiting")
  func stillPlayingEntryKeepsWaiting() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    link.playingHere = [42]
    let inbox = link.inbox()

    await inbox.receive(try data(sequence: 1, entries: [try entry(position: 200)]))
    await inbox.phoneSessionEnded()

    #expect(inbox.pendingCount == 1)
    #expect(link.applied.isEmpty)
  }

  @Test("the newest waiting listen wins when several arrive for one episode")
  func newestWaitingListenWins() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    link.playingHere = [42]
    let inbox = link.inbox()
    let newer = clock.addingTimeInterval(-60)
    let older = clock.addingTimeInterval(-300)

    await inbox.receive(try data(sequence: 1, entries: [try entry(position: 100, listenedAt: newer)]))
    await inbox.receive(try data(sequence: 2, entries: [try entry(position: 150, listenedAt: older)]))
    #expect(inbox.pendingCount == 1)

    link.playingHere = []
    await inbox.phoneSessionEnded()

    #expect(link.applied.count == 1)
    #expect(link.applied.first?.position == 100)
    #expect(link.applied.first?.listenedAt == newer)
  }

  // MARK: Removal

  @Test("an applied finished entry removes the copy from the Watch")
  func appliedFinishRemovesTheCopy() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    let inbox = link.inbox()

    await inbox.receive(try data(sequence: 1, entries: [try entry(position: 3_600, finished: true)]))

    #expect(link.removed == [42])
  }

  @Test("a converged finished entry still removes the copy from the Watch")
  func convergedFinishRemovesTheCopy() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    link.outcome = .rejected(.converged)
    let inbox = link.inbox()

    await inbox.receive(try data(sequence: 1, entries: [try entry(position: 3_600, finished: true)]))

    #expect(link.removed == [42])
  }

  @Test("a rejected finished entry leaves the Watch copy alone")
  func rejectedFinishDoesNotRemoveTheCopy() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    link.outcome = .rejected(.phoneNewer)
    let inbox = link.inbox()

    await inbox.receive(try data(sequence: 1, entries: [try entry(position: 3_600, finished: true)]))

    #expect(link.removed.isEmpty)
  }

  @Test("a waiting finished entry removes the copy when the session ends")
  func waitingFinishRemovesTheCopy() async throws {
    let link = Link()
    link.episodeIDs = [7: ["e1": 42]]
    link.playingHere = [42]
    let inbox = link.inbox()

    await inbox.receive(try data(sequence: 1, entries: [try entry(position: 3_600, finished: true)]))
    #expect(link.removed.isEmpty)

    link.playingHere = []
    await inbox.phoneSessionEnded()

    #expect(link.removed == [42])
  }

  // MARK: Helpers

  private func entry(
    feed: String = "7", episode: String = "e1", position: Double = 120, listenedAt: Date? = nil,
    finished: Bool = false, duration: Double? = 3_600
  ) throws -> WatchNativeProgressEntry {
    let selection = try WatchNativeSelection(feedID: feed, episodeID: episode)
    return try WatchNativeProgressEntry(
      selection: selection, position: position, lastListenedAt: listenedAt ?? clock,
      isFinished: finished, duration: duration)
  }

  private func data(sequence: UInt64, entries: [WatchNativeProgressEntry], install: String? = nil) throws
    -> Data
  {
    let report = try WatchNativeProgressReport(
      watchInstallID: install ?? "11111111-2222-3333-4444-555555555555", sequence: sequence, entries: entries)
    return try WatchWireCodec.encode(report)
  }
}
