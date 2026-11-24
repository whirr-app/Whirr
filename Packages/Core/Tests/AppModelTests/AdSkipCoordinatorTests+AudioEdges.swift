import AdSkip
import Foundation
import Persistence
import Testing

@testable import AppModel

/// Audio edges: where an episode's audio lines up with another episode's
/// moves a saved range's edges past the words the range was matched on. The evidence comes from
/// the stage-1 query and is kept and carried with the plan.
extension AdSkipCoordinatorTests {

  /// Wordless audio both shows play next to the ad, such as a sponsor's music. Each word starts
  /// just after the spoken word under it, so the print hears it and the transcriber does not.
  static func jingle(from start: Double, count: Int) -> [TranscriptWord] {
    (0..<count).map {
      let wordStart = start + Double($0) * 0.5 + 0.01
      return TranscriptWord(text: "jingle\(Int(start))-\($0)", start: wordStart, end: wordStart + 0.39)
    }
  }

  /// 48 programme words, six seconds of words of this episode's own from 24.0 s, the ad from
  /// 30.0 s to 49.9 s, `outro` words of its own, then programme.
  static func withJingle(_ tag: String, outro: Int = 0) -> Transcript {
    transcript(
      programme(tag, count: 48) + programme(tag + "lowj", count: 12) + ad
        + programme(tag + "lowo", count: outro) + programme(tag + "x"))
  }

  /// `withJingle`, with the jingle under the six seconds before the ad and `outro` words of it
  /// after.
  func jingled(_ harness: Harness, _ id: String, show: String, outro: Int = 0) -> AdSkipLocalEpisode {
    let episode = harness.episode(id, transcript: Self.withJingle(id, outro: outro), show: show)
    harness.audio.unspoken.withLock {
      $0[episode.fileURL] = Self.jingle(from: 24, count: 12) + Self.jingle(from: 50, count: outro)
    }
    return episode
  }

  @Test func anotherShowsAudioMovesTheSavedStart() async throws {
    let harness = try Harness()
    await harness.run([
      jingled(harness, "a", show: "rss:1"),
      jingled(harness, "b", show: "rss:2"),
    ])

    for (id, show) in [("a", "rss:1"), ("b", "rss:2")] {
      let ranges = try await harness.ranges(id, show: show)
      #expect(ranges.count == 1)
      // The matcher's refinement window reaches a fraction of a second past shared audio.
      #expect(ranges.allSatisfy { abs($0.startTime - 24) < 0.4 }, "\(id)")
      #expect(ranges.allSatisfy { abs($0.endTime - 49.9) < 1e-9 }, "\(id)")
    }
    let edges = try await harness.coordinator.audioEdgesForTests()
    #expect(edges[Harness.identity("a", show: "rss:1")]?.count == 1)
  }

  @Test func theSameShowsAudioMovesTheSavedStart() async throws {
    let harness = try Harness()
    // A theme played next to the ad in every episode moves the edge too; a few seconds of it
    // skipped is accepted.
    await harness.run([
      jingled(harness, "a", show: "rss:1"),
      jingled(harness, "b", show: "rss:1"),
    ])

    for id in ["a", "b"] {
      let ranges = try await harness.ranges(id)
      #expect(ranges.count == 1)
      #expect(ranges.allSatisfy { abs($0.startTime - 24) < 0.4 }, "\(id)")
    }
    #expect(try await harness.coordinator.audioEdgesForTests()[Harness.identity("a")]?.count == 1)
  }

  @Test func linkedCopiesOfOneEpisodeAreNotEvidence() async throws {
    let harness = try Harness()
    // The RSS and Audiobookshelf copies of a are one episode: they never match each other, so
    // neither moves the other's edges. b shares the ad but not the jingle.
    let rss = jingled(harness, "a", show: "rss:1")
    let abs = harness.episode(
      "a", transcript: Self.withJingle("a"), source: .abs, linked: [Harness.identity("a")])
    harness.audio.unspoken.withLock { $0[abs.fileURL] = Self.jingle(from: 24, count: 12) }
    await harness.run([rss, abs, harness.episode("b", transcript: Self.withJingle("b"))])

    #expect(try await harness.ranges("a").map(\.startTime) == [30.0])
    let evidence = try #require(try await harness.coordinator.audioEdgesForTests()[Harness.identity("a")])
    #expect(evidence.isEmpty == false)
    #expect(evidence.allSatisfy { $0.start > 29 })
  }

  @Test func theArbiterCanVetoAnAudioEdge() async throws {
    let harness = try Harness()
    // The ad's steps keep the range; the jingle's six seconds of unscored words dilute the
    // extended range below the cut.
    harness.scorer.perStep.withLock {
      $0 = { $0.contains("lowj") ? 0 : ($0.contains("acmead") ? 0.13 : 0) }
    }
    await harness.run([
      jingled(harness, "a", show: "rss:1"),
      jingled(harness, "b", show: "rss:2"),
    ])
    #expect(try await harness.ranges("a").map(\.startTime) == [30.0])
  }

