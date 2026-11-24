import AdSkip
import Foundation
import Persistence
import PlayerCore

/// The coordinator as the player's range source.
extension AdSkipCoordinator: PlaybackSkipRangeSource {

  /// The loaded file's ranges under the current rules, or none: the setting is off, the file is
  /// not an analysed local episode, or its fingerprint no longer matches the analysis. Asking also
  /// puts the episode first in the analysis queue.
  public func skipRanges(for request: PlaybackSkipRangeRequest) async -> [PlayerSkipRange] {
    guard let local = localEpisode(matching: request) else { return [] }
    await prioritize(local.identity)
    guard let rows = await servedRows(of: local.identity, fileURL: request.fileURL) else { return [] }
    // The pre-roll edge is applied here, not saved, so it changes no rules revision and no stored
    // plan.
    return rows.map {
      PlayerSkipRange(
        start: PlaybackEdges.start(atItemStartFor: $0.startTime), end: $0.endTime,
        endsItem: $0.endsItem)
    }
  }

  public nonisolated func skipRangeChanges() -> AsyncStream<Void> {
    rangeChanges.stream()
  }

  /// Progress is read from the settled state, so a hold that lifts and returns at once, as on
  /// every activation while the speech model is missing, never reaches the player. "Off" is read
  /// from the live setting: the settled one is false until the first settle of every launch, and
  /// an unknown setting says nothing. Asking also puts the episode first, as asking for ranges
  /// does.
  public func analysisStatus(for request: PlaybackSkipRangeRequest) async -> PlaybackAdAnalysisStatus {
    guard let local = localEpisode(matching: request) else { return .none }
    await prioritize(local.identity)
    // Before the settled guard, and not gated on the charging signal: whether the file is one
    // analysis would cover does not depend on either.
    if isEnabled == false { return isSchedulable(local) ? .notEnabled : .none }
    let settled = activity.settled
    guard settled.speaks(about: isSchedulable(local)) else { return .none }
    let row = try? await dependencies.episodes.episode(for: local.identity)
    if let row, row.state != .decoded, needsDecode(local, stored: row) == false,
      dependencies.fingerprinting.fingerprint(ofFileAt: request.fileURL) == row.fingerprint
    {
      // Analysed, or given up on under this transcriber: nothing more is coming.
      return .none
    }
    switch settled.standing(of: local.identity) {
    case .checking: return .checking
    case .queued: return .none
    case .waiting(let hold): return .waiting(hold)
    }
  }

  /// Grants Check Now for the loaded episode and puts it first.
  public func checkNow(for request: PlaybackSkipRangeRequest) async {
    guard let local = localEpisode(matching: request) else { return }
    await prioritize(local.identity)
    grantedPriority = local.identity
    await wake()
  }

  /// Queues the undo for the worker, which tombstones the range so it is never a hit again, here
  /// or in any other episode, drops what the store taught for it, and recomputes.
  public func undoSkip(_ range: PlayerSkipRange, for request: PlaybackSkipRangeRequest) async {
    guard let local = localEpisode(matching: request) else { return }
    pendingUndos.append(PendingUndo(identity: local.identity, start: range.start, end: range.end))
    await wake()
  }

  /// The local episode a request is about. Identity decides; the path only separates two accounts'
  /// copies of one server episode, and the fingerprint check that follows is the real guard.
  private func localEpisode(matching request: PlaybackSkipRangeRequest) -> AdSkipLocalEpisode? {
    guard let episodeID = request.episodeID else { return nil }
    let matches = currentLocalEpisodes.values.filter {
      $0.identity.itemID == request.itemID && $0.identity.episodeID == episodeID
    }
    guard matches.count > 1 else { return matches.first }
    let path = request.fileURL.standardizedFileURL.path
    return matches.first { $0.fileURL.standardizedFileURL.path == path }
  }
}
