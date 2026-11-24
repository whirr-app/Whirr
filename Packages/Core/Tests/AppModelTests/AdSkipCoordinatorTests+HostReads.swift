import AdSkip
import Foundation
import Persistence
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// Host reads: a complete listener transcript adds the spans `HostReadSpans` proposes, laid over
/// the ranges ad skip already serves, which never move for it.
extension AdSkipCoordinatorTests {

  final class FakeListenerTranscripts: CompleteEpisodeTranscriptReading {
    private let transcripts = Mutex<[AdSkipEpisodeIdentity: CompleteEpisodeTranscript]>([:])
    private let continuations = Mutex<[AsyncStream<AdSkipEpisodeIdentity>.Continuation]>([])
    private let revision = Mutex(0)

    /// Sets or removes the episode's complete transcript, under a new file name, and reports it.
    func set(_ identity: AdSkipEpisodeIdentity, _ transcript: Transcript?) {
      let name = revision.withLock { value -> String in
        value += 1
        return "listener-\(value).words"
      }
      transcripts.withLock {
        $0[identity] = transcript.map { CompleteEpisodeTranscript(fileName: name, transcript: $0) }
      }
      for continuation in continuations.withLock({ $0 }) { continuation.yield(identity) }
    }

    func completeTranscript(for identity: AdSkipEpisodeIdentity) async -> CompleteEpisodeTranscript? {
      transcripts.withLock { $0[identity] }
    }

    func completeTranscriptChanges() async -> AsyncStream<AdSkipEpisodeIdentity> {
      let (stream, continuation) = AsyncStream<AdSkipEpisodeIdentity>.makeStream()
      continuations.withLock { $0.append(continuation) }
      return stream
    }
  }

  static let laterAd = (0..<40).map { "zetaad\($0)" }

  /// What ad skip hears of an episode: `ad` from 100.0 s to 119.9 s and `laterAd` from 160.0 s
  /// to 179.9 s, in 320 s of programme of its own.
  static func twoBreaks(_ tag: String) -> Transcript {
    transcript(
      programme(tag, count: 200) + ad + programme(tag + "x", count: 80) + laterAd
        + programme(tag + "y", count: 280))
  }

  /// The listener's transcript of the same 320 s: programme, with a host read whose sponsor is
  /// first named at `named` seconds, heading a sentence, and whose address is given at `address`.
  static func listened(_ tag: String, named: Double, address: Double) -> Transcript {
    var words = programme(tag + "l", count: 640)
    let (first, action) = (Int(named * 2), Int(address * 2))
    words[first - 1] = "Done."
    words.replaceSubrange(first..<first + 6, with: ["Fuse", "Energy", "keeps", "my", "lights", "on."])
    words.replaceSubrange(action..<action + 5, with: ["Go", "to", "fuseenergy.com", "slash", "show."])
    return transcript(words)
  }

  /// A read from 200.0 s whose address is in the step from 220 s: served to 224.9 s, the end of
  /// that step's last word, clear of both breaks.
  static func clearRead(_ tag: String) -> Transcript { listened(tag, named: 200, address: 220) }

  static func hostReads(_ ranges: [AdSkipRange]) -> [AdSkipRange] { ranges.filter(\.fromHostRead) }
  static func shipped(_ ranges: [AdSkipRange]) -> [AdSkipRange] {
    ranges.filter { $0.fromHostRead == false }
  }

