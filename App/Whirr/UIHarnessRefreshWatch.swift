import CoreSupport

#if DEBUG || PERF_INVESTIGATION
  import Foundation
  import QuartzCore
  import SwiftUI
  import UIKit
  import os

  extension UIHarness {
    /// `WHIRR_REFRESH_WATCH=1`: log every change to the browse scroll view's vertical geometry.
    /// Noisy (a line per scrolled frame), so it stays opt-in.
    static var logsRefreshGeometry: Bool {
      ProcessInfo.processInfo.environment["WHIRR_REFRESH_WATCH"] == "1"
    }

    /// The watch itself runs in every debug build of the real app, because the defect is reported
    /// there and not in the harness. Silent unless it catches the scroll view settled above the top
    /// of its own content, which costs a handful of property reads per frame and no log traffic.
    /// Harness runs opt in, so a scroll measurement is never sharing its run loop with this.
    static var watchesRefresh: Bool {
      logsRefreshGeometry || isActive == false
    }

    /// `WHIRR_REFRESH_MUTATES=1`: the harness refresh retires and restores a shelf, so a pull
    /// changes `HomeView`'s `elements` the way a real sync does.
    nonisolated static var refreshMutatesContent: Bool {
      ProcessInfo.processInfo.environment["WHIRR_REFRESH_MUTATES"] == "1"
    }

    /// `WHIRR_REFRESH_DELAY_MS`: how long the harness's fake sync holds the refresh action open.
    /// The stock fake returns immediately, which is not the shape a real pull takes.
    nonisolated static var refreshDelayMilliseconds: Int {
      ProcessInfo.processInfo.environment["WHIRR_REFRESH_DELAY_MS"].flatMap(Int.init) ?? 0
    }
  }

  /// Debug-only watch on the browse scroll view's vertical geometry across a real pull to refresh.
  ///
  /// Only samples: a refresh can't be started in-process (`sendActions(for: .valueChanged)` and
  /// `beginRefreshing()` don't reach SwiftUI's action), so the gesture is injected from outside.
  /// Reports where height is left behind (`contentInset`, `contentOffset`, or a framework spacer),
  /// since each wants a different fix.
  struct UIHarnessRefreshWatch: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
      let view = UIView(frame: .zero)
      view.isUserInteractionEnabled = false
      view.isHidden = true
      context.coordinator.start(from: view)
      return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
      private let logger = CoreLogging.logger(category: "HarnessRefresh")
      private var link: CADisplayLink?
      private weak var anchor: UIView?
      private weak var watched: UIScrollView?
      private let started = CACurrentMediaTime()
      private var lastLine = ""
      private var lastStillOffset: CGFloat = .nan
      private var stillSince: Double = 0
      private var reportedStrand = false

      func start(from view: UIView) {
        anchor = view
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
      }

      @objc private func tick() {
        guard let anchor else { return }
        guard let scrollView = Self.tallestVerticalScrollView(from: anchor) else { return }
        if watched !== scrollView {
          watched = scrollView
          logger.notice(
            "WHIRR_REFRESH_TARGET class=\(String(describing: type(of: scrollView)), privacy: .public) has_rc=\(scrollView.refreshControl != nil, privacy: .public)"
          )
        }

        let refresh = scrollView.refreshControl
        let state = refresh.map { $0.isRefreshing ? "refreshing" : "idle" } ?? "none"
        let refreshY = refresh?.frame.minY ?? .nan
        let refreshHeight = refresh?.frame.height ?? .nan
        let contentTop = Self.contentTop(of: scrollView)
        let elapsed = CACurrentMediaTime() - started
        defer { noteStrand(in: scrollView, at: elapsed) }
        guard UIHarness.logsRefreshGeometry else { return }

        let line = String(
          format:
            "off=%.2f ins=%.2f adj=%.2f safe=%.2f csz=%.1f h=%.1f rc=%@ rc_y=%.2f rc_h=%.2f top=%.2f",
          scrollView.contentOffset.y, scrollView.contentInset.top,
          scrollView.adjustedContentInset.top, scrollView.safeAreaInsets.top,
          scrollView.contentSize.height, scrollView.bounds.height, state, refreshY, refreshHeight,
          contentTop)
        guard line != lastLine else { return }
        lastLine = line
        logger.notice(
          "WHIRR_REFRESH t=\(elapsed, format: .fixed(precision: 3), privacy: .public) \(line, privacy: .public)"
        )
      }

      /// A resting position above the top of the content is the defect's signature: the scroll view
      /// has settled, nothing is refreshing, and yet the content still sits below where the top of
      /// the page belongs. Stillness is required because the release bounce passes through the same
      /// offsets on its way home.
      private func noteStrand(in scrollView: UIScrollView, at elapsed: Double) {
        let offset = scrollView.contentOffset.y
        let rest = -scrollView.adjustedContentInset.top
        let isRefreshing = scrollView.refreshControl?.isRefreshing ?? false
        let excess = rest - offset

        guard isRefreshing == false, excess > 4, abs(offset - lastStillOffset) < 0.5 else {
          lastStillOffset = offset
          stillSince = elapsed
          reportedStrand = false
          return
        }
        guard reportedStrand == false, elapsed - stillSince > 0.5 else { return }
        reportedStrand = true
        // `tracking` is the whole question. A scroll view still tracking a touch is holding the
        // overscroll open because nothing ever ended the drag; one that is idle has been left
        // parked by whatever last wrote its offset. The two want opposite fixes.
        logger.notice(
          """
          WHIRR_REFRESH_STRANDED t=\(elapsed, format: .fixed(precision: 3), privacy: .public) \
          excess=\(excess, format: .fixed(precision: 2), privacy: .public) \
          off=\(offset, format: .fixed(precision: 2), privacy: .public) \
          rest=\(rest, format: .fixed(precision: 2), privacy: .public) \
          ins=\(scrollView.contentInset.top, format: .fixed(precision: 2), privacy: .public) \
          safe=\(scrollView.safeAreaInsets.top, format: .fixed(precision: 2), privacy: .public) \
          tracking=\(scrollView.isTracking, privacy: .public) \
          dragging=\(scrollView.isDragging, privacy: .public) \
          decelerating=\(scrollView.isDecelerating, privacy: .public) \
          rc=\(scrollView.refreshControl?.isRefreshing ?? false, privacy: .public)
          """
        )
      }

      /// The top of the laid-out content in the scroll view's own coordinates. A stranded inset and
      /// a stranded spacer both push the first row down, but only the spacer moves this.
      private static func contentTop(of scrollView: UIScrollView) -> CGFloat {
        scrollView.subviews
          .filter { !($0 is UIRefreshControl) }
          .filter { $0.frame.height > 1 && $0.frame.width > 1 && !$0.isHidden }
          .map(\.frame.minY)
          .min() ?? .nan
      }

      private static func tallestVerticalScrollView(from anchor: UIView) -> UIScrollView? {
        guard let root = anchor.window?.rootViewController?.view else { return nil }
        var found: [UIScrollView] = []
        var pending = [root]
        while let view = pending.popLast() {
          if let scrollView = view as? UIScrollView { found.append(scrollView) }
          pending.append(contentsOf: view.subviews)
        }
        return
          found
          .filter { $0.bounds.height > 200 }
          .max { $0.contentSize.height < $1.contentSize.height }
      }
    }
  }

  extension View {
    /// Attaches the watch to any composition, the shipping shell included, when the flag is set.
    func harnessRefreshWatch() -> some View {
      overlay {
        if UIHarness.watchesRefresh {
          UIHarnessRefreshWatch()
        }
      }
    }
  }
#endif
