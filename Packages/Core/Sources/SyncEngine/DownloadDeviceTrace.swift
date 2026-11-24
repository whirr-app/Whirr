import CoreSupport
import Foundation
import Persistence

/// The bounded source of a download purge. These values describe the local caller only; they
/// never contain an item, episode, or account identifier.
public enum DownloadPurgeSource: String, Equatable, Sendable {
  case itemDetail
  case contextMenu
  case finishedDownloadAutoDelete
  case podcastEpisodeRemoval
  case autoDownloadReaper
  case storageCeiling
  case readerEbook
  case storage
  case accountRemoval
  /// A pinned list letting go of a download its own request made: the member left the list, or
  /// the list was unpinned.
  case pinnedListRelease
  /// A smart list letting go of a download its own request made: the episode left the list's top
  /// N, the limit was lowered, auto-download was switched off, or the list was deleted.
  case smartListRelease

  /// Purges the user did not ask for at this moment; they step aside for an item with a transfer
  /// in flight. Every other source is an explicit removal and removes regardless.
  ///
  /// The storage-ceiling pass does not call the guarded purge methods: its claim transaction
  /// revalidates in-flight transfers, so this flag is descriptive there.
  var isAutomatic: Bool {
    switch self {
    case .finishedDownloadAutoDelete, .storageCeiling, .pinnedListRelease, .smartListRelease: true
    case .itemDetail, .contextMenu, .podcastEpisodeRemoval, .autoDownloadReaper, .readerEbook,
      .storage, .accountRemoval:
      false
    }
  }

  /// The listener removing a download by hand. A pinned list holding the member must not
  /// download it again. The selection batch's Remove Downloads passes `.contextMenu`.
  public var isHandRemoval: Bool {
    switch self {
    case .itemDetail, .contextMenu, .storage, .podcastEpisodeRemoval: true
    case .finishedDownloadAutoDelete, .autoDownloadReaper, .storageCeiling, .readerEbook,
      .accountRemoval, .pinnedListRelease, .smartListRelease:
      false
    }
  }
}

/// The download queue's DEBUG-only device trace, read like the other `WHIRR*` streams:
///
///     log stream --predicate 'eventMessage CONTAINS "WHIRRDL"'
///
/// Like `DrainCadenceTrace`, it answers what the UI cannot: a relaunch that reattaches to a
/// transfer and one that restarts from zero look identical (both come from
/// `reconcileAfterLaunch`'s join), a Wi-Fi hold and a never-started row both render "waiting",
/// and a stalled queue looks the same whether the cause is the two-transfer cap, the cellular
/// policy or low disk.
///
/// Every record is an observation, never a verdict.
///
/// Records carry only the local `downloads.id` and byte counts: no URL, token, or server
/// item/episode/session id (SECURITY.md §7).
public enum DownloadDeviceTrace {
  public static let prefix = "WHIRRDL"

  /// The outcome of one launch-reconciliation pass, in a single line because the durable table
  /// afterwards cannot distinguish reattached from restarted rows.
  public struct Reconcile: Equatable, Sendable {
    /// Every surviving download row, whatever its state.
    public let rows: Int
    /// What the adapter still believes it is transferring.
    public let liveTasks: Int
    /// `.interrupted` rows with a matching live task, restored to `.downloading` without
    /// re-enqueuing.
    public let reattached: Int
    /// `.interrupted` rows with no live task, requeued to `.pending` for the ordinary scheduler.
    public let requeued: Int
    /// Live tasks with no row at all, cancelled outright. A nonzero count after an ordinary
    /// relaunch means a phantom row.
    public let orphansCancelled: Int
    /// Durably Wi-Fi-held rows whose live task this fresh process adopted into
    /// `networkHeldActiveDownloadIds`. A durable hold whose task did not survive is the
    /// difference between this and the held rows visible in the UI.
    public let heldAdopted: Int

