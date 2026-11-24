import AdSkip
import Foundation
import Persistence
import Testing

@testable import AppModel

/// A sponsor phrase before a kept range moves where it starts skipping: only the
/// saved range changes, and only when the arbiter keeps the extended range.
extension AdSkipCoordinatorTests {

  static let phrase = ["this", "episode", "is", "brought", "to", "you", "by", "zork"]

  /// 52 programme words, the phrase from 26.0 s, `copy` words of unrepeated sponsor copy, the ad,
  /// then programme.
  static func withPhrase(_ tag: String, copy: Int = 0) -> Transcript {
    transcript(
      programme(tag, count: 52) + phrase + programme(tag + "c", count: copy) + ad
        + programme(tag + "x"))
  }

  @Test func aSponsorPhraseMovesTheSavedStartAndNothingElse() async throws {
    let harness = try Harness()
    await harness.run([
      harness.episode("a", transcript: Self.withPhrase("a")),
      harness.episode("b", transcript: Self.withAd("b")),
    ])

    let a = try await harness.ranges("a")
    let b = try await harness.ranges("b")
    #expect(a.map(\.startTime) == [26.0])
    #expect(b.map(\.startTime) == [30.0])
    // The end, the creative and the store are the matched ad's, as in an episode with no phrase.
    #expect(a.map(\.endTime) == b.map(\.endTime))
    #expect(a.map(\.fromStore) == b.map(\.fromStore))
    // Each names the one creative both taught, once a later recompute matches the store.
    #expect(a.map { $0.creativeId == nil } == b.map { $0.creativeId == nil })
    let creatives = try await harness.signatures.allCreatives()
    #expect(creatives.count == 1)
    #expect(creatives.allSatisfy { $0.hashes.count == 33 })
  }

  @Test func theArbiterCanVetoAPhraseStart() async throws {
    let harness = try Harness()
    // Only the ad scores: 80 s of unscored copy dilutes the extended range below the cut.
    harness.scorer.perStep.withLock { $0 = { $0.contains("acmead") ? 0.12 : 0 } }
    await harness.run([
      harness.episode("a", transcript: Self.withPhrase("a", copy: 160)),
      harness.episode("b", transcript: Self.withAd("b")),
    ])
    #expect(try await harness.ranges("a").map(\.startTime) == [110.0])
  }

  @Test func aPhraseStartIsAppliedWhenAnOlderRevisionIsRescored() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withPhrase("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    for var row in try await harness.episodes.allEpisodes() {
      row.rulesRevision = 2
      _ = try await harness.episodes.save(
        row,
        ranges: [
          AdSkipRange(
            startTime: 30, endTime: 49.9, meanAdProbability: 0.9, rulesRevision: 2,
            fromStore: false, endsItem: false, creativeId: nil)
        ])
    }

    let restarted = try Harness(reusing: harness)
    await restarted.run([a, b])
    #expect(try await restarted.ranges("a").map(\.startTime) == [26.0])
    #expect(try await restarted.ranges("a").map(\.rulesRevision) == [AdSkipRules.revision])
  }

  /// A presenting partner opening the pre-roll under the show's name, 60 s of its read, a sponsor
  /// phrase, 30 s of that sponsor's copy, then the matched ad: the partner's line is 97.5 s before
  /// the ad, past the 90 s cap, and 63.5 s before the phrase.
  static func withPresentingPartner(_ tag: String) -> Transcript {
    transcript(
      programme(tag, count: 59) + ["end."] + ["the", "zork", "hour", "is", "powered", "by", "acme."]
        + programme(tag + "p", count: 120) + phrase + programme(tag + "c", count: 60) + ad
        + programme(tag + "x"))
  }

  @Test func aSecondPhraseRoundRunsFromAPhraseMovedStart() async throws {
    let harness = try Harness()
    await harness.run([
      harness.episode("a", transcript: Self.withPresentingPartner("a"), showTitle: "The Zork Hour"),
      harness.episode("b", transcript: Self.withAd("b"), showTitle: "The Zork Hour"),
    ])
    let starts = try await harness.ranges("a").map(\.startTime)
    #expect(starts == [30.0])
  }

  @Test func withoutTheShowsNameTheSecondRoundFindsNothing() async throws {
    let harness = try Harness()
    await harness.run([
      harness.episode("a", transcript: Self.withPresentingPartner("a")),
      harness.episode("b", transcript: Self.withAd("b")),
    ])
    let starts = try await harness.ranges("a").map(\.startTime)
    #expect(starts == [93.5])
  }
}
