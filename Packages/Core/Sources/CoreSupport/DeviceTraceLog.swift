import Foundation

/// The single emission point for every DEBUG device trace (`WHIRRDL`, `WHIRRSYNC`, `WHIRRENG`,
/// `WHIRRPERF`, `WHIRRPOD`, `WHIRRRDR`, `WHIRRSRCH`, `WHIRRKBD`, `WHIRRFOCUS`), read off a physical
/// device with:
///
///     idevicesyslog -u <hardware-udid> --no-colors -p Whirr
///
/// Not `NSLog`: unified logging redacts dynamic arguments from a process springboard launched, and
/// `NSLog` hands `os_log` its finished string as one dynamic argument, so every line reads
/// `Whirr(Foundation)[pid] <Notice>: <private>`. A `%{public}@` inside an `NSLog` format does not
/// help; the annotation must be on the logging call, as `Logger`'s interpolation privacy is.
/// Launching from Xcode lifts the redaction only for that process, and a home-screen launch with
/// no debugger must still produce a readable trace.
///
/// `.public` is safe: these records carry local row ids, positions and byte counts, no URL, token
/// or credential material (SECURITY.md), and the call sites are `#if DEBUG`.
public enum DeviceTraceLog {
  private static let logger = CoreLogging.logger(category: "trace")

  public static func emit(_ message: String) {
    logger.notice("\(message, privacy: .public)")
  }
}
