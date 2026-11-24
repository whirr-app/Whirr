import AdSkip
import Foundation
import Persistence
import Testing

@testable import AppModel
@testable import PlayerCore

/// Two served spans more than the player's join apart and no more than `breakFillSeconds` apart
/// are served with the gap between them: what plays between two ads of one
/// break, which no other episode carries.
extension AdSkipCoordinatorTests {

  static let secondAd = (0..<40).map { "zetaad\($0)" }

  /// a: programme, the ad from 30.0 s, `gap` words of its own read, the second ad, programme.
  /// b: both ads 2 s apart, so its two spans already play as one skip.
  func breakLibrary(_ harness: Harness, gap: Int = 40) -> [AdSkipLocalEpisode] {
    [
      harness.episode(
        "a",
        transcript: Self.transcript(
          Self.programme("a") + Self.ad + Self.programme("ar", count: gap) + Self.secondAd
            + Self.programme("ax"))),
      harness.episode(
        "b",
        transcript: Self.transcript(
          Self.programme("b") + Self.ad + Self.programme("br", count: 4) + Self.secondAd
            + Self.programme("bx"))),
    ]
  }

  @Test func theJoinMatchesThePlayers() {
    #expect(PlaybackEdges.joinGapSeconds == PlayerReducer.skipJoinGap)
  }

  @Test func aShortGapBetweenTwoAdsIsServedWithThem() async throws {
    let harness = try Harness()
    await harness.run(breakLibrary(harness))

    // The read runs from 49.9 s to the second ad at 70.0 s.
    let a = try await harness.ranges("a")
    #expect(a.count == 3, "\(a)")
    let fill = try #require(a.count == 3 ? a[1] : nil)
    #expect(abs(fill.startTime - 49.9) < 1e-9 && fill.endTime == 70.0, "\(fill)")
    #expect(fill.creativeId == nil && fill.fromStore == false && fill.endsItem == false)
    #expect(fill.rulesRevision == AdSkipRules.revision)
    #expect(zip(a, a.dropFirst()).allSatisfy { $0.endTime == $1.startTime })
    // Playback-only: the store learns the matched ads, not the read.
    let creatives = try await harness.signatures.allCreatives()
    #expect(creatives.isEmpty == false)
    #expect(creatives.allSatisfy { $0.endTime - $0.startTime < 25 })
  }

  @Test func aGapPastTheCapPlays() async throws {
    let harness = try Harness()
    // 130 words: a 65.1 s read.
    await harness.run(breakLibrary(harness, gap: 130))
    #expect(try await harness.ranges("a").count == 2)
  }

  @Test func aGapHoldingATombstonedShingleIsNotFilled() async throws {
    let harness = try Harness()
    let library = breakLibrary(harness)
    // A tombstone of the read's middle, as another episode's Undo of the same words would leave.
    let full = try #require(harness.transcriber.fullTranscript(library[0].fileURL))
    let tombstone = try #require(
      SignatureStore.tombstone(
        from: PreparedTranscript(transcript: full, silences: []), start: 56, end: 64,
        teachers: [EpisodeKey("elsewhere")]))
    _ = try await harness.signatures.apply(
      AdSignatureStoreChange(insertions: [NewAdSignatureCreative(tombstone, lastSeen: harness.clock.now())]))

    await harness.run(library)

    let a = try await harness.ranges("a")
    #expect(a.count == 2, "\(a)")
    #expect(a.map(\.startTime) == [30, 70])
  }

  @Test func aGapAfterAStingSegmentIsFilled() async throws {
    let harness = try Harness()
    // a: the sting, the phrase at 32.0 s, a 100 s read, a second sting at 136.0 s, 20 s of its
    // own, then the ad from 162.0 s, past the phrase's reach. The segment ends at the second
    // sting; the gap runs from there to the ad.
    let aWords =
      Self.phrase + Self.programme("ac", count: 200) + Self.programme("alows2", count: 12)
      + Self.programme("ag", count: 40) + Self.ad + Self.programme("ax")
    let bWords =
      Self.programme("bm", count: 208) + Self.programme("bg", count: 20) + Self.ad
      + Self.programme("bx")
    await harness.run([
      stung(harness, "a", transcript: Self.withSting("a", after: aWords), more: [136]),
      stung(harness, "b", transcript: Self.withSting("b", after: bWords), more: [136]),
    ])

    let a = try await harness.ranges("a")
    #expect(a.count == 3, "\(a)")
    #expect(a.first.map { abs($0.startTime - 26) < 0.4 } == true)
    let fill = try #require(a.count == 3 ? a[1] : nil)
    #expect(abs(fill.startTime - 136) < 0.4 && fill.endTime == 162, "\(fill)")
    #expect(fill.creativeId == nil && fill.fromStore == false)
    #expect(zip(a, a.dropFirst()).allSatisfy { $0.endTime == $1.startTime })
  }

  @Test func undoingAJoinedFillKeepsItGone() async throws {
    let harness = try Harness()
    let library = breakLibrary(harness)
    await harness.run(library)
    let served = await harness.coordinator.skipRanges(for: Self.request(library[0]))
    #expect(served.count == 3)
    let first = try #require(served.first)
    let last = try #require(served.last)

    // The player joins the three into one skip, and Undo receives the joined range.
    await harness.coordinator.undoSkip(
      PlayerSkipRange(start: first.start, end: last.end, endsItem: last.endsItem),
      for: Self.request(library[0]))
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.ranges("a").isEmpty)
  }
}
