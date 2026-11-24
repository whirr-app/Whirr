import Foundation
import Persistence
import WatchProtocol

/// Applies a Watch listen of a received RSS episode as a listen on this phone.
///
/// The report names episodes by feed and identity key, so every entry is resolved through the rows
/// a local listen writes and applied through that same writer: the phone stays the only writer of
/// RSS episode state. Nothing is persisted here beyond the highest sequence seen since launch.
/// That is enough because a replay after a relaunch is harmless — the peer-listen rule rejects a
/// listen the row already holds (converged) or one the phone has since superseded, so a stored
/// cursor would add a second source of truth without changing an outcome.
@MainActor
final class WatchNativeProgressInbox {
  typealias ActiveInstallID = @MainActor () async -> String?
  typealias EpisodeIDs = @MainActor (_ feedId: Int64, _ identityKeys: Set<String>) async -> [String: Int64]
  typealias Apply =
    @MainActor (
      _ episodeId: Int64, _ position: Double, _ finished: Bool, _ listenedAt: Date, _ duration: Double?,
      _ now: Date
    ) async -> RSSPeerListenOutcome?
  typealias IsPlayingHere = @MainActor (_ episodeId: Int64) -> Bool
  typealias RemoveFromWatch = @MainActor (_ episodeId: Int64) async -> Void

  private let activeInstallID: ActiveInstallID
  private let episodeIDs: EpisodeIDs
  private let apply: Apply
  private let isPlayingHere: IsPlayingHere
  private let removeFromWatch: RemoveFromWatch
  private let now: @MainActor () -> Date

  /// The highest sequence accepted per Watch install in this process. A report for any other
  /// install is rejected before it reaches here, so this holds at most one meaningful entry.
  private var lastSequences: [String: UInt64] = [:]
  /// The newest entry per episode for a listen that arrived while the phone was playing that
  /// episode. Applying it earlier would make the phone's next tick fail as stale.
  private var waiting: [Int64: WatchNativeProgressEntry] = [:]

  init(
    activeInstallID: @escaping ActiveInstallID,
    episodeIDs: @escaping EpisodeIDs,
    apply: @escaping Apply,
    isPlayingHere: @escaping IsPlayingHere,
    removeFromWatch: @escaping RemoveFromWatch,
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.activeInstallID = activeInstallID
    self.episodeIDs = episodeIDs
    self.apply = apply
    self.isPlayingHere = isPlayingHere
    self.removeFromWatch = removeFromWatch
    self.now = now
  }

  /// Held listens still waiting for the phone's session on their episode to end.
  var pendingCount: Int { waiting.count }

  func receive(_ data: Data) async {
    guard data.count <= WatchNativeProgressReport.maxWireBytes,
      let report = try? WatchWireCodec.decode(WatchNativeProgressReport.self, from: data),
      let install = await activeInstallID(), report.watchInstallID == install
    else { return }
    // A Watch with no known install means the phone has never offered it a copy, so it also has
    // no listen of a received copy to report.
    if let last = lastSequences[install], report.sequence <= last { return }
    lastSequences[install] = report.sequence

    var entriesByFeed: [Int64: [WatchNativeProgressEntry]] = [:]
    for entry in report.entries {
      guard let feedId = Int64(entry.selection.feedID), feedId > 0 else { continue }
      entriesByFeed[feedId, default: []].append(entry)
    }

    for (feedId, entries) in entriesByFeed {
      let identityKeys = Set(entries.map(\.selection.episodeID))
      let known = await episodeIDs(feedId, identityKeys)
      for entry in entries {
        guard let episodeId = known[entry.selection.episodeID] else { continue }
        if isPlayingHere(episodeId) {
          hold(entry, for: episodeId)
        } else {
          waiting[episodeId] = nil
          await applyEntry(entry, episodeId: episodeId)
        }
      }
    }
  }

  /// Called when the phone's playback session ends. `isPlayingHere` must already report the ending
  /// session as gone; an episode that is still loaded keeps waiting, because applying its listen
  /// now would make the phone's next tick fail as stale.
  func phoneSessionEnded() async {
    for (episodeId, entry) in waiting where !isPlayingHere(episodeId) {
      waiting[episodeId] = nil
      await applyEntry(entry, episodeId: episodeId)
    }
  }

  private func hold(_ entry: WatchNativeProgressEntry, for episodeId: Int64) {
    if let held = waiting[episodeId], held.lastListenedAt > entry.lastListenedAt { return }
    waiting[episodeId] = entry
  }

  private func applyEntry(_ entry: WatchNativeProgressEntry, episodeId: Int64) async {
    let outcome = await apply(
      episodeId, entry.position, entry.isFinished, entry.lastListenedAt, entry.duration, now())
    // A played episode leaves the Watch once the phone records it finished. A converged entry
    // is one the phone already holds, so the episode is finished here too.
    guard entry.isFinished, let outcome else { return }
    switch outcome {
    case .applied, .rejected(.converged):
      await removeFromWatch(episodeId)
    case .rejected:
      break
    }
  }
}
