import Foundation
import Persistence

/// A bounded automatic retry of failed automatic downloads. The failure sites arm a deadline;
/// every `schedule()` pass requeues what has come due. There is no timer (API-CONVENTIONS
/// rule 20): `schedule()` already runs on launch, on every transfer event and intent, on network
/// changes, and on every overnight wake.
extension DownloadCoordinator {
  private enum DueRetry {
    case abs(Int64)
    case rss(Int64)
  }

  /// The ABS table's retry adapter, rebuilt per use so it always sees the coordinator's current
  /// store.
  var absRowSpine: AbsDownloadRowSpine { AbsDownloadRowSpine(store: downloadStore) }

  /// The RSS adapter, absent exactly when this composition has no RSS store or account removal has
  /// begun; `rssDownloadStore` owns that rule.
  var rssRowSpine: RssDownloadRowSpine? {
    guard let rssDownloadStore else { return nil }
    return RssDownloadRowSpine(store: rssDownloadStore)
  }

  /// Gives a just-failed row its next retry deadline when the policy allows one. The store guard
  /// leaves a row alone that has meanwhile left `.failed` or is manual.
  func armAutomaticRetry(_ identity: TransferIdentity, failure: AutomaticDownloadFailure) async {
    let failedAt = now()
    guard let target = rowTarget(for: identity),
      let notBefore = await armedDeadline(
        on: target.spine, downloadId: target.id, failedAt: failedAt, failure: failure)
    else { return }
    emitRetryTrace(identity, .retryScheduled(afterSeconds: Int(notBefore.timeIntervalSince(failedAt))))
  }

  /// Runs at the start of `performSchedule`, on the serial chain. Requeues at most
  /// `maxConcurrentTransfers` due rows, earliest deadline first, so a failure burst cannot crowd
  /// out a manual request. A due row behind a closed gate stays `.failed`, count and deadline
  /// untouched, for the next pass.
  func requeueDueAutomaticRetries() async {
    // The automatic pass's own gates: never spend an attempt on a link that is metered,
    // constrained or under Low Power Mode, nor while the disk is full.
    guard queuePauseReason != .lowDisk, networkConditions.isConstrainedOrCellular == false,
      networkConditions.isLowPowerMode == false
    else { return }
    let at = now()
    let limit = Self.maxConcurrentTransfers
    var due: [(notBefore: Date, retry: DueRetry)] = []
    for row in await absRowSpine.due(now: at, limit: limit) {
      due.append((row.notBefore, .abs(row.id)))
    }
    if let rssRowSpine {
      for row in await rssRowSpine.due(now: at, limit: limit) {
        due.append((row.notBefore, .rss(row.id)))
      }
    }
    // One budget over both tables: the limit is spent on the merged, deadline-ordered list.
    due.sort { $0.notBefore < $1.notBefore }

    for entry in due.prefix(limit) {
      switch entry.retry {
      case .abs(let id):
        guard let attempt = await absRowSpine.requeue(id: id, now: at) else { continue }
        // The failure marker waits for this requeue; without it the row strands `.pending` and
        // skipped.
        eventFailedDownloadIds.remove(id)
        emitRetryTrace(.abs(rowID: id), .retry(attempt: attempt))
      case .rss(let id):
        guard let rssRowSpine, let attempt = await rssRowSpine.requeue(id: id, now: at)
        else { continue }
        rssEventFailedDownloadIds.remove(id)
        emitRetryTrace(.rss(rowID: id), .retry(attempt: attempt))
      }
    }
  }

  /// The one arm body: the policy decides the deadline, the adapter's guarded write decides
  /// whether this row still wants it.
  private func armedDeadline(
    on spine: any DownloadRowSpine, downloadId: Int64, failedAt: Date,
    failure: AutomaticDownloadFailure
  ) async -> Date? {
    guard let row = await spine.fetch(id: downloadId), spine.isFailedAutomatic(row: row),
      let notBefore = automaticRetryPolicy.nextAttempt(
        after: failedAt, retriesSoFar: row.autoRetryCount, origin: row.origin, failure: failure),
      await spine.arm(id: downloadId, notBefore: notBefore)
    else { return nil }
    return notBefore
  }

  /// The identity stays the only thing that chooses a table; ids are never compared across them.
  private func rowTarget(
    for identity: TransferIdentity
  ) -> (id: Int64, spine: any DownloadRowSpine)? {
    switch identity {
    case .abs(let id):
      return (id, absRowSpine)
    case .rss(let id):
      guard let rssRowSpine else { return nil }
      return (id, rssRowSpine)
    }
  }

  private func emitRetryTrace(_ identity: TransferIdentity, _ event: DownloadDeviceTrace.TransferEvent) {
    switch identity {
    case .abs(let id):
      emitDeviceTraceRecord(.transfer(DownloadDeviceTrace.Transfer(downloadId: id, event: event)))
    case .rss(let id):
      emitDeviceTraceRecord(.rssTransfer(DownloadDeviceTrace.Transfer(downloadId: id, event: event)))
    }
  }
}
