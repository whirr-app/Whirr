import CoreSupport
import Foundation

/// The sync cadence's DEBUG-only device trace, read like the other `WHIRR*` streams:
///
///     log stream --predicate 'eventMessage CONTAINS "WHIRRSYNC"'
///
/// Gives a device day real drain timestamps to check intervals against (at least ten consecutive
/// intervals per mode, each within 2 s of nominal). Shares the `WHIRRSYNC` prefix with
/// `PlaybackSessionCoordinator`'s sessionless-tick line.
///
/// Only the periodic deadline is traced: immediate drains (pause, seek, backgrounding, close;
/// API-CONVENTIONS rule 7) would add short intervals that read as violations of a rule they are
/// not subject to.
public enum DrainCadenceTrace {
  public static let prefix = "WHIRRSYNC"

  /// Which cadence the interval was scheduled under. `normal` is 15 s; every degraded variant is
  /// 60 s (API-CONVENTIONS rule 7). They stay distinct so the reader can see why an interval
  /// went long.
  public enum Condition: String, Sendable {
    case normal
    case lowPower
    case cellular
    case lowPowerAndCellular

    public init(isLowPowerMode: Bool, isConstrainedOrCellular: Bool) {
      switch (isLowPowerMode, isConstrainedOrCellular) {
      case (false, false): self = .normal
      case (true, false): self = .lowPower
      case (false, true): self = .cellular
      case (true, true): self = .lowPowerAndCellular
      }
    }
  }

  /// One periodic drain. Has no field that could hold a URL, token, item id or session id, a
  /// stronger guarantee than a sanitiser that has to be remembered (SECURITY.md §7).
  public struct Record: Equatable, Sendable {
    public let sincePreviousDrain: TimeInterval?
    public let nominal: TimeInterval
    public let condition: Condition

    public init(sincePreviousDrain: TimeInterval?, nominal: TimeInterval, condition: Condition) {
      self.sincePreviousDrain = sincePreviousDrain
      self.nominal = nominal
      self.condition = condition
    }
  }

  /// The observation and the target, side by side, with no verdict. Whether an interval is within
  /// 2 s is the reader's arithmetic; an app that graded itself would assert what the device day
  /// exists to check.
  public static func line(_ record: Record) -> String {
    let since = record.sincePreviousDrain.map { String(format: "%.1f", $0) } ?? "first"
    return
      "\(prefix) drain since=\(since) nominal=\(String(format: "%.1f", record.nominal)) condition=\(record.condition.rawValue)"
  }

  static func emit(_ record: Record) {
    #if DEBUG
      DeviceTraceLog.emit(line(record))
    #endif
  }
}

/// Bookkeeping for the interval between consecutive periodic drains.
///
/// `nominal` is captured at schedule time, not fire time: a condition change cancels the pending
/// deadline and schedules a fresh one, so reading the current condition would report a 60 s
/// interval against a 15 s target on every transition.
struct DrainCadenceRecorder {
  private var previousDrainAt: Date?
  private var scheduledNominal: TimeInterval?

  mutating func scheduled(nominal: TimeInterval) {
    scheduledNominal = nominal
  }

  /// Breaks the series, so the next drain reports no interval rather than the wall gap since the
  /// last one. Periodic drains are suppressed while playback is not `.playing`, so a pause, item
  /// switch or lost observation would otherwise show as one interval far over nominal. Idempotent:
  /// the discarded interval is the first one after the interruption, however many preceded it.
  mutating func interrupted() {
    previousDrainAt = nil
  }

  mutating func fired(now: Date, condition: DrainCadenceTrace.Condition) -> DrainCadenceTrace.Record {
    let record = DrainCadenceTrace.Record(
      sincePreviousDrain: previousDrainAt.map { now.timeIntervalSince($0) },
      nominal: scheduledNominal ?? 0,
      condition: condition)
    previousDrainAt = now
    return record
  }
}
