import Foundation
import Persistence

extension AdSkipCoordinator {
  /// The latest progress; nil while the setting is off or before the inputs have arrived.
  public var progress: AdSkipProgress? { progressChanges.latest }

  /// The current progress at once, then every change.
  public nonisolated func progressUpdates() -> AsyncStream<AdSkipProgress?> {
    progressChanges.stream()
  }

  /// Reads the stored episodes and publishes. A failed read keeps the last value shown.
  func publishProgress() async {
    guard isEnabled == true, localEpisodes != nil else {
      progressChanges.publish(nil)
      return
    }
    guard let stored = try? await dependencies.episodes.allEpisodes() else { return }
    publishProgress(stored: stored)
  }

  func publishProgress(stored: [AdSkipEpisodeRecord]) {
    guard isEnabled == true, let localEpisodes else {
      progressChanges.publish(nil)
      return
    }
    let storedByIdentity = Self.byIdentity(stored)
    var analysed = 0
    var unanalysable = 0
    var remaining = 0
    for episode in localEpisodes.values where Self.isAnalysable(episode) {
      let row = storedByIdentity[episode.identity]
      // A decoded episode still waits for its first windows.
      if row?.state == .analysed {
        analysed += 1
      } else if row?.state == .decoded && unreadableFiles.contains(episode.identity) == false
        || needsDecode(episode, stored: row)
      {
        remaining += 1
      } else {
        unanalysable += 1
      }
    }
    let activity: AdSkipProgress.Activity =
      remaining == 0 && hasQueuedWork == false
      ? .idle : (isAllowed && isDeferred == false ? .analysing : .paused)
    progressChanges.publish(
      AdSkipProgress(
        analysed: analysed, unanalysable: unanalysable,
        total: analysed + unanalysable + remaining, activity: activity))
  }
}
