import CoreSupport
import Foundation
import MetricKit
import os

/// Opt-in gate for field memory metrics. They are diagnostic plumbing, not a product feature:
/// they stay off until someone switches them on, so an ordinary install never starts
/// collecting. The environment key suits a tethered device run where flipping a default is
/// inconvenient; the persisted key is for longer field validation.
enum MemoryMetricsOptIn {
  static let defaultsKey = "WhirrMemoryMetricsEnabled"
  static let environmentKey = "ABS_MEMORY_METRICS"

  static func isEnabled(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    if environment[environmentKey] == "1" { return true }
    return defaults.bool(forKey: defaultsKey)
  }
}

/// Process-lifetime home for the subscriber, mirroring `BackgroundDownloadHardware`/
/// `PlaybackHardware`. `MXMetricManager` does not keep its subscribers alive, so something has to;
/// this is that something, and nothing else in the app holds a reference.
@MainActor
enum MemoryMetricsHardware {
  private static let subscriber = MetricKitMemorySubscriber()
  private static var isStarted = false

  /// Idempotent, and a no-op unless collection was switched on. Called once at
  /// launch; the opt-in decision itself is `MemoryMetricsOptIn`'s and is tested there.
  static func startIfEnabled() {
    guard isStarted == false, MemoryMetricsOptIn.isEnabled() else { return }
    isStarted = true
    subscriber.start()
  }
}

/// Receives MetricKit's daily payloads and hands the memory figures to an injected sink.
///
/// Never transmits anything: the default sink logs to the unified log so device runs can read
/// peaks off a tethered or `log collect`-ed device. `nonisolated` because
/// `MXMetricManagerSubscriber` has no actor annotation and MetricKit delivers on its own queue, so
/// `@MainActor` would make `didReceive` assert an executor it may not be on.
nonisolated final class MetricKitMemorySubscriber: NSObject, MXMetricManagerSubscriber {
  private let sink: @Sendable (MemoryMetricSnapshot) -> Void

  init(sink: @escaping @Sendable (MemoryMetricSnapshot) -> Void = MetricKitMemorySubscriber.logSink) {
    self.sink = sink
  }

  /// Registers with MetricKit. Call only behind `MemoryMetricsOptIn.isEnabled`, since
  /// `MXMetricManager` begins accumulating for this subscriber the moment it is added.
  func start() {
    MXMetricManager.shared.add(self)
  }

  func stop() {
    MXMetricManager.shared.remove(self)
  }

  // MARK: - MXMetricManagerSubscriber

  /// A one-line adapter over the tested seam below. `MXMetricPayload` has no public initializer,
  /// so this method itself is not unit-testable; keeping it free of logic is what makes that
  /// acceptable rather than a coverage gap.
  func didReceive(_ payloads: [MXMetricPayload]) {
    receive(payloadJSON: payloads.map { $0.jsonRepresentation() })
  }

  /// The tested entry point (`MetricKitMemoryReportingTests`). Payloads that carry no memory
  /// metrics, or that fail to parse, are dropped silently: a diagnostic path must never be able
  /// to fail an app launch or a measurement run.
  func receive(payloadJSON payloads: [Data]) {
    for payload in payloads {
      guard let snapshot = MemoryMetricPayloadParser.snapshot(fromPayloadJSON: payload) else {
        continue
      }
      sink(snapshot)
    }
  }

  // MARK: - Default sink

  private static let log = CoreLogging.logger(category: "WHIRRMEM")

  /// Numbers and an app version only: no device identifier, no payload passthrough. Tagged
  /// `WHIRRMEM` to sit alongside the existing `WHIRRPERF`/`WHIRRENG` device streams.
  static let logSink: @Sendable (MemoryMetricSnapshot) -> Void = { snapshot in
    log.info(
      """
      WHIRRMEM peak=\(snapshot.peakMemoryBytes ?? -1, privacy: .public) \
      suspended=\(snapshot.averageSuspendedMemoryBytes ?? -1, privacy: .public) \
      version=\(snapshot.appVersion ?? "?", privacy: .public)
      """)
  }
}
