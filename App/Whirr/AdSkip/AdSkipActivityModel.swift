import AdSkip
import AppModel
import Observation

/// Which episode is being checked for ads now, for the tiles' transient glyph. Follows the
/// coordinator's settled activity, so a unit that defers at once never reaches a tile.
@MainActor
@Observable
final class AdSkipActivityModel {
  private(set) var activity: AdSkipAnalysisActivity?
  @ObservationIgnored private var task: Task<Void, Never>?

  init(updates: AsyncStream<AdSkipAnalysisActivity?>) {
    task = Task { [weak self] in
      for await activity in updates {
        guard let self else { return }
        if self.activity != activity { self.activity = activity }
      }
    }
  }

  isolated deinit {
    task?.cancel()
  }

  /// By item and episode only, as the player's range lookup matches: two accounts' copies of one
  /// server episode are both marked, which is harmless for a transient glyph.
  func isAnalysing(itemID: String, episodeID: String?) -> Bool {
    guard let episodeID, let activity else { return false }
    return activity.includes(itemID: itemID, episodeID: episodeID)
  }
}

extension AdSkipActivityModel {
  /// The production model; without a coordinator nothing is ever analysed.
  static let shared = AdSkipActivityModel(
    updates: AdSkipComposition.coordinator?.analysisActivityUpdates() ?? AsyncStream { $0.finish() })
}