  @Test func theLaterOfTheAudioEndAndThePauseWins() async throws {
    // A pause that wins is then bridged whole: the served end is the pause's end.
    for (outro, pause, expected) in [(12, 52.0, 56.0), (4, 54.0, 54.5)] {
      let harness = try Harness()
      // The programme after the pause scores as programme, so the post-roll tail keeps nothing.
      harness.scorer.perStep.withLock { $0 = { $0.contains("axw") ? 0.1 : 0.9 } }
      let a = jingled(harness, "a", show: "rss:1", outro: outro)
      harness.audio.set(a.fileURL, [Silence(start: pause, end: pause + 0.5)])
      await harness.run([a, jingled(harness, "b", show: "rss:2", outro: outro)])

      let end = try #require(try await harness.ranges("a").first?.endTime)
      #expect(abs(end - expected) < 0.4, "outro \(outro): \(end)")
    }
  }

  @Test func theEarlierOfTheAudioStartAndThePhraseWins() async throws {
    let harness = try Harness()
    // a reads the sponsor phrase from 26.0 s; b plays the end of it, unspoken, from 28.0 s.
    let a = harness.episode("a", transcript: Self.withPhrase("a"), show: "rss:1")
    let bWords = Self.transcript(Self.programme("b", count: 52) + Self.ad + Self.programme("bx"))
      .words.map { word in
        word.start < 26 ? word : TranscriptWord(text: word.text, start: word.start + 4, end: word.end + 4)
      }
    let b = harness.episode(
      "b", transcript: Transcript(words: bWords, duration: 84), show: "rss:2")
    harness.audio.unspoken.withLock {
      $0[b.fileURL] = Self.phrase.enumerated().dropFirst(4).map {
        TranscriptWord(text: $1, start: 26 + Double($0) * 0.5, end: 26 + Double($0) * 0.5 + 0.4)
      }
    }
    await harness.run([a, b])

    #expect(try await harness.ranges("a", show: "rss:1").map(\.startTime) == [26.0])
    let start = try #require(try await harness.ranges("b", show: "rss:2").first?.startTime)
    #expect(abs(start - 28) < 0.4)
  }

  // MARK: - Plans

  @Test func evidenceIsStoredWithThePlanAndCarriedPastAnUnrelatedArrival() async throws {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement)
    let library = [jingled(harness, "a", show: "rss:1"), jingled(harness, "b", show: "rss:2")]
    await harness.run(library)
    let a = Harness.identity("a", show: "rss:1")
    let before = try #require(try await harness.coordinator.audioEdgesForTests()[a])
    #expect(before.isEmpty == false)
    let stored = try await Self.storedPlan(harness, a)
    #expect(stored?.audioEdges.map { TimeSpan(start: $0.start, end: $0.end) } == before)

    measurement.reset()
    await harness.coordinator.setLocalEpisodes(
      library + [harness.episode("n", transcript: Self.transcript(Self.programme("n", count: 160)))])
    await harness.coordinator.waitUntilIdle()
    #expect(measurement.queries == 1)
    #expect(try await harness.coordinator.audioEdgesForTests()[a] == before)
  }

  @Test func aPlanStoredUnderAnotherLibraryIsPlannedAgainWithItsEvidence() async throws {
    let harness = try Harness()
    let library = [jingled(harness, "a", show: "rss:1"), jingled(harness, "b", show: "rss:2")]
    await harness.run(library)
    // As a plan stored before audio edges was: same windows, no evidence, an older rules key.
    let a = Harness.identity("a", show: "rss:1")
    let rowId = try #require(try await harness.episodes.episode(for: a)?.id)
    let stored = try #require(try await Self.storedPlan(harness, a))
    try await harness.episodes.saveStageOnePlan(
      StoredStageOnePlan(windows: stored.windows, audioEdges: []), forEpisodeId: rowId,
      libraryKey: "revision 1")

    let measurement = RecordingMeasurement()
    let restarted = try Harness(reusing: harness, measurement: measurement)
    await restarted.run(library)
    #expect(measurement.queries == 1)
    let replanned = try await Self.storedPlan(restarted, a)
    #expect(replanned?.audioEdges.isEmpty == false)
  }

  /// The episode's plan as stored under the coordinator's current library.
  static func storedPlan(
    _ harness: Harness, _ identity: AdSkipEpisodeIdentity
  ) async throws -> StoredStageOnePlan? {
    guard let rowId = try await harness.episodes.episode(for: identity)?.id,
      let key = await harness.coordinator.audioLibrary?.key
    else { return nil }
    return try await harness.episodes.stageOnePlan(forEpisodeId: rowId, libraryKey: key)
  }
}
