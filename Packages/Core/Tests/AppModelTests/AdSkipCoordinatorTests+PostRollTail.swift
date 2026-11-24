import AdSkip
import Foundation
import Persistence
import Testing

@testable import AppModel

/// The post-roll tail: an episode whose last stretch follows a stitch
/// silence and holds none of its show's own audio has that stretch transcribed, outside the index
/// view, and a stretch that scores as an ad is skipped to the end of the item.
extension AdSkipCoordinatorTests {

  /// 200 programme words, a 6 s outro sting every episode of the show plays from 100.0 s, then
  /// `tail` words: 40 of its own by default, a one-off post-roll from 106.0 s to 125.9 s.
  static func withOutro(_ tag: String, tail: [String]? = nil) -> Transcript {
    transcript(
      programme(tag, count: 200) + (0..<12).map { "outro\($0)" }
        + (tail ?? programme(tag + "post", count: 40)))
  }

  /// The windows transcribed for `episode` that reach the end of its file.
  func tailCalls(_ harness: Harness, _ episode: AdSkipLocalEpisode, duration: Double) -> [TimeSpan] {
    windowCalls(harness, episode).flatMap { $0 }.filter { abs($0.end - duration) < 1e-6 }
  }

  /// The windows transcribed for `episode` that start before `time`. A short recurring run, such
  /// as an outro, has stage 2 listen for 10 s after it (`StingSegment`), so episodes here are
  /// heard after their shared audio whether or not a tail is.
  func callsStarting(
    _ harness: Harness, _ episode: AdSkipLocalEpisode, before time: Double
  ) -> [TimeSpan] {
    windowCalls(harness, episode).flatMap { $0 }.filter { $0.start < time }
  }

