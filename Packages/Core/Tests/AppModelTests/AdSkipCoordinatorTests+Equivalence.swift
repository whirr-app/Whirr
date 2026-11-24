import AdSkip
import Foundation
import Persistence
import Synchronization
import Testing

@testable import AppModel

/// What the coordinator's matching costs per arrival, and the outcome a drained library settles on
/// under each arrival pattern. Later changes to matching must leave both outcomes as recorded.
extension AdSkipCoordinatorTests {

  // MARK: - Measurement

  final class RecordingMeasurement: AdSkipMatchingMeasuring {
    let started = Mutex<[AdSkipMatchingUnit]>([])
    let finished = Mutex<[(unit: AdSkipMatchingUnit, detail: AdSkipMatchingDetail)]>([])

    func willStart(_ unit: AdSkipMatchingUnit) async {
      started.withLock { $0.append(unit) }
    }

    func didFinish(_ unit: AdSkipMatchingUnit, _ detail: AdSkipMatchingDetail) async {
      finished.withLock { $0.append((unit, detail)) }
    }

    func reset() {
      started.withLock { $0 = [] }
      finished.withLock { $0 = [] }
    }

    var recomputes: [AdSkipMatchingDetail] {
      finished.withLock { $0.filter { $0.unit == .recompute }.map(\.detail) }
    }

    /// Queries the worker's own replans and recomputes ran. The idle shadow check's are not
    /// counted.
    var queries: Int {
      finished.withLock {
        $0.filter { $0.unit != .replanMismatch }.reduce(0) { $0 + $1.detail.queries }
      }
    }
  }

  @Test func oneArrivalReplansTheLibraryOnceAndRecomputesTwice() async throws {
    let measurement = RecordingMeasurement()
    // Full replans; every episode here shares the arrival's ad anyway.
    let harness = try Harness(measurement: measurement, incremental: false)
    let base = (0..<8).map { harness.episode("b\($0)", transcript: Self.withAd("b\($0)")) }
    await harness.run(base)
    measurement.reset()

    await harness.coordinator.setLocalEpisodes(
      base + [harness.episode("n", transcript: Self.withAd("n"))])
    await harness.coordinator.waitUntilIdle()

    // One full replan of 9 episodes, and one recompute after each of the two transcriptions. A
    // stored decode alone does not recompute before the first transcription. The arrival's ad is
    // already stored: it adds a teacher and no print, so the library the arrival built is not
    // dropped a second time.
    #expect(measurement.recomputes.count == 2)
    #expect(measurement.recomputes.allSatisfy { $0.succeeded })
    #expect(measurement.queries == 9)
    #expect(measurement.started.withLock { $0.count } == measurement.finished.withLock { $0.count })
  }

  @Test func aRecomputeReportsHowLongEachMatchedCreativeWentUnseen() async throws {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement)
    await harness.run([
      harness.episode("a", transcript: Self.withAd("a")),
      harness.episode("b", transcript: Self.withAd("b")),
    ])
    measurement.reset()

    // Neither teacher is left, so only the store matches c, with creatives last seen 45 days ago.
    harness.clock.advance(days: 45)
    await harness.coordinator.setLocalEpisodes([harness.episode("c", transcript: Self.withAd("c"))])
    await harness.coordinator.waitUntilIdle()

