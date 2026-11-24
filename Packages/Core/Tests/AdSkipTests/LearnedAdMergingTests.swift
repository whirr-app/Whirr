import Foundation
import Testing

@testable import AdSkip

@Suite struct LearnedAdMergingTests {
  private let epoch = Date(timeIntervalSince1970: 1_000_000_000)

  /// `count` frames of one recording, the same for the same seed.
  private static func audio(_ seed: UInt64, count: Int) -> [UInt32] {
    var random = SplitMix64(seed: seed)
    return (0..<count).map { _ in UInt32(truncatingIfNeeded: random.next()) }
  }

  private static func hashes(_ range: Range<UInt64>) -> Set<UInt64> { Set(range) }

  private func content(_ hashes: Set<UInt64>, _ words: [UInt32]?) -> LearnedAdMerging.Content {
    LearnedAdMerging.Content(hashes: hashes, print: words.map(AudioPrint.init(words:)))
  }

  private func ad(
    _ id: Int64, _ hashes: Set<UInt64>, teachers: Set<EpisodeKey> = [], seen: TimeInterval = 0,
    kind: SignatureCreative.Kind = .learned, start: Double = 0
  ) -> SignatureCreative {
    SignatureCreative(
      id: id, kind: kind, lastSeen: epoch.addingTimeInterval(seen), start: start, end: start + 30,
      teachers: teachers, hashes: hashes)
  }

  // MARK: - The rule

