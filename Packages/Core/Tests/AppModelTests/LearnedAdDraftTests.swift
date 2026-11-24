import AdSkip
import Foundation
import Persistence
import SyncEngine
import Testing

@testable import AppModel

/// The pass's draft of the signature store: which of the four
/// learning cases a kept range takes, and the one store change that comes out.
@Suite struct LearnedAdDraftTests {
  private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  private var now: Date { epoch.addingTimeInterval(1_000) }

  private static func audio(_ seed: UInt64, count: Int) -> [UInt32] {
    var state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1
    return (0..<count).map { _ in
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return UInt32(truncatingIfNeeded: state >> 32)
    }
  }

  private func keys(_ names: String...) -> Set<EpisodeKey> { Set(names.map(EpisodeKey.init)) }

  private func stored(
    _ id: Int64, _ hashes: Range<UInt64>, teachers: Set<EpisodeKey>, start: Double = 10, seen: TimeInterval = 0
  ) -> SignatureCreative {
    SignatureCreative(
      id: id, kind: .learned, lastSeen: epoch.addingTimeInterval(seen), start: start, end: start + 30,
      teachers: teachers, hashes: Set(hashes))
  }

  private func range(
    _ hashes: Set<UInt64>, teachers: Set<EpisodeKey>, start: Double = 10
  ) -> NewSignatureCreative {
    NewSignatureCreative(kind: .learned, start: start, end: start + 30, teachers: teachers, hashes: hashes)
  }

  private func makeDraft(_ loaded: [SignatureCreative], prints: [Int64: AudioPrint] = [:]) -> LearnedAdDraft {
    LearnedAdDraft(loaded: loaded, expired: [], prints: prints)
  }

  @Test func aRangeTheStoreAlreadyHoldsOnlyRefreshesIt() {
    var draft = makeDraft([stored(1, 0..<50, teachers: keys("a", "b"))])
    draft.learn(range(Set(0..<40), teachers: keys("a")), print: nil, now: now)
    #expect(draft.change(matched: [:], now: now) == AdSignatureStoreChange(seen: [1: now]))
  }

  /// One episode carries the ad twice. The second range joins the first's ad, and on the next
  /// pass both are already held: no id changes, so the audio library is not dropped.
  @Test func anAdCarriedTwiceByOneEpisodeIsOneAdAndStaysIt() {
    var first = makeDraft([])
    first.learn(range(Set(0..<50), teachers: keys("a"), start: 10), print: nil, now: now)
    first.learn(range(Set(0..<50), teachers: keys("a"), start: 200), print: nil, now: now)
    let change = first.change(matched: [:], now: now)
    #expect(change.deletions.isEmpty && change.additions.isEmpty)
    #expect(change.insertions.map(\.startTime) == [10])

    var second = makeDraft([stored(1, 0..<50, teachers: keys("a"), start: 10)])
    second.learn(range(Set(0..<50), teachers: keys("a"), start: 10), print: nil, now: now)
    second.learn(range(Set(0..<50), teachers: keys("a"), start: 200), print: nil, now: now)
    #expect(second.change(matched: [:], now: now) == AdSignatureStoreChange(seen: [1: now]))
  }

  @Test func whatOnlyThisGroupTaughtForAnOverlappingRangeIsReplaced() {
    var draft = makeDraft([stored(1, 0..<50, teachers: keys("a"), start: 10)])
    draft.learn(range(Set(100..<150), teachers: keys("a", "a2"), start: 12), print: nil, now: now)
    let change = draft.change(matched: [1: now], now: now)
    #expect(change.deletions == [1] && change.seen.isEmpty)
    #expect(change.insertions.map(\.hashes) == [Set(100..<150)])
    #expect(draft.successors(inserted: [7], surviving: [7]) == [1: 7])
    #expect(draft.successors(inserted: [7], surviving: []) == [:])
  }

  /// "Every teacher in the group", not "any": a merged ad's range is another episode's.
  @Test func anAdAnotherGroupAlsoTaughtIsNotReplaced() {
    var draft = makeDraft([stored(1, 0..<50, teachers: keys("a", "z"), start: 10)])
    draft.learn(range(Set(100..<150), teachers: keys("a"), start: 12), print: nil, now: now)
    let change = draft.change(matched: [:], now: now)
    #expect(change.deletions.isEmpty)
    #expect(change.insertions.count == 1)
  }