    let ages = try #require(measurement.recomputes.compactMap(\.storeMatchAges).first { !$0.isEmpty })
    #expect(ages.allSatisfy { $0 == 45 * 86_400 })
  }

  @Test func aRemovalStillRecomputesBeforeTheNextTranscription() async throws {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement)
    let base = (0..<8).map { harness.episode("b\($0)", transcript: Self.withAd("b\($0)")) }
    await harness.run(base)
    measurement.reset()

    // The removal owes a recompute that the decode alone would not, so the remaining episodes'
    // ranges are brought current before the new episode is transcribed.
    await harness.coordinator.setLocalEpisodes(
      Array(base.dropFirst()) + [harness.episode("n", transcript: Self.withAd("n"))])
    await harness.coordinator.waitUntilIdle()

    #expect(measurement.recomputes.count == 3)
  }

  @Test func aRelaunchWithNothingNewRunsNoQuery() async throws {
    let harness = try Harness()
    let library = (0..<4).map { harness.episode("b\($0)", transcript: Self.withAd("b\($0)")) }
    await harness.run(library)
    await harness.coordinator.stop()

    let measurement = RecordingMeasurement()
    let restarted = try Harness(reusing: harness, measurement: measurement)
    await restarted.run(library)

    // Every plan is stored for this exact library, so none is queried again. The one recompute
    // plans stage 2 again, which lives only in memory, and queries nothing.
    #expect(measurement.queries == 0)
    #expect(measurement.recomputes.count == 1)
    #expect(restarted.transcriber.calls.withLock { $0 }.isEmpty)
  }

  @Test func aRelaunchWhereAnalysisIsNotAllowedRunsNothing() async throws {
    let harness = try Harness()
    let library = (0..<4).map { harness.episode("b\($0)", transcript: Self.withAd("b\($0)")) }
    await harness.run(library)
    await harness.coordinator.stop()

    let measurement = RecordingMeasurement()
    let restarted = try Harness(reusing: harness, measurement: measurement)
    await restarted.run(library, allowed: false)

    #expect(measurement.queries == 0)
    #expect(measurement.recomputes.isEmpty)
  }

  @Test func aRelaunchWhoseLinksChangedPlansAgain() async throws {
    let harness = try Harness()
    let library = (0..<4).map { harness.episode("b\($0)", transcript: Self.withAd("b\($0)")) }
    await harness.run(library)
    await harness.coordinator.stop()

    // No print changes, but b1 is now a copy of b0, so neither may match the other.
    let measurement = RecordingMeasurement()
    let restarted = try Harness(reusing: harness, measurement: measurement)
    var linked = library
    linked[1] = restarted.episode("b1", transcript: Self.withAd("b1"), linked: [Harness.identity("b0")])
    await restarted.run(linked)

    #expect(measurement.queries >= 4)
  }

  @Test func aStoredPlanThatCannotBeReadIsPlannedAgain() async throws {
    let harness = try Harness()
    let library = (0..<3).map { harness.episode("b\($0)", transcript: Self.withAd("b\($0)")) }
    await harness.run(library)
    await harness.coordinator.stop()
    try await harness.database.writeAsync { db in
      try db.execute(sql: "UPDATE adSkipStageOnePlan SET windows = x'0102'")
    }

    let measurement = RecordingMeasurement()
    let restarted = try Harness(reusing: harness, measurement: measurement)
    await restarted.run(library)

    #expect(measurement.queries == 3)
    #expect(restarted.transcriber.calls.withLock { $0 }.isEmpty)
  }

  /// Stored plans against the code without them: the same arrivals, across a restart,
  /// once with the plans kept and once with them deleted before every restart, settle identically
  /// and transcribe the same windows.
  @Test func storedPlansChangeNothingAcrossRestarts() async throws {
    func run(keepingPlans: Bool) async throws -> (CanonicalOutcome?, [[TimeSpan]], Int) {
      let measurement = RecordingMeasurement()
      var harness = try Harness(measurement: measurement)
      var calls: [[TimeSpan]] = []
      for inputs in [[[0], [1]], [[0, 1], [2], [3]], [[0, 1, 2, 3], [4, 5]]] {
        await Self.arrive(harness, inputs: inputs)
        calls += harness.transcriber.windowCalls.withLock { $0 }
        await harness.coordinator.stop()
        if keepingPlans == false {
          try await harness.database.writeAsync { db in
            try db.execute(sql: "DELETE FROM adSkipStageOnePlan")
          }
        }
        harness = try Harness(reusing: harness, measurement: measurement)
      }
      await Self.arrive(harness, inputs: [[0, 1, 2, 3, 4, 5]])
      return (try await Self.fixedPoint(of: harness), calls, measurement.queries)
    }
    let kept = try await run(keepingPlans: true)
    let planned = try await run(keepingPlans: false)
    #expect(kept.0 != nil)
    #expect(kept.0 == planned.0)
    #expect(kept.1 == planned.1)
    // Each restart reuses what the one before stored.
    #expect(kept.2 < planned.2)
  }

  @Test func aRelaunchWithAnalysisNotAllowedRunsNoQuery() async throws {
    let harness = try Harness()
    let library = (0..<3).map { harness.episode("b\($0)", transcript: Self.withAd("b\($0)")) }
    await harness.run(library)
    await harness.coordinator.stop()

    let measurement = RecordingMeasurement()
    let restarted = try Harness(reusing: harness, measurement: measurement)
    await restarted.run(library, allowed: false)

    #expect(measurement.queries == 0)
    #expect(measurement.finished.withLock { $0 }.isEmpty)
  }

  // MARK: - Canonical outcome

  /// A creative by content, never by id: ids differ between runs that learn in another order.
  struct CreativeContent: Hashable, Comparable {
    let kind: String
    let start: Double
    let end: Double
    let teachers: [String]
    let hashes: [UInt64]
    let hasAudioPrint: Bool
    let lastSeen: Date

    init(_ creative: StoredAdSignatureCreative) {
      kind = "\(creative.kind)"
      start = creative.startTime
      end = creative.endTime
      teachers = creative.teachers.sorted()
      hashes = creative.hashes.sorted()
      hasAudioPrint = creative.hasAudioPrint
      lastSeen = creative.lastSeen
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
      (lhs.kind, lhs.start, lhs.end, lhs.teachers.joined(separator: ","), lhs.hashes.count)
        < (rhs.kind, rhs.start, rhs.end, rhs.teachers.joined(separator: ","), rhs.hashes.count)
    }
  }

  struct RangeContent: Hashable {
    let start: Double
    let end: Double
    let meanAdProbability: Double
    let fromStore: Bool
    let endsItem: Bool
    let creative: CreativeContent?

    var withoutCreative: RangeContent {
      RangeContent(
        start: start, end: end, meanAdProbability: meanAdProbability, fromStore: fromStore,
        endsItem: endsItem, creative: nil)
    }
  }

  struct EpisodeOutcome: Hashable {
    let state: String
    let ranges: [RangeContent]
    let coverage: [TimeSpan]
    let words: Int
  }

  /// Every episode's ranges, state and coverage, and the store, compared by content.
  struct CanonicalOutcome: Equatable {
    let episodes: [String: EpisodeOutcome]
    let store: [CreativeContent]

    /// What differs, field by field: `a.creative` names episode a's ranges crediting another
    /// creative, `store` the store's content.
    func difference(from other: CanonicalOutcome) -> Set<String> {
      var notes: Set<String> = []
      for key in Set(episodes.keys).union(other.episodes.keys) {
        let name = String(key.split(separator: "-").last ?? "")
        guard let mine = episodes[key], let theirs = other.episodes[key] else {
          notes.insert("\(name).missing")
          continue
        }
        if mine.state != theirs.state { notes.insert("\(name).state") }
        if mine.ranges.map(\.withoutCreative) != theirs.ranges.map(\.withoutCreative) {
          notes.insert("\(name).ranges")
        }
        if mine.ranges.map(\.creative) != theirs.ranges.map(\.creative) {
          notes.insert("\(name).creative")
        }
        if mine.coverage != theirs.coverage { notes.insert("\(name).coverage") }
        if mine.words != theirs.words { notes.insert("\(name).words") }
      }
      if store != other.store { notes.insert("store") }
      return notes
    }
  }

  static func outcome(of harness: Harness) async throws -> CanonicalOutcome {
    let creatives = try await harness.signatures.allCreatives()
    let byId = Dictionary(uniqueKeysWithValues: creatives.map { ($0.id, CreativeContent($0)) })
    var episodes: [String: EpisodeOutcome] = [:]
    for row in try await harness.episodes.allEpisodes() {
      guard let rowId = row.id else { continue }
      let stored = try row.transcriptFileName.map { try harness.transcripts.read(fileName: $0) }
      episodes["\(row.source)-\(row.episodeID)"] = EpisodeOutcome(
        state: "\(row.state)",
        ranges: try await harness.episodes.ranges(forEpisodeId: rowId).map {
          RangeContent(
            start: $0.startTime, end: $0.endTime, meanAdProbability: $0.meanAdProbability,
            fromStore: $0.fromStore, endsItem: $0.endsItem,
            creative: $0.creativeId.flatMap { byId[$0] })
        },
        coverage: stored?.coverageSpans ?? [], words: stored?.words.count ?? 0)
    }
    return CanonicalOutcome(episodes: episodes, store: creatives.map(CreativeContent.init).sorted())
  }

  /// Drains, then recomputes with nothing new until two outcomes in a row agree.
  /// Nil when no fixed point is reached within the cap.
  static func fixedPoint(of harness: Harness, cap: Int = 3) async throws -> CanonicalOutcome? {
    await harness.coordinator.waitUntilIdle()
    var previous = try await outcome(of: harness)
    for _ in 0..<cap {
      await harness.coordinator.forceRecompute()
      await harness.coordinator.waitUntilIdle()
      let next = try await outcome(of: harness)
      if next == previous { return next }
      previous = next
    }
    return nil
  }

  // MARK: - Baseline over arrival patterns

  static let zedAd = (0..<40).map { "zedad\($0)" }

  /// Three episodes carry one ad, two another, and one carries none.
  static func baselineLibrary(_ harness: Harness) -> [AdSkipLocalEpisode] {
    let other = { (tag: String) in transcript(programme(tag) + zedAd + programme(tag + "x")) }
    return [
      harness.episode("a", transcript: withAd("a")),
      harness.episode("b", transcript: withAd("b")),
      harness.episode("c", transcript: withAd("c")),
      harness.episode("d", transcript: other("d")),
      harness.episode("e", transcript: other("e")),
      harness.episode("f", transcript: transcript(programme("f", count: 160))),
    ]
  }

  /// Arrives in `inputs`, each a set of indices into the library added to what came before; the
  /// worker drains between inputs.
  static func arrive(_ harness: Harness, inputs: [[Int]]) async {
    let library = baselineLibrary(harness)
    var present: [AdSkipLocalEpisode] = []
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.setEnabled(true)
    for input in inputs {
      present += input.map { library[$0] }
      await harness.coordinator.setLocalEpisodes(present)
      await harness.coordinator.waitUntilIdle()
    }
  }

  static func baseline(inputs: [[Int]]) async throws -> CanonicalOutcome? {
    let harness = try Harness()
    await arrive(harness, inputs: inputs)
    return try await fixedPoint(of: harness)
  }

  /// The first half before a restart, the rest after it, on the same stores.
  static func baselineAcrossRestart() async throws -> CanonicalOutcome? {
    let harness = try Harness()
    await arrive(harness, inputs: [[0], [1], [2]])
    await harness.coordinator.stop()
    let restarted = try Harness(reusing: harness)
    await arrive(restarted, inputs: [[0, 1, 2], [3], [4], [5]])
    return try await fixedPoint(of: restarted)
  }

  /// Five arrival patterns of one library, against all arriving at once. Patterns that settle
  /// differently are recorded as the baseline, not fixed: later changes must keep them as they are.
  @Test func arrivalPatternsSettleAsRecorded() async throws {
    let together = try #require(try await Self.baseline(inputs: [[0, 1, 2, 3, 4, 5]]))
    let patterns: [(String, CanonicalOutcome?)] = [
      ("one at a time", try await Self.baseline(inputs: [[0], [1], [2], [3], [4], [5]])),
      ("reversed", try await Self.baseline(inputs: [[5], [4], [3], [2], [1], [0]])),
      ("shuffled", try await Self.baseline(inputs: [[3], [0], [5], [2], [4], [1]])),
      ("in pairs", try await Self.baseline(inputs: [[0, 3], [1, 4], [2, 5]])),
      ("across a restart", try await Self.baselineAcrossRestart()),
    ]
    var report: [String: Set<String>] = [:]
    for (name, outcome) in patterns {
      report[name] = outcome.map { $0.difference(from: together) } ?? ["no fixed point"]
    }
    // Ranges, states and the store's content settle the same under every pattern. Only transcript
    // coverage depends on arrival order: it only grows, so windows wanted under an earlier,
    // smaller library stay transcribed after the plan moves.
    #expect(
      report == [
        "one at a time": [], "in pairs": [], "across a restart": [],
        "shuffled": ["a.coverage"],
        "reversed": ["a.coverage", "b.coverage"],
      ])
  }
}
