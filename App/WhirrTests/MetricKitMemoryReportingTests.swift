import Foundation
import TestSupport
import Testing

@testable import Whirr

/// Field-validation half of the memory reporting. MetricKit payloads only arrive on a real device,
/// hours after the fact, so the production path is split in two: a pure parse over
/// `jsonRepresentation()`, and a one-line adapter that hands MetricKit's typed payloads to it. The
/// logic lives on the parse side, which is what these cover. `MXMetricPayload` cannot be built in a
/// test, and a test that only proved MetricKit calls its own delegate would assert nothing here.
@Suite("MetricKit memory reporting")
struct MetricKitMemoryReportingTests {

  // MARK: - Measurement strings

  @Test("Parses a kB measurement into bytes")
  func parsesKilobyteMeasurement() {
    #expect(MemoryMetricPayloadParser.bytes(fromMeasurement: "174600 kB") == 174_600_000)
  }

  @Test("Parses an MB measurement into bytes")
  func parsesMegabyteMeasurement() {
    #expect(MemoryMetricPayloadParser.bytes(fromMeasurement: "512 MB") == 512_000_000)
  }

  @Test("Parses a bare bytes measurement")
  func parsesByteMeasurement() {
    #expect(MemoryMetricPayloadParser.bytes(fromMeasurement: "2048 bytes") == 2048)
  }

  /// MetricKit reports decimal kB/MB, not KiB/MiB: 174600 kB is 174.6 MB, not 178.8. Getting this
  /// wrong silently inflates every recorded peak by about 5%, and moves any threshold set against
  /// it.
  @Test("Uses decimal SI units, matching MetricKit's own reporting")
  func usesDecimalUnits() {
    #expect(MemoryMetricPayloadParser.bytes(fromMeasurement: "1 kB") == 1000)
    #expect(MemoryMetricPayloadParser.bytes(fromMeasurement: "1 MB") == 1_000_000)
  }

  @Test("Returns nil for a measurement it cannot parse")
  func rejectsMalformedMeasurement() {
    #expect(MemoryMetricPayloadParser.bytes(fromMeasurement: "") == nil)
    #expect(MemoryMetricPayloadParser.bytes(fromMeasurement: "lots") == nil)
    #expect(MemoryMetricPayloadParser.bytes(fromMeasurement: "12 furlongs") == nil)
    #expect(MemoryMetricPayloadParser.bytes(fromMeasurement: "kB") == nil)
  }

  // MARK: - Payload parsing

  @Test("Extracts peak and average suspended memory from a payload")
  func parsesMemoryMetricsFromPayload() throws {
    let snapshot = try #require(MemoryMetricPayloadParser.snapshot(fromPayloadJSON: Self.samplePayload))

    #expect(snapshot.peakMemoryBytes == 174_600_000)
    #expect(snapshot.averageSuspendedMemoryBytes == 83_880_000)
    #expect(snapshot.appVersion == "1.0")
  }

  @Test("Extracts the reporting period")
  func parsesReportingPeriod() throws {
    let snapshot = try #require(MemoryMetricPayloadParser.snapshot(fromPayloadJSON: Self.samplePayload))
    let start = try #require(snapshot.periodStart)
    let end = try #require(snapshot.periodEnd)

    #expect(end.timeIntervalSince(start) == 86_400)
  }

  @Test("A payload carrying no memory metrics yields no snapshot")
  func payloadWithoutMemoryMetricsIsIgnored() {
    let json = Data(#"{"appVersion":"1.0","timeStampBegin":"2026-07-27 00:00:00 +0000"}"#.utf8)
    #expect(MemoryMetricPayloadParser.snapshot(fromPayloadJSON: json) == nil)
  }

  @Test("Malformed JSON yields no snapshot rather than throwing")
  func malformedPayloadIsIgnored() {
    #expect(MemoryMetricPayloadParser.snapshot(fromPayloadJSON: Data([0x00, 0x01])) == nil)
  }

  // MARK: - Forwarding

  @Test("Each parseable payload is forwarded to the sink exactly once")
  func forwardsOneSnapshotPerPayload() async {
    let recorder = SnapshotRecorder()
    let subscriber = MetricKitMemorySubscriber { snapshot in recorder.append(snapshot) }

    subscriber.receive(payloadJSON: [Self.samplePayload, Self.samplePayload])

    #expect(recorder.snapshots.count == 2)
    #expect(recorder.snapshots.first?.peakMemoryBytes == 174_600_000)
  }

  @Test("Unparseable payloads are dropped without reaching the sink")
  func doesNotForwardUnparseablePayloads() async {
    let recorder = SnapshotRecorder()
    let subscriber = MetricKitMemorySubscriber { snapshot in recorder.append(snapshot) }

    subscriber.receive(payloadJSON: [Data([0x00]), Self.samplePayload])

    #expect(recorder.snapshots.count == 1)
  }

  // MARK: - Opt-in

  /// Opt-in only, and never uploads by itself. A default-on subscriber would collect field data
  /// from every user unasked.
  @Test("Collection is off unless deliberately switched on")
  func collectionIsOptIn() {
    let defaults = Self.emptyDefaults()
    #expect(MemoryMetricsOptIn.isEnabled(defaults: defaults, environment: [:]) == false)
  }

  @Test("The defaults key switches collection on")
  func defaultsKeyEnablesCollection() {
    let defaults = Self.emptyDefaults()
    defaults.set(true, forKey: MemoryMetricsOptIn.defaultsKey)

    #expect(MemoryMetricsOptIn.isEnabled(defaults: defaults, environment: [:]))
  }

  @Test("The environment override switches collection on for a tethered run")
  func environmentOverrideEnablesCollection() {
    let environment = [MemoryMetricsOptIn.environmentKey: "1"]
    #expect(MemoryMetricsOptIn.isEnabled(defaults: Self.emptyDefaults(), environment: environment))
  }

  // MARK: - Fixtures

  /// Shaped after `MXMetricPayload.jsonRepresentation()`: `MXMeasurement` serializes as a
  /// unit-suffixed string and `MXAverage` as an object carrying one.
  private static let samplePayload = Data(
    """
    {
      "appVersion": "1.0",
      "timeStampBegin": "2026-07-27 00:00:00 +0000",
      "timeStampEnd": "2026-07-28 00:00:00 +0000",
      "memoryMetrics": {
        "peakMemoryUsage": "174600 kB",
        "averageSuspendedMemory": {
          "averageValue": "83880 kB",
          "standardDeviation": 0,
          "sampleCount": 862
        }
      }
    }
    """.utf8)

  private static func emptyDefaults() -> UserDefaults {
    let suiteName = "MetricKitMemoryReportingTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}

private nonisolated final class SnapshotRecorder: @unchecked Sendable {
  private let storage = Locked<[MemoryMetricSnapshot]>([])

  var snapshots: [MemoryMetricSnapshot] {
    storage.value
  }

  func append(_ snapshot: MemoryMetricSnapshot) {
    storage.withValue { $0.append(snapshot) }
  }
}
