import Foundation

/// The memory figures from a MetricKit payload and the window they cover. A flat value type
/// rather than a retained `MXMetricPayload`, which carries device, disk, network and location
/// metrics this app has no business holding on to.
nonisolated struct MemoryMetricSnapshot: Sendable, Equatable {
  let appVersion: String?
  let periodStart: Date?
  let periodEnd: Date?
  /// `MXMemoryMetric.peakMemoryUsage`.
  let peakMemoryBytes: Int64?
  let averageSuspendedMemoryBytes: Int64?
}

/// Parses `MXMetricPayload.jsonRepresentation()`, the only form a test can construct (the payload
/// and its measurement types have no public initializers). `nonisolated` despite the target's
/// `@MainActor` default: MetricKit delivers on its own queue, and these helpers are passed as
/// function values to `Optional.flatMap`, a nonisolated call either way.
nonisolated enum MemoryMetricPayloadParser {

  static func snapshot(fromPayloadJSON data: Data) -> MemoryMetricSnapshot? {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let memory = root["memoryMetrics"] as? [String: Any]
    else {
      return nil
    }

    let peak = (memory["peakMemoryUsage"] as? String).flatMap(bytes(fromMeasurement:))
    let suspended = memory["averageSuspendedMemory"] as? [String: Any]
    let average = (suspended?["averageValue"] as? String).flatMap(bytes(fromMeasurement:))

    return MemoryMetricSnapshot(
      appVersion: root["appVersion"] as? String,
      periodStart: (root["timeStampBegin"] as? String).flatMap(date(fromTimestamp:)),
      periodEnd: (root["timeStampEnd"] as? String).flatMap(date(fromTimestamp:)),
      peakMemoryBytes: peak,
      averageSuspendedMemoryBytes: average)
  }

  /// `MXMeasurement` serialises as a unit-suffixed string, e.g. `"174600 kB"`. The units are
  /// decimal SI (`UnitInformationStorage`'s kilobytes are 1000 bytes, not 1024). Reading them as
  /// binary would inflate every recorded figure by ~5% and quietly shift any threshold set on it.
  static func bytes(fromMeasurement measurement: String) -> Int64? {
    let parts = measurement.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count == 2, let value = Double(parts[0]) else { return nil }

    let multiplier: Double
    switch parts[1] {
    case "bytes", "B": multiplier = 1
    case "kB": multiplier = 1_000
    case "MB": multiplier = 1_000_000
    case "GB": multiplier = 1_000_000_000
    default: return nil
    }

    return Int64((value * multiplier).rounded())
  }

  /// Built per call rather than cached in a static: `DateFormatter` is not `Sendable`, and caching
  /// one on a nonisolated type would need a concurrency escape hatch for no gain. This parses
  /// two timestamps per daily MetricKit payload.
  private static func date(fromTimestamp timestamp: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return formatter.date(from: timestamp)
  }
}
