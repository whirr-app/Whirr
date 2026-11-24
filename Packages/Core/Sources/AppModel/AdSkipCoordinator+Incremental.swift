import AdSkip
import Foundation
import Persistence

/// Incremental audio replanning. When prints change only by additions, an episode's stage-1 plan
/// is kept unless its audio recurs in an added print; new and flagged episodes are queried against
/// the whole library. Anything removed, re-keyed or reordered replans the whole library.
///
/// Not exact: a new print can still change an unflagged episode's runs through `AudioRecurrence`'s
/// library-wide couplings (common hashes, per-chunk offset rank, first match wins). On real prints
/// every such change was a run below `minimumRunSeconds` that moved no window. Debug builds check
/// every carried plan against a full query once the worker is idle.
extension AdSkipCoordinator {
  /// Debug builds' shadow of the incremental replan: queries every carried plan's episode against
  /// the whole library and reports how many plans' windows or audio-edge evidence differ. Plans
  /// are never corrected from it. Stops when an input arrives; what is left is checked at the next
  /// idle, if the library is still the same.
  func checkCarriedPlans() async {
    guard let measurement = dependencies.matchingMeasurement, let library = plans.audioLibrary,
      plans.uncheckedCarriedPlans.isEmpty == false
    else { return }
    await measurement.willStart(.replanMismatch)
    var queries = 0
    var mismatches = 0
    for identity in plans.uncheckedCarriedPlans.sorted(by: { $0.episodeKey < $1.episodeKey }) {
      guard await queue.hasPendingPass == false, await shouldContinueRecompute,
        plans.audioLibrary?.key == library.key
      else { break }
      plans.uncheckedCarriedPlans.remove(identity)
      guard let index = library.queryIndex[identity],
        let plan = plans.stageOnePlans[identity] ?? plans.carriedStageOnePlans[identity]
      else { continue }
      let queried = await AdSkipPlanBook.query(index, in: library)
      queries += 1
      if queried != plan { mismatches += 1 }
    }
    await measurement.didFinish(
      .replanMismatch,
      AdSkipMatchingDetail(
        queries: queries, librarySize: library.references.count, windowMismatches: mismatches))
  }

  // MARK: - Tests

  /// Every stored row's stage-1 plan, made as the queue would make it. For tests.
  func stageOnePlansForTests() async throws -> [AdSkipEpisodeIdentity: [TimeSpan]] {
    var plans: [AdSkipEpisodeIdentity: [TimeSpan]] = [:]
    for row in try await dependencies.episodes.allEpisodes() {
      if let plan = try await stageOneWindows(of: row) { plans[row.identity] = plan }
    }
    return plans
  }

  /// Every stored row's audio-edge evidence, planned as the queue would plan it. For tests.
  func audioEdgesForTests() async throws -> [AdSkipEpisodeIdentity: [TimeSpan]] {
    var edges: [AdSkipEpisodeIdentity: [TimeSpan]] = [:]
    for row in try await dependencies.episodes.allEpisodes() {
      if let plan = try await stageOnePlan(of: row) { edges[row.identity] = plan.audioEdges }
    }
    return edges
  }

  /// What a full replan of the current library plans for each of its episodes, leaving every plan
  /// as it is. For tests.
  func fullReplanForTests() async throws -> [AdSkipEpisodeIdentity: [TimeSpan]] {
    let library = try await loadedAudioLibrary()
    return library.queryIndex.mapValues {
      TranscriptionWindows.stageOne(runs: AudioRecurrence.runs(of: $0, in: library.references))
    }
  }
}
