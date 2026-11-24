import Foundation
import Testing

@testable import AdSkip

@Suite struct ConfirmedReachTests {
  private struct Words {
    var random: SplitMix64
    init(seed: UInt64) { random = SplitMix64(seed: seed) }
    mutating func next(_ count: Int) -> [UInt32] {
      (0..<count).map { _ in UInt32(truncatingIfNeeded: random.next()) }
    }
  }

  /// Frames in `seconds` of audio.
  private func frames(_ seconds: Double) -> Int { Int(seconds / AudioPrint.hopSeconds) }

  @Test func aConfirmedPlugIsFoundWhereverItPlays() throws {
    var words = Words(seed: 11)
    let plug = words.next(frames(13))
    let episode = words.next(frames(30)) + plug + words.next(frames(600))
    let matches = ConfirmedReach.matches(
      in: AudioPrint(words: episode), creatives: [(id: 7, print: AudioPrint(words: plug))])
    let match = try #require(matches.first)
    #expect(matches.count == 1)
    #expect(match.creativeId == 7)
    #expect(abs(match.span.start - AudioPrint.time(ofFrame: frames(30))) < 0.5)
    #expect(abs(match.span.end - AudioPrint.time(ofFrame: frames(30) + plug.count)) < 0.5)
  }

  @Test func aPlugPlayingTwiceIsFoundTwice() {
    var words = Words(seed: 12)
    let plug = words.next(frames(8))
    let episode = words.next(frames(20)) + plug + words.next(frames(300)) + plug + words.next(frames(60))
    let matches = ConfirmedReach.matches(
      in: AudioPrint(words: episode), creatives: [(id: 3, print: AudioPrint(words: plug))])
    #expect(matches.map(\.creativeId) == [3, 3])
    #expect(matches.count == 2 && matches[0].span.start < matches[1].span.start)
  }

  @Test func audioThatIsNotThePlugMatchesNothing() {
    var words = Words(seed: 13)
    let plug = words.next(frames(13))
    let episode = words.next(frames(600))
    #expect(
      ConfirmedReach.matches(
        in: AudioPrint(words: episode), creatives: [(id: 1, print: AudioPrint(words: plug))]
      ).isEmpty)
  }

  @Test func aMatchCoveringTooLittleOfItsPrintIsNoMatch() {
    var words = Words(seed: 14)
    let plug = words.next(frames(20))
    // Only the first 40% of the plug plays.
    let episode = words.next(frames(30)) + Array(plug[0..<frames(8)]) + words.next(frames(300))
    #expect(
      ConfirmedReach.matches(
        in: AudioPrint(words: episode), creatives: [(id: 1, print: AudioPrint(words: plug))]
      ).isEmpty)
  }

  @Test func overlappingMatchesOfTwoCreativesJoinUnderTheLowestId() throws {
    var words = Words(seed: 15)
    let plug = words.next(frames(13))
    let episode = words.next(frames(30)) + plug + words.next(frames(300))
    // The same plug, marked in two episodes: one print a little longer than the other.
    let longer = Array(episode[(frames(29))..<(frames(30) + plug.count + frames(1))])
    let matches = ConfirmedReach.matches(
      in: AudioPrint(words: episode),
      creatives: [(id: 9, print: AudioPrint(words: longer)), (id: 4, print: AudioPrint(words: plug))])
    let match = try #require(matches.first)
    #expect(matches.count == 1)
    #expect(match.creativeId == 4)
    #expect(abs(match.span.start - AudioPrint.time(ofFrame: frames(29))) < 0.5)
  }

  @Test func noCreativesOrAnEmptyEpisodeMatchNothing() {
    var words = Words(seed: 16)
    let plug = AudioPrint(words: words.next(frames(10)))
    #expect(ConfirmedReach.matches(in: AudioPrint(words: words.next(frames(100))), creatives: []).isEmpty)
    #expect(ConfirmedReach.matches(in: AudioPrint(words: []), creatives: [(id: 1, print: plug)]).isEmpty)
    #expect(
      ConfirmedReach.matches(
        in: AudioPrint(words: words.next(frames(100))), creatives: [(id: 1, print: AudioPrint(words: []))]
      ).isEmpty)
  }

  @Test func matchesAreLaidOverRangesLikeMarks() {
    let matches = [ConfirmedReach.Match(creativeId: 2, span: TimeSpan(start: 3, end: 16))]
    let pieces = ConfirmedReach.laying(matches, over: [(start: 10, end: 60, endsItem: false)])
    #expect(pieces.map { [$0.start, $0.end] } == [[3, 16], [16, 60]])
    #expect(pieces.map(\.creativeId) == [2, nil])
    #expect(pieces.map(\.source) == [nil, 0])
  }

  @Test func learningSkipsWhatAConfirmedMatchCovers() {
    func kept(_ start: Double, _ end: Double, endsItem: Bool = false) -> KeptRange {
      KeptRange(start: start, end: end, meanAdProbability: 0.8, endsItem: endsItem)
    }
    let match = ConfirmedReach.Match(creativeId: 1, span: TimeSpan(start: 100, end: 113))
    // Untouched, wholly covered, and cut into a long remnant and a short one.
    #expect(ConfirmedReach.unmatched([kept(0, 60)], by: [match]) == [kept(0, 60)])
    #expect(ConfirmedReach.unmatched([kept(101, 112)], by: [match]).isEmpty)
    #expect(
      ConfirmedReach.unmatched([kept(90, 160, endsItem: true)], by: [match])
        == [kept(113, 160, endsItem: true)])
    #expect(ConfirmedReach.unmatched([kept(90, 160)], by: []) == [kept(90, 160)])
  }
}
