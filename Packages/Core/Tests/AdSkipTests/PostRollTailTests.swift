import Foundation
import Testing

@testable import AdSkip

@Suite struct PostRollTailTests {
  private let silences = [Silence(start: 3_067.36, end: 3_069.08)]
  private let duration = 3_099.14
  /// The tail window, from 12.5 s before the silence to the end of the file.
  private let tailWindow = TimeSpan(start: 3_054.86, end: 3_099.14)

  private func kept(_ start: Double, _ end: Double) -> KeptRange {
    KeptRange(start: start, end: end, meanAdProbability: 0.9, endsItem: false)
  }

  @Test func aTranscribedTailIsACandidateFromTheSilencesEnd() {
    let candidate = PostRollTail.candidate(
      silences: silences, duration: duration, sameShow: [], coverage: [tailWindow], kept: [])
    #expect(candidate == CandidateRange(start: 3_069.08, end: 3_099.14))
  }

  @Test func aTailNotYetTranscribedIsNoCandidate() {
    #expect(
      PostRollTail.candidate(silences: silences, duration: duration, sameShow: [], coverage: [], kept: [])
        == nil)
    // Short of the window's context, or short of the end.
    for coverage in [
      TimeSpan(start: 3_060, end: 3_099.14), TimeSpan(start: 3_054.86, end: 3_090),
    ] {
      #expect(
        PostRollTail.candidate(
          silences: silences, duration: duration, sameShow: [], coverage: [coverage], kept: []) == nil)
    }
  }

  @Test func aTailTheTriggerRejectsIsNoCandidate() {
    #expect(
      PostRollTail.candidate(
        silences: silences, duration: duration, sameShow: [TimeSpan(start: 3_070, end: 3_099)],
        coverage: [tailWindow], kept: []) == nil)
  }

  @Test func aKeptRangeOverlappingTheTailOwnsIt() {
    for range in [kept(3_060, 3_070), kept(3_080, 3_099.14), kept(3_000, 3_099.14)] {
      #expect(
        PostRollTail.candidate(
          silences: silences, duration: duration, sameShow: [], coverage: [tailWindow], kept: [range])
          == nil)
    }
    // One that ends at the silence's end, or earlier, does not.
    #expect(
      PostRollTail.candidate(
        silences: silences, duration: duration, sameShow: [], coverage: [tailWindow],
        kept: [kept(2_042.22, 2_146.97), kept(3_040, 3_069.08)]) != nil)
  }

  // MARK: - Undo

  /// Words two to a second from `start`, `count` of them, tagged `tag`.
  private static func words(_ tag: String, from start: Double, count: Int) -> [TranscriptWord] {
    (0..<count).map {
      let wordStart = start + Double($0) * 0.5
      return TranscriptWord(text: "\(tag)\($0)", start: wordStart, end: wordStart + 0.4)
    }
  }

  /// Twelve outro words to 106.0 s, a 1.2 s silence, then forty post-roll words to the end.
  private static let covered = PreparedTranscript(
    transcript: Transcript(
      words: words("outro", from: 100, count: 12) + words("post", from: 107.2, count: 40),
      duration: 127.2),
    silences: [Silence(start: 106, end: 107.2)])

  @Test func aTailTombstoneNamesNoShingleTheIndexHolds() throws {
    // The outro was in a stage-1 window; the tail's words never are.
    let index = PreparedTranscript(
      transcript: Transcript(words: Self.words("outro", from: 100, count: 12), duration: 127.2),
      silences: [])
    let tombstone = try #require(
      PostRollTail.tombstone(
        covered: Self.covered, index: index, start: 106, end: 127.2, teachers: [EpisodeKey("a")]))
    #expect(tombstone.kind == .tombstone)
    #expect(tombstone.hashes.isDisjoint(with: index.shingles.map(\.hash)))
    // Every shingle of the post-roll's own words is held.
    let post = Self.covered.shingles.filter { $0.start >= 107.2 }
    #expect(post.isEmpty == false)
    #expect(Set(post.map(\.hash)).isSubset(of: tombstone.hashes))
    // An index holding the whole range leaves nothing to tombstone.
    #expect(
      PostRollTail.tombstone(
        covered: Self.covered, index: Self.covered, start: 106, end: 127.2, teachers: []) == nil)
  }

  @Test func aTombstoneHoldingTheTailsWordsUndoesIt() throws {
    let tombstone = try #require(
      PostRollTail.tombstone(
        covered: Self.covered,
        index: PreparedTranscript(transcript: Transcript(words: [], duration: 127.2), silences: []),
        start: 106, end: 127.2, teachers: [EpisodeKey("a")]))
    let store = SignatureStore(creatives: [
      SignatureCreative(
        id: 7, kind: .tombstone, lastSeen: Date(), start: 106, end: 127.2, teachers: [EpisodeKey("a")],
        hashes: tombstone.hashes)
    ])
    let candidate = CandidateRange(start: 107.2, end: 127.2)
    #expect(PostRollTail.undoing(candidate, in: Self.covered, store: store) == [7])
    #expect(PostRollTail.undoing(candidate, in: Self.covered, store: SignatureStore(creatives: [])).isEmpty)
  }

  @Test func aNeighboursTombstoneDoesNotUndoTheTail() {
    // An undone range that ended at the silence holds shingles that run on past it, but none
    // lying wholly in the tail.
    let straddling = Set(
      Self.covered.shingles.filter { $0.start < 106 && $0.end > 107.2 }.map(\.hash))
    #expect(straddling.isEmpty == false)
    let store = SignatureStore(creatives: [
      SignatureCreative(
        id: 3, kind: .tombstone, lastSeen: Date(), start: 90, end: 106, teachers: [],
        hashes: Set(Self.covered.shingles.filter { $0.start < 106 }.map(\.hash)))
    ])
    #expect(
      PostRollTail.undoing(CandidateRange(start: 107.2, end: 127.2), in: Self.covered, store: store)
        .isEmpty)
  }

  @Test func aTailTooShortForAWholeShingleIsHeldByOneOverlappingIt() {
    let short = PreparedTranscript(
      transcript: Transcript(
        words: Self.words("outro", from: 100, count: 12) + Self.words("post", from: 107.2, count: 3),
        duration: 118),
      silences: [Silence(start: 106, end: 107.2)])
    let hashes = Set(short.shingles.filter { $0.end > 107.2 }.map(\.hash))
    #expect(hashes.isEmpty == false)
    let store = SignatureStore(creatives: [
      SignatureCreative(
        id: 4, kind: .tombstone, lastSeen: Date(), start: 106, end: 118, teachers: [], hashes: hashes)
    ])
    #expect(PostRollTail.undoing(CandidateRange(start: 107.2, end: 118), in: short, store: store) == [4])
  }

  @Test func theArbitersCutIsTheDefaultAndTheTailsIsStricter() {
    let transcript = Transcript(
      words: [TranscriptWord(text: "ad", start: 1, end: 2)], duration: 10)
    let steps = Arbiter.steps(for: transcript)
    let candidate = CandidateRange(start: 0, end: 10)
    let probabilities = Dictionary(uniqueKeysWithValues: steps.indices.map { ($0, 0.3) })
    #expect(
      Arbiter.keep([candidate], transcript: transcript, steps: steps, probabilities: probabilities)
        .count == 1)
    #expect(
      Arbiter.keep(
        [candidate], transcript: transcript, steps: steps, probabilities: probabilities,
        threshold: PostRollTail.keepThreshold
      ).isEmpty)
  }
}