  @Test func aCompleteListenerTranscriptAddsItsHostRead() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.twoBreaks("a"))
    let b = harness.episode("b", transcript: Self.twoBreaks("b"))
    harness.listener.set(a.identity, Self.clearRead("a"))
    await harness.run([a, b])

    let ranges = try await harness.ranges("a")
    let read = try #require(Self.hostReads(ranges).first)
    #expect(Self.hostReads(ranges).count == 1)
    #expect(abs(read.startTime - 200) < 1e-9 && abs(read.endTime - 224.9) < 1e-9)
    #expect(read.fromStore == false && read.creativeId == nil && read.fromTail == false)
    #expect(read.rulesRevision == AdSkipRules.revision)
    #expect(Self.shipped(ranges).isEmpty == false)
    #expect(Self.hostReads(try await harness.ranges("b")).isEmpty)
    // Served with the rest.
    let served = await harness.coordinator.skipRanges(for: Self.request(a))
    #expect(served.contains { abs($0.start - 200) < 1e-9 && abs($0.end - 224.9) < 1e-9 })
  }

  @Test func noCompleteTranscriptAndNoReaderAddNothing() async throws {
    // The reader answers nil for a partial transcript and for one of an older file.
    let harness = try Harness()
    await harness.run([
      harness.episode("a", transcript: Self.twoBreaks("a")),
      harness.episode("b", transcript: Self.twoBreaks("b")),
    ])
    #expect(Self.hostReads(try await harness.ranges("a")).isEmpty)

    let unread = try Harness(readsListenerTranscripts: false)
    let a = unread.episode("a", transcript: Self.twoBreaks("a"))
    unread.listener.set(a.identity, Self.clearRead("a"))
    await unread.run([a, unread.episode("b", transcript: Self.twoBreaks("b"))])
    #expect(Self.hostReads(try await unread.ranges("a")).isEmpty)
    #expect(try await unread.ranges("a").isEmpty == false)
  }

  @Test func anEpisodeNotYetAnalysedHasNoHostReads() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.twoBreaks("a"))
    harness.listener.set(a.identity, Self.clearRead("a"))
    await harness.run([a, harness.episode("b", transcript: Self.twoBreaks("b"))])
    let row = try #require(try await harness.episodes.episode(for: a.identity))
    let store = SignatureStore(creatives: [])

    let analysed = try await harness.coordinator.hostReadRanges(
      for: row, isAnalysed: true, shipped: [], silences: [], showTitle: nil, store: store,
      duringRecompute: false)
    #expect(analysed.ranges.count == 1)
    let waiting = try await harness.coordinator.hostReadRanges(
      for: row, isAnalysed: false, shipped: [], silences: [], showTitle: nil, store: store,
      duringRecompute: false)
    #expect(waiting.ranges.isEmpty)
  }

  @Test func theShippedRangesAreTheSameWithAndWithoutATranscript() async throws {
    // The read opens at 85 s and gives its address at 125 s: it runs over the first break, and
    // ends 30 s before the second.
    let reading = Self.listened("a", named: 85, address: 125)
    var results: [(ranges: [AdSkipRange], creatives: Int, windows: [[TimeSpan]])] = []
    for transcript in [nil, reading] {
      let harness = try Harness()
      let a = harness.episode("a", transcript: Self.twoBreaks("a"))
      if let transcript { harness.listener.set(a.identity, transcript) }
      await harness.run([a, harness.episode("b", transcript: Self.twoBreaks("b"))])
      results.append(
        (
          try await harness.ranges("a"), try await harness.signatures.allCreatives().count,
          windowCalls(harness, a)
        ))
    }
    let (without, with) = (results[0], results[1])
    #expect(Self.hostReads(without.ranges).isEmpty)
    #expect(Self.shipped(with.ranges) == without.ranges)
    // What is left of the read lies beside the shipped ranges, never over one.
    let reads = Self.hostReads(with.ranges)
    #expect(reads.isEmpty == false)
    #expect(abs((reads.first?.startTime ?? 0) - 85) < 1e-9)
    for read in reads {
      #expect(read.endTime - read.startTime >= HostReadSpans.minimumServedSeconds)
      #expect(without.ranges.allSatisfy { $0.endTime <= read.startTime || read.endTime <= $0.startTime })
    }
    // It teaches nothing and asks for no audio to be transcribed.
    #expect(with.creatives == without.creatives)
    #expect(with.windows == without.windows)
  }

  @Test func anUndoneHostReadStaysUndoneAndItsTombstoneIsKept() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.twoBreaks("a"))
    let b = harness.episode("b", transcript: Self.twoBreaks("b"))
    harness.listener.set(a.identity, Self.clearRead("a"))
    await harness.run([a, b])
    let before = Self.shipped(try await harness.ranges("a"))
    let others = try await harness.ranges("b")
    let skipped = try #require(
      await harness.coordinator.skipRanges(for: Self.request(a)).first { abs($0.start - 200) < 1e-9 })

    await harness.coordinator.undoSkip(skipped, for: Self.request(a))
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("a") == before)
    let tombstone = try #require(
      try await harness.signatures.allCreatives().first { $0.kind == .tombstone })

    // Each recompute proposes the read again, drops it, and counts its tombstone as seen, so the
    // Undo outlives the 90 days an unseen one is kept.
    for _ in 0..<3 {
      harness.clock.advance(days: 40)
      await harness.coordinator.forceRecompute()
      await harness.coordinator.waitUntilIdle()
      #expect(try await harness.ranges("a") == before)
    }
    let kept = try #require(
      try await harness.signatures.allCreatives().first { $0.id == tombstone.id })
    #expect(kept.lastSeen > tombstone.lastSeen)
    // It vetoes nothing the library matches.
    #expect(try await harness.ranges("b") == others)
  }

  @Test func aTranscriptThatCompletesOrGoesAwayIsAppliedWithoutACharger() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.twoBreaks("a"))
    await harness.run([a, harness.episode("b", transcript: Self.twoBreaks("b"))])
    let before = try await harness.ranges("a")
    #expect(Self.hostReads(before).isEmpty)
    let scored = harness.scorer.scoredSteps.withLock { $0 }

    await harness.coordinator.setAllowed(false)
    await harness.coordinator.waitUntilIdle()
    harness.listener.set(a.identity, Self.clearRead("a"))
    await harness.coordinator.noteCompleteTranscriptChange(a.identity)
    await harness.coordinator.waitUntilIdle()
    #expect(Self.hostReads(try await harness.ranges("a")).count == 1)
    #expect(Self.shipped(try await harness.ranges("a")) == before)
    // Every 5 s step of the 320 s transcript, once.
    #expect(harness.scorer.scoredSteps.withLock { $0 } - scored == 64)

    harness.listener.set(a.identity, nil)
    await harness.coordinator.noteCompleteTranscriptChange(a.identity)
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("a") == before)
  }

  @Test func aTranscriptIsScoredOncePerFile() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.twoBreaks("a"))
    harness.listener.set(a.identity, Self.clearRead("a"))
    await harness.run([a, harness.episode("b", transcript: Self.twoBreaks("b"))])
    let scored = harness.scorer.scoredSteps.withLock { $0 }

    await harness.coordinator.forceRecompute()
    await harness.coordinator.waitUntilIdle()
    #expect(harness.scorer.scoredSteps.withLock { $0 } == scored)

    harness.listener.set(a.identity, Self.clearRead("a"))
    await harness.coordinator.forceRecompute()
    await harness.coordinator.waitUntilIdle()
    #expect(harness.scorer.scoredSteps.withLock { $0 } - scored == 64)
  }

  @Test func theReadersChangesReachTheCoordinator() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.twoBreaks("a"))
    let b = harness.episode("b", transcript: Self.twoBreaks("b"))
    let (episodes, episodeInput) = AsyncStream<[AdSkipLocalEpisode]>.makeStream()
    let (enabled, enabledInput) = AsyncStream<Bool>.makeStream()
    let (allowed, allowedInput) = AsyncStream<Bool>.makeStream()
    await harness.coordinator.start(localEpisodes: episodes, isEnabled: enabled, isAllowed: allowed)
    episodeInput.yield([a, b])
    enabledInput.yield(true)
    allowedInput.yield(true)
    await harness.coordinator.drainBacklog()
    #expect(try await harness.ranges("a").isEmpty == false)

    harness.listener.set(a.identity, Self.clearRead("a"))
    _ = await awaitCondition(
      "the host read to be stored",
      observing: { "\((try? await harness.ranges("a"))?.count ?? -1) ranges for a" },
      until: { Self.hostReads((try? await harness.ranges("a")) ?? []).isEmpty == false })
    #expect(Self.hostReads(try await harness.ranges("a")).count == 1)
    await harness.coordinator.stop()
  }
}
