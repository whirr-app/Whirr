import Foundation
import Testing

@testable import AdSkip

@Suite struct SignatureStoreTests {
  private let a = EpisodeKey("a")
  private let b = EpisodeKey("b")
  private let epoch = Date(timeIntervalSince1970: 1_000_000_000)

  private func creative(
    _ id: Int64, _ kind: SignatureCreative.Kind = .learned, seen: Date? = nil,
    teachers: Set<EpisodeKey> = [], hashes: Set<UInt64> = [], confirmed: Bool = false
  ) -> SignatureCreative {
    SignatureCreative(
      id: id, kind: kind, lastSeen: seen ?? epoch, start: 0, end: 1, teachers: teachers,
      hashes: hashes, confirmed: confirmed)
  }

  @Test func learnedMatchesExcludeTheTeachingGroup() {
    let store = SignatureStore(creatives: [
      creative(1, teachers: [a], hashes: [10]), creative(2, teachers: [b], hashes: [10, 11]),
    ])
    #expect(store.learnedMatches(10, excludingGroup: [a]) == [2])
    #expect(store.learnedMatches(10, excludingGroup: [EpisodeKey("z")]).sorted() == [1, 2])
    #expect(store.learnedMatches(10, excludingGroup: [a, b]).isEmpty)
    #expect(store.learnedMatches(99, excludingGroup: []).isEmpty)
  }

  /// An ad matches unless every teacher is in the episode's group.
  @Test func aLearnedAdMatchesUnlessEveryTeacherIsInTheGroup() {
    let a2 = EpisodeKey("a2")
    let z = EpisodeKey("z")
    func matches(_ teachers: Set<EpisodeKey>, _ group: Set<EpisodeKey>) -> Bool {
      SignatureStore(creatives: [creative(1, teachers: teachers, hashes: [10])])
        .learnedMatches(10, excludingGroup: group) == [1]
    }
    // Restored without teachers.
    #expect(matches([], [a]))
    #expect(matches([a], [a]) == false)
    // A later link joined the teacher's group.
    #expect(matches([a], [a, a2]) == false)
    #expect(matches([a], [z]))
    // Merged from two groups' copies: each still matches, as it matched the other's copy.
    #expect(matches([a, b], [a]))
    #expect(matches([a, b], [b]))
    // The two were later found to be copies of one episode.
    #expect(matches([a, b], [a, b]) == false)
    // Taught with a linked copy that is no longer analysed.
    #expect(matches([a, a2], [a]))
  }

  @Test func tombstonesAreNotLearnedMatches() {
    let store = SignatureStore(creatives: [creative(1, .tombstone, teachers: [a], hashes: [10])])
    #expect(store.isTombstoned(10))
    #expect(store.isTombstoned(11) == false)
    #expect(store.learnedMatches(10, excludingGroup: []).isEmpty)
  }

  private func prepared() -> PreparedTranscript {
    // 12 words at 1 s cadence (0.9 s long): shingle i spans [i, i + 7.9]; five shingles.
    Fixture.prepared(Fixture.words("w", count: 12, step: 1, length: 0.9))
  }

  @Test func learningTakesOnlyWhollyInsideShingles() {
    let p = prepared()
    // Range [1, 8.9] holds shingle 1 ([1, 8.9]) wholly; shingle 0 starts before, 2 ends after.
    let kept = KeptRange(start: 1, end: 8.9, meanAdProbability: 1, endsItem: false)
    let learned = SignatureStore.learning(from: p, kept: [kept], teachers: [a])
    #expect(learned.count == 1)
    #expect(learned[0].hashes == [p.shingles[1].hash])
    #expect(learned[0].kind == .learned)
    #expect(learned[0].teachers == [a])
    #expect((learned[0].start, learned[0].end) == (1, 8.9))
  }

  @Test func learningYieldsNothingForARangeHoldingNoShingle() {
    let p = prepared()
    let kept = KeptRange(start: 1, end: 8.8, meanAdProbability: 1, endsItem: false)
    #expect(SignatureStore.learning(from: p, kept: [kept], teachers: [a]).isEmpty)
  }

  @Test func learningMakesOneCreativePerRange() {
    let p = prepared()
    let kept = [
      KeptRange(start: 0, end: 7.9, meanAdProbability: 1, endsItem: false),
      KeptRange(start: 0, end: 20, meanAdProbability: 1, endsItem: true),
    ]
    let learned = SignatureStore.learning(from: p, kept: kept, teachers: [a])
    #expect(learned.map(\.hashes.count) == [1, p.shingles.count])
  }

