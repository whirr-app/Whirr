import AdSkip
import Foundation
import Persistence
import Testing

@testable import AppModel

/// A sponsor phrase straight after a short recurring sting skips from the sting to the next kept
/// range or sting, even when the read between is a one-off too long for the phrase start to
/// reach and is never transcribed past its opener.
extension AdSkipCoordinatorTests {

  /// 52 programme words, then words of this episode's own under a 6 s sting from 26.0 s, then
  /// `after` from 32.0 s.
  static func withSting(_ tag: String, after: [String]) -> Transcript {
    transcript(programme(tag, count: 52) + programme(tag + "lows", count: 12) + after)
  }

  /// `transcript`, with the sting (the jingle from 26.0 s) and `more` stings under it.
  func stung(
    _ harness: Harness, _ id: String, transcript: Transcript, more: [Double] = []
  ) -> AdSkipLocalEpisode {
    let episode = harness.episode(id, transcript: transcript)
    harness.audio.unspoken.withLock {
      $0[episode.fileURL] = ([26.0] + more).flatMap { Self.jingle(from: $0, count: 12) }
    }
    return episode
  }

  /// a: the sting, the phrase at 32.0 s, 300 words (150 s) of one-off read, then the ad at
  /// 186.0 s. b: the sting and the ad, no phrase.
  func segmentLibrary(_ harness: Harness) -> [AdSkipLocalEpisode] {
    [
      stung(
        harness, "a",
        transcript: Self.withSting(
          "a", after: Self.phrase + Self.programme("ac", count: 300) + Self.ad + Self.programme("ax"))),
      stung(
        harness, "b",
        transcript: Self.withSting(
          "b", after: Self.programme("bm", count: 100) + Self.ad + Self.programme("bx"))),
    ]
  }

  @Test func aPhraseAfterAStingSkipsTheReadUpToTheKeptRange() async throws {
    let harness = try Harness()
    await harness.run(segmentLibrary(harness))

    let a = try await harness.ranges("a")
    #expect(a.count == 1)
    // The sting's start, to the matcher's refinement.
    #expect(a.allSatisfy { abs($0.startTime - 26) < 0.4 }, "\(a.map(\.startTime))")
    let b = try await harness.ranges("b")
    // The end is the matched ad's, 186 s into a and 82 s into b.
    #expect(a.map { $0.endTime - 186 } == b.map { $0.endTime - 82 })
    #expect(b.map(\.startTime) == [82.0])
    // Playback-only: the store learns the matched ad, not the segment.
    let creatives = try await harness.signatures.allCreatives()
    #expect(creatives.isEmpty == false)
    #expect(creatives.allSatisfy { $0.endTime - $0.startTime < 25 })
  }

  @Test func theReadIsNeverTranscribedPastItsOpener() async throws {
    let harness = try Harness()
    let library = segmentLibrary(harness)
    await harness.run(library)
    let calls = harness.transcriber.calls.withLock { $0 }
    let windows = zip(calls, harness.transcriber.windowCalls.withLock { $0 })
      .filter { $0.0 == library[0].fileURL }.flatMap(\.1)
    // The after-sting window reaches the phrase; nothing asks for the middle of the read.
    #expect(windows.contains { $0.start <= 32 && $0.end >= 42 })
    // Stage 2a looks back 92 s from the ad at 186 s, so 50-90 s is the read's unheard middle.
    #expect(windows.contains { $0.start < 90 && $0.end > 50 } == false)
  }

  @Test func theNextStingEndsASegmentWithNoKeptRange() async throws {
    let harness = try Harness()
    // a: the sting, the phrase at 32.0 s, a 60 s read, a second sting at 96.0 s, then programme.
    let aWords =
      Self.phrase + Self.programme("ac", count: 120) + Self.programme("alows2", count: 12)
      + Self.programme("ax")
    let bWords = Self.programme("bm", count: 128) + Self.programme("bx")
    await harness.run([
      stung(harness, "a", transcript: Self.withSting("a", after: aWords), more: [96]),
      stung(harness, "b", transcript: Self.withSting("b", after: bWords), more: [96]),
    ])

    let a = try await harness.ranges("a")
    #expect(a.count == 1)
    #expect(a.allSatisfy { abs($0.startTime - 26) < 0.4 && abs($0.endTime - 96) < 0.4 }, "\(a)")
    #expect(a.allSatisfy { $0.creativeId == nil && $0.fromStore == false })
    #expect(try await harness.ranges("b").isEmpty)
    #expect(try await harness.signatures.allCreatives().isEmpty)
  }

  @Test func undoingASegmentKeepsItGone() async throws {
    let harness = try Harness()
    let library = segmentLibrary(harness)
    await harness.run(library)
    let skipped = try #require(await harness.coordinator.skipRanges(for: Self.request(library[0])).first)
    #expect(abs(skipped.start - 26) < 0.4)

    await harness.coordinator.undoSkip(skipped, for: Self.request(library[0]))
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.ranges("a").isEmpty)
  }

  @Test func undoingASegmentAStingEndsKeepsItGone() async throws {
    // No stage-1 window reaches this read, so only words the after-sting window heard can hold
    // the undo.
    let harness = try Harness()
    let aWords =
      Self.phrase + Self.programme("ac", count: 120) + Self.programme("alows2", count: 12)
      + Self.programme("ax")
    let bWords = Self.programme("bm", count: 128) + Self.programme("bx")
    let library = [
      stung(harness, "a", transcript: Self.withSting("a", after: aWords), more: [96]),
      stung(harness, "b", transcript: Self.withSting("b", after: bWords), more: [96]),
    ]
    await harness.run(library)
    let skipped = try #require(await harness.coordinator.skipRanges(for: Self.request(library[0])).first)

    await harness.coordinator.undoSkip(skipped, for: Self.request(library[0]))
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.ranges("a").isEmpty)
  }
}
