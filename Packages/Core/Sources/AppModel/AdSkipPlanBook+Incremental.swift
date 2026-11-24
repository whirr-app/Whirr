import AdSkip
import Foundation
import Persistence

/// Incremental audio replanning: the plans a new library keeps because its episode's audio recurs
/// in none of the added prints.
extension AdSkipPlanBook {
  /// The retained plans `library` keeps: every one whose episode's audio recurs in none of the
  /// added prints (a pairwise check). Empty, so every episode is queried, when no plans were
  /// retained or a reference was removed, re-keyed or reordered.
  func plansCarried(
    into library: AudioLibrary, on coordinator: isolated AdSkipCoordinator
  ) async -> [AdSkipEpisodeIdentity: StageOnePlan] {
    guard let retained = retainedPlans else { return [:] }
    let kept = Set(retained.entries)
    guard library.entries.filter(kept.contains) == retained.entries else { return [:] }
    let added = library.entries.indices.filter { kept.contains(library.entries[$0]) == false }
    let candidates = retained.plans.compactMap { identity, plan -> (AdSkipEpisodeIdentity, Int, StageOnePlan)? in
      guard let index = library.queryIndex[identity],
        retained.entryByEpisode[identity] == library.entries[index]
      else { return nil }
      return (identity, index, plan)
    }
    let references = library.references
    let (carried, checks) = await Task.detached(priority: .utility) {
      var checks = 0
      var carried: [AdSkipEpisodeIdentity: StageOnePlan] = [:]
      for (identity, index, plan) in candidates {
        // The kept episode against each added print alone: does its audio recur there?
        let recurs = added.contains { print in
          checks += 1
          return AudioRecurrence.runs(of: 0, in: [references[index], references[print]]).isEmpty == false
        }
        if recurs == false { carried[identity] = plan }
      }
      return (carried, checks)
    }.value
    stageOnePairChecks += checks
    return carried
  }
}
