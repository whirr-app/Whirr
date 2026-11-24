import AdSkip
import Foundation
import Persistence
import Testing

@testable import AppModel

/// Audio-gated transcription: only stretches whose audio recurs are
/// transcribed, and the work unit is a decode or an episode's missing windows.
extension AdSkipCoordinatorTests {

  /// A print that cannot be read takes its row with it, once: the coordinator catches the thrown
  /// `UnreadablePrints`, discards the episode and loads the library again, so the broken episode is
  /// decoded and planned anew while the rest of the library keeps its ranges.
  @Test func anUnreadableAudioPrintIsDiscardedAndDecodedAgain() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.long("a"))
    let b = harness.episode("b", transcript: Self.long("b"))
    await harness.run([a, b])
    let row = try #require(try await harness.episodes.episode(for: a.identity))
    try FileManager.default.removeItem(
      at: harness.transcripts.rootURL.appendingPathComponent(try #require(row.audioPrintFileName)))
    let analyses = harness.audio.calls.withLock { $0.filter { $0 == a.fileURL }.count }

    // Forgetting the store walks the library again: the load finds the missing print.
    await harness.coordinator.forgetLearnedAds()
    await harness.coordinator.waitUntilIdle()

    // The episode was discarded with its row, decoded again and planned against its new print.
    #expect(harness.audio.calls.withLock { $0.filter { $0 == a.fileURL }.count } == analyses + 1)
    let rebuilt = try #require(try await harness.episodes.episode(for: a.identity))
    #expect(rebuilt.state == .analysed)
    let print = try #require(rebuilt.audioPrintFileName)
    #expect(harness.audioPrintFiles().contains(print))
    #expect(try await harness.ranges("a").map(\.startTime) == [100.0])
    // And the library's other episode is untouched.
    #expect(try await harness.ranges("b").map(\.startTime) == [100.0])
  }

  /// 200 programme words, the ad from 100.0 s to 119.9 s, 200 more: 220 s.
  static func long(_ tag: String) -> Transcript {
    transcript(programme(tag, count: 200) + ad + programme(tag + "x", count: 200))
  }

  func coverage(_ harness: Harness, _ id: String) async throws -> [TimeSpan] {
    let row = try #require(try await harness.episodes.episode(for: Harness.identity(id)))
    let name = try #require(row.transcriptFileName)
    return try harness.transcripts.read(fileName: name).coverageSpans
  }

  func windowCalls(_ harness: Harness, _ episode: AdSkipLocalEpisode) -> [[TimeSpan]] {
    zip(harness.transcriber.calls.withLock { $0 }, harness.transcriber.windowCalls.withLock { $0 })
      .filter { $0.0 == episode.fileURL }.map(\.1)
  }

  @Test func anEpisodeWhoseAudioRecursNowhereIsAnalysedWithoutTranscribing() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a", transcript: Self.long("a"))])
    #expect(harness.transcriber.calls.withLock { $0 }.isEmpty)
    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.analysed])
    #expect(try await coverage(harness, "a").isEmpty)
    #expect(harness.audioPrintFiles().count == 1)
    #expect(try await harness.ranges("a").isEmpty)
  }

  @Test func onlyTheRecurringStretchAndItsLookBackAreTranscribed() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.long("a"))
    let b = harness.episode("b", transcript: Self.long("b"))
    await harness.run([a, b])

    for (id, episode) in [("a", a), ("b", b)] {
      let ranges = try await harness.ranges(id)
      #expect(ranges.map(\.startTime) == [100.0])
      // Stage 1 around the ad, then stage 2a's 92 s before the kept start: the rest is never heard.
      let first = try #require(windowCalls(harness, episode).first)
      #expect(first.count == 1)
      #expect(abs((first.first?.start ?? 0) - 72.5) < 0.5)
      #expect(abs((first.first?.end ?? 0) - 147.4) < 0.5)
      let covered = try await coverage(harness, id)
      #expect(covered.count == 1)
      #expect(abs((covered.first?.start ?? 0) - 8.0) < 1e-6)
      #expect(TranscriptionWindows.seconds(covered, duration: 220) < 150)
      // Stage 2 settles within its two rounds.
      #expect(windowCalls(harness, episode).count <= 1 + AdSkipPlanBook.stageTwoRoundLimit)
    }
    #expect(try await harness.episodes.allEpisodes().allSatisfy { $0.state == .analysed })
    // What is learned keeps the ad's audio print.
    let creatives = try await harness.signatures.allCreatives()
    #expect(creatives.count == 1)
    #expect(creatives.allSatisfy { $0.hasAudioPrint })
  }

  /// 59 programme words, "end.", the partner's line from 30.0 s, 172 more programme words, the
  /// sponsor phrase from 119.5 s, 60 words of sponsor copy, the ad, then programme. The partner's
  /// line is more than `maximumExtensionSeconds` before the ad; the phrase is not, and the extra
  /// round from the phrase reaches the partner's line.
  static func withPresentingPartnerLaterPhrase(_ tag: String) -> Transcript {
    transcript(
      programme(tag, count: 59) + ["end."]
        + ["the", "zork", "hour", "is", "powered", "by", "acme."]
        + programme(tag + "p", count: 172) + phrase + programme(tag + "c", count: 60) + ad
        + programme(tag + "x"))
  }

  /// Stage 2 looks back from the first sponsor-phrase round's starts only. The second round's
  /// earlier start is an anchor, looked back over by `anchorLookBackSeconds` only and never a
  /// sponsor look-back origin: the earliest wanted window starts at 30.0 − 27.5 s, where a merged
  /// start would reach the top of the file.
  ///
  /// The fixture restarts the coordinator over a rewritten transcript because both phrase rounds
  /// must run in one recompute, before any stage-2 round is spent; that is the state a relaunch
  /// mid-analysis produces, with the phrases heard and the file's first seconds not.
  @Test func stageTwoLooksBackFromTheFirstPhraseRoundNotASecondRoundsEarlierStart() async throws {
    let harness = try Harness()
    let a = harness.episode(
      "a", transcript: Self.withPresentingPartnerLaterPhrase("a"), showTitle: "The Zork Hour")
    let b = harness.episode("b", transcript: Self.withAd("b"), showTitle: "The Zork Hour")
    await harness.run([a, b])
    await harness.coordinator.stop()

    // Rewrite a's transcript as it stands after stage 2's first look-back: the partner's line at
    // 30.0 s and the phrase at 119.5 s are heard, the file's first seconds are not. A fresh
    // coordinator therefore runs both phrase rounds in its first recompute, before any stage-2
    // round is spent, and its stage-2 window is the one the queue asks for.
    var row = try #require(try await harness.episodes.episode(for: a.identity))
    let stored = try harness.transcripts.read(fileName: try #require(row.transcriptFileName))
    row.transcriptFileName = try harness.transcripts.write(
      StoredTranscript(
        words: stored.words.filter { $0.start >= 30 }, silences: stored.silences,
        duration: stored.duration,
        coverage: [StoredTimeSpan(start: 30, end: stored.duration)]))
    _ = try await harness.episodes.save(row, ranges: try await harness.ranges("a"))

    let restarted = try Harness(reusing: harness)
    let rewritten = restarted.episode(
      "a", transcript: Self.withPresentingPartnerLaterPhrase("a"), showTitle: "The Zork Hour")
    await restarted.run([
      rewritten,
      restarted.episode("b", transcript: Self.withAd("b"), showTitle: "The Zork Hour"),
    ])

    // The second round moved the served start to the partner's line at 30.0 s; the first round's
    // own phrase starts at 119.5 s.
    #expect(try await restarted.ranges("a").map(\.startTime) == [30.0])
    // The partner's start is an anchor, so it is looked back over by `anchorLookBackSeconds` only.
    // Were it a look-back origin, it would reach 92 s before 30.0 s and the file's first 2.5 s
    // would be transcribed.
    let starts = windowCalls(restarted, rewritten).flatMap { $0 }.map(\.start)
    let earliest = try #require(starts.min())
    #expect(abs(earliest - (30.0 - TranscriptionWindows.anchorLookBackSeconds)) < 1e-6)
  }

  @Test func aStageTwoBacklogLongerThanTwoRecomputesIsStillTranscribed() async throws {
    // Every episode loses its look-back at once, as a rules change that asks for new stage-2
    // stretches does. A recompute runs every `analysesPerRecompute` transcriptions, so the last
    // episodes wait through more recomputes than the round limit before their turn.
    let harness = try Harness()
    let count = AdSkipCoordinator.analysesPerRecompute * (AdSkipPlanBook.stageTwoRoundLimit + 1)
    let library = (0..<count).map { harness.episode("e\($0)", transcript: Self.long("e\($0)")) }
    await harness.run(library)
    await harness.coordinator.stop()
    for episode in library {
      var row = try #require(try await harness.episodes.episode(for: episode.identity))
      let stored = try harness.transcripts.read(fileName: try #require(row.transcriptFileName))
      let stageOne = StoredTimeSpan(start: 72.5, end: 147.4)
      row.transcriptFileName = try harness.transcripts.write(
        StoredTranscript(
          words: stored.words.filter { $0.start >= stageOne.start && $0.end <= stageOne.end },
          silences: stored.silences, duration: stored.duration, coverage: [stageOne]))
      row.rulesRevision = AdSkipRules.revision - 1
      _ = try await harness.episodes.save(row, ranges: try await harness.ranges(episode.identity.episodeID))
    }

    let restarted = try Harness(reusing: harness)
    await restarted.run((0..<count).map { restarted.episode("e\($0)", transcript: Self.long("e\($0)")) })

    for episode in library {
      let covered = try await coverage(restarted, episode.identity.episodeID)
      #expect(covered.contains { $0.start <= 8.5 && $0.end >= 72.5 }, "\(episode.identity.episodeID)")
    }
  }

  @Test func aRelaunchOnChargeAsksAgainForStageTwoItNeverHeard() async throws {
    // Stage 2 is queued only in memory: a process that ends before the queue reaches an episode
    // leaves its row on the current revision with the look-back unheard.
    let harness = try Harness()
    let library = ["a", "b"].map { harness.episode($0, transcript: Self.long($0)) }
    await harness.run(library)
    await harness.coordinator.stop()
    let a = library[0]
    var row = try #require(try await harness.episodes.episode(for: a.identity))
    let stored = try harness.transcripts.read(fileName: try #require(row.transcriptFileName))
    let stageOne = StoredTimeSpan(start: 72.5, end: 147.4)
    row.transcriptFileName = try harness.transcripts.write(
      StoredTranscript(
        words: stored.words.filter { $0.start >= stageOne.start && $0.end <= stageOne.end },
        silences: stored.silences, duration: stored.duration, coverage: [stageOne]))
    _ = try await harness.episodes.save(row, ranges: try await harness.ranges("a"))

    let restarted = try Harness(reusing: harness)
    await restarted.run(["a", "b"].map { restarted.episode($0, transcript: Self.long($0)) })

    #expect(try await coverage(restarted, "a").contains { $0.start <= 8.5 && $0.end >= 72.5 })
  }

  @Test func episodesSharingOnlyALongAdAreNotGroupedAsCopies() async throws {
    // A 150 s ad between 200 s of programme either side: the index views are mostly the ad
    // (Jaccard about 0.54), but the episodes share under a third of their audio.
    let longAd = (0..<300).map { "acmead\($0)" }
    func episode(_ tag: String) -> Transcript {
      Self.transcript(Self.programme(tag, count: 400) + longAd + Self.programme(tag + "x", count: 400))
    }
    let harness = try Harness()
    await harness.run([harness.episode("a", transcript: episode("a")), harness.episode("b", transcript: episode("b"))])
    for id in ["a", "b"] {
      #expect(try await harness.ranges(id).map(\.startTime) == [200.0])
    }
  }

  @Test func linkedCopiesOpenNoWindowsInEachOther() async throws {
    let harness = try Harness()
    let abs = Harness.identity("a", source: .abs)
    await harness.run([
      harness.episode("a", transcript: Self.long("a"), linked: [abs]),
      harness.episode("a", transcript: Self.long("a"), size: 2_000, source: .abs),
    ])
    #expect(harness.transcriber.calls.withLock { $0 }.isEmpty)
    #expect(try await harness.episodes.allEpisodes().allSatisfy { $0.state == .analysed })
  }

  @Test func aLaterArrivalGrowsAnAnalysedEpisodesWindowsAndItsStepsAreScoredAgain() async throws {
    let harness = try Harness()
    // A jingle with no speech from 240 s, after the last word.
    let spoken = Self.long("a")
    let a = harness.episode("a", transcript: Transcript(words: spoken.words, duration: 280))
    harness.audio.unspoken.withLock {
      $0[a.fileURL] = (0..<40).map {
        TranscriptWord(text: "jingle\($0)", start: 240 + Double($0) * 0.5, end: 240 + Double($0) * 0.5 + 0.4)
      }
    }
    let b = harness.episode("b", transcript: Self.long("b"))
    await harness.run([a, b])
    let callsBefore = windowCalls(harness, a).count
    let scored = harness.scorer.scoredSteps.withLock { $0 }
    let fileBefore = try await harness.episodes.episode(for: a.identity)?.transcriptFileName

    // c carries the jingle, so a's audio now recurs there too.
    let c = harness.episode("c", transcript: Transcript(words: [], duration: 200))
    harness.audio.unspoken.withLock {
      $0[c.fileURL] = (0..<40).map {
        TranscriptWord(text: "jingle\($0)", start: 100 + Double($0) * 0.5, end: 100 + Double($0) * 0.5 + 0.4)
      }
    }
    harness.transcriber.set(c.fileURL, .success(Transcript(words: [], duration: 200)))
    await harness.coordinator.setLocalEpisodes([a, b, c])
    await harness.coordinator.waitUntilIdle()

    let grown = windowCalls(harness, a).dropFirst(callsBefore)
    #expect(grown.count == 1)
    #expect(grown.first?.contains { $0.start < 240 && $0.end > 259 } == true)
    #expect(try await coverage(harness, "a").contains { $0.start <= 240 && $0.end >= 259 })
    // No new words, but a new file: its steps are scored again rather than read from the cache.
    #expect(try await harness.episodes.episode(for: a.identity)?.transcriptFileName != fileBefore)
    #expect(harness.scorer.scoredSteps.withLock { $0 } > scored)
    #expect(try await harness.ranges("a").map(\.startTime) == [100.0])
    #expect(try await harness.episodes.episode(for: a.identity)?.state == .analysed)
  }

  @Test func anEpisodeTranscribedInFullBeforeGatingNeedsOnlyItsDecode() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    // Rows from revision 3: a whole transcript, revision 3 ranges, no audio print.
    for (episode, transcript) in [(a, Self.withAd("a")), (b, Self.withAd("b"))] {
      let name = try harness.transcripts.write(StoredTranscript(transcript, silences: []))
      let fingerprint = try #require(harness.fingerprints.fingerprint(ofFileAt: episode.fileURL))
      _ = try await harness.episodes.save(
        AdSkipEpisodeRecord(
          source: .rss, accountId: nil, itemID: episode.identity.itemID,
          episodeID: episode.identity.episodeID, fileByteSize: fingerprint.byteSize,
          fileModificationTime: fingerprint.modificationTime, transcriberRevision: "t1",
          rulesRevision: 3, state: .analysed, transcriptFileName: name,
          analysedAt: harness.clock.now()),
        ranges: [
          AdSkipRange(
            startTime: 30, endTime: 49.9, meanAdProbability: 0.9, rulesRevision: 3,
            fromStore: false, endsItem: false)
        ])
    }

    // Revision 3 is no longer served, so nothing is skipped until it is decoded.
    await harness.run([a, b], allowed: false)
    #expect(await harness.coordinator.skipRanges(for: Self.request(a)).isEmpty)

    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()
    #expect(harness.transcriber.calls.withLock { $0 }.isEmpty)
    #expect(harness.audio.calls.withLock { $0.count } == 2)
    let rows = try await harness.episodes.allEpisodes()
    #expect(rows.allSatisfy { $0.audioPrintFileName != nil && $0.state == .analysed })
    #expect(rows.allSatisfy { $0.rulesRevision == AdSkipRules.revision })
    let ranges = try await harness.ranges("a")
    #expect(ranges.map(\.startTime) == [30.0])
    #expect(ranges.map(\.rulesRevision) == [AdSkipRules.revision])
  }

  /// 200 programme words then the ad, ending the speech at 119.9 s; `tail` more seconds of audio
  /// with no words follow.
  static func endingWithAd(_ tag: String, tail: Double) -> Transcript {
    let spoken = transcript(programme(tag, count: 200) + ad)
    return Transcript(words: spoken.words, duration: spoken.duration + tail)
  }

  @Test func aRangeEndsTheItemOnlyWhenTheCoverageReachesTheEndOfTheFile() async throws {
    let harness = try Harness()
    await harness.run([
      harness.episode("a", transcript: Self.endingWithAd("a", tail: 0)),
      harness.episode("b", transcript: Self.endingWithAd("b", tail: 0)),
      harness.episode("c", transcript: Self.endingWithAd("c", tail: 120)),
    ])
    #expect(try await harness.ranges("a").map(\.endsItem) == [true])
    // c's window stops 27.5 s past the ad, two minutes before the end: what follows is unheard.
    #expect(try await harness.ranges("c").map(\.endsItem) == [false])
  }

  @Test func aFailedTranscriptionRecordsTheEpisodeAsFailedAndDropsItsFiles() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.long("a"))
    let b = harness.episode("b", transcript: Self.long("b"))
    harness.transcriber.set(a.fileURL, .failure(Unexpected()))
    // The audio still carries the ad, so a window opens and its transcription fails.
    harness.audio.unspoken.withLock { $0[a.fileURL] = Self.long("a").words }
    await harness.run([a, b])
    let row = try #require(try await harness.episodes.episode(for: a.identity))
    #expect(row.state == .failed)
    #expect(row.transcriptFileName == nil && row.audioPrintFileName == nil)
    #expect(harness.transcriptFiles().count == 1)
    #expect(harness.audioPrintFiles().count == 1)
  }

  @Test func theWholeFileModeTranscribesEveryEpisodeInFull() async throws {
    let harness = try Harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Self.long("a"))
    await harness.run([a])
    #expect(harness.transcriber.windowCalls.withLock { $0 } == [[TimeSpan(start: 0, end: 220)]])
    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.analysed])
  }

  @Test func anUndoTombstonesOnlyIndexedWords() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.long("a"))
    let b = harness.episode("b", transcript: Self.long("b"))
    await harness.run([a, b])
    let skipped = try #require(await harness.coordinator.skipRanges(for: Self.request(b)).first)
    let stageOne = try #require(windowCalls(harness, b).first)
    let name = try #require(try await harness.episodes.episode(for: b.identity)?.transcriptFileName)
    let stored = try harness.transcripts.read(fileName: name)
    let index = TranscriptViews(
      transcript: stored.transcript, silences: stored.pipelineSilences,
      coverage: stored.coverageSpans, stageOne: stageOne
    ).index
    let expected = SignatureStore.tombstone(
      from: index, start: skipped.start, end: skipped.end, teachers: [b.identity.episodeKey])

    await harness.coordinator.undoSkip(skipped, for: Self.request(b))
    await harness.coordinator.waitUntilIdle()
    let tombstones = try await harness.signatures.allCreatives().filter { $0.kind == .tombstone }
    let expectedHashes = try #require(expected).hashes
    #expect(tombstones.map(\.hashes) == [expectedHashes])
    #expect(tombstones.allSatisfy { $0.hasAudioPrint == false })
  }
}
