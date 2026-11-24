import AdSkip
import Foundation
import Persistence
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// Incremental audio replanning: an arrival re-queries only the episodes whose audio recurs in
/// it, and every scenario settles as the same arrivals do under full replans, with each
/// episode's stage-1 windows equal to a full replan's.
extension AdSkipCoordinatorTests {

  // MARK: - What an arrival queries

  /// Three episodes carry the acme ad, two the zed ad, one nothing shared.
  static func mixedLibrary(_ harness: Harness) -> [AdSkipLocalEpisode] {
    let zed = { (tag: String) in transcript(programme(tag) + zedAd + programme(tag + "x")) }
    return [
      harness.episode("s0", transcript: withAd("s0")),
      harness.episode("s1", transcript: withAd("s1")),
      harness.episode("s2", transcript: withAd("s2")),
      harness.episode("z0", transcript: zed("z0")),
      harness.episode("z1", transcript: zed("z1")),
      harness.episode("u0", transcript: transcript(programme("u0", count: 160))),
    ]
  }

  /// The queries and pairwise checks one arrival costs once `mixedLibrary` has settled.
  func arrivalCost(
    incremental: Bool, _ arrival: (Harness) -> AdSkipLocalEpisode
  ) async throws -> (queries: Int, pairChecks: Int, outcome: CanonicalOutcome) {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement, incremental: incremental)
    let library = Self.mixedLibrary(harness)
    await harness.run(library)
    measurement.reset()
    await harness.coordinator.setLocalEpisodes(library + [arrival(harness)])
    await harness.coordinator.waitUntilIdle()
    return (measurement.queries, measurement.pairChecks, try await Self.outcome(of: harness))
  }

  @Test func anArrivalSharingNoAudioQueriesOnlyItself() async throws {
    let arrival = { (harness: Harness) in
      harness.episode("n", transcript: Self.transcript(Self.programme("n", count: 160)))
    }
    let full = try await arrivalCost(incremental: false, arrival)
    let incremental = try await arrivalCost(incremental: true, arrival)

    #expect(full.queries == 7)
    #expect(incremental.queries == 1)
    #expect(incremental.pairChecks == 6)
    #expect(incremental.outcome == full.outcome)
  }

  @Test func anArrivalRequeriesOnlyTheEpisodesSharingItsAudio() async throws {
    let arrival = { (harness: Harness) in harness.episode("n", transcript: Self.withAd("n")) }
    let full = try await arrivalCost(incremental: false, arrival)
    let incremental = try await arrivalCost(incremental: true, arrival)

    // The first replan queries n and the three acme carriers, not the zed carriers or u0.
    #expect(incremental.queries < full.queries)
    #expect(incremental.outcome == full.outcome)
  }

  @Test func aRemovalReplansTheWholeLibrary() async throws {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement)
    let library = Self.mixedLibrary(harness)
    await harness.run(library)
    measurement.reset()

    await harness.coordinator.setLocalEpisodes(library.filter { $0.identity != Harness.identity("u0") })
    await harness.coordinator.waitUntilIdle()

    #expect(measurement.queries == 5)
    #expect(measurement.pairChecks == 0)
  }

  @Test func aLinkChangeReplansTheWholeLibraryAtTheNextArrival() async throws {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement)
    var library = Self.mixedLibrary(harness)
    await harness.run(library)

    // No print changes, but z1 is a copy of z0. Plans are kept until the prints change; then
    // both entries are re-keyed, so nothing is carried.
    library[4] = harness.episode(
      "z1", transcript: Self.transcript(Self.programme("z1") + Self.zedAd + Self.programme("z1x")),
      linked: [Harness.identity("z0")])
    await harness.coordinator.setLocalEpisodes(library)
    await harness.coordinator.waitUntilIdle()
    measurement.reset()
    await harness.coordinator.setLocalEpisodes(
      library + [harness.episode("n", transcript: Self.transcript(Self.programme("n", count: 160)))])
    await harness.coordinator.waitUntilIdle()

    #expect(measurement.queries == 7)
    #expect(measurement.pairChecks == 0)
  }

  // MARK: - Retention across invalidations

  /// A decode invalidates the audio plans, keeping the settled ones for the next library; with the
  /// library already gone, a second decode has nothing new to keep and must leave the first's
  /// retention alone. A second invalidation that retained instead would drop every plan, and the
  /// next library would query all of them.
  @Test func twoArrivalsAtOnceKeepThePlansTheFirstInvalidationRetained() async throws {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement)
    let library = Self.mixedLibrary(harness)
    await harness.run(library)
    measurement.reset()

    await harness.coordinator.setLocalEpisodes(
      library + [
        harness.episode("n1", transcript: Self.transcript(Self.programme("n1", count: 160))),
        harness.episode("n2", transcript: Self.transcript(Self.programme("n2", count: 160))),
      ])
    await harness.coordinator.waitUntilIdle()

    // The six settled plans are carried and pair-checked against both added prints; only the two
    // arrivals are queried.
    #expect(measurement.queries == 2)
    #expect(measurement.pairChecks == 12)
  }

  /// The same two arrivals under full replans: nothing is retained, so every episode is queried
  /// and nothing is pair-checked.
  @Test func fullReplansRetainNothingAcrossTwoInvalidations() async throws {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement, incremental: false)
    let library = Self.mixedLibrary(harness)
    await harness.run(library)
    measurement.reset()

    await harness.coordinator.setLocalEpisodes(
      library + [
        harness.episode("n1", transcript: Self.transcript(Self.programme("n1", count: 160))),
        harness.episode("n2", transcript: Self.transcript(Self.programme("n2", count: 160))),
      ])
    await harness.coordinator.waitUntilIdle()

    #expect(measurement.queries == 8)
    #expect(measurement.pairChecks == 0)
  }

  // MARK: - Stepwise oracle

  enum Step {
    /// The local set, as indices into the library.
    case present([Int])
    case forget
    /// Undoes the first served range of the episode at that index.
    case undo(Int)
    case advance(days: Double)
  }

  struct Replay {
    /// After each step: the canonical outcome and every transcription request so far.
    var outcomes: [CanonicalOutcome] = []
    var windowCalls: [[[TimeSpan]]] = []
    /// After each step, the episodes whose plan differs from a full replan of the same library.
    var planMismatches: [[String]] = []
    var queries = 0
  }

  /// Runs `steps` on a fresh harness, restarting it where `restartBefore` says, and records each
  /// step's outcome and how each plan compares with a full replan.
  static func replay(
    _ library: (Harness) -> [AdSkipLocalEpisode], _ steps: [Step], incremental: Bool,
    restartBefore: Set<Int> = []
  ) async throws -> Replay {
    let measurement = RecordingMeasurement()
    var harness = try Harness(measurement: measurement, incremental: incremental)
    var episodes = library(harness)
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.setEnabled(true)
    var present: [AdSkipLocalEpisode] = []
    var replay = Replay()
    var calls: [[TimeSpan]] = []
    for (index, step) in steps.enumerated() {
      if restartBefore.contains(index) {
        calls += harness.transcriber.windowCalls.withLock { $0 }
        await harness.coordinator.stop()
        harness = try Harness(reusing: harness, measurement: measurement, incremental: incremental)
        episodes = library(harness)
        let identities = Set(present.map(\.identity))
        present = episodes.filter { identities.contains($0.identity) }
        await harness.coordinator.setLocalEpisodes(present)
        await harness.coordinator.setAllowed(true)
        await harness.coordinator.setEnabled(true)
      }
      switch step {
      case .present(let indices):
        present = indices.map { episodes[$0] }
        await harness.coordinator.setLocalEpisodes(present)
      case .forget:
        await harness.coordinator.forgetLearnedAds()
      case .undo(let index):
        let request = Self.request(episodes[index])
        if let range = await harness.coordinator.skipRanges(for: request).first {
          await harness.coordinator.undoSkip(range, for: request)
        }
        // Asking for ranges prioritized the episode; the order of work must not depend on it.
        await harness.coordinator.prioritize(nil)
      case .advance(let days):
        harness.clock.advance(days: days)
        await harness.coordinator.forceRecompute()
      }
      await harness.coordinator.waitUntilIdle()
      replay.outcomes.append(try await outcome(of: harness))
      replay.windowCalls.append(calls + harness.transcriber.windowCalls.withLock { $0 })
      let plans = try await harness.coordinator.stageOnePlansForTests()
      let full = try await harness.coordinator.fullReplanForTests()
      replay.planMismatches.append(
        full.keys.filter { plans[$0] != full[$0] }.map(\.episodeID).sorted())
    }
    replay.queries = measurement.queries
    return replay
  }

  /// Runs `steps` once with full replans and once incrementally, and expects the same outcome and
  /// transcription requests after every step, with every incremental plan equal to a full replan's.
  /// Returns the two runs' query counts.
  @discardableResult
  static func expectIncrementalMatchesFull(
    _ library: (Harness) -> [AdSkipLocalEpisode], _ steps: [Step], restartBefore: Set<Int> = [],
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> (full: Int, incremental: Int) {
    let full = try await replay(library, steps, incremental: false, restartBefore: restartBefore)
    let incremental = try await replay(library, steps, incremental: true, restartBefore: restartBefore)
    for step in steps.indices {
      #expect(
        incremental.outcomes[step] == full.outcomes[step],
        "step \(step): \(incremental.outcomes[step].difference(from: full.outcomes[step]))",
        sourceLocation: sourceLocation)
      #expect(
        incremental.windowCalls[step] == full.windowCalls[step], "step \(step)",
        sourceLocation: sourceLocation)
      #expect(incremental.planMismatches[step].isEmpty, "step \(step)", sourceLocation: sourceLocation)
    }
    return (full.queries, incremental.queries)
  }

  @Test func incrementalReplansSettleAsFullOnesOverArrivalPatterns() async throws {
    let patterns: [([[Int]], Set<Int>)] = [
      ([[0], [1], [2], [3], [4], [5]], []),
      ([[5], [4], [3], [2], [1], [0]], []),
      ([[3], [0], [5], [2], [4], [1]], []),
      ([[0, 3], [1, 4], [2, 5]], []),
      ([[0], [1], [2], [3], [4], [5]], [3]),
    ]
    var saved = 0
    for (inputs, restarts) in patterns {
      var present: [Int] = []
      let steps = inputs.map { input -> Step in
        present += input
        return .present(present)
      }
      let queries = try await Self.expectIncrementalMatchesFull(
        Self.baselineLibrary, steps, restartBefore: restarts)
      #expect(queries.incremental <= queries.full)
      saved += queries.full - queries.incremental
    }
    #expect(saved > 0)
  }

  // MARK: - Removals and store changes

  @Test func incrementalReplansSettleAsFullOnesThroughRemovalsAndStoreChanges() async throws {
    let all = Array(0..<6)
    try await Self.expectIncrementalMatchesFull(
      Self.mixedLibrary,
      [.present([0, 3, 5]), .present([0, 3, 5, 1]), .present([0, 5, 1]), .present([0, 5, 1, 4, 2])])
    try await Self.expectIncrementalMatchesFull(
      Self.mixedLibrary, [.present([0, 1, 3]), .forget, .present([0, 1, 3, 4, 2])])
    try await Self.expectIncrementalMatchesFull(
      Self.mixedLibrary, [.present([0, 1, 3, 4]), .undo(1), .present(all)])
    try await Self.expectIncrementalMatchesFull(
      Self.mixedLibrary, [.present([0, 1, 3]), .advance(days: 91), .present([0, 1, 3, 2, 4])])
  }

  // MARK: - Generated libraries

  struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  static let jingle = (0..<6).map { "jingle\($0)" }

  /// 6-9 episodes from `seed`: two ads each carried by 2-4 of them, a 3 s jingle in most, one
  /// linked copy of the first, and one sharing nothing. Learned creatives with prints follow from
  /// the ads.
  static func generatedLibrary(seed: UInt64) -> (Harness) -> [AdSkipLocalEpisode] {
    var rng = SeededGenerator(state: seed)
    let count = Int.random(in: 6...9, using: &rng)
    // The last is the copy, the one before it shares nothing; the ads go among the rest.
    let carriers = (0..<count - 2)
    let acme = Set(carriers.shuffled(using: &rng).prefix(Int.random(in: 2...4, using: &rng)))
    let zed = Set(carriers.shuffled(using: &rng).prefix(Int.random(in: 2...4, using: &rng)))
    let jingled = Set(carriers.filter { _ in Int.random(in: 0..<4, using: &rng) > 0 })
    return { harness in
      func words(_ index: Int) -> [String] {
        let tag = "g\(index)"
        return (jingled.contains(index) ? jingle : []) + programme(tag, count: 40)
          + (acme.contains(index) ? ad : []) + programme(tag + "m", count: 40)
          + (zed.contains(index) ? zedAd : []) + programme(tag + "x", count: 40)
      }
      var episodes = (0..<count - 1).map { harness.episode("g\($0)", transcript: transcript(words($0))) }
      episodes.append(
        harness.episode("g\(count - 1)", transcript: transcript(words(0)), linked: [Harness.identity("g0")]))
      return episodes
    }
  }

  /// Seeded orders of generated libraries, one grouping each: one at a time, in twos, or half at
  /// once and then one at a time, at a size the suite can afford.
  @Test(arguments: 0..<12)
  func incrementalReplansSettleAsFullOnesOverGeneratedLibraries(seed: Int) async throws {
    let library = Self.generatedLibrary(seed: UInt64(seed))
    var rng = SeededGenerator(state: UInt64(1_000 + seed))
    let count = library(try Harness()).count
    let order = Array(0..<count).shuffled(using: &rng)
    let groups: [[Int]]
    switch seed % 3 {
    case 0: groups = order.map { [$0] }
    case 1: groups = stride(from: 0, to: count, by: 2).map { Array(order[$0..<min(count, $0 + 2)]) }
    default: groups = [Array(order.prefix(count / 2))] + order.dropFirst(count / 2).map { [$0] }
    }
    var present: [Int] = []
    let steps = groups.map { group -> Step in
      present += group
      return .present(present)
    }
    try await Self.expectIncrementalMatchesFull(library, steps)
  }

  // MARK: - Global couplings

  /// A carries two 10 s stretches of an ad 7 s apart, more than `mergeSeconds`, with a 3 s jingle
  /// between them; B carries the two stretches back to back, and the jingle elsewhere when
  /// `jingleInB`. So A's two runs earn a window only when the jingle's sub-floor run bridges them.
  /// N carries the jingle alone.
  static func bridgedLibrary(jingleInB: Bool) -> (Harness) -> [AdSkipLocalEpisode] {
    { harness in
      let first = Array(ad.prefix(20))
      let second = Array(ad.suffix(20))
      return [
        harness.episode(
          "a",
          transcript: transcript(
            programme("a") + first + programme("ag", count: 4) + jingle + programme("ah", count: 4)
              + second + programme("ax"))),
        harness.episode(
          "b",
          transcript: transcript(
            programme("b") + first + second + programme("bx", count: 100)
              + (jingleInB ? jingle : []) + programme("by"))),
        harness.episode(
          "n", transcript: transcript(programme("n", count: 100) + jingle + programme("nx", count: 100))),
      ]
    }
  }

  /// N bridges A's two runs, so A gains a window it did not have: the pairwise check finds the
  /// jingle in N and A is re-queried.
  @Test func anArrivalThatBridgesAnEpisodesRunsReQueriesIt() async throws {
    let library = Self.bridgedLibrary(jingleInB: false)
    try await Self.expectIncrementalMatchesFull(library, [.present([0, 1]), .present([0, 1, 2])])

    let harness = try Harness()
    let episodes = library(harness)
    await harness.run(Array(episodes.prefix(2)))
    let a = Harness.identity("a")
    #expect(try await harness.coordinator.stageOnePlansForTests()[a] == [])
    await harness.run(episodes)
    #expect(try await harness.coordinator.stageOnePlansForTests()[a]?.count == 1)
  }

  /// An arrival whose audio is the jingle looped more than `commonOccurrences` times. A full replan
  /// finds the jingle's hashes common across the library, so A loses the bridge and with it its
  /// window. The pairwise check cannot see this: within A and the arrival alone the hashes are
  /// already common, so the two share no run and A's plan is kept. Only the shadow check finds
  /// this difference; it is recorded here, not fixed.
  @Test func aHashMadeCommonByAnUnrelatedArrivalIsMissedAndTheShadowCheckReportsIt() async throws {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement)
    let library = Array(Self.bridgedLibrary(jingleInB: true)(harness).prefix(2))
    await harness.run(library)
    let a = Harness.identity("a")
    let before = try await harness.coordinator.fullReplanForTests()
    #expect(before[a]?.count == 1)

    // The jingle starts 42 s into A. Copies 8 s apart, a whole number of frames, repeat A's frames
    // exactly, so every one of A's jingle hashes occurs once per copy.
    let looped = harness.episode("loop")
    let copies = AudioRecurrence.commonOccurrences + 10
    harness.audio.unspoken.withLock {
      $0[looped.fileURL] = (1...copies).flatMap { copy in
        Self.jingle.enumerated().map { index, word in
          let start = 42 + 8 * Double(copy) + 0.5 * Double(index)
          return TranscriptWord(text: word, start: start, end: start + 0.4)
        }
      }
    }
    measurement.reset()
    await harness.coordinator.setLocalEpisodes(library + [looped])
    await harness.coordinator.waitUntilIdle()

    let full = try await harness.coordinator.fullReplanForTests()
    let planned = try await harness.coordinator.stageOnePlansForTests()
    #expect(full[a]?.isEmpty == true)
    #expect(planned[a] == before[a])
    // A's windows and B's evidence: B's jingle alignment with A is lost in the full replan too.
    #expect(measurement.shadowChecks.map(\.windowMismatches) == [2])
  }

  // MARK: - Shadow check

  @Test func carriedPlansAreCheckedAgainstAFullQueryOnceIdle() async throws {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement)
    let library = Self.mixedLibrary(harness)
    await harness.run(library)
    measurement.reset()

    await harness.coordinator.setLocalEpisodes(
      library + [harness.episode("n", transcript: Self.transcript(Self.programme("n", count: 160)))])
    await harness.coordinator.waitUntilIdle()

    let checks = measurement.shadowChecks
    #expect(checks.map(\.queries) == [6])
    #expect(checks.map(\.windowMismatches) == [0])
    #expect(checks.map(\.librarySize) == [measurement.recomputes.last?.librarySize])
  }

  /// An input arriving while the idle shadow check runs stops it early; the pass it queued runs,
  /// then the check finishes the plans it left. The check is what `waitUntilIdle` covers after the
  /// queue is otherwise empty.
  @Test func anInputDuringTheIdleCheckStopsItAndTheNextCheckFinishes() async throws {
    let measurement = HoldingShadowMeasurement()
    let harness = try Harness(measurement: measurement)
    let library = Self.mixedLibrary(harness)
    await harness.run(library)
    measurement.arm()

    await harness.coordinator.setLocalEpisodes(
      library + [harness.episode("n", transcript: Self.transcript(Self.programme("n", count: 160)))])
    #expect(await waitUntil("the idle check is held") { measurement.holding })

    // An input with nothing new: it wakes the queue, so the check stops before its first query.
    await harness.coordinator.setAllowed(true)
    measurement.release()
    await harness.coordinator.waitUntilIdle()

    #expect(measurement.shadowQueries == [0, 6])
  }

  @Test func fullReplansAreNotChecked() async throws {
    let measurement = RecordingMeasurement()
    let harness = try Harness(measurement: measurement, incremental: false)
    let library = Self.mixedLibrary(harness)
    await harness.run(library)
    await harness.coordinator.setLocalEpisodes(library + [harness.episode("n", transcript: Self.withAd("n"))])
    await harness.coordinator.waitUntilIdle()

    #expect(measurement.shadowChecks.isEmpty)
  }

  @Test func nothingIsCheckedWithoutAMeasurement() async throws {
    let harness = try Harness()
    let library = Self.mixedLibrary(harness)
    await harness.run(library)
    await harness.coordinator.setLocalEpisodes(library + [harness.episode("n", transcript: Self.withAd("n"))])
    await harness.coordinator.waitUntilIdle()

    // Every carried plan is still waiting: release builds never run the check.
    #expect(await harness.coordinator.uncheckedCarriedPlans.isEmpty == false)
  }

  /// Holds the next idle shadow check at its start until `release()`.
  final class HoldingShadowMeasurement: AdSkipMatchingMeasuring {
    // The check runs to completion regardless of cancellation, so a cancelled one stays parked.
    private let gate = TestGate<Void>(
      label: "HoldingShadowMeasurement replan check", ignoresCancellation: true)
    private let details = Mutex<[AdSkipMatchingDetail]>([])

    var holding: Bool { gate.parkedCount > 0 }

    /// The queries each finished check ran, in order.
    var shadowQueries: [Int] { details.withLock { $0.map(\.queries) } }

    func arm() {
      details.withLock { $0 = [] }
      gate.hold()
    }

    func release() {
      gate.release()
    }

    func willStart(_ unit: AdSkipMatchingUnit) async {
      guard unit == .replanMismatch else { return }
      await gate.pass()
    }

    func didFinish(_ unit: AdSkipMatchingUnit, _ detail: AdSkipMatchingDetail) async {
      guard unit == .replanMismatch else { return }
      details.withLock { $0.append(detail) }
    }
  }
}

extension AdSkipCoordinatorTests.RecordingMeasurement {
  var pairChecks: Int {
    finished.withLock {
      $0.filter { $0.unit != .replanMismatch }.reduce(0) { $0 + ($1.detail.pairChecks ?? 0) }
    }
  }

  var shadowChecks: [AdSkipMatchingDetail] {
    finished.withLock { $0.filter { $0.unit == .replanMismatch }.map(\.detail) }
  }
}
