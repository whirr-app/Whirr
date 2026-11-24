import Foundation
import WatchProtocol

extension WatchPendingProgressReport {
  /// Builds the report from the Watch's pending rows. Each title is represented by the row the
  /// listener touched last; a row without a listen or a finish says nothing the phone could use.
  public init(
    accountStamp: WatchAccountStamp, sequence: UInt64, sessions: [WatchOfflineProgressSession],
    downloaded: [WatchSelection]
  ) throws {
    var latest: [WatchABSSelection: WatchOfflineProgressSession] = [:]
    for session in sessions where session.accountStamp == accountStamp {
      guard session.hasProgressToSend,
        let selection = try? WatchABSSelection(selection: session.selection)
      else { continue }
      if let current = latest[selection], current.effectiveLastListenedAt >= session.effectiveLastListenedAt {
        continue
      }
      latest[selection] = session
    }
    let entries = latest.sorted { $0.value.effectiveLastListenedAt > $1.value.effectiveLastListenedAt }
      .compactMap { selection, session in
        try? WatchPendingProgressEntry(
          selection: selection, position: session.currentPosition,
          lastListenedAt: session.effectiveLastListenedAt, isFinished: session.isFinished,
          duration: session.duration)
      }
    var seen: Set<WatchABSSelection> = []
    let titles = downloaded.compactMap { try? WatchABSSelection(selection: $0) }.filter { seen.insert($0).inserted }
    try self.init(
      accountStamp: accountStamp, sequence: sequence,
      entries: Array(entries.prefix(WatchPendingProgressLimits.maxEntries)),
      downloaded: Array(titles.prefix(WatchPendingProgressLimits.maxDownloaded)))
  }
}