    public init(
      rows: Int, liveTasks: Int, reattached: Int, requeued: Int, orphansCancelled: Int,
      heldAdopted: Int
    ) {
      self.rows = rows
      self.liveTasks = liveTasks
      self.reattached = reattached
      self.requeued = requeued
      self.orphansCancelled = orphansCancelled
      self.heldAdopted = heldAdopted
    }
  }

  /// Every input to one `performSchedule` pass's start/hold decision. Emitted once per pass.
  /// Scheduling is triggered by queue and network/preference changes, never by byte-level
  /// progress, so this stays sparse.
  public struct Schedule: Equatable, Sendable {
    public let active: Int
    public let pending: Int
    public let slots: Int
    public let isConstrainedOrCellular: Bool
    public let allowsCellular: Bool
    public let isQueuePausedForLowDisk: Bool
    /// Pending rows this pass will not consider: a row carrying a failed-event marker is dropped
    /// before any gate is evaluated, so without this the line could show two pending rows, two
    /// free slots and every policy open, yet start nothing.
    public let skipped: Int

    public init(
      active: Int, pending: Int, slots: Int, isConstrainedOrCellular: Bool, allowsCellular: Bool,
      isQueuePausedForLowDisk: Bool, skipped: Int
    ) {
      self.active = active
      self.pending = pending
      self.slots = slots
      self.isConstrainedOrCellular = isConstrainedOrCellular
      self.allowsCellular = allowsCellular
      self.isQueuePausedForLowDisk = isQueuePausedForLowDisk
      self.skipped = skipped
    }
  }

  /// Which side of a Wi-Fi hold a row was on. Both land on the same durable
  /// `.pending(.waitingForWiFi)` state, so the row cannot say which happened, and only `.active`
  /// involves a suspended adapter task that the resume path later assumes still exists.
  public enum HoldOrigin: String, Equatable, Sendable {
    case active
    case pending
  }

  public enum Outcome: Equatable, Sendable {
    /// Validated and committed by `DownloadFileStore.completeTransfer`.
    case stored
    /// A real disk-full write failure. Pauses the whole queue.
    case lowDisk
    /// Completed, then rejected by `DownloadFileStore.completeTransfer`. `.validation` covers four
    /// unrelated guards, so the one that fired rides along. Without it a stale server-recorded
    /// file size is indistinguishable from a server serving the wrong route.
    case rejected(DownloadErrorCategory, DownloadValidationReason? = nil)
    /// Completed, then rejected by `RSSFileStore.completeTransfer`. The RSS store has its own
    /// reason set because its guards differ (an absolute cap and the response's own length, not a
    /// server-declared size), and `.validation` alone does not say which fired.
    case rssRejected(DownloadErrorCategory, RSSTransferRejection)
    /// A terminal failure reported by the adapter. The optional values are the NSError's bounded
    /// domain/code pair; no description or userInfo crosses this boundary.
    case failed(errorDomain: String?, errorCode: Int?)
    /// A second consecutive `401`, or a failed renewal: durable `.pausedAuth` awaiting the user.
    /// On device this is otherwise a silently stalled row.
    case authPaused
  }

  public enum TransferEvent: Equatable, Sendable {
    case start(expectedBytes: Int64)
    case hold(origin: HoldOrigin)
    /// A Wi-Fi hold resumed through the adapter. There is no companion "resumed nothing" event: a
    /// hold with no live task in this process is restarted from zero by the ordinary scheduler,
    /// which traces `start`. So `release` followed by no `progress` line is how that case looks
    /// from the outside.
    case release
    case finish(Outcome)
    /// A failed automatic row was given an automatic retry this many seconds from now.
    case retryScheduled(afterSeconds: Int)
    /// That retry came due and requeued the row; `attempt` counts retries, not transfers.
    case retry(attempt: Int)
  }

  public struct Transfer: Equatable, Sendable {
    public let downloadId: Int64
    public let event: TransferEvent

