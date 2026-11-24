#if PERF_INVESTIGATION
  import Foundation
  import ObjectiveC
  import QuartzCore
  import UIKit
  import os

  /// Opt-in local measurement. No UI, network, persistent preferences, or shipping-build cost.
  /// The external XCTest runner marks windows through simulator Darwin notifications.
  @MainActor
  final class MicrostutterProbe {
    static let shared = MicrostutterProbe()
    private let signposter = OSSignposter(
      subsystem: "com.remoteconcern.whirr", category: .pointsOfInterest)
    private var interval: OSSignpostIntervalState?
    private var observers: [CFRunLoopObserver] = []
    private var link: CADisplayLink?
    private var turnStart: CFTimeInterval?
    private var previousFrame: CFTimeInterval?
    private var expectedFrame: CFTimeInterval = 0
    private var label: String?
    private var start: CFTimeInterval = 0
    private var turns: [Double] = []
    private var turnOffsets: [Double] = []
    private var gaps: [Double] = []
    private var gapOffsets: [Double] = []
    private var budgets: [Double] = []
    private var counts: [String: Int] = [:]
    private var timings: [String: Double] = [:]
    private var activationCounts: [String: Int] = [:]
    private var activationTimings: [String: Double] = [:]
    private var activationIntervals: [[String: Any]] = []
    private let recordsEventTimeline = ProcessInfo.processInfo.arguments.contains("-perf-event-timeline")
    private var events: [(name: String, offset: Double, count: Int, elapsed: Double?)] = []
    /// A browse sweep of a real library notes roughly fourteen counters across 436 tiles, so a
    /// 4,096 ceiling truncates the timeline two thirds of the way through the window and drops
    /// the late scrollback the long turns sit in. The timeline is opt-in behind
    /// `-perf-event-timeline`, so the larger reservation costs a non-timeline run nothing.
    private let eventCapacity = 65_536
    private var droppedEvents = 0
    private var records: [[String: Any]] = []
    private var touchIntervals: [(start: Double, end: Double)] = []
    private var activeTouchStart: Double?

    /// Timestamp input delivered to the app, separating XCTest target-query cost from touch work.
    /// Primitive storage only; this never publishes observable state or changes the event.
    func receivedTouchEvent(_ event: UIEvent) {
      guard label != nil, event.type == .touches, let touches = event.allTouches else { return }
      let now = CACurrentMediaTime()
      if touches.contains(where: { $0.phase == .began }), activeTouchStart == nil {
        activeTouchStart = now
      }
      if touches.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }),
        let activeTouchStart
      {
        touchIntervals.append((activeTouchStart, now))
        self.activeTouchStart = nil
      }
    }

    func note(_ name: String, count: Int = 1, elapsed: Double? = nil) {
      guard label != nil else { return }
      counts[name, default: 0] += count
      if recordsEventTimeline {
        if events.count < eventCapacity {
          events.append((name, CACurrentMediaTime() - start, count, elapsed))
        } else {
          droppedEvents += 1
        }
      }
      if let elapsed { timings[name, default: 0] += elapsed * 1_000 }
    }

    /// Records synchronous scene-activation work separately from body, accessibility, and touch
    /// counters. The values are still window-scoped proxies; an absent entry means the Darwin begin
    /// marker was not delivered before the callback, not that activation work did not run.
    func noteActivation(
      _ name: String,
      count: Int = 1,
      elapsed: Double? = nil,
      startedAt: CFTimeInterval? = nil
    ) {
      guard label != nil else { return }
      activationCounts[name, default: 0] += count
      if let elapsed { activationTimings[name, default: 0] += elapsed * 1_000 }
      if let startedAt {
        activationIntervals.append([
          "name": name,
          "start_offset_s": startedAt - start,
          "end_offset_s": CACurrentMediaTime() - start,
        ])
      }
    }

    func startIfRequested() {
      guard ProcessInfo.processInfo.arguments.contains("-whirr-perf-probe"), link == nil else {
        return
      }
      try? FileManager.default.removeItem(
        at: URL.cachesDirectory.appending(path: "microstutter-results.json"))
      if let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
        let instrumented = class_getInstanceMethod(
          UIApplication.self, #selector(UIApplication.microstutterSendEvent(_:)))
      {
        method_exchangeImplementations(original, instrumented)
      }
      if recordsEventTimeline { events.reserveCapacity(eventCapacity) }
      turns.reserveCapacity(16_384)
      turnOffsets.reserveCapacity(16_384)
      gaps.reserveCapacity(4_096)
      gapOffsets.reserveCapacity(4_096)
      budgets.reserveCapacity(4_096)
      let after = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
      ) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.turnStart = CACurrentMediaTime() }
      }!
      let before = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
      ) { [weak self] _, _ in
        MainActor.assumeIsolated {
          guard let self, let turnStart = self.turnStart else { return }
          if self.label != nil {
            let duration = CACurrentMediaTime() - turnStart
            self.turns.append(duration)
            self.turnOffsets.append(turnStart - self.start)
            // The stalling turns in the Library sweep run no instrumented app code, so only a
            // sampling profile can name them, and Instruments' clock cannot be aligned to a probe
            // offset after the fact. Emitting the turn as a point of interest puts its end in the
            // trace's own timebase; the turn occupies [end - duration, end]. Only long turns are
            // emitted, so an ordinary turn pays nothing.
            if self.expectedFrame > 0, duration > self.expectedFrame * 1.5 {
              self.signposter.emitEvent(
                "LongTurn",
                "ms=\(duration * 1_000, privacy: .public) offset=\(turnStart - self.start, privacy: .public)"
              )
            }
          }
          self.turnStart = nil
        }
      }!
      observers = [after, before]
      for observer in observers { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
      let displayLink = CADisplayLink(target: self, selector: #selector(frame(_:)))
      displayLink.add(to: .main, forMode: .common)
      link = displayLink
      let center = CFNotificationCenterGetDarwinNotifyCenter()
      for suffix in [
        "begin.H1", "begin.H1T", "begin.H2", "begin.L1", "begin.LA1", "begin.SA1", "begin.P1", "begin.P2",
        "begin.P1T", "begin.P2T", "begin.S1",
        "begin.S2", "begin.S1T", "begin.S2T", "begin.G1", "begin.C1", "begin.PC1", "begin.PC2",
        "begin.PC3", "begin.H3", "begin.LB1",
        "begin.G2",
        "begin.AX1",
        "begin.idle", "end",
      ] {
        CFNotificationCenterAddObserver(
          center, nil,
          { _, _, name, _, _ in
            guard let name else { return }
            let suffix = (name.rawValue as String).replacingOccurrences(
              of: "com.remoteconcern.whirr.perf.", with: "")
            Task { @MainActor in
              if suffix == "end" {
                MicrostutterProbe.shared.end()
              } else {
                MicrostutterProbe.shared.begin(String(suffix.dropFirst(6)))
              }
            }
          }, ("com.remoteconcern.whirr.perf." + suffix) as CFString, nil, .deliverImmediately)
      }
    }

    @objc private func frame(_ sender: CADisplayLink) {
      let budget = sender.targetTimestamp - sender.timestamp
      if budget > 0 { expectedFrame = budget }
      defer { previousFrame = sender.timestamp }
      guard label != nil, let previousFrame else { return }
      gaps.append(sender.timestamp - previousFrame)
      gapOffsets.append(sender.timestamp - start)
      budgets.append(expectedFrame)
    }

    private func begin(_ name: String) {
      end()
      turns.removeAll(keepingCapacity: true)
      turnOffsets.removeAll(keepingCapacity: true)
      gaps.removeAll(keepingCapacity: true)
      gapOffsets.removeAll(keepingCapacity: true)
      budgets.removeAll(keepingCapacity: true)
      previousFrame = nil
      expectedFrame = 0
      touchIntervals.removeAll(keepingCapacity: true)
      activeTouchStart = nil
      events.removeAll(keepingCapacity: true)
      droppedEvents = 0
      counts.removeAll(keepingCapacity: true)
      timings.removeAll(keepingCapacity: true)
      activationCounts.removeAll(keepingCapacity: true)
      activationTimings.removeAll(keepingCapacity: true)
      activationIntervals.removeAll(keepingCapacity: true)
      turnStart = nil
      label = name
      start = CACurrentMediaTime()
      interval = signposter.beginInterval("Microstutter.scenario", "\(name, privacy: .public)")
    }

    private func end() {
      guard let label else { return }
      let wall = CACurrentMediaTime() - start
      self.label = nil
      turnStart = nil
      if let interval { signposter.endInterval("Microstutter.scenario", interval) }
      interval = nil
      let sorted = turns.sorted()
      let sortedBudgets = budgets.filter { $0 > 0 }.sorted()
      let budget = sortedBudgets.isEmpty ? expectedFrame : sortedBudgets[sortedBudgets.count / 2]
      // Run-loop busy intervals are stall proxies, not rendered-frame hitch counts. The budget
      // comes from the active display link rather than assuming 60 Hz or ProMotion's maximum.
      let stalls = budget > 0 ? turns.filter { $0 > budget * 1.5 } : []
      let missed = zip(gaps, budgets).filter { $0.1 > 0 && $0.0 > $0.1 * 1.5 }
      // Include each complete finger interval and 500ms of post-input animation. Exclude
      // target lookup/snapshot work before the first touch. This remains a run-loop proxy.
      let inputTurns = zip(turnOffsets, turns).filter { offset, duration in
        touchIntervals.contains { touch in
          start + offset + duration >= touch.start && start + offset <= touch.end + 0.5
        }
      }.map { $0.1 }
      let inputStalls = budget > 0 ? inputTurns.filter { $0 > budget * 1.5 } : []
      let inputGaps = gaps.indices.filter { index in
        touchIntervals.contains { touch in
          start + gapOffsets[index] >= touch.start && start + gapOffsets[index] - gaps[index] <= touch.end + 0.5
        }
      }
      var record: [String: Any] = [:]
      record["input_frame_gap_proxy_count"] = inputGaps.filter { budgets[$0] > 0 && gaps[$0] > budgets[$0] * 1.5 }.count
      record["input_frame_gap_max_ms"] = (inputGaps.map { gaps[$0] }.max() ?? 0) * 1_000
      record["touch_intervals"] = touchIntervals.map {
        ["begin_offset_s": $0.start - start, "end_offset_s": $0.end - start]
      }
      record["input_turn_max_ms"] = (inputTurns.max() ?? 0) * 1_000
      record["input_stall_proxy_count"] = inputStalls.count
      record["input_stall_proxy_total_ms"] = inputStalls.reduce(0, +) * 1_000
      record["input_busy_ms"] = inputTurns.reduce(0, +) * 1_000
      if recordsEventTimeline {
        record["event_timeline"] = events.map { event -> [String: Any] in
          var value: [String: Any] = ["name": event.name, "offset_s": event.offset, "count": event.count]
          if let elapsed = event.elapsed { value["elapsed_ms"] = elapsed * 1_000 }
          return value
        }
        record["event_timeline_dropped"] = droppedEvents
      }
      record["counts"] = counts
      record["timings_ms"] = timings
      record["activation_counts"] = activationCounts
      record["activation_timings_ms"] = activationTimings
      record["activation_intervals"] = activationIntervals
      record["long_turns"] = zip(turnOffsets, turns).filter { budget > 0 && $0.1 > budget * 1.5 }.map {
        ["offset_s": $0.0, "duration_ms": $0.1 * 1_000]
      }
      record["scenario"] = label
      record["uptime_start_s"] = start
      record["wall_s"] = wall
      record["frame_budget_ms"] = budget * 1_000
      record["turn_count"] = turns.count
      record["busy_ms"] = turns.reduce(0, +) * 1_000
      record["turn_p50_ms"] = (sorted.isEmpty ? 0 : sorted[sorted.count / 2]) * 1_000
      record["turn_p95_ms"] = (sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]) * 1_000
      record["turn_max_ms"] = (sorted.last ?? 0) * 1_000
      record["stall_proxy_count"] = stalls.count
      record["stall_proxy_total_ms"] = stalls.reduce(0, +) * 1_000
      record["over33_count"] = turns.filter { $0 > 0.03333 }.count
      record["over50_count"] = turns.filter { $0 > 0.05 }.count
      record["frame_count"] = gaps.count
      record["frame_gap_proxy_count"] = missed.count
      record["frame_gap_max_ms"] = (gaps.max() ?? 0) * 1_000
      records.append(record)
      // Only serialize after the measured window. The runner waits before the next window.
      let url = URL.cachesDirectory.appending(path: "microstutter-results.json")
      if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url, options: .atomic)
      }
    }
  }

  extension UIApplication {
    @objc fileprivate func microstutterSendEvent(_ event: UIEvent) {
      MicrostutterProbe.shared.receivedTouchEvent(event)
      microstutterSendEvent(event)
    }
  }
#endif