  @Test func tombstoneCoversEveryOverlappingShingle() {
    let p = prepared()
    // Range [8, 9]: shingles 0 ([0, 7.9]) misses; 1 ([1, 8.9]) through 4 ([4, 11.9]) overlap.
    let tomb = SignatureStore.tombstone(from: p, start: 8, end: 9, teachers: [b])
    #expect(tomb?.hashes == Set(p.shingles[1...4].map(\.hash)))
    #expect(tomb?.kind == .tombstone)
    #expect(tomb?.teachers == [b])
    #expect(tomb.map { ($0.start, $0.end) } ?? (0, 0) == (8, 9))
  }

  @Test func tombstoneIdsAreReportedPerHash() {
    let store = SignatureStore(creatives: [
      creative(1, .tombstone, hashes: [10]), creative(2, .tombstone, hashes: [10, 11]),
      creative(3, hashes: [10]),
    ])
    #expect(store.tombstones(holding: 10).sorted() == [1, 2])
    #expect(store.tombstones(holding: 12).isEmpty)
  }

  @Test func tombstoneOfNothingIsNil() {
    #expect(SignatureStore.tombstone(from: prepared(), start: 50, end: 60, teachers: [a]) == nil)
  }

  @Test func expiryBoundaryIsExclusive() {
    let now = epoch.addingTimeInterval(SignatureStore.expiry)
    let store = SignatureStore(creatives: [
      creative(1, seen: epoch), creative(2, seen: epoch.addingTimeInterval(-1)),
      creative(3, seen: epoch.addingTimeInterval(1)),
    ])
    #expect(store.expired(asOf: now) == [2])
    #expect(SignatureStore.expiry == 90 * 86_400)
  }

  @Test func aConfirmedCreativeNeverExpires() {
    let now = epoch.addingTimeInterval(SignatureStore.expiry * 2)
    let store = SignatureStore(creatives: [
      creative(1, seen: epoch, confirmed: true), creative(2, seen: epoch),
    ])
    #expect(store.expired(asOf: now) == [2])
  }

  /// The predicate the backup filters bytes with is this one: a confirmed creative survives any
  /// age, and an unconfirmed one expires strictly after `expiry`, not on the boundary.
  @Test func expiryIsOnePredicateForConfirmedAndUnconfirmedCreatives() {
    let atExpiry = epoch.addingTimeInterval(SignatureStore.expiry)
    let pastExpiry = atExpiry.addingTimeInterval(1)

    #expect(SignatureStore.isExpired(confirmed: true, lastSeen: epoch, asOf: pastExpiry) == false)
    #expect(SignatureStore.isExpired(confirmed: false, lastSeen: epoch, asOf: atExpiry) == false)
    #expect(SignatureStore.isExpired(confirmed: false, lastSeen: epoch, asOf: pastExpiry))
  }

  /// The listener's ads go after every other, however old, and among themselves oldest first.
  @Test func aConfirmedCreativeIsEvictedAfterEveryOther() {
    let store = SignatureStore(creatives: [
      creative(1, seen: epoch, hashes: [1, 2], confirmed: true),
      creative(2, seen: epoch.addingTimeInterval(10), hashes: [3, 4]),
      creative(3, seen: epoch.addingTimeInterval(20), hashes: [5, 6]),
      creative(4, seen: epoch.addingTimeInterval(5), hashes: [7, 8], confirmed: true),
    ])
    #expect(store.evictions(cap: 4) == [2, 3])
    #expect(store.evictions(cap: 2) == [2, 3, 1])
    #expect(store.evictions(cap: 0) == [2, 3, 1, 4])
  }

  @Test func evictionStopsOnceUnderTheCap() {
    let store = SignatureStore(creatives: [
      creative(1, seen: epoch.addingTimeInterval(30), hashes: [1, 2, 3]),
      creative(2, seen: epoch.addingTimeInterval(10), hashes: [4, 5, 6]),
      creative(3, seen: epoch.addingTimeInterval(20), hashes: [7, 8, 9]),
    ])
    #expect(store.evictions(cap: 9).isEmpty)
    #expect(store.evictions(cap: 8) == [2])
    #expect(store.evictions(cap: 6) == [2])
    #expect(store.evictions(cap: 5) == [2, 3])
    #expect(store.evictions(cap: 0) == [2, 3, 1])
  }

  @Test func evictionTiesBreakByAscendingIdAndCountTombstones() {
    let store = SignatureStore(creatives: [
      creative(5, .tombstone, hashes: [1, 2]), creative(2, hashes: [3, 4]),
      creative(9, hashes: [5, 6]),
    ])
    #expect(store.evictions(cap: 4) == [2])
    #expect(store.evictions(cap: 2) == [2, 5])
  }
}