    public init(downloadId: Int64, event: TransferEvent) {
      self.downloadId = downloadId
      self.event = event
    }
  }

  /// Throttled to one line per decile by `DownloadProgressTraceThrottle`.
  public struct Progress: Equatable, Sendable {
    public let downloadId: Int64
    public let receivedBytes: Int64
    /// `nil` when the adapter never learned a total; rendered `?` rather than guessed.
    public let percent: Int?

    public init(downloadId: Int64, receivedBytes: Int64, percent: Int?) {
      self.downloadId = downloadId
      self.receivedBytes = receivedBytes
      self.percent = percent
    }
  }

  public enum PurgeScope: String, Equatable, Sendable {
    case item
    case episode
    case ebook
    case audio
    case all
    case tombstoned
  }

  public struct Purge: Equatable, Sendable {
    public let scope: PurgeScope
    public let source: DownloadPurgeSource
    public let rows: Int

    public init(scope: PurgeScope, source: DownloadPurgeSource, rows: Int) {
      self.scope = scope
      self.source = source
      self.rows = rows
    }
  }

  /// How far a confirmed purge got before the coordinator could ever see it.
  ///
  /// Every other record comes from `DownloadCoordinator`, so without this one silence cannot
  /// distinguish "never called" from "called and threw" from "called and did nothing".
  public enum PurgeIntentOutcome: String, Equatable, Sendable {
    /// Handed to `DownloadIntents`. A `purge` line must follow it; if none does, the coordinator
    /// is the next place to look.
    case forwarded
    /// Confirmed with nothing staged: the confirmation was cleared (for example by its own
    /// alert's dismissal) before it could be acted on.
    case unstaged
    /// `DownloadIntents` threw. Always preceded by this same intent's `forwarded` line.
    case failed
  }

  public struct PurgeIntent: Equatable, Sendable {
    /// `nil` only for `.unstaged`, where there was no staged target left to describe.
    public let scope: PurgeScope?
    public let source: DownloadPurgeSource
    public let outcome: PurgeIntentOutcome

    public init(scope: PurgeScope?, source: DownloadPurgeSource, outcome: PurgeIntentOutcome) {
      self.scope = scope
      self.source = source
      self.outcome = outcome
    }
  }

  public enum Record: Equatable, Sendable {
    case reconcile(Reconcile)
    case schedule(Schedule)
    case transfer(Transfer)
    /// The same shape for a device-owned RSS enclosure, under its own tag: RSS row ids are a
    /// separate sequence from ABS row ids, so `id=7` alone would not say which table it names.
    case rssTransfer(Transfer)
    case progress(Progress)
    case purge(Purge)
    case purgeIntent(PurgeIntent)
    case cancel(downloadId: Int64)
  }

  public static func line(_ record: Record) -> String {
    switch record {
    case .reconcile(let summary):
      return
        "\(prefix) reconcile rows=\(summary.rows) live=\(summary.liveTasks) reattached=\(summary.reattached) requeued=\(summary.requeued) orphans=\(summary.orphansCancelled) held=\(summary.heldAdopted)"
    case .schedule(let gate):
      return
        "\(prefix) schedule active=\(gate.active) pending=\(gate.pending) slots=\(gate.slots) cellular=\(flag(gate.isConstrainedOrCellular)) allowCellular=\(flag(gate.allowsCellular)) lowDisk=\(flag(gate.isQueuePausedForLowDisk)) skipped=\(gate.skipped)"
    case .transfer(let transfer):
      return "\(prefix) transfer id=\(transfer.downloadId) event=\(rendered(transfer.event))"
    case .rssTransfer(let transfer):
      return "\(prefix) rssTransfer id=\(transfer.downloadId) event=\(rendered(transfer.event))"
    case .progress(let progress):
      let percent = progress.percent.map(String.init) ?? "?"
      return "\(prefix) progress id=\(progress.downloadId) pct=\(percent) bytes=\(progress.receivedBytes)"
    case .purge(let purge):
      return
        "\(prefix) purge scope=\(purge.scope.rawValue) source=\(purge.source.rawValue) rows=\(purge.rows)"
    case .purgeIntent(let intent):
      return
        "\(prefix) purgeIntent scope=\(intent.scope?.rawValue ?? "none") source=\(intent.source.rawValue) outcome=\(intent.outcome.rawValue)"
    case .cancel(let downloadId):
      return "\(prefix) cancel id=\(downloadId)"
    }
  }