  @Test func theSameAdFromAnotherEpisodeAddsATeacherAndItsNewHashes() {
    var draft = makeDraft([stored(1, 0..<50, teachers: keys("a"))])
    draft.learn(range(Set(5..<55), teachers: keys("b")), print: nil, now: now)
    #expect(
      draft.change(matched: [:], now: now)
        == AdSignatureStoreChange(
          additions: [1: AdSignatureAddition(teachers: ["b"], hashes: Set(50..<55))], seen: [1: now]))
  }

  /// A longer break containing a stored ad becomes the survivor; ranges that named the stored ad
  /// name the new one.
  @Test func aLongerPrintBecomesTheSurvivorAndTheOldAdIsRenamed() {
    let spot = Self.audio(1, count: 3000)
    let longer = Self.audio(2, count: 600) + spot + Self.audio(3, count: 600)
    var draft = makeDraft([stored(5, 0..<50, teachers: keys("a"))], prints: [5: AudioPrint(words: spot)])
    draft.learn(range(Set(0..<60), teachers: keys("b"), start: 300), print: AudioPrint(words: longer), now: now)
    let change = draft.change(matched: [5: now], now: now)
    #expect(change.deletions == [5] && change.additions.isEmpty && change.seen.isEmpty)
    #expect(change.insertions.map(\.teachers) == [["a", "b"]])
    #expect(change.insertions.map(\.hashes) == [Set(0..<60)])
    #expect(change.insertions.map(\.startTime) == [300])
    #expect(change.insertions.first?.audioPrint == AudioPrint(words: longer).data)
    #expect(draft.successors(inserted: [9], surviving: [9]) == [5: 9])
  }

  /// A stored ad with no print never gains one, so a printed range of the same ad takes over.
  @Test func anAdWithNoPrintGivesWayToAPrintedRange() {
    var draft = makeDraft([stored(1, 0..<50, teachers: keys("a"))])
    draft.learn(range(Set(0..<50), teachers: keys("a")), print: AudioPrint(words: Self.audio(1, count: 3000)), now: now)
    let change = draft.change(matched: [:], now: now)
    #expect(change.deletions == [1])
    #expect(change.insertions.count == 1 && change.insertions.first?.audioPrint != nil)
  }

  /// The stored copies collapse before anything is matched: the pass matches the survivor, the
  /// absorbed copy is deleted and renamed, and the survivor takes the later date.
  @Test func storedCopiesCollapseAndTheSurvivorTakesTheLaterDate() {
    let draft = makeDraft([
      stored(1, 0..<50, teachers: keys("a"), seen: 0), stored(2, 0..<50, teachers: keys("b"), seen: 500),
      SignatureCreative(
        id: 3, kind: .tombstone, lastSeen: epoch, start: 0, end: 5, teachers: keys("a"), hashes: [900]),
    ])
    #expect(draft.collapsed.map(\.id) == [1, 3])
    #expect(draft.collapsed.first?.teachers == keys("a", "b"))
    #expect(
      draft.change(matched: [2: now], now: now)
        == AdSignatureStoreChange(
          deletions: [2], additions: [1: AdSignatureAddition(teachers: ["b"])],
          seen: [1: epoch.addingTimeInterval(500)]))
    #expect(draft.successors(inserted: [], surviving: [1, 3]) == [2: 1])
  }

  @Test func anExpiredAdIsDeletedAndNeverMerged() {
    let draft = LearnedAdDraft(
      loaded: [stored(1, 0..<50, teachers: keys("a")), stored(2, 0..<50, teachers: keys("b"))], expired: [1],
      prints: [:])
    #expect(draft.collapsed.map(\.id) == [2])
    #expect(draft.change(matched: [:], now: now) == AdSignatureStoreChange(deletions: [1]))
  }

  // MARK: - Audio keys

  @Test func aLearnedPrintCarriesItsTeachersOnlyWhenOneLinkedGroupHoldsThemAll() {
    let groups = [
      EpisodeKey("a"): keys("a", "a2"), EpisodeKey("a2"): keys("a", "a2"), EpisodeKey("b"): keys("b"),
    ]
    #expect(AdSkipPlanBook.audioKeys(teachers: keys("a"), groups: groups) == keys("a"))
    #expect(AdSkipPlanBook.audioKeys(teachers: keys("a", "a2"), groups: groups) == keys("a", "a2"))
    // Two groups: the ad may open a window on either.
    #expect(AdSkipPlanBook.audioKeys(teachers: keys("a", "b"), groups: groups).isEmpty)
    // A teacher that has left the phone is outside every group.
    #expect(AdSkipPlanBook.audioKeys(teachers: keys("a", "gone"), groups: groups).isEmpty)
    #expect(AdSkipPlanBook.audioKeys(teachers: keys("gone"), groups: groups).isEmpty)
    #expect(AdSkipPlanBook.audioKeys(teachers: keys(), groups: groups).isEmpty)
  }
}

/// The same two limits are written in three targets that cannot see one another.
@Suite struct LearnedAdLimitsTests {
  @Test func theTeacherAndHashLimitsAreTheBackupFiles() {
    #expect(LearnedAdMerging.maximumTeachers == PodcastLearnedAdsSnapshotCodec.maxTeachersPerAd)
    #expect(NativePodcastBackupRestorer.maximumLearnedAdTeachers == PodcastLearnedAdsSnapshotCodec.maxTeachersPerAd)
    #expect(LearnedAdMerging.maximumHashes == PodcastLearnedAdsSnapshotCodec.maxHashesPerAd)
  }
}
