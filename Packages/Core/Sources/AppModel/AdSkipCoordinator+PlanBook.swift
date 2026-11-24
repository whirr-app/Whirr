import AdSkip
import Persistence

/// The plan book's state that the test suites read. Kept on the coordinator so those suites need
/// no rewrite; the coordinator's own code reaches the book's fields through `plans`.
extension AdSkipCoordinator {
  /// See `AudioLibrary`; nil until needed after a change to the set of prints.
  var audioLibrary: AudioLibrary? { plans.audioLibrary }

  /// Episodes whose current plan was carried and not yet checked against a full query.
  var uncheckedCarriedPlans: Set<AdSkipEpisodeIdentity> { plans.uncheckedCarriedPlans }
}