  private static func rendered(_ event: TransferEvent) -> String {
    switch event {
    case .start(let expectedBytes): return "start bytes=\(expectedBytes)"
    case .hold(let origin): return "hold origin=\(origin.rawValue)"
    case .release: return "release"
    case .retryScheduled(let afterSeconds): return "retryScheduled after=\(afterSeconds)s"
    case .retry(let attempt): return "retry attempt=\(attempt)"
    case .finish(let outcome):
      switch outcome {
      case .stored: return "finish result=stored"
      case .lowDisk: return "finish result=lowDisk"
      case .rejected(let category, let validationReason):
        let reason = validationReason.map { " reason=\($0.rawValue)" } ?? ""
        return "finish result=rejected category=\(category.rawValue)\(reason)"
      case .rssRejected(let category, let rejection):
        return "finish result=rejected category=\(category.rawValue) reason=\(rejection.rawValue)"
      case .failed(let errorDomain, let errorCode):
        let details = [
          errorDomain.map { "domain=\($0)" },
          errorCode.map { "code=\($0)" },
        ].compactMap { $0 }.joined(separator: " ")
        return details.isEmpty
          ? "finish result=failed"
          : "finish result=failed \(details)"
      case .authPaused: return "finish result=authPaused"
      }
    }
  }

  private static func flag(_ value: Bool) -> String { value ? "1" : "0" }

  /// Public because `.purgeIntent` is emitted from `AppModel`, above the coordinator. DEBUG-only
  /// like every other call site.
  public static func emit(_ record: Record) {
    #if DEBUG
      DeviceTraceLog.emit(line(record))
    #endif
  }
}

/// Keeps the byte-level progress callback readable. `URLSession` reports progress far too often to
/// log a line each. One per decile shows a transfer moving, stalling and resuming, and keeps a
/// two-slot device day legible in a single `log stream`.
///
/// State is per download and dropped on any terminal event: a requeued row restarts from zero
/// (byte-level resume is not implemented; see `BackgroundTransferEvent.failed`), so a retained
/// high-water decile would silence its whole second attempt.
struct DownloadProgressTraceThrottle {
  /// The step size when the adapter never learned a total. 8 MiB keeps an unknown-total transfer
  /// to roughly the same line count as a decile-throttled one.
  static let unknownTotalChunkBytes: Int64 = 8 * 1_024 * 1_024

  enum Decision: Equatable {
    case skip
    case trace(percent: Int?)
  }

  private var lastStepByDownloadId: [Int64: Int64] = [:]

  mutating func decision(
    downloadId: Int64, receivedBytes: Int64, expectedBytes: Int64?
  ) -> Decision {
    let percent: Int?
    let step: Int64
    if let expectedBytes, expectedBytes > 0 {
      let clamped = min(100, max(0, Int((receivedBytes * 100) / expectedBytes)))
      percent = clamped
      step = Int64(clamped / 10)
    } else {
      percent = nil
      step = receivedBytes / Self.unknownTotalChunkBytes
    }

    if let previous = lastStepByDownloadId[downloadId], step <= previous { return .skip }
    lastStepByDownloadId[downloadId] = step
    return .trace(percent: percent)
  }

  mutating func forget(downloadId: Int64) {
    lastStepByDownloadId[downloadId] = nil
  }
}
