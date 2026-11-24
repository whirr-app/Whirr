import CoreSupport

#if DEBUG || PERF_INVESTIGATION
  import Foundation
  import QuartzCore
  import UIKit
  import os

  /// Debug-only scroll instrumentation for the simulator.
  ///
  /// The Simulator runtime lacks the hitch and FPS instruments and throttles display cadence, so
  /// frame gaps can't separate an app stall from host scheduling. This measures main-thread run
  /// loop turn duration (`kCFRunLoopAfterWaiting` to the next `kCFRunLoopBeforeWaiting`, ordered
  /// after Core Animation's commit observer): the app's own work for a pass, causal on any
  /// cadence. Frame gaps are corroboration only.
  @MainActor
  final class HarnessScrollProbe {
    static let shared = HarnessScrollProbe()

    struct Sample {
      var timestamp: CFTimeInterval
      var duration: CFTimeInterval
    }

    private let logger = CoreLogging.logger(category: "ScrollProbe")
    private let signposter = OSSignposter(
      subsystem: "com.remoteconcern.whirr", category: .pointsOfInterest)

    private var afterWaitingObserver: CFRunLoopObserver?
    private var beforeWaitingObserver: CFRunLoopObserver?
    private var displayLink: CADisplayLink?

    private var turnStart: CFTimeInterval?
    private var previousFrameTimestamp: CFTimeInterval?
    private var startedAt: CFTimeInterval = 0

    private var turnCounts = [Int](repeating: 0, count: HarnessProbeEvent.allCases.count)
    private var windowCounts = [Int](repeating: 0, count: HarnessProbeEvent.allCases.count)
    private var isRunning = false

    private var windowLabel: String?
    private var windowStart: CFTimeInterval = 0
    private var windowTurns: [Sample] = []
    private var windowFrameGaps: [CFTimeInterval] = []
    private var idleTurns: [Sample] = []
    private var idleFrameGaps: [CFTimeInterval] = []

    /// Reported per window so a run's rows can be pooled offline without re-deriving them.
    private(set) var windowSummaries: [String] = []

    private var stallThreshold: CFTimeInterval {
      (ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_STALL_MS"].flatMap(Double.init)
        ?? 16.67) / 1_000
    }

    /// Attributes one app-owned event to the run loop turn it happened in. Kept to two array
    /// writes so instrumenting a per-card callback cannot itself become the cost being measured.
    @inline(__always)
    func note(_ event: HarnessProbeEvent, _ count: Int = 1) {
      guard isRunning else { return }
      turnCounts[event.rawValue] += count
      windowCounts[event.rawValue] += count
    }

    func start() {
      guard afterWaitingObserver == nil else { return }
      isRunning = true
      startedAt = CACurrentMediaTime()

      // Ordered first in `afterWaiting` and last in `beforeWaiting` so the measured interval
      // encloses every source, timer, and the Core Animation commit that runs in the same turn.
      let after = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
      ) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.turnDidBegin() }
      }
      let before = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
      ) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.turnDidEnd() }
      }
      CFRunLoopAddObserver(CFRunLoopGetMain(), after, .commonModes)
      CFRunLoopAddObserver(CFRunLoopGetMain(), before, .commonModes)
      afterWaitingObserver = after
      beforeWaitingObserver = before

      let link = CADisplayLink(target: self, selector: #selector(frameDidFire(_:)))
      link.add(to: .main, forMode: .common)
      displayLink = link

      logger.notice(
        "WHIRR_PROBE_START stall_threshold_ms=\(self.stallThreshold * 1_000, privacy: .public)")
    }

    func stop() {
      if let afterWaitingObserver {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), afterWaitingObserver, .commonModes)
      }
      if let beforeWaitingObserver {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), beforeWaitingObserver, .commonModes)
      }
      afterWaitingObserver = nil
      beforeWaitingObserver = nil
      isRunning = false
      displayLink?.invalidate()
      displayLink = nil
      report(label: "idle", turns: idleTurns, frameGaps: idleFrameGaps, wall: nil)
      logger.notice("WHIRR_PROBE_STOP")
    }

    /// Opens a named measurement window. Turns recorded outside any window are pooled as `idle`
    /// and reported once at `stop`, which is what calibrates the stall threshold against the
    /// host's own cadence rather than against a fixed 60 Hz assumption.
    func beginWindow(_ label: String) {
      endWindow()
      windowLabel = label
      windowStart = CACurrentMediaTime()
      windowTurns.removeAll(keepingCapacity: true)
      windowFrameGaps.removeAll(keepingCapacity: true)
      for index in windowCounts.indices {
        windowCounts[index] = 0
      }
    }

    func endWindow() {
      guard let windowLabel else { return }
      report(
        label: windowLabel, turns: windowTurns, frameGaps: windowFrameGaps,
        wall: CACurrentMediaTime() - windowStart)
      self.windowLabel = nil
      windowTurns.removeAll(keepingCapacity: true)
      windowFrameGaps.removeAll(keepingCapacity: true)
      for index in windowCounts.indices {
        windowCounts[index] = 0
      }
    }

    private func turnDidBegin() {
      turnStart = CACurrentMediaTime()
      for index in turnCounts.indices {
        turnCounts[index] = 0
      }
    }

    private func turnDidEnd() {
      guard let turnStart else { return }
      self.turnStart = nil
      let now = CACurrentMediaTime()
      let sample = Sample(timestamp: turnStart, duration: now - turnStart)
      if windowLabel != nil {
        windowTurns.append(sample)
      } else {
        idleTurns.append(sample)
      }
      guard sample.duration > stallThreshold else { return }
      if signposter.isEnabled {
        signposter.emitEvent(
          "MainThreadStall",
          "\(sample.duration * 1_000, format: .fixed(precision: 2)) ms")
      }
      logger.notice(
        """
        WHIRR_PROBE_STALL window=\(self.windowLabel ?? "idle", privacy: .public) \
        t=\(turnStart - self.startedAt, format: .fixed(precision: 4), privacy: .public) \
        dur_ms=\(sample.duration * 1_000, format: .fixed(precision: 3), privacy: .public) \
        \(Self.breakdown(self.turnCounts), privacy: .public)
        """)
    }

    @objc private func frameDidFire(_ link: CADisplayLink) {
      defer { previousFrameTimestamp = link.timestamp }
      guard let previousFrameTimestamp else { return }
      let gap = link.timestamp - previousFrameTimestamp
      if windowLabel != nil {
        windowFrameGaps.append(gap)
      } else {
        idleFrameGaps.append(gap)
      }
    }

    private func report(
      label: String, turns: [Sample], frameGaps: [CFTimeInterval], wall: CFTimeInterval?
    ) {
      let durations = turns.map(\.duration).sorted()
      let gaps = frameGaps.sorted()
      let busy = durations.reduce(0, +)
      let line = """
        WHIRR_PROBE_WINDOW label=\(label) \
        wall_s=\(Self.format(wall ?? 0)) turns=\(turns.count) busy_ms=\(Self.format(busy * 1_000)) \
        turn_p50_ms=\(Self.format(Self.percentile(durations, 0.5) * 1_000)) \
        turn_p95_ms=\(Self.format(Self.percentile(durations, 0.95) * 1_000)) \
        turn_p99_ms=\(Self.format(Self.percentile(durations, 0.99) * 1_000)) \
        turn_max_ms=\(Self.format((durations.last ?? 0) * 1_000)) \
        over8=\(durations.count { $0 > 0.008 }) over16=\(durations.count { $0 > 0.01667 }) \
        over33=\(durations.count { $0 > 0.03333 }) over50=\(durations.count { $0 > 0.05 }) \
        frames=\(gaps.count) gap_p50_ms=\(Self.format(Self.percentile(gaps, 0.5) * 1_000)) \
        gap_p95_ms=\(Self.format(Self.percentile(gaps, 0.95) * 1_000)) \
        gap_max_ms=\(Self.format((gaps.last ?? 0) * 1_000)) \
        \(Self.breakdown(windowCounts))
        """
      windowSummaries.append(line)
      logger.notice("\(line, privacy: .public)")
    }

    /// `label=count` for each event that fired.
    private static func breakdown(_ counts: [Int]) -> String {
      HarnessProbeEvent.allCases
        .filter { counts[$0.rawValue] > 0 }
        .map { "\($0.label)=\(counts[$0.rawValue])" }
        .joined(separator: " ")
    }

    private static func percentile(_ sorted: [CFTimeInterval], _ fraction: Double) -> CFTimeInterval {
      guard sorted.isEmpty == false else { return 0 }
      return sorted[Int((Double(sorted.count - 1) * fraction).rounded(.down))]
    }

    private static func format(_ value: Double) -> String {
      String(format: "%.3f", value)
    }
  }
#endif
