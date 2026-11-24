import CoreSupport
import Foundation

/// The reader's DEBUG-only device trace, read like the `WHIRRENG`/`WHIRRPERF`/`WHIRRPOD`/`WHIRRMEM`
/// streams:
///
///     log stream --predicate 'eventMessage CONTAINS "WHIRRRDR"'
///
/// Two facts are unobservable from outside: which download state the projection emitted (a
/// spinner looks the same behind any), and what Readium said when the parse failed
/// (`classifyOpenFailure` collapses every unrecognised error onto `.unopenable`).
///
/// Lives in ReaderCore because AppModel and the App's Readium adapter both emit into the stream,
/// so one owner must fix the record shape.
public enum ReaderTrace {
  public static let prefix = "WHIRRRDR"

  /// The longest a single field value may be. Readium's errors nest several layers of underlying
  /// error and run to hundreds of characters; an untruncated one would push the fields identifying
  /// the book past the end of the record.
  static let valueLimit = 180

  /// One record. Fields keep the order given. Callers put the identifying ones first so a
  /// truncated tail never costs the item id.
  public static func line(_ event: String, _ fields: KeyValuePairs<String, String>) -> String {
    let rendered = fields.map { "\($0.key)=\(sanitize($0.value))" }
    return ([prefix, event] + rendered).joined(separator: " ")
  }

  public static func emit(_ event: String, _ fields: KeyValuePairs<String, String>) {
    #if DEBUG
      DeviceTraceLog.emit(line(event, fields))
    #endif
  }

  /// A file's name without the container path. The path leaks nothing secret, but it is per-install
  /// noise that crowds out the fields being read.
  public static func fileValue(_ url: URL) -> String {
    sanitize(url.lastPathComponent)
  }

  /// Whitespace becomes `_` so one record stays one line, then the value is bounded. Both matter to
  /// `log stream`, which is line-oriented.
  private static func sanitize(_ value: String) -> String {
    let flattened = value.map { $0.isWhitespace ? "_" : $0 }
    guard flattened.count > valueLimit else { return String(flattened) }
    return String(flattened.prefix(valueLimit)) + "…"
  }
}
