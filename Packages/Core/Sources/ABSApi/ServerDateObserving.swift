import Foundation

/// Clock-skew observation source: every authenticated response's HTTP `Date` header, with local
/// receipt time and the token account. Hooked into `AuthenticatedHTTPClient.send(_:)` only, so
/// never pre-auth traffic (`/login` and `/logout` precede any account) nor the internal
/// `/auth/refresh` request (no Bearer of its own).
///
/// ABSApi never imports Persistence (ARCHITECTURE.md §1), so the SyncEngine-owned conformance maps
/// `account` to a local account row and persists the estimated server-clock offset.
public protocol ServerDateObserving: Sendable {
  func observeServerDate(_ serverDate: Date, receivedAt: Date, account: TokenAccount) async
}

/// No-op default (as `NoOpDiagnosticsRecording` is in SyncEngine), so compositions and tests that
/// don't care about clock skew need no optional threaded through every call site.
public struct NoOpServerDateObserving: ServerDateObserving {
  public init() {}
  public func observeServerDate(_ serverDate: Date, receivedAt: Date, account: TokenAccount) async {}
}

/// RFC 7231 §7.1.1.1 IMF-fixdate parsing for the `Date` response header (e.g. "Tue, 15 Nov 1994
/// 08:12:31 GMT"), the only format Node/Express servers (ABS's runtime) emit via
/// `Date.prototype.toUTCString()`. The obsolete RFC 850/asctime forms are not parsed, as no ABS
/// response has been seen to use them (API-CONVENTIONS.md rule 22). An unrecognised format emits
/// no observation rather than throwing or risking a wrong parse.
enum HTTPDateParsing {
  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
  }()

  static func parse(_ value: String) -> Date? {
    formatter.date(from: value)
  }
}

extension HTTPResponse {
  /// Case-insensitive header lookup. `URLSessionHTTPClient` preserves whatever casing
  /// `HTTPURLResponse.allHeaderFields` reports and test fakes may use any casing, so a plain
  /// dictionary subscript is unreliable.
  func headerValue(caseInsensitive name: String) -> String? {
    for (field, value) in headers where field.caseInsensitiveCompare(name) == .orderedSame {
      return value
    }
    return nil
  }
}
