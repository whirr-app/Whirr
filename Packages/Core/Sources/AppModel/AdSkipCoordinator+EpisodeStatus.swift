import AdSkip
import Foundation
import Persistence

extension AdSkipCoordinator {

  /// The status of the downloaded episode a card shows. Unlike `analysisStatus(for:)` it answers
  /// for any episode and leaves the queue alone: opening a card is not a request to analyse.
  ///
  /// An RSS download is also found through its linked server copy. Two accounts' copies of one
  /// server episode are separate files with separate analyses and the card does not say which it
  /// plays, so the least settled copy answers: never a skip the played file may not have.
  public func episodeStatus(itemID: String, episodeID: String) async -> AdSkipEpisodeStatus {
    let matches = currentLocalEpisodes.values.filter { local in
      ([local.identity] + local.linkedIdentities).contains {
        $0.itemID == itemID && $0.episodeID == episodeID
      }
    }
    var least: AdSkipEpisodeStatus?
    for local in matches {
      let status = await episodeStatus(of: local)
      if least.map({ status.settledness < $0.settledness }) ?? true { least = status }
    }
    return least ?? .none
  }

  /// Yields whenever any episode's status may have changed. Both sources are needed: a finished
  /// download and a row reaching `.analysed` signal only the ranges, a hold only the status.
  public nonisolated func episodeStatusChanges() -> AsyncStream<Void> {
    // Opened here, not in the task, so a signal sent before the task first runs is kept.
    let status = statusChanges.stream()
    let ranges = rangeChanges.stream()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let forwarding = Task {
        await withTaskGroup(of: Void.self) { group in
          for source in [status, ranges] {
            group.addTask {
              for await _ in source { continuation.yield() }
            }
          }
        }
      }
      continuation.onTermination = { _ in forwarding.cancel() }
    }
  }

  /// Read from the settled state, as the player's status is, so a hold that lifts and returns at
  /// once never reaches the card.
  private func episodeStatus(of local: AdSkipLocalEpisode) async -> AdSkipEpisodeStatus {
    let settled = activity.settled
    guard settled.speaks(about: isSchedulable(local)) else { return .none }
    let row = try? await dependencies.episodes.episode(for: local.identity)
    if let row, needsDecode(local, stored: row) == false {
      switch row.state {
      case .failed:
        return .failed
      case .analysed:
        // A changed file is analysed again from scratch, so its old ranges promise nothing.
        if let rowId = row.id,
          dependencies.fingerprinting.fingerprint(ofFileAt: local.fileURL) == row.fingerprint,
          let ranges = try? await dependencies.episodes.ranges(forEpisodeId: rowId)
        {
          return .ready(
            AdSkipBreaks(
              servedRows: ranges.filter {
                AdSkipRules.servedRevisions.contains($0.rulesRevision)
              }))
        }
      case .decoded:
        break
      }
    }
    switch settled.standing(of: local.identity) {
    case .checking: return .checking
    case .queued: return .queued
    case .waiting(let hold): return .waiting(hold)
    }
  }

  /// The skips the listener would hear. One break is stored as several ranges (each ad, the fill
  /// between two of them, a sting segment) and the player plays ranges within its join of each
  /// other as one skip (`PlayerReducer.skipJoinGap`), so counting rows would overstate it.
  static func breakCount(of ranges: [AdSkipRange]) -> Int {
    AdSkipBreaks(
      servedRows: ranges.filter { AdSkipRules.servedRevisions.contains($0.rulesRevision) }
    ).count
  }
}
