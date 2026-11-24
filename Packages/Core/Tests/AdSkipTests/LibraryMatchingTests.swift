import Foundation
import Testing

@testable import AdSkip

@Suite struct LibraryMatchingTests {
  private let one = EpisodeKey("one")
  private let two = EpisodeKey("two")
  private let three = EpisodeKey("three")

  /// A 20 s block of identical words (40 words at 0.5 s) shared by episodes one and two.
  private func ad() -> [TranscriptWord] {
    Fixture.words("ad", count: 40, step: 0.5, length: 0.4)
  }

  private func episode(_ id: String, adStart: Double?) -> PreparedTranscript {
    var words = Fixture.words(id + "pre", count: 20, from: 0)  // 0 ... 10 s
    if let adStart {
      words += ad().map {
        TranscriptWord(text: $0.text, start: $0.start + adStart, end: $0.end + adStart)
      }
    }
    let tail = (adStart ?? 10) + 20
    words += Fixture.words(id + "post", count: 20, from: tail + 0.5)
    return Fixture.prepared(words)
  }

  private func context(
    store: SignatureStore = SignatureStore(creatives: [])
  ) -> (PreparedTranscript, LibraryIndex, EpisodeGroups, SignatureStore) {
    let one = episode("one", adStart: 10.5)
    let two = episode("two", adStart: 10.5)
    let three = episode("three", adStart: nil)
    let shingles = [self.one: one.shingleHashes, self.two: two.shingleHashes, self.three: three.shingleHashes]
    let groups = EpisodeGrouping.groups(shingles: shingles, identityLinks: [])
    return (one, LibraryIndex(shingles: shingles), groups, store)
  }

  @Test func sharedAdRunIsACandidate() {
    let (prepared, index, groups, store) = context()
    let result = LibraryMatching.candidates(
      for: one, transcript: prepared, groups: groups, library: index, store: store)
    #expect(result.candidates.count == 1)
    let range = result.candidates[0].range
    #expect(range.start == 10.5)
    #expect(range.end - range.start >= 15)
    #expect(result.candidates.allSatisfy { $0.storeCreatives.isEmpty })
  }

  @Test func theEpisodeWithoutTheAdHasNoCandidates() {
    let (_, index, groups, store) = context()
    let three = episode("three", adStart: nil)
    let result = LibraryMatching.candidates(
      for: self.three, transcript: three, groups: groups, library: index, store: store)
    #expect(result.candidates.isEmpty)
  }

  @Test func copiesOfTheSameEpisodeDoNotMatchEachOther() {
    let one = episode("one", adStart: 10.5)
    let shingles = [self.one: one.shingleHashes, self.two: one.shingleHashes]
    let groups = EpisodeGrouping.groups(shingles: shingles, identityLinks: [])
    let result = LibraryMatching.candidates(
      for: self.one, transcript: one, groups: groups, library: LibraryIndex(shingles: shingles),
      store: SignatureStore(creatives: []))
    #expect(result.candidates.isEmpty)
  }

  @Test func aTombstoneVetoesLibraryHits() {
    let (prepared, index, groups, _) = context()
    let tomb = SignatureStore.tombstone(
      from: prepared, start: 10.5, end: 30.5, teachers: [one])
    let store = SignatureStore(creatives: [
      SignatureCreative(
        id: 1, kind: .tombstone, lastSeen: Date(), start: 10.5, end: 30.5, teachers: [one],
        hashes: tomb?.hashes ?? [])
    ])
    let result = LibraryMatching.candidates(
      for: one, transcript: prepared, groups: groups, library: index, store: store)
    #expect(result.candidates.isEmpty)
    #expect(result.matchedTombstones == [1])
  }

  @Test func learnedCreativesHitForOtherEpisodesAndReportTheirIds() {
    // The ad appears only in episode three's library neighbour via the store.
    let three = episode("three", adStart: 10.5)
    let hashes = three.shingleHashes
    let creative = SignatureCreative(
      id: 7, kind: .learned, lastSeen: Date(), start: 10.5, end: 30.5, teachers: [two],
      hashes: hashes)
    let store = SignatureStore(creatives: [creative])
    let shingles = [self.three: hashes]
    let groups = EpisodeGrouping.groups(shingles: shingles, identityLinks: [])
    let result = LibraryMatching.candidates(
      for: self.three, transcript: three, groups: groups,
      library: LibraryIndex(shingles: shingles), store: store)
    #expect(result.candidates.count == 1)
    #expect(result.candidates.map(\.storeCreatives) == [[7]])
  }

