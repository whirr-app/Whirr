import ABSApi
import AppModel
import Foundation
import Persistence

/// The Audiobookshelf half of the On Apple Watch screen (ADR 0021): the bound
/// account's desired set and the downloads the Watch started itself, in the same row and status
/// vocabulary as the followed-show episodes.
extension OnAppleWatchPresentation {
  /// The rows the screen draws, with a copy removed on this iPhone left out. A copy the Watch
  /// removed stays, as for followed shows; a download the Watch started itself offers Remove and no
  /// recovery action.
  static func rows(
    _ rows: [ABSWatchCopyRow], readiness: WatchABSReadiness
  ) -> [OnAppleWatchRow] {
    rows.compactMap { row in
      if row.state == .removed(.phone) { return nil }
      let status = status(for: row, readiness: readiness)
      return OnAppleWatchRow(
        id: row.id,
        kind: row.isBook ? .book : .episode,
        target: .audiobookshelf(row.key),
        title: row.title,
        subtitle: row.subtitle ?? "",
        artworkItemID: row.key.itemId,
        artworkSource: row.artwork?.source,
        artworkFallbackSource: nil,
        artworkRevision: row.artwork?.revision ?? .unversioned,
        status: status,
        action: row.isPhoneOrigin ? status.action : nil,
        canRemove: row.state != .removed(.watch),
        requestedAt: row.requestedAt)
    }
  }

  /// One Audiobookshelf title's status. A phone request and a download the Watch started itself
  /// read the same way once the Watch has reported on them.
  static func status(
    for row: ABSWatchCopyRow, readiness: WatchABSReadiness
  ) -> OnAppleWatchStatus {
    if case .removed(let remover) = row.state {
      return remover == .watch ? .removedOnWatch : .couldNotDownload
    }
    // As for followed shows: the files went with the Watch app.
    if readiness == .notInstalled { return .watchAppNotInstalled }
    switch row.state {
    case .delivered: return .onWatch
    case .declined(let reason): return declined(reason)
    case .failed(let reason): return failed(reason)
    case .wanted, .waitingForWatch: return notYetAcknowledged(readiness)
    case .sending: return groupStatus(row.group, readiness: readiness)
    case .removed: return .couldNotDownload
    }
  }

  /// The Watch's latest report on the row's own revision: the only source of a percentage, the
  /// part count and the Wi-Fi hold.
  private static func groupStatus(
    _ group: ABSWatchGroup?, readiness: WatchABSReadiness
  ) -> OnAppleWatchStatus {
    guard let group else { return notYetAcknowledged(readiness) }
    switch group.state {
    case .queued: return .waitingForWatch
    case .downloading: return .downloadingOnWatch(progress: group.progress, parts: parts(group))
    case .waitingForNetwork: return .waitingForWiFiOnWatch
    case .ready: return .onWatch
    case .failed: return .couldNotDownload
    case .declined: return group.declineReason == .storageFull ? .watchStorageFull : .couldNotDownload
    case .removed: return .removedOnWatch
    }
  }

  /// A book's parts, once it has more than one. An episode is one file.
  static func parts(_ group: ABSWatchGroup) -> OnAppleWatchParts? {
    guard group.isBook, group.trackCount > 1 else { return nil }
    return OnAppleWatchParts(completed: group.completedTracks, total: group.trackCount)
  }

  private static func declined(_ reason: WatchCopyState.DeclineReason) -> OnAppleWatchStatus {
    switch reason {
    case .storageFull: .watchStorageFull
    case .signedOut: .setUpWatch
    case .invalid: .couldNotDownload
    }
  }

  /// The Watch retries a network failure by itself when the network returns, so the row
  /// says what it is waiting for rather than offering Try Again.
  private static func failed(_ reason: WatchCopyState.FailureReason?) -> OnAppleWatchStatus {
    switch reason {
    case .notOnServer: .notOnServer
    case .noAudio: .noAudioToDownload
    case .network: .waitingForWiFiOnWatch
    case .server, .tooLarge, .couldNotDownload, nil: .couldNotDownload
    }
  }

  /// Before the Watch acknowledges a request, the only fact is what its last status report said
  /// about itself and its account.
  private static func notYetAcknowledged(_ readiness: WatchABSReadiness) -> OnAppleWatchStatus {
    switch readiness {
    case .unknown: .openWhirrOnWatch
    case .ready: .waitingForWatch
    case .needsUpdate: .updateWhirrOnWatch
    case .setUpWatch: .setUpWatch
    case .notInstalled: .watchAppNotInstalled
    }
  }
}
