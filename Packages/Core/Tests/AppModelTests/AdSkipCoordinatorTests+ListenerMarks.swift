import AdSkip
import Foundation
import Persistence
import PlayerCore
import TestSupport
import Testing

@testable import AppModel

/// The listener's own ad marks: served whole, taught as confirmed ads, and never lost to a
/// recompute or an Undo of something else.
extension AdSkipCoordinatorTests {
  private static func key(_ id: String) -> String { Harness.identity(id).episodeKey.rawValue }

  /// 100 s of programme, the ad from 100.0 s to 119.9 s, and 100 s more, which analysis alone
  /// cannot call an ad.
  private static func unflagged(_ tag: String) -> Transcript {
    transcript(programme(tag, count: 200) + ad + programme(tag + "x", count: 200))
  }

  /// One analysed episode "a" whose listener transcript is its own, and nothing flagged in it.
  private func analysedAlone(
    wholeFiles: Bool = false
  ) async throws -> (Harness, AdSkipLocalEpisode) {
    let harness = try Harness(wholeFiles: wholeFiles)
    let a = harness.episode("a", transcript: Self.unflagged("a"))
    harness.listener.set(a.identity, Self.unflagged("a"))
    await harness.run([a])
    #expect(try await harness.ranges("a").isEmpty)
    return (harness, a)
  }

  private func marks(_ harness: Harness, _ id: String) async throws -> [AdSkipListenerMark] {
    guard let row = try await harness.episodes.episode(for: Harness.identity(id)), let rowId = row.id
    else { return [] }
    return try await harness.episodes.listenerMarks(forEpisodeId: rowId)
  }

  private func mark(
    _ harness: Harness, _ episode: AdSkipLocalEpisode, _ start: Double, _ end: Double
  ) async {
    await harness.coordinator.markAd(identity: episode.identity, start: start, end: end)
    await harness.coordinator.waitUntilIdle()
  }

  // MARK: - Serving and teaching

  @Test func aMarkIsServedWholeAndTeachesAConfirmedAdAnotherEpisodeMatches() async throws {
    let (harness, a) = try await analysedAlone()
    await mark(harness, a, 100, 120)

    let ranges = try await harness.ranges("a")
    #expect(ranges.count == 1)
    let served = try #require(ranges.first)
    #expect(served.fromListener && served.startTime == 100 && served.endTime == 120)
    #expect(served.meanAdProbability == 1 && served.fromStore == false && served.endsItem == false)
    #expect(
      await harness.coordinator.transcriptAdRanges(for: a.identity) == [
        TranscriptAdRange(start: 100, end: 120, origin: .listener)
      ])

    let creatives = try await harness.signatures.allCreatives()
    let taught = try #require(creatives.first)
    #expect(creatives.count == 1 && taught.kind == .learned && taught.confirmed)
    #expect(taught.teachers == [Self.key("a")] && taught.hashes.isEmpty == false)
    #expect(try await marks(harness, "a").map(\.creativeId) == [taught.id])

    // Another episode carrying the same ad skips it, from the confirmed ad.
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let matched = try await harness.ranges("b")
    #expect(matched.map(\.creativeId) == [taught.id] && matched.first?.fromStore == true)
    #expect(try await harness.ranges("a").map(\.fromListener) == [true])