  @Test func theSameAdSharesFourFifthsOfTheSmallerHashSet() {
    // 10 hashes against 100: eight shared is the same ad, seven is not.
    let big = Self.hashes(0..<100)
    #expect(LearnedAdMerging.isSameAd(content(Self.hashes(0..<8).union([200, 201]), nil), content(big, nil)))
    #expect(
      LearnedAdMerging.isSameAd(content(Self.hashes(0..<7).union([200, 201, 202]), nil), content(big, nil))
        == false)
    #expect(LearnedAdMerging.isSameAd(content([], nil), content(big, nil)) == false)
  }

  @Test func sharedWordsWithoutSharedAudioAreNotTheSameAd() {
    let words = Self.hashes(0..<50)
    let recording = Self.audio(1, count: 3000)
    #expect(LearnedAdMerging.isSameAd(content(words, recording), content(words, recording)))
    #expect(LearnedAdMerging.isSameAd(content(words, recording), content(words, Self.audio(2, count: 3000))) == false)
  }

  @Test func anAdWithoutAPrintIsJudgedByItsHashes() {
    let words = Self.hashes(0..<50)
    #expect(LearnedAdMerging.isSameAd(content(words, nil), content(words, Self.audio(2, count: 3000))))
    #expect(LearnedAdMerging.isSameAd(content(words, []), content(words, Self.audio(2, count: 3000))))
  }

  @Test func aShortAdInsideALongBreakSharesItsAudioOneWay() {
    // The ad is the middle of a break two and a half times its length.
    let ad = Self.audio(3, count: 3000)
    let breakAudio = Self.audio(4, count: 2250) + ad + Self.audio(5, count: 2250)
    let short = AudioPrint(words: ad)
    let long = AudioPrint(words: breakAudio)
    #expect(AudioRecurrence.share(of: short, foundIn: long) >= 0.8)
    #expect(AudioRecurrence.share(of: long, foundIn: short) < 0.5)
    #expect(AudioRecurrence.sharedFraction(of: short, and: long) < 0.5)
    #expect(AudioRecurrence.share(of: short, foundIn: AudioPrint(words: [])) == 0)
    #expect(AudioRecurrence.share(of: AudioPrint(words: []), foundIn: long) == 0)
    #expect(LearnedAdMerging.isSameAd(content(Self.hashes(0..<50), ad), content(Self.hashes(0..<50), breakAudio)))
  }

  // MARK: - Absorbing

  @Test func theLongerPrintOutlivesAndAPrintBeatsNone() {
    let short = AudioPrint(words: Self.audio(1, count: 100))
    let long = AudioPrint(words: Self.audio(1, count: 200))
    #expect(LearnedAdMerging.outlives(long, short))
    #expect(LearnedAdMerging.outlives(short, long) == false)
    #expect(LearnedAdMerging.outlives(short, nil))
    #expect(LearnedAdMerging.outlives(nil, short) == false)
    #expect(LearnedAdMerging.outlives(short, short) == false)
    #expect(LearnedAdMerging.outlives(nil, nil) == false)
  }

  @Test func teachersStopAtTheFileLimit() {
    let own: Set<EpisodeKey> = [EpisodeKey("own")]
    let more = Set((0..<400).map { EpisodeKey(String(format: "k%03d", $0)) })
    let merged = LearnedAdMerging.teachers(own, adding: more)
    #expect(merged.count == LearnedAdMerging.maximumTeachers)
    #expect(merged.contains(EpisodeKey("own")))
    #expect(merged.contains(EpisodeKey("k000")))
    #expect(merged.contains(EpisodeKey("k399")) == false)
    #expect(LearnedAdMerging.teachers(own, adding: [EpisodeKey("b")]) == [EpisodeKey("own"), EpisodeKey("b")])
  }

  @Test func anAbsorbPastTheHashLimitIsRefused() {
    let limit = UInt64(LearnedAdMerging.maximumHashes)
    #expect(LearnedAdMerging.canAbsorb(Self.hashes(0..<10), into: Self.hashes(0..<limit)))
    #expect(LearnedAdMerging.canAbsorb(Self.hashes(limit..<(limit + 1)), into: Self.hashes(0..<limit)) == false)
  }

  // MARK: - Collapse

  @Test func copiesCollapseIntoTheAdWithTheLongestPrint() {
    let a = EpisodeKey("a")
    let b = EpisodeKey("b")
    let c = EpisodeKey("c")
    let recording = Self.audio(7, count: 4000)
    let store = [
      ad(1, Self.hashes(0..<40), teachers: [a], seen: 10, start: 100),
      ad(2, Self.hashes(0..<44), teachers: [b], seen: 30, start: 200),
      ad(3, Self.hashes(2..<42), teachers: [c], seen: 20, start: 300),
      ad(4, Self.hashes(500..<540), teachers: [a], seen: 5),
      ad(5, Self.hashes(0..<40), teachers: [a], kind: .tombstone),
    ]
    let prints: [Int64: AudioPrint] = [
      1: AudioPrint(words: Array(recording[500..<3000])),
      2: AudioPrint(words: recording),
      3: AudioPrint(words: Array(recording[0..<3500])),
      4: AudioPrint(words: Self.audio(8, count: 3000)),
    ]
    let collapse = LearnedAdMerging.collapse(store, prints: prints)
    #expect(collapse.creatives.map(\.id) == [2, 4, 5])
    #expect(collapse.absorbed == [1: 2, 3: 2])
    let merged = collapse.creatives.first
    #expect(merged?.hashes == Self.hashes(0..<44))
    #expect(merged?.teachers == [a, b, c])
    #expect(merged?.lastSeen == epoch.addingTimeInterval(30))
    // The print's own range, not another copy's.
    #expect(merged?.start == 200)
    // An ad that merged with nothing and a tombstone holding the same hashes are untouched.
    #expect(collapse.creatives[1] == store[3])
    #expect(collapse.creatives[2] == store[4])
  }

  /// One short ad sits in two breaks that share nothing else. It joins one of them; joining both
  /// would leave a whole break's audio in no print.
  @Test func aShortAdDoesNotJoinTwoBreaksThatAreNotTheSame() {
    let spot = Self.audio(3, count: 3000)
    let first = Self.audio(4, count: 2250) + spot + Self.audio(5, count: 2250)
    let second = Self.audio(6, count: 2400) + spot + Self.audio(7, count: 2400)
    let shared = Self.hashes(0..<10)
    let result = LearnedAdMerging.collapse(
      [
        ad(1, shared.union(Self.hashes(100..<140))), ad(2, shared.union(Self.hashes(200..<240))), ad(3, shared),
      ],
      prints: [1: AudioPrint(words: first), 2: AudioPrint(words: second), 3: AudioPrint(words: spot)])
    #expect(result.creatives.map(\.id) == [1, 2])
    #expect(result.absorbed == [3: 1])
    #expect(result.creatives[1].hashes == shared.union(Self.hashes(200..<240)))
  }

  @Test func equalPrintsKeepTheOlderId() {
    let recording = AudioPrint(words: Self.audio(9, count: 3000))
    let store = [ad(7, Self.hashes(0..<40)), ad(3, Self.hashes(0..<40))]
    let collapse = LearnedAdMerging.collapse(store, prints: [3: recording, 7: recording])
    #expect(collapse.creatives.map(\.id) == [3])
    #expect(collapse.absorbed == [7: 3])
    let unprinted = LearnedAdMerging.collapse(store, prints: [:])
    #expect(unprinted.creatives.map(\.id) == [3])
  }

  @Test func collapsingIsTheSameInAnyInputOrderAndSettlesInOneRun() {
    // A chain: 1 is the same as 2 and 2 as 3, but 1 and 3 share too little.
    let store = [
      ad(1, Self.hashes(0..<50)), ad(2, Self.hashes(8..<58)), ad(3, Self.hashes(16..<66)),
      ad(4, Self.hashes(900..<950)),
    ]
    #expect(
      LearnedAdMerging.isSameAd(content(store[0].hashes, nil), content(store[2].hashes, nil)) == false)
    let first = LearnedAdMerging.collapse(store, prints: [:])
    let reversed = LearnedAdMerging.collapse(store.reversed(), prints: [:])
    #expect(first.creatives == reversed.creatives)
    #expect(first.absorbed == reversed.absorbed)
    #expect(first.creatives.map(\.id) == [1, 4])
    #expect(first.creatives.first?.hashes == Self.hashes(0..<66))
    let second = LearnedAdMerging.collapse(first.creatives, prints: [:])
    #expect(second.creatives == first.creatives)
    #expect(second.absorbed.isEmpty)
  }

  @Test func anAdThatWouldPassTheHashLimitStaysSeparate() {
    let limit = UInt64(LearnedAdMerging.maximumHashes)
    let store = [ad(1, Self.hashes(0..<limit)), ad(2, Self.hashes(0..<40).union([limit + 1]))]
    let collapse = LearnedAdMerging.collapse(store, prints: [:])
    #expect(collapse.creatives.map(\.id) == [1, 2])
    #expect(collapse.absorbed.isEmpty)
  }

  /// A confirmed ad is the listener's own word. It neither absorbs nor is absorbed by a copy.
  @Test func aConfirmedAdIsNeverCollapsed() {
    let a = EpisodeKey("a")
    let b = EpisodeKey("b")
    let words = Self.hashes(0..<40)
    let confirmed = SignatureCreative(
      id: 1, kind: .learned, lastSeen: epoch.addingTimeInterval(10), start: 0, end: 30,
      teachers: [a], hashes: words, confirmed: true)
    let copy = ad(2, words, teachers: [b], seen: 20)
    let other = ad(3, words, teachers: [b], seen: 30)
    let collapse = LearnedAdMerging.collapse([confirmed, copy, other], prints: [:])
    #expect(collapse.creatives.map(\.id) == [1, 2])
    #expect(collapse.absorbed == [3: 2])
    #expect(collapse.creatives.first == confirmed)
  }
}
