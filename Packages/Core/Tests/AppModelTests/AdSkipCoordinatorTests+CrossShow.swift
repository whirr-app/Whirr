import AdSkip
import Foundation
import Persistence
import Testing

@testable import AppModel

/// Another show's audio passes the veto: a candidate the arbiter drops is
/// served when one alignment with an episode of another show covers 15 s of it, and is never
/// learned.
extension AdSkipCoordinatorTests {

  /// A cross-promo the classifier scores as programme.
  static let promo = (0..<40).map { "promo\($0)" }

  /// 60 programme words, `words` from 30.0 s, 60 more programme words.
  static func withPromo(_ tag: String, _ words: [String] = promo) -> Transcript {
    transcript(programme(tag) + words + programme(tag + "x"))
  }

  /// Every step holding a promo word scores as programme.
  func vetoingPromos(_ harness: Harness) {
    harness.scorer.perStep.withLock { $0 = { $0.contains("promo") ? 0.01 : 0.9 } }
  }

  @Test func anotherShowsAudioKeepsAVetoedCandidateAndIsNotLearned() async throws {
    let harness = try Harness()
    vetoingPromos(harness)
    await harness.run([
      harness.episode("a", transcript: Self.withPromo("a"), show: "rss:1"),
      harness.episode("c", transcript: Self.withPromo("c"), show: "rss:2"),
    ])

    for (id, show) in [("a", "rss:1"), ("c", "rss:2")] {
      let ranges = try await harness.ranges(id, show: show)
      #expect(ranges.count == 1, "\(id)")
      #expect(ranges.allSatisfy { $0.startTime == 30 && abs($0.endTime - 49.9) < 1e-9 }, "\(id)")
      #expect(ranges.allSatisfy { $0.creativeId == nil && $0.fromStore == false }, "\(id)")
      #expect(ranges.allSatisfy { $0.meanAdProbability < 0.5 }, "\(id)")
    }
    #expect(try await harness.signatures.allCreatives().isEmpty)
  }

  @Test func theSameShowsAudioDoesNotPassTheVeto() async throws {
    let harness = try Harness()
    vetoingPromos(harness)
    await harness.run([
      harness.episode("a", transcript: Self.withPromo("a")),
      harness.episode("b", transcript: Self.withPromo("b")),
    ])
    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.ranges("b").isEmpty)
  }

  @Test func aFourteenSecondAlignmentDoesNotPassTheVeto() async throws {
    let harness = try Harness()
    vetoingPromos(harness)
    // a and b, one show, share the whole promo; c, another, plays its first 13.9 s.
    await harness.run([
      harness.episode("a", transcript: Self.withPromo("a")),
      harness.episode("b", transcript: Self.withPromo("b")),
      harness.episode("c", transcript: Self.withPromo("c", Array(Self.promo.prefix(28))), show: "rss:2"),
    ])
    #expect(try await harness.ranges("a").isEmpty)
  }

  @Test func shortAlignmentsWithTwoShowsDoNotAddUp() async throws {
    let harness = try Harness()
    vetoingPromos(harness)
    // c plays the promo's first 13.9 s and d its last: together all of it, neither 15 s.
    await harness.run([
      harness.episode("a", transcript: Self.withPromo("a")),
      harness.episode("b", transcript: Self.withPromo("b")),
      harness.episode("c", transcript: Self.withPromo("c", Array(Self.promo.prefix(28))), show: "rss:2"),
      harness.episode("d", transcript: Self.withPromo("d", Array(Self.promo.suffix(28))), show: "rss:3"),
    ])
    #expect(try await harness.ranges("a").isEmpty)
  }

  @Test func aRerunOnAnotherFeedIsNotEvidence() async throws {
    let harness = try Harness()
    vetoingPromos(harness)
    // r is a, reposted on a sister feed: no link and its own file, but the same audio, so it joins
    // a's group by shared words and audio.
    await harness.run([
      harness.episode("a", transcript: Self.withPromo("a")),
      harness.episode("b", transcript: Self.withPromo("b")),
      harness.episode("r", transcript: Self.withPromo("a"), show: "rss:2"),
    ])
    // a's only other alignment is b's, of its own show.
    #expect(try await harness.ranges("a").isEmpty)
    // For r, b is another show's episode: the group rules out a rerun, not every alignment.
    #expect(try await harness.ranges("r", show: "rss:2").count == 1)
  }

  @Test func oneShowFollowedThroughBothSourcesIsOneShow() async throws {
    let harness = try Harness()
    vetoingPromos(harness)
    let fingerprint = String(repeating: "0123456789abcdef", count: 4)
    var a = harness.episode("a", transcript: Self.withPromo("a"))
    var e = harness.episode("e", transcript: Self.withPromo("e"), source: .abs)
    a.feedFingerprint = fingerprint
    e.feedFingerprint = fingerprint
    await harness.run([a, e])
    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.ranges("e", source: .abs).isEmpty)
  }

  @Test func showsJoinAcrossLinksAndFeedFingerprints() {
    let fingerprint = String(repeating: "0123456789abcdef", count: 4)
    func local(
      _ identity: AdSkipEpisodeIdentity, linked: [AdSkipEpisodeIdentity] = [], fingerprint: String? = nil
    ) -> AdSkipLocalEpisode {
      AdSkipLocalEpisode(
        identity: identity, fileURL: URL(fileURLWithPath: "/\(identity.episodeKey.rawValue)"),
        languageTag: nil, showTitle: nil, linkedIdentities: linked, feedFingerprint: fingerprint)
    }
    let rssX = Harness.identity("x", show: "rss:1")
    let absX = Harness.identity("x", source: .abs)
    let absY = Harness.identity("y", source: .abs)
    let rssZ = Harness.identity("z", show: "rss:2")
    let rssW = Harness.identity("w", show: "rss:3")
    let other = Harness.identity("v", show: "rss:4")
    let shows = AdSkipPlanBook.shows(
      of: [
        local(rssX, linked: [absX]), local(absX), local(absY), local(rssZ, fingerprint: fingerprint),
        local(rssW, fingerprint: fingerprint), local(other),
      ])
    // rss:1 and the ABS show by a linked copy; rss:2 and rss:3 by their feed.
    #expect(shows[rssX] == shows[absY])
    #expect(shows[rssZ] == shows[rssW])
    #expect(Set([shows[rssX], shows[rssZ], shows[other]]).count == 3)
  }

  @Test func anotherShowsAudioMovesAVetoedRangesStart() async throws {
    let harness = try Harness()
    vetoingPromos(harness)
    // The promo's music from 24.0 s, which the transcriber does not hear, plays in both shows.
    var episodes: [AdSkipLocalEpisode] = []
    for (id, show) in [("a", "rss:1"), ("c", "rss:2")] {
      let episode = harness.episode(
        id,
        transcript: Self.transcript(
          Self.programme(id, count: 48) + Self.programme(id + "lowj", count: 12) + Self.promo
            + Self.programme(id + "x")),
        show: show)
      harness.audio.unspoken.withLock { $0[episode.fileURL] = Self.jingle(from: 24, count: 12) }
      episodes.append(episode)
    }
    await harness.run(episodes)

    let ranges = try await harness.ranges("a")
    #expect(ranges.count == 1)
    // The arbiter would veto the move; the alignment with c covers it.
    #expect(ranges.allSatisfy { abs($0.startTime - 24) < 0.4 }, "\(ranges)")
  }
}
