import CoreSupport

#if DEBUG || PERF_INVESTIGATION
  import Foundation
  import QuartzCore
  import SwiftUI
  import UIKit
  import os

  extension UIHarness {
    enum ScrollAxis: String {
      case vertical
      case horizontal
      case both
    }

    static var scrollAxis: ScrollAxis {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_SCROLL_AXIS"]
        .flatMap(ScrollAxis.init(rawValue:)) ?? .vertical
    }

    static var scrollReps: Int {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_SCROLL_REPS"].flatMap(Int.init) ?? 3
    }

    /// Seconds per leg. A leg is one end-to-end traverse of the surface being driven.
    static var scrollLegSeconds: Double {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_SCROLL_LEG"].flatMap(Double.init) ?? 0.9
    }

    /// Unattended runs terminate themselves so a batch of ablations can be scripted.
    static var exitsAfterScroll: Bool {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_SCROLL_EXIT"] == "1"
    }
  }

  /// Debug-only fixed scroll protocol for unattended simulator runs.
  ///
  /// Offsets are stepped from wall-clock time, not `UIView.animate`: a finger forces layout into
  /// the same run loop turn as each offset change (which `HarnessScrollProbe` can attribute), where
  /// a Core Animation animation lets layout trail the layer.
  struct UIHarnessScrollDriver: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
      let view = UIView(frame: .zero)
      view.isUserInteractionEnabled = false
      view.isHidden = true
      context.coordinator.schedule(from: view)
      return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    @MainActor
    final class Coordinator {
      private let logger = CoreLogging.logger(category: "HarnessScroll")
      private let probe = HarnessScrollProbe.shared
      private var task: Task<Void, Never>?

      deinit { task?.cancel() }

      func schedule(from anchor: UIView) {
        guard task == nil else { return }
        task = Task { [weak anchor] in
          probe.start()
          // The settle delay is also the probe's idle calibration sample: it establishes this
          // host's own run-loop cadence with nothing scrolling.
          try? await Task.sleep(for: UIHarness.scrollScriptDelay)
          guard Task.isCancelled == false, let anchor,
            let vertical = await Self.waitForScrollView(from: anchor, axis: .vertical)
          else {
            logger.error("WHIRR_SCROLL_DRIVER_NO_VERTICAL_SCROLL_VIEW")
            probe.stop()
            Self.exitIfRequested()
            return
          }

          logger.notice(
            """
            WHIRR_SCROLL_DRIVER_START axis=\(UIHarness.scrollAxis.rawValue, privacy: .public) \
            reps=\(UIHarness.scrollReps, privacy: .public) \
            leg_s=\(UIHarness.scrollLegSeconds, privacy: .public) \
            extent=\(Self.maxOffset(of: vertical, axis: .vertical), privacy: .public)
            """)

          HarnessMenuAudit.report("settled")

          switch UIHarness.scrollAxis {
          case .vertical:
            await runVertical(vertical)
          case .horizontal:
            await runHorizontal(vertical)
          case .both:
            await runVertical(vertical)
            await Self.settle(vertical)
            await runHorizontal(vertical)
          }

          HarnessMenuAudit.report("scrolled")
          probe.stop()
          logger.notice("WHIRR_SCROLL_DRIVER_END")
          Self.exitIfRequested()
        }
      }

      // MARK: - Passes

      private func runVertical(_ scrollView: UIScrollView) async {
        await Self.reset(scrollView, axis: .vertical)
        probe.beginWindow("vertical")
        for _ in 0..<UIHarness.scrollReps {
          await Self.drag(scrollView, axis: .vertical, to: Self.maxOffset(of: scrollView, axis: .vertical))
          try? await Task.sleep(for: .milliseconds(400))
          await Self.drag(scrollView, axis: .vertical, to: Self.minOffset(of: scrollView, axis: .vertical))
          try? await Task.sleep(for: .milliseconds(400))
        }
        probe.endWindow()
      }

      /// Walks the page top to bottom, driving every horizontal shelf that becomes visible. Each
      /// shelf gets its own probe window so a single slow rail cannot hide behind the page average.
      private func runHorizontal(_ vertical: UIScrollView) async {
        await Self.reset(vertical, axis: .vertical)
        var visited: Set<ObjectIdentifier> = []
        var shelfIndex = 0
        var pageStep = 0

        while pageStep < 24 {
          let shelves = Self.visibleHorizontalScrollViews(near: vertical)
          for shelf in shelves where visited.contains(ObjectIdentifier(shelf)) == false {
            visited.insert(ObjectIdentifier(shelf))
            let extent = Self.maxOffset(of: shelf, axis: .horizontal)
            guard extent > 1 else { continue }
            logger.notice(
              """
              WHIRR_SCROLL_SHELF index=\(shelfIndex, privacy: .public) \
              extent=\(extent, privacy: .public) \
              content_w=\(shelf.contentSize.width, privacy: .public) \
              bounds_w=\(shelf.bounds.width, privacy: .public) \
              bounds_h=\(shelf.bounds.height, privacy: .public) \
              content_h=\(shelf.contentSize.height, privacy: .public)
              """)
            probe.beginWindow("horizontal-shelf-\(shelfIndex)")
            for _ in 0..<UIHarness.scrollReps {
              await Self.drag(shelf, axis: .horizontal, to: extent)
              try? await Task.sleep(for: .milliseconds(250))
              await Self.drag(
                shelf, axis: .horizontal, to: Self.minOffset(of: shelf, axis: .horizontal))
              try? await Task.sleep(for: .milliseconds(250))
            }
            probe.endWindow()
            shelfIndex += 1
          }

          let bottom = Self.maxOffset(of: vertical, axis: .vertical)
          guard vertical.contentOffset.y < bottom - 1 else { break }
          let next = min(bottom, vertical.contentOffset.y + vertical.bounds.height * 0.6)
          await Self.drag(vertical, axis: .vertical, to: next, seconds: 0.4)
          await Self.settle(vertical)
          pageStep += 1
        }

        logger.notice("WHIRR_SCROLL_SHELVES_DRIVEN count=\(shelfIndex, privacy: .public)")
      }

      // MARK: - Motion

      private static func drag(
        _ scrollView: UIScrollView, axis: Axis, to target: CGFloat, seconds: Double? = nil
      ) async {
        let duration = seconds ?? UIHarness.scrollLegSeconds
        let origin = axis == .vertical ? scrollView.contentOffset.y : scrollView.contentOffset.x
        guard abs(target - origin) > 0.5, duration > 0 else { return }
        let interval = CleanRoomPerformanceSignposts.beginInterval(
          "UIHarness.scrollLeg", object: scrollView)
        let start = CACurrentMediaTime()
        while true {
          let fraction = min(1, (CACurrentMediaTime() - start) / duration)
          let value = origin + (target - origin) * CGFloat(fraction)
          switch axis {
          case .vertical:
            scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: value)
          case .horizontal:
            scrollView.contentOffset = CGPoint(x: value, y: scrollView.contentOffset.y)
          }
          if fraction >= 1 { break }
          // Shorter than a frame on purpose: the loop must never be the thing that limits how
          // often the offset moves, or it would mask the stalls it exists to find.
          try? await Task.sleep(for: .milliseconds(4))
          if Task.isCancelled { break }
        }
        CleanRoomPerformanceSignposts.endInterval("UIHarness.scrollLeg", state: interval)
      }

      private static func reset(_ scrollView: UIScrollView, axis: Axis) async {
        await drag(scrollView, axis: axis, to: minOffset(of: scrollView, axis: axis), seconds: 0.3)
        await settle(scrollView)
      }

      private static func settle(_ scrollView: UIScrollView) async {
        try? await Task.sleep(for: .milliseconds(600))
      }

      private static func exitIfRequested() {
        guard UIHarness.exitsAfterScroll else { return }
        // Give os_log a moment to flush the summaries before the process goes away.
        Task {
          try? await Task.sleep(for: .milliseconds(750))
          exit(0)
        }
      }

      // MARK: - Discovery

      enum Axis { case vertical, horizontal }

      private static func minOffset(of scrollView: UIScrollView, axis: Axis) -> CGFloat {
        switch axis {
        case .vertical: -scrollView.adjustedContentInset.top
        case .horizontal: -scrollView.adjustedContentInset.left
        }
      }

      private static func maxOffset(of scrollView: UIScrollView, axis: Axis) -> CGFloat {
        switch axis {
        case .vertical:
          max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height
              + scrollView.adjustedContentInset.bottom)
        case .horizontal:
          max(
            -scrollView.adjustedContentInset.left,
            scrollView.contentSize.width - scrollView.bounds.width
              + scrollView.adjustedContentInset.right)
        }
      }

      private static func allScrollViews(from anchor: UIView) -> [UIScrollView] {
        guard let root = anchor.window?.rootViewController?.view else { return [] }
        var found: [UIScrollView] = []
        var pending = [root]
        while let view = pending.popLast() {
          if let scrollView = view as? UIScrollView { found.append(scrollView) }
          pending.append(contentsOf: view.subviews)
        }
        return found
      }

      private static func largestScrollView(from anchor: UIView, axis: Axis) -> UIScrollView? {
        allScrollViews(from: anchor)
          .filter { maxOffset(of: $0, axis: axis) - minOffset(of: $0, axis: axis) > 1 }
          .max {
            maxOffset(of: $0, axis: axis) - minOffset(of: $0, axis: axis)
              < maxOffset(of: $1, axis: axis) - minOffset(of: $1, axis: axis)
          }
      }

      private static func waitForScrollView(from anchor: UIView, axis: Axis) async -> UIScrollView? {
        for _ in 0..<20 {
          if let scrollView = largestScrollView(from: anchor, axis: axis) { return scrollView }
          try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
      }

      /// Shelves are discovered through the vertical scroll view rather than a stored anchor:
      /// a hosted row is created and destroyed as its list cell recycles, so the set is only
      /// meaningful for the rows on screen right now.
      private static func visibleHorizontalScrollViews(near vertical: UIScrollView) -> [UIScrollView] {
        guard let window = vertical.window else { return [] }
        let visible = vertical.convert(vertical.bounds, to: window)
        return allScrollViews(from: vertical)
          .filter { $0 !== vertical }
          .filter { maxOffset(of: $0, axis: .horizontal) > 1 }
          .filter { $0.convert($0.bounds, to: window).intersects(visible) }
          .sorted {
            $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
          }
      }
    }
  }
#endif