    // The learning passes leave the listener's ad as it was: it is not merged into or added to.
    let c = harness.episode("c", transcript: Self.withAd("c"))
    await harness.run([a, b, c])
    let held = try await harness.signatures.allCreatives().filter(\.confirmed)
    #expect(held.map(\.id) == [taught.id] && held.first?.teachers == [Self.key("a")])
    #expect(held.first?.hashes == taught.hashes)
  }

  @Test func aMarkSurvivesARecomputeAndAHostReadPass() async throws {
    let (harness, a) = try await analysedAlone()
    await mark(harness, a, 100, 120)

    await harness.coordinator.forceRecompute()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("a").map(\.fromListener) == [true])

    harness.listener.set(a.identity, Self.unflagged("a"))
    await harness.coordinator.waitUntilIdle()
    let after = try await harness.ranges("a")
    #expect(after.map(\.fromListener) == [true] && after.first?.startTime == 100)
  }

  @Test func aMarkLaidOverADetectedAdCutsItAndTheViewJoinsThemAsTheListeners() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.twoBreaks("a"))
    let b = harness.episode("b", transcript: Self.twoBreaks("b"))
    harness.listener.set(a.identity, Self.twoBreaks("a"))
    await harness.run([a, b])
    let before = try await harness.ranges("a")
    // Two breaks and the gap between them, which break fill served.
    #expect(before.count == 3)
    let first = before[0]
    let second = before[2]

    await mark(harness, a, first.endTime - 10, second.startTime + 10)

    let laid = try await harness.ranges("a")
    #expect(laid.map(\.fromListener) == [false, true, false])
    #expect(laid[0].startTime == first.startTime && laid[0].endTime == first.endTime - 10)
    #expect(laid[1].startTime == first.endTime - 10 && laid[1].endTime == second.startTime + 10)
    #expect(laid[2].startTime == second.startTime + 10 && laid[2].endTime == second.endTime)
    let shown = await harness.coordinator.transcriptAdRanges(for: a.identity)
    #expect(
      shown == [TranscriptAdRange(start: first.startTime, end: second.endTime, origin: .listener)])
  }

  @Test func aMarkMadeWhileAnotherEpisodeIsBeingAnalysedIsNotOverwrittenByThatRecompute() async throws {
    let (harness, a) = try await analysedAlone(wholeFiles: true)
    let c = harness.episode("c", transcript: Self.unflagged("c"))
    harness.transcriber.hold(c.fileURL)
    await harness.coordinator.setLocalEpisodes([a, c])
    #expect(
      await awaitCondition("transcription to be held", until: { harness.transcriber.holding }).isObserved)

    await harness.coordinator.markAd(identity: a.identity, start: 100, end: 120)
    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.ranges("a").map(\.fromListener) == [true])
    #expect(try await marks(harness, "a").count == 1)
  }

  @Test func aMarkIsAppliedWithoutWaitingForCharging() async throws {
    let (harness, a) = try await analysedAlone()
    await harness.coordinator.setAllowed(false)
    await mark(harness, a, 100, 120)
    #expect(try await harness.ranges("a").map(\.fromListener) == [true])
  }

  @Test func theSameSpanMarkedTwiceIsOneMarkAndOneAd() async throws {
    let (harness, a) = try await analysedAlone()
    await mark(harness, a, 100, 120)
    await mark(harness, a, 100, 120)
    #expect(try await marks(harness, "a").count == 1)
    #expect(try await harness.signatures.allCreatives().count == 1)
    #expect(try await harness.ranges("a").count == 1)
  }

  @Test func marksThatOverlapAreServedAsOne() async throws {
    let (harness, a) = try await analysedAlone()
    await mark(harness, a, 100, 120)
    await mark(harness, a, 110, 140)
    #expect(try await marks(harness, "a").count == 2)
    let served = try await harness.ranges("a")
    #expect(served.map(\.startTime) == [100] && served.map(\.endTime) == [140])
  }

  /// Under the 15 s a run needs, it still teaches: its print is what reaches other episodes.
  @Test func aMarkUnderFifteenSecondsTeachesAConfirmedAdWithItsPrint() async throws {
    let (harness, a) = try await analysedAlone()
    await mark(harness, a, 100, 110)
    #expect(try await harness.ranges("a").map(\.fromListener) == [true])
    let taught = try #require(try await harness.signatures.allCreatives().first)
    #expect(taught.confirmed && taught.hasAudioPrint)
    #expect(try await marks(harness, "a").map(\.creativeId) == [taught.id])
    #expect(try await marks(harness, "a").map(\.teachingRevision) == [AdSkipListenerMark.teachingRevision])
  }

  @Test func aMarkOverThisGroupsTombstoneDeletesItAndAnotherGroupsStands() async throws {
    let (harness, a) = try await analysedAlone()
    _ = try await harness.signatures.apply(
      AdSignatureStoreChange(insertions: [
        NewAdSignatureCreative(
          kind: .tombstone, lastSeen: Date(), startTime: 105, endTime: 115,
          teachers: [Self.key("a")], hashes: [1]),
        NewAdSignatureCreative(
          kind: .tombstone, lastSeen: Date(), startTime: 100, endTime: 120, teachers: ["other"],
          hashes: [2]),
        NewAdSignatureCreative(
          kind: .tombstone, lastSeen: Date(), startTime: 200, endTime: 220,
          teachers: [Self.key("a")], hashes: [3]),
      ]))

    await mark(harness, a, 100, 120)

    let tombstones = try await harness.signatures.allCreatives().filter { $0.kind == .tombstone }
    #expect(tombstones.map(\.startTime).sorted() == [100, 200])
    #expect(tombstones.contains { $0.teachers == ["other"] })
  }

  // MARK: - Refusals

  @Test func aMarkIsRefusedWhileAdSkipIsOff() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.unflagged("a"))
    harness.listener.set(a.identity, Self.unflagged("a"))
    await harness.run([a], enabled: false)
    await mark(harness, a, 100, 120)
    #expect(try await harness.episodes.allEpisodes().isEmpty)
    #expect(try await harness.signatures.allCreatives().isEmpty)
  }

  @Test func aMarkOnAnEpisodeNotYetAnalysedIsRefused() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.unflagged("a"))
    harness.listener.set(a.identity, Self.unflagged("a"))
    await harness.run([a], allowed: false)
    await mark(harness, a, 100, 120)
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.signatures.allCreatives().isEmpty)
  }

  @Test func aMarkWithNoCompleteListenerTranscriptIsRefused() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.unflagged("a"))
    await harness.run([a])
    await mark(harness, a, 100, 120)
    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await marks(harness, "a").isEmpty)

    let unread = try Harness(readsListenerTranscripts: false)
    let b = unread.episode("b", transcript: Self.unflagged("b"))
    unread.listener.set(b.identity, Self.unflagged("b"))
    await unread.run([b])
    await mark(unread, b, 100, 120)
    #expect(try await unread.ranges("b").isEmpty)
  }

  @Test func aMarkUnderFiveSecondsIsRefused() async throws {
    let (harness, a) = try await analysedAlone()
    await mark(harness, a, 100, 104.9)
    await mark(harness, a, 120, 110)
    #expect(try await marks(harness, "a").isEmpty)
    #expect(try await harness.ranges("a").isEmpty)
    await mark(harness, a, 100, 105)
    #expect(try await harness.ranges("a").count == 1)
  }

  // MARK: - A short mark beside an ad

  /// Episode "b" with its ad detected, from the library "a" taught, and the listener's transcript
  /// of it.
  private func detectedAd() async throws -> (Harness, AdSkipLocalEpisode, AdSkipRange) {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    harness.listener.set(b.identity, Self.withAd("b"))
    await harness.run([a, b])
    let detected = try #require(try await harness.ranges("b").first)
    #expect(detected.fromListener == false && detected.endTime - detected.startTime > 15)
    return (harness, b, detected)
  }

  @Test func aShortMarkDirectlyBeforeADetectedAdIsSkippedWithItAsOneBlock() async throws {
    let (harness, b, detected) = try await detectedAd()
    await mark(harness, b, detected.startTime - 3, detected.startTime)

    let stored = try await harness.ranges("b")
    #expect(stored.map(\.fromListener) == [true, false])
    #expect(stored[0].endTime - stored[0].startTime == 3)
    #expect(stored[1].startTime == detected.startTime && stored[1].endTime == detected.endTime)

    // The player is given the two ranges within its join gap, which it plays as one skip.
    let served = await harness.coordinator.skipRanges(for: Self.request(b))
    #expect(served.count == 2)
    #expect(served[1].start - served[0].end <= PlaybackEdges.joinGapSeconds)
    #expect(served[0].start == detected.startTime - 3 && served[1].end == detected.endTime)

    // The transcript shows the one block, the listener's.
    #expect(
      await harness.coordinator.transcriptAdRanges(for: b.identity) == [
        TranscriptAdRange(start: detected.startTime - 3, end: detected.endTime, origin: .listener)
      ])
  }

  @Test func aShortMarkBesideADetectedAdTeachesTheJoinedSpanAndRemovingItDeletesOnlyThat() async throws {
    let (harness, b, detected) = try await detectedAd()
    let original = try await harness.signatures.allCreatives().filter(\.confirmed)
    let start = detected.startTime - 3
    await mark(harness, b, start, detected.startTime)

    let taught = try #require(
      try await harness.signatures.allCreatives().first {
        $0.confirmed && original.map(\.id).contains($0.id) == false
      })
    #expect(taught.kind == .learned && taught.startTime == start && taught.endTime == detected.endTime)
    // The lead-in's shingles are held beside the ad's.
    #expect(taught.hashes.count > (original.map(\.hashes.count).max() ?? 0))

    // The mark keeps its own span and carries the creative; the detected row is as it was.
    let held = try await marks(harness, "b")
    #expect(held.map(\.creativeId) == [taught.id])
    #expect(held[0].startTime == start && held[0].endTime == detected.startTime)
    let stored = try await harness.ranges("b")
    #expect(stored.map(\.fromListener) == [true, false])
    #expect(stored[1].startTime == detected.startTime && stored[1].endTime == detected.endTime)

    await harness.coordinator.removeListenerMarks(
      identity: b.identity, start: start, end: detected.startTime)
    await harness.coordinator.waitUntilIdle()
    let remaining = try await harness.signatures.allCreatives().filter(\.confirmed)
    #expect(remaining.map(\.id).sorted() == original.map(\.id).sorted())
    let after = try await harness.ranges("b")
    #expect(after.map(\.fromListener) == [false])
    #expect(after.first?.startTime == detected.startTime && after.first?.endTime == detected.endTime)
  }

  @Test func aShortMarkBesideAnAdTeachesALeadInAnotherEpisodeIsSkippedWith() async throws {
    let (harness, b, detected) = try await detectedAd()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    await mark(harness, b, detected.startTime - 3, detected.startTime)

    // "c" carries b's lead-in words (the last six words of its programme) before the same ad.
    let leadIn = Array(Self.programme("b").suffix(6))
    let c = harness.episode(
      "c", transcript: Self.transcript(Self.programme("c") + leadIn + Self.ad + Self.programme("cx")))
    await harness.run([a, b, c])

    let skipped = try #require(try await harness.ranges("c").first)
    #expect(skipped.startTime <= 60 * 0.5 + 0.5)
    #expect(skipped.endTime >= (60 + 6 + 40) * 0.5 - 0.5)
  }

  @Test func aShortMarkBeyondTheJoinGapOfAnyAdIsRefused() async throws {
    let (harness, b, detected) = try await detectedAd()
    await mark(harness, b, detected.startTime - 15, detected.startTime - 12)
    await mark(harness, b, detected.endTime + 20, detected.endTime + 22)
    #expect(try await marks(harness, "b").isEmpty)
    #expect(try await harness.ranges("b").map(\.fromListener) == [false])
  }

  @Test func aShortMarkAfterADetectedAdIsKeptAndAZeroLengthOneIsNot() async throws {
    let (harness, b, detected) = try await detectedAd()
    await mark(harness, b, detected.endTime + 5, detected.endTime + 5)
    #expect(try await marks(harness, "b").isEmpty)
    await mark(harness, b, detected.endTime + 5, detected.endTime + 7)
    #expect(try await harness.ranges("b").map(\.fromListener) == [false, true])
  }

  @Test func undoingTheJoinedBlockRemovesOnlyTheShortMark() async throws {
    let (harness, b, detected) = try await detectedAd()
    await mark(harness, b, detected.startTime - 3, detected.startTime)
    let block = try #require(await harness.coordinator.transcriptAdRanges(for: b.identity).first)

    await harness.coordinator.undoRange(
      identity: b.identity, start: block.start, end: block.end, origin: block.origin)
    await harness.coordinator.waitUntilIdle()

    #expect(try await marks(harness, "b").isEmpty)
    let after = try await harness.ranges("b")
    #expect(after.map(\.fromListener) == [false])
    #expect(after.first?.startTime == detected.startTime && after.first?.endTime == detected.endTime)
    #expect(try await harness.signatures.allCreatives().contains { $0.kind == .tombstone } == false)
  }

  @Test func aMarkOnAFileThatChangedSinceItWasAnalysedIsDropped() async throws {
    let (harness, a) = try await analysedAlone()
    harness.fingerprints.set(a.fileURL, size: 77_777)
    await mark(harness, a, 100, 120)
    #expect(try await marks(harness, "a").isEmpty)
    #expect(try await harness.signatures.allCreatives().isEmpty)
  }

  // MARK: - Taking a mark back

  @Test func removingAMarkWritesNoTombstoneAndARecomputeRestoresWhatItCut() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.twoBreaks("a"))
    let b = harness.episode("b", transcript: Self.twoBreaks("b"))
    harness.listener.set(a.identity, Self.twoBreaks("a"))
    await harness.run([a, b])
    let before = try await harness.ranges("a")
    #expect(before.count == 3)
    let (first, second) = (before[0], before[2])
    await mark(harness, a, first.endTime - 10, second.startTime + 10)
    #expect(try await harness.ranges("a").map(\.fromListener) == [false, true, false])
    var changes = harness.coordinator.skipRangeChanges().makeAsyncIterator()

    await harness.coordinator.undoRange(
      identity: a.identity, start: first.endTime, end: second.startTime, origin: .listener)

    #expect(await changes.next() != nil)
    #expect(try await harness.ranges("a").contains { $0.fromListener } == false)
    await harness.coordinator.waitUntilIdle()
    let restored = try await harness.ranges("a")
    #expect(restored.map(\.startTime) == before.map(\.startTime))
    #expect(restored.map(\.endTime) == before.map(\.endTime))
    #expect(try await marks(harness, "a").isEmpty)
    let creatives = try await harness.signatures.allCreatives()
    #expect(creatives.contains { $0.kind == .tombstone } == false)
    #expect(creatives.contains { $0.confirmed } == false)
  }

  @Test func undoingADetectedRangeLeavesTheListenersMarkAlone() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.twoBreaks("a"))
    let b = harness.episode("b", transcript: Self.twoBreaks("b"))
    harness.listener.set(a.identity, Self.twoBreaks("a"))
    await harness.run([a, b])
    let before = try await harness.ranges("a")
    await mark(harness, a, before[0].endTime - 10, before[2].startTime + 10)

    await harness.coordinator.undoRange(
      identity: a.identity, start: before[0].startTime, end: before[0].endTime - 10,
      origin: .detected)
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.ranges("a").contains { $0.fromListener })
    #expect(try await marks(harness, "a").count == 1)
  }

  @Test func undoingAnAdAMarkTaughtLeavesItInTheStore() async throws {
    let (harness, a) = try await analysedAlone()
    await mark(harness, a, 100, 120)
    let taught = try #require(try await harness.signatures.allCreatives().first)
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let shown = try #require(await harness.coordinator.transcriptAdRanges(for: b.identity).first)

    await harness.coordinator.undoRange(
      identity: b.identity, start: shown.start, end: shown.end, origin: shown.origin)
    await harness.coordinator.waitUntilIdle()

    let after = try await harness.signatures.allCreatives()
    #expect(after.contains { $0.id == taught.id && $0.confirmed })
    #expect(after.contains { $0.kind == .tombstone })
  }

  @Test func forgettingLearnedAdsKeepsTheMarksAndTheirRanges() async throws {
    let (harness, a) = try await analysedAlone()
    await mark(harness, a, 100, 120)

    await harness.coordinator.forgetLearnedAds()
    await harness.coordinator.waitUntilIdle()

    #expect(try await marks(harness, "a").count == 1)
    #expect(try await harness.ranges("a").map(\.fromListener) == [true])
  }

  // MARK: - Confirmed reach

  /// A club plug of 8 s, too short for a recurrence run to open a window on.
  private static let plug = (0..<16).map { "clubplug\($0)" }

  /// `lead` programme words, the plug, then 300 programme words.
  private static func plugged(_ tag: String, lead: Int) -> Transcript {
    transcript(programme(tag, count: lead) + plug + programme(tag + "x", count: 300))
  }

  /// "a" with the plug from 10 s to 18 s and the listener's transcript of it, and "b" with the
  /// plug from 20 s to 28 s; both analysed, and neither skips it.
  private func pluggedPair() async throws -> (Harness, AdSkipLocalEpisode, AdSkipLocalEpisode) {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.plugged("a", lead: 20))
    let b = harness.episode("b", transcript: Self.plugged("b", lead: 40))
    harness.listener.set(a.identity, Self.plugged("a", lead: 20))
    await harness.run([a, b])
    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.ranges("b").isEmpty)
    return (harness, a, b)
  }

  @Test func aShortMarkReachesAnotherEpisodeByItsAudioOnBattery() async throws {
    let (harness, a, b) = try await pluggedPair()
    await harness.coordinator.setAllowed(false)
    await mark(harness, a, 10, 18)

    let taught = try #require(try await harness.signatures.allCreatives().first { $0.confirmed })
    let reached = try await harness.ranges("b")
    #expect(reached.count == 1)
    let range = try #require(reached.first)
    #expect(range.creativeId == taught.id && range.fromStore && range.fromListener == false)
    #expect(abs(range.startTime - 20) < 1 && abs(range.endTime - 28) < 1)
    #expect(range.meanAdProbability == 1)
    // The marked episode serves the mark, not a match of its own creative.
    #expect(try await harness.ranges("a").map(\.fromListener) == [true])

    // It holds through a recompute, and learning adds no unconfirmed copy of it.
    await harness.coordinator.forceRecompute()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").map(\.creativeId) == [taught.id])
    #expect(try await harness.signatures.allCreatives().filter { $0.kind == .learned }.map(\.id) == [taught.id])
    _ = b
  }

  @Test func markTeachesAgreesWithWhatAMarkTeaches() async throws {
    let (harness, a, b) = try await pluggedPair()
    let coordinator = harness.coordinator
    #expect(await coordinator.markTeaches(identity: a.identity, start: 10, end: 18))
    // Under the 4 s floor with no ad beside it: it would skip only here.
    #expect(await coordinator.markTeaches(identity: a.identity, start: 100, end: 102) == false)
    // An episode with no listener transcript cannot be marked at all.
    #expect(await coordinator.markTeaches(identity: b.identity, start: 20, end: 28) == false)

    await mark(harness, a, 100, 102)
    #expect(try await harness.signatures.allCreatives().contains { $0.confirmed } == false)
    await mark(harness, a, 10, 18)
    #expect(try await harness.signatures.allCreatives().filter(\.confirmed).count == 1)
  }

  @Test func undoingAReachedPlugSuppressesItThereAndOnlyThere() async throws {
    let (harness, a, b) = try await pluggedPair()
    await mark(harness, a, 10, 18)
    let taught = try #require(try await harness.signatures.allCreatives().first { $0.confirmed })
    let shown = try #require(await harness.coordinator.transcriptAdRanges(for: b.identity).first)

    await harness.coordinator.undoRange(
      identity: b.identity, start: shown.start, end: shown.end, origin: shown.origin)
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").isEmpty)

    await harness.coordinator.forceRecompute()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").isEmpty)
    #expect(try await harness.signatures.allCreatives().contains { $0.id == taught.id && $0.confirmed })
    #expect(try await harness.ranges("a").map(\.fromListener) == [true])
  }

  @Test func removingTheTeachingMarkEndsItsReach() async throws {
    let (harness, a, _) = try await pluggedPair()
    await mark(harness, a, 10, 18)
    #expect(try await harness.ranges("b").count == 1)

    await harness.coordinator.removeListenerMarks(identity: a.identity, start: 12, end: 14)
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.ranges("b").isEmpty)
    #expect(try await harness.signatures.allCreatives().isEmpty)
  }

  /// A mark the 15 s floor left teaching nothing is taught once on the next launch.
  @Test func aMarkFromAnEarlierTeachingRevisionIsTaughtOnceOnLaunch() async throws {
    let (first, a, b) = try await pluggedPair()
    let rowId = try #require(try await first.episodes.episode(for: a.identity)?.id)
    _ = try await first.episodes.addListenerMark(
      episodeId: rowId, startTime: 10, endTime: 18, creativeId: nil, createdAt: Date(),
      ranges: { marks, ranges in AdSkipCoordinator.laying(marks, over: ranges) })
    try first.database.write { db in
      try db.execute(sql: "UPDATE adSkipListenerMark SET teachingRevision = 1")
    }

    let relaunched = try Harness(reusing: first)
    await relaunched.run([a, b])

    let taught = try #require(try await relaunched.signatures.allCreatives().first { $0.confirmed })
    #expect(try await marks(relaunched, "a").map(\.creativeId) == [taught.id])
    #expect(try await marks(relaunched, "a").map(\.teachingRevision) == [AdSkipListenerMark.teachingRevision])
    #expect(try await relaunched.ranges("b").map(\.creativeId) == [taught.id])
  }
}
