import CoreSupport
import Foundation
import SyncEngine

/// Search's DEBUG-only device trace, read like the `WHIRRENG`/`WHIRRRDR`/`WHIRRPERF`/`WHIRRPOD`/
/// `WHIRRMEM` streams:
///
///     log stream --predicate 'eventMessage CONTAINS "WHIRRSRCH"'
///
/// Records which library failed and why (from `SearchFanOutResult.failures`), which a "results may
/// be incomplete" annotation cannot show. Emits only on failure: logging every clean fan-out per
/// keystroke would bury the records worth reading.
public enum SearchTrace {
  public static let prefix = "WHIRRSRCH"

  /// Long enough for a `String(describing:)` of a nested transport error to stay diagnostic, short
  /// enough that the identifying fields ahead of it survive. Mirrors `ReaderTrace.valueLimit`.
  static let valueLimit = 180

  /// Fields keep the order given, identifying ones first, so a truncated tail never costs the
  /// library id.
  public static func line(_ event: String, _ fields: KeyValuePairs<String, String>) -> String {
    let rendered = fields.map { "\($0.key)=\(sanitize($0.value))" }
    return ([prefix, event] + rendered).joined(separator: " ")
  }

  static func emit(_ event: String, _ fields: KeyValuePairs<String, String>) {
    #if DEBUG
      DeviceTraceLog.emit(line(event, fields))
    #endif
  }

  /// One record per failed library. Silent when every library answered.
  static func emitFanOutResult(query: String, failures: [SearchLibraryFailure]) {
    guard failures.isEmpty == false else { return }
    for failure in failures {
      emit(
        "fanOutLibraryFailed",
        [
          "library": failure.libraryId, "failed": String(failures.count),
          "query": queryValue(query), "error": failure.message,
        ])
    }
  }

  /// The fan-out never reached any library.
  static func emitFanOutFailure(query: String, error: Error) {
    emit("fanOutFailed", ["query": queryValue(query), "error": String(describing: error)])
  }

  /// The query's shape, never the query itself: what is searched for is the reader's business.
  /// Nothing here can carry a credential either, since tokens live in headers (SECURITY.md).
  private static func queryValue(_ query: String) -> String {
    "\(query.count)chars"
  }

  private static func sanitize(_ value: String) -> String {
    let collapsed = value.replacingOccurrences(of: "\n", with: " ")
    guard collapsed.count > valueLimit else { return collapsed }
    return String(collapsed.prefix(valueLimit)) + "…"
  }
}
