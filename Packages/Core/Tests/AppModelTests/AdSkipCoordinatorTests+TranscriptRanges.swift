import AdSkip
import Foundation
import Persistence
import PlayerCore
import Testing

@testable import AppModel

/// The transcript view's read of the ranges, and its origin-carrying undo.
extension AdSkipCoordinatorTests {

  /// Replaces the episode's ranges with `ranges`, as a recompute would have stored them.
  private func store(
    _ ranges: [(Double, Double, hostRead: Bool)], for episode: AdSkipLocalEpisode, in harness: Harness
  ) async throws {
    let rowId = try #require(try await harness.episodes.episode(for: episode.identity)?.id)
    try await harness.episodes.replaceRanges([
      rowId: ranges.map {
        AdSkipRange(
          startTime: $0.0, endTime: $0.1, meanAdProbability: 0.9, rulesRevision: AdSkipRules.revision,
          fromStore: false, endsItem: false, fromHostRead: $0.hostRead)
      }
    ])
  }

  @Test func theViewReadMatchesWhatPlaysOnTheSnapAndTheJoin() async throws {
    let harness = try Harness()
    let a = harness.episode(
      "a", transcript: Self.transcript(Self.programme("a", count: 6) + Self.ad + Self.programme("ax")))
    let b = harness.episode(
      "b", transcript: Self.transcript(Self.programme("b", count: 6) + Self.ad + Self.programme("bx")))
    await harness.run([a, b])

    let played = try #require(await harness.coordinator.skipRanges(for: Self.request(b)).first)
    #expect(played.start == 0)
    let shown = await harness.coordinator.transcriptAdRanges(for: b.identity)
    #expect(shown == [TranscriptAdRange(start: played.start, end: played.end, origin: .detected)])

    // Within the player's join gap, ranges are one; beyond it they are two. A joined range is a
    // host read only when every part is.
    try await store([(100, 120, false), (125, 130, true), (200, 210, true)], for: b, in: harness)
    #expect(
      await harness.coordinator.transcriptAdRanges(for: b.identity) == [
        TranscriptAdRange(start: 100, end: 130, origin: .detected),
        TranscriptAdRange(start: 200, end: 210, origin: .hostRead),
      ])
    try await store([(100, 120, true), (128, 140, true)], for: b, in: harness)
    #expect(
      await harness.coordinator.transcriptAdRanges(for: b.identity) == [
        TranscriptAdRange(start: 100, end: 140, origin: .hostRead)
      ])
    try await store([(100, 120, true), (129.5, 140, true)], for: b, in: harness)
    #expect(await harness.coordinator.transcriptAdRanges(for: b.identity).count == 2)
  }

  @Test func theCardsBreaksMatchTheTranscriptViewsSpans() async throws {
    let harness = try Harness()
    let a = harness.episode(
      "a", transcript: Self.transcript(Self.programme("a", count: 6) + Self.ad + Self.programme("ax")))
    await harness.run([a])

    let rows = try await harness.ranges("a").filter {
      AdSkipRules.servedRevisions.contains($0.rulesRevision)
    }
    let breaks = AdSkipBreaks(servedRows: rows)
    let shown = await harness.coordinator.transcriptAdRanges(for: a.identity)

    #expect(breaks.breaks.map { [$0.start, $0.end] } == shown.map { [$0.start, $0.end] })
  }

  @Test func theViewReadAppliesTheSameChecksAsThePlayersRead() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    #expect(await harness.coordinator.transcriptAdRanges(for: b.identity).count == 1)

    harness.fingerprints.set(b.fileURL, size: 77_777)
    #expect(await harness.coordinator.transcriptAdRanges(for: b.identity).isEmpty)
    harness.fingerprints.set(a.fileURL, size: 1)
    await harness.coordinator.setEnabled(false)
    #expect(await harness.coordinator.transcriptAdRanges(for: a.identity).isEmpty)
    #expect(await harness.coordinator.transcriptAdRanges(for: Harness.identity("unknown")).isEmpty)
  }

  @Test func theViewReadDoesNotPutTheEpisodeFirst() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let z = harness.episode("z", transcript: Self.withAd("z"))
    await harness.coordinator.setLocalEpisodes([a, z])
    _ = await harness.coordinator.transcriptAdRanges(for: z.identity)
    await harness.run([a, z])
    #expect(harness.audio.calls.withLock { $0 } == [a.fileURL, z.fileURL])
  }

  @Test func aViewUndoRemovesTheRangeAndSignalsWhenNoTombstoneCanBeBuilt() async throws {
    // A host read with no listener transcript behind it: nothing to tombstone, so no recompute.
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.twoBreaks("a"))
    let b = harness.episode("b", transcript: Self.twoBreaks("b"))
    await harness.run([a, b])
    let shipped = try await harness.ranges("a")
    try await store(shipped.map { ($0.startTime, $0.endTime, false) } + [(200, 225, true)], for: a, in: harness)
    var changes = harness.coordinator.skipRangeChanges().makeAsyncIterator()

    await harness.coordinator.undoRange(identity: a.identity, start: 200, end: 225, origin: .hostRead)
    await harness.coordinator.waitUntilIdle()

    #expect(await changes.next() != nil)
    #expect(Self.hostReads(try await harness.ranges("a")).isEmpty)
    #expect(try await harness.ranges("a").count == shipped.count)
    #expect(try await harness.signatures.allCreatives().contains { $0.kind == .tombstone } == false)
  }

  @Test func aViewUndoOfADetectedRangeStillBuildsItsTombstoneFromTheRowsItDeleted() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let shown = try #require(await harness.coordinator.transcriptAdRanges(for: b.identity).first)

    await harness.coordinator.undoRange(
      identity: b.identity, start: shown.start, end: shown.end, origin: shown.origin)
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.ranges("b").isEmpty)
    #expect(await harness.coordinator.transcriptAdRanges(for: b.identity).isEmpty)
    #expect(try await harness.signatures.allCreatives().contains { $0.kind == .tombstone })
  }

  @Test func aViewUndoOfAJoinedRangeRemovesEveryRowItCovers() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.twoBreaks("a"))
    let b = harness.episode("b", transcript: Self.twoBreaks("b"))
    await harness.run([a, b])
    try await store([(100, 120, false), (125, 130, true), (300, 310, true)], for: a, in: harness)
    let shown = try #require(await harness.coordinator.transcriptAdRanges(for: a.identity).first)
    #expect(shown == TranscriptAdRange(start: 100, end: 130, origin: .detected))
    var changes = harness.coordinator.skipRangeChanges().makeAsyncIterator()

    await harness.coordinator.undoRange(
      identity: a.identity, start: shown.start, end: shown.end, origin: shown.origin)

    // Before the worker runs: both rows are gone and the change is signalled. The far host read
    // is not in the span and stays.
    #expect(await changes.next() != nil)
    #expect(try await harness.ranges("a").map(\.startTime) == [300])
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.signatures.allCreatives().contains { $0.kind == .tombstone })
  }
}

/// Whether the transcript may offer a mark.
extension AdSkipCoordinatorTests {

  @Test func markingIsHiddenWhileAdSkipIsOff() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    await harness.run([a], enabled: false)
    #expect(await harness.coordinator.markingAvailability(for: a.identity) == .hidden)
  }

  @Test func markingIsUnavailableUntilTheEpisodeIsAnalysedAndWhileItsFileHasChanged() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    await harness.run([a], allowed: false)
    #expect(
      await harness.coordinator.markingAvailability(for: a.identity) == .unavailable(.notAnalysed))
    #expect(
      await harness.coordinator.markingAvailability(for: Harness.identity("unknown"))
        == .unavailable(.notAnalysed))

    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()
    #expect(await harness.coordinator.markingAvailability(for: a.identity) == .available)

    harness.fingerprints.set(a.fileURL, size: 77_777)
    #expect(
      await harness.coordinator.markingAvailability(for: a.identity) == .unavailable(.notAnalysed))
  }
}