  @Test func aOneOffPostRollAfterTheShowsOutroIsSkippedToTheEnd() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withOutro("a"))
    // b plays the same outro, then programme of its own; it has no stitch silence.
    let b = harness.episode("b", transcript: Self.withOutro("b"))
    // The stitch gap, as Empire 122's: the outro's alignment ends inside it.
    harness.audio.set(a.fileURL, [Silence(start: 105.4, end: 106.6)])
    await harness.run([a, b])

    // From 12.5 s before the silence to the end of the file, and nothing else.
    let tail = tailCalls(harness, a, duration: 126)
    #expect(tail.count == 1)
    #expect(abs((tail.first?.start ?? 0) - 92.9) < 1e-6)
    #expect(tailCalls(harness, b, duration: 126) == [])
    #expect(try await coverage(harness, "a").contains { $0.start <= 92.9 && $0.end >= 126 })
    // The outro is too short for stage 1, and its alignment is the plan's same-show evidence.
    let plan = try #require(try await Self.storedPlan(harness, Harness.identity("a")))
    #expect(plan.windows.isEmpty)
    #expect(plan.sameShowEdges.isEmpty == false)
    #expect(plan.sameShowEdges.allSatisfy { $0.start >= 99 && $0.end <= 107 })
    #expect(try await harness.episodes.allEpisodes().allSatisfy { $0.state == .analysed })
    // Served from the silence's start, and skipping it finishes the item.
    let ranges = try await harness.ranges("a")
    #expect(ranges.count == 1)
    let range = try #require(ranges.first)
    #expect(abs(range.startTime - 105.4) < 1e-9)
    #expect(range.endTime == 126)
    #expect(range.endsItem && range.fromTail)
    #expect(range.fromStore == false && range.creativeId == nil)
    // Its start looks back for nothing more: the tail window is all it costs.
    #expect(windowCalls(harness, a).flatMap { $0 }.allSatisfy { $0.start >= 92.9 - 1e-6 })
    // The tail feeds no index view: b matches nothing, and nothing is learned from it.
    #expect(try await harness.ranges("b").isEmpty)
    #expect(try await harness.signatures.allCreatives().isEmpty)
  }

  @Test func aTailThatScoresAsProgrammeIsNotSkipped() async throws {
    let harness = try Harness()
    harness.scorer.perStep.withLock { $0 = { $0.contains("apost") ? 0.49 : 0.9 } }
    let a = harness.episode("a", transcript: Self.withOutro("a"))
    harness.audio.set(a.fileURL, [Silence(start: 105.4, end: 106.6)])
    await harness.run([a, harness.episode("b", transcript: Self.withOutro("b"))])

    #expect(tailCalls(harness, a, duration: 126).count == 1)
    #expect(try await harness.ranges("a").isEmpty)
  }

  @Test func aPostRollTheLibraryAlreadySkipsIsNotProposedAgain() async throws {
    let harness = try Harness()
    // Another show plays the same post-roll, so repetition keeps it and the tail adds nothing.
    let a = harness.episode("a", transcript: Self.transcript(Self.programme("a", count: 200) + Self.ad))
    let c = harness.episode(
      "c", transcript: Self.transcript(Self.programme("c", count: 200) + Self.ad), show: "rss:2")
    harness.audio.set(a.fileURL, [Silence(start: 99.4, end: 100.0)])
    await harness.run([a, c])

    let ranges = try await harness.ranges("a")
    #expect(ranges.count == 1)
    #expect(ranges.allSatisfy { $0.fromTail == false && $0.endTime >= 119.9 })
  }

  @Test func theShowsOwnCreditsAfterTheSilenceAreNotTranscribed() async throws {
    let harness = try Harness()
    // Both play the same 12 s of credits after the silence: too short for stage 1, and the
    // show's own.
    let credits = (0..<24).map { "credits\($0)" }
    let a = harness.episode("a", transcript: Self.transcript(Self.programme("a", count: 200) + credits))
    let b = harness.episode("b", transcript: Self.transcript(Self.programme("b", count: 200) + credits))
    harness.audio.set(a.fileURL, [Silence(start: 99.4, end: 100.0)])
    await harness.run([a, b])

    // The tail would open at 86.9 s; only the look after the credits is heard.
    #expect(callsStarting(harness, a, before: 99) == [])
    #expect(callsStarting(harness, b, before: 99) == [])
    #expect(try await harness.episodes.allEpisodes().allSatisfy { $0.state == .analysed })
  }

  @Test func anotherShowsAudioAfterTheSilenceIsTranscribed() async throws {
    let harness = try Harness()
    // The same 12 s, played by another show: a cross-promo, which the same-show rule leaves alone.
    let promo = (0..<24).map { "xpromo\($0)" }
    let a = harness.episode("a", transcript: Self.transcript(Self.programme("a", count: 200) + promo))
    let c = harness.episode(
      "c", transcript: Self.transcript(Self.programme("c", count: 200) + promo), show: "rss:2")
    harness.audio.set(a.fileURL, [Silence(start: 99.4, end: 100.0)])
    await harness.run([a, c])

    #expect(callsStarting(harness, a, before: 99).map(\.start) == [86.9])
    #expect(tailCalls(harness, a, duration: 112).count == 1)
    #expect(callsStarting(harness, c, before: 99) == [])
  }

  // MARK: - Undo

  @Test func anUndoneTailStaysUndoneAcrossARecomputeAndARelaunch() async throws {
    let first = try Harness()
    let a = first.episode("a", transcript: Self.withOutro("a"))
    let b = first.episode("b", transcript: Self.withOutro("b"))
    first.audio.set(a.fileURL, [Silence(start: 105.4, end: 106.6)])
    await first.run([a, b])
    let skipped = try #require(await first.coordinator.skipRanges(for: Self.request(a)).first)
    #expect(skipped.endsItem)

    await first.coordinator.undoSkip(skipped, for: Self.request(a))
    await first.coordinator.waitUntilIdle()
    #expect(try await first.ranges("a").isEmpty)
    let tombstones = try await first.signatures.allCreatives().filter { $0.kind == .tombstone }
    #expect(tombstones.count == 1)

    // An unrelated arrival recomputes the library; the tail is proposed again and dropped.
    let n = first.episode("n", transcript: Self.transcript(Self.programme("n", count: 160)))
    await first.coordinator.setLocalEpisodes([a, b, n])
    await first.coordinator.waitUntilIdle()
    #expect(try await first.ranges("a").isEmpty)

    let relaunched = try Harness(reusing: first)
    relaunched.audio.set(a.fileURL, [Silence(start: 105.4, end: 106.6)])
    await relaunched.run([a, b, n])
    #expect(try await relaunched.ranges("a").isEmpty)
    #expect(await relaunched.coordinator.skipRanges(for: Self.request(a)).isEmpty)
  }

  @Test func anUndoneTailVetoesNoRepetitionElsewhere() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withOutro("a"))
    let b = harness.episode("b", transcript: Self.withOutro("b"))
    // Two episodes of another show share an ad mid-programme, which repetition skips.
    let c = harness.episode("c", transcript: Self.withAd("c"), show: "rss:2")
    let d = harness.episode("d", transcript: Self.withAd("d"), show: "rss:2")
    harness.audio.set(a.fileURL, [Silence(start: 105.4, end: 106.6)])
    let library = [a, b, c, d]
    await harness.run(library)
    let before = try await harness.ranges("c", show: "rss:2")
    #expect(before.count == 1)
    let skipped = try #require(await harness.coordinator.skipRanges(for: Self.request(a)).first)

    await harness.coordinator.undoSkip(skipped, for: Self.request(a))
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.ranges("c", show: "rss:2").map(\.startTime) == before.map(\.startTime))
    #expect(try await harness.ranges("d", show: "rss:2").count == 1)
    // The tombstone is written over the tail range alone.
    let tombstone = try #require(
      try await harness.signatures.allCreatives().first { $0.kind == .tombstone })
    #expect(tombstone.startTime >= 105.4 - 1e-9)
  }

  @Test func theWholeFileModeAddsNoTail() async throws {
    let harness = try Harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Self.withOutro("a"))
    harness.audio.set(a.fileURL, [Silence(start: 105.4, end: 106.6)])
    await harness.run([a])

    #expect(windowCalls(harness, a) == [[TimeSpan(start: 0, end: 126)]])
  }
}
