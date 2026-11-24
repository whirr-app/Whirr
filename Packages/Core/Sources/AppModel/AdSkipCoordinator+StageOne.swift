import AdSkip
import Persistence

/// Stage-1 planning on the worker: the row's plan and the audio library, each dropping the
/// episode of a print that cannot be read and loading again. The planning itself is
/// `AdSkipPlanBook`.
extension AdSkipCoordinator {
  // MARK: - Planning

  /// The row's stage-1 windows, from where its audio recurs in the library. Nil means its words all
  /// feed the index: a row transcribed in full before audio prints, or the whole-file mode.
  func stageOneWindows(of row: AdSkipEpisodeRecord) async throws -> [TimeSpan]? {
    try await stageOnePlan(of: row)?.windows
  }

  /// The row's stage-1 plan; nil exactly when `stageOneWindows` is. A print that cannot be read has
  /// its episode decoded again, once, as an unreadable transcript does.
  func stageOnePlan(of row: AdSkipEpisodeRecord) async throws -> StageOnePlan? {
    do {
      return try await plans.stageOnePlan(of: row, local: currentLocalEpisodes, on: self)
    } catch let unreadable as AdSkipPlanBook.UnreadablePrints {
      try await discardUnreadable(unreadable.identities)
      return try await stageOnePlan(of: row)
    }
  }

  /// The library, loaded once per change to the set of prints. A print that cannot be read has its
  /// episode decoded again, once, as an unreadable transcript does.
  func loadedAudioLibrary() async throws -> AudioLibrary {
    do {
      return try await plans.loadedAudioLibrary(local: currentLocalEpisodes, on: self)
    } catch let unreadable as AdSkipPlanBook.UnreadablePrints {
      try await discardUnreadable(unreadable.identities)
      return try await loadedAudioLibrary()
    }
  }
}