  @Test func theTeachingGroupDoesNotMatchItsOwnLearning() {
    let three = episode("three", adStart: 10.5)
    let store = SignatureStore(creatives: [
      SignatureCreative(
        id: 7, kind: .learned, lastSeen: Date(), start: 10.5, end: 30.5, teachers: [self.three],
        hashes: three.shingleHashes)
    ])
    let shingles = [self.three: three.shingleHashes]
    let groups = EpisodeGrouping.groups(shingles: shingles, identityLinks: [])
    let result = LibraryMatching.candidates(
      for: self.three, transcript: three, groups: groups,
      library: LibraryIndex(shingles: shingles), store: store)
    #expect(result.candidates.isEmpty)
    #expect(result.candidates.allSatisfy { $0.storeCreatives.isEmpty })
  }

  @Test func libraryIndexOccursOutsideOnlyForOtherEpisodes() {
    let index = LibraryIndex(shingles: [one: [1, 2], two: [2, 3]])
    #expect(index.occursOutside(2, group: [one]))
    #expect(index.occursOutside(1, group: [one]) == false)
    #expect(index.occursOutside(2, group: [one, two]) == false)
    #expect(index.occursOutside(9, group: []) == false)
  }
}

@Suite struct LibraryMatchingAttributionTests {
  private let one = EpisodeKey("one")
  private let two = EpisodeKey("two")

  /// Two 20 s ads in episode one, 60 s apart: `lib` also airs in episode two, `kept` only in the
  /// store.
  private func episodeOne() -> PreparedTranscript {
    var words = Fixture.words("intro", count: 20)
    words += Fixture.words("lib", count: 40, from: 10.5)
    words += Fixture.words("gap", count: 60, from: 31)
    words += Fixture.words("kept", count: 40, from: 61.5)
    words += Fixture.words("outro", count: 20, from: 82)
    return Fixture.prepared(words)
  }

  @Test func storeCreativesAreAttributedToTheCandidateTheyHit() {
    let prepared = episodeOne()
    let two = Fixture.prepared(Fixture.words("lib", count: 40))
    let stored = Set(prepared.shingles.filter { $0.start >= 61.5 && $0.end <= 82 }.map(\.hash))
    let store = SignatureStore(creatives: [
      SignatureCreative(
        id: 4, kind: .learned, lastSeen: Date(), start: 0, end: 20, teachers: [EpisodeKey("x")],
        hashes: stored)
    ])
    let shingles = [one: prepared.shingleHashes, self.two: two.shingleHashes]
    let result = LibraryMatching.candidates(
      for: one, transcript: prepared,
      groups: EpisodeGrouping.groups(shingles: shingles, identityLinks: []),
      library: LibraryIndex(shingles: shingles), store: store)
    #expect(result.candidates.count == 2)
    #expect(result.candidates[0].storeCreatives.isEmpty)
    #expect(result.candidates[1].storeCreatives == [4])
    #expect(result.matchedTombstones.isEmpty)
  }

  @Test func aTombstonedHashReportsTheTombstoneAndNotTheLearnedCreative() {
    let prepared = episodeOne()
    let hashes = Set(prepared.shingles.filter { $0.start >= 61.5 && $0.end <= 82 }.map(\.hash))
    let store = SignatureStore(creatives: [
      SignatureCreative(
        id: 4, kind: .learned, lastSeen: Date(), start: 0, end: 20, teachers: [EpisodeKey("x")],
        hashes: hashes),
      SignatureCreative(
        id: 5, kind: .tombstone, lastSeen: Date(), start: 0, end: 20, teachers: [EpisodeKey("x")],
        hashes: hashes),
    ])
    let shingles = [one: prepared.shingleHashes]
    let result = LibraryMatching.candidates(
      for: one, transcript: prepared,
      groups: EpisodeGrouping.groups(shingles: shingles, identityLinks: []),
      library: LibraryIndex(shingles: shingles), store: store)
    #expect(result.candidates.isEmpty)
    #expect(result.matchedTombstones == [5])
  }
}
