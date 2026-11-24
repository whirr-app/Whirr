import Foundation

/// The Library-refresh performance bracket (`WHIRRPERF library`), read on a device alongside the
/// other `WHIRR*` records with:
///
///     idevicesyslog -u <hardware-udid> --no-colors -p Whirr
///
/// Makes two claims checkable on hardware (neither is visible in the UI or the simulator):
///
/// 1. One transaction per returned metadata batch. `commit=metadata` counts what reached SQLite,
///    so a 200-item pass ends in a handful of lines rather than hundreds.
/// 2. No rendered projection replaced while the list is moving. `projection=deferred` is a
///    snapshot the model held; `projection=published` is one it handed to SwiftUI. Several
///    deferred lines then one published line at the end of a fling is healthy; a published line
///    between two deferred ones is a regression.
///
/// Lives in `CoreSupport` because `SyncEngine` and `AppModel` each own half of the bracket.
/// Counts only: no item id, server id, title, URL, token or timestamp (SECURITY.md), and every
/// call site is `#if DEBUG`.
public enum LibraryRefreshPerfTrace {
  public static let prefix = "WHIRRPERF library"

  /// Whether a source projection reached SwiftUI or was held for the scroll gate.
  public enum ProjectionOutcome: String, Equatable, Sendable {
    case published
    case deferred
  }

  public enum Record: Equatable, Sendable {
    /// One committed expanded-metadata batch: `index` counts batches within the running pass,
    /// `items` is how many item rows that one transaction carried.
    case metadataCommit(index: Int, items: Int)
    /// One decision about a source projection, with the row count it carried.
    case projection(ProjectionOutcome, items: Int)
  }

  public static func line(_ record: Record) -> String {
    switch record {
    case .metadataCommit(let index, let items):
      return "\(prefix) commit=metadata batch=\(index) items=\(items)"
    case .projection(let outcome, let items):
      return "\(prefix) projection=\(outcome.rawValue) items=\(items)"
    }
  }

  public static func emit(_ record: Record) {
    #if DEBUG
      DeviceTraceLog.emit(line(record))
    #endif
  }
}
