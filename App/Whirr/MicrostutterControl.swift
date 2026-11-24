#if PERF_INVESTIGATION
  import AppModel
  import CoreFoundation
  import UIKit

  /// Opt-in, non-destructive UI state control for repeatable performance gestures.
  /// This is inert unless the PERF_INVESTIGATION app receives -whirr-perf-controls.
  @MainActor
  enum MicrostutterControl {
    private static var installed = false
    private static let resetName = "com.remoteconcern.whirr.perf.reset.home"

    /// Call from the existing PERF_INVESTIGATION scene `.onAppear`.
    static func startIfRequested() {
      guard !installed,
        ProcessInfo.processInfo.arguments.contains("-whirr-perf-controls")
      else { return }
      installed = true
      CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), nil,
        { _, _, name, _, _ in
          guard name != nil else { return }
          Task { @MainActor in MicrostutterControl.resetHome() }
        }, resetName as CFString, nil, .deliverImmediately)
    }

    private static func resetHome() {
      guard let window = activeKeyWindow(),
        window.rootViewController?.presentedViewController == nil,
        let scrollView = mainVerticalScrollView(in: window),
        scrollView.refreshControl?.isRefreshing != true
      else {
        post("failed")
        return
      }

      scrollView.setContentOffset(
        CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
        animated: false)
      post("succeeded")
    }

    private static func activeKeyWindow() -> UIWindow? {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive }
        .flatMap(\.windows)
        .first { $0.isKeyWindow && !$0.isHidden && $0.alpha > 0 }
    }

    private static func mainVerticalScrollView(in window: UIWindow) -> UIScrollView? {
      guard let root = window.rootViewController?.view else { return nil }
      var candidates: [(UIScrollView, CGRect)] = []

      func visit(_ view: UIView) {
        guard !view.isHidden, view.alpha > 0, view.window === window else { return }
        if let scroll = view as? UIScrollView {
          let frame = scroll.convert(scroll.bounds, to: window)
          let fullWidth = frame.width >= window.bounds.width * 0.85
          let substantialHeight = frame.height >= window.bounds.height * 0.45
          let scrollable = scroll.contentSize.height > scroll.bounds.height + 1
          if fullWidth && substantialHeight && scrollable && scroll.isScrollEnabled && frame.intersects(window.bounds) {
            candidates.append((scroll, frame))
          }
        }
        view.subviews.forEach(visit)
      }

      visit(root)
      return
        candidates
        .sorted { lhs, rhs in
          if lhs.1.height != rhs.1.height { return lhs.1.height > rhs.1.height }
          return lhs.1.width > rhs.1.width
        }
        .first?.0
    }

    /// Drives a scripted scroll from inside the app so a measured window has no XCUITest work:
    /// gesture-driven scenarios largely measure the automation (host sampling puts about 63% of
    /// busy main-thread time in `XCTElementSnapshotRequest`, on Library and Home alike). A sweep,
    /// not a replica of a finger (no gesture recognizer or deceleration), so absolute numbers do
    /// not compare with the drag scenarios.
    ///
    /// `WHIRR_PERF_SELF_SCROLL` carries the window label and must be one
    /// `MicrostutterProbe.startIfRequested` observes (a fixed list of `begin.*` names). Failure is
    /// silent: the sweep runs and writes `done`, but no window opens and no results file appears.
    static func startSelfScrollIfRequested() {
      let environment = ProcessInfo.processInfo.environment
      guard let label = environment["WHIRR_PERF_SELF_SCROLL"], !label.isEmpty else { return }
      let repetitions = environment["WHIRR_PERF_SELF_SCROLL_REPS"].flatMap(Int.init) ?? 3
      let settle = environment["WHIRR_PERF_SELF_SCROLL_DELAY"].flatMap(Double.init) ?? 8
      Task { @MainActor in
        await runSelfScroll(label: label, repetitions: repetitions, settle: settle)
      }
    }

    /// One fling covers this many screen heights over `flingDuration`, then rests. The pause lets
    /// a frame settle so the next sweep starts from a quiet run loop, like a reader pausing
    /// between flicks.
    private static let flingScreens: CGFloat = 2.0
    private static let flingDuration: CFTimeInterval = 1.0
    private static let flingRest = Duration.milliseconds(350)
    private static let flingsPerWindow = 5

    private static func runSelfScroll(label: String, repetitions: Int, settle: Double) async {
      let wanted = ProcessInfo.processInfo.environment["WHIRR_PERF_SELF_SCROLL_TAB"]
      // Select before settling, not after: the settle delay is what lets the chosen screen finish
      // its first load, and a tab switched at the end of it would be measured cold.
      if let wanted {
        try? await Task.sleep(for: .seconds(3))
        selectTab(named: wanted)
      }
      try? await Task.sleep(for: .seconds(settle))
      guard let window = activeKeyWindow() else {
        writeSelfScrollStatus("no-window")
        return
      }
      guard let scroll = sweepScrollView(in: window) else {
        writeSelfScrollStatus("no-scroll-view\n" + scrollViewCensus(in: window))
        return
      }
      for _ in 0..<repetitions {
        scroll.setContentOffset(
          CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
        try? await Task.sleep(for: .seconds(1))
        postPerf("begin." + label)
        for _ in 0..<flingsPerWindow {
          await ScrollSweep(
            scroll: scroll, distance: scroll.bounds.height * flingScreens, duration: flingDuration
          ).run()
          try? await Task.sleep(for: flingRest)
        }
        postPerf("end")
        try? await Task.sleep(for: .seconds(1))
      }
      writeSelfScrollStatus(
        "done\ntab: \(selectedTabReport)"
          + "\nswept: frame=\(Int(scroll.bounds.width))x\(Int(scroll.bounds.height))"
          + " content=\(Int(scroll.contentSize.width))x\(Int(scroll.contentSize.height))"
          + "\n" + scrollViewCensus(in: window))
    }

    /// Selects a root tab by name so a sweep need not rely on a tap. Goes through
    /// `NavigationModel.section`: the `.sidebarAdaptable` shell has no `UITabBarController`, so a
    /// search would return nil and measure whichever tab is showing.
    private static weak var navigation: NavigationModel?

    /// Registered by `LibraryShellView` under PERF_INVESTIGATION. Weak, and never read outside a
    /// self-scroll run, so the harness cannot keep the shell's model alive.
    static func register(navigation model: NavigationModel) {
      navigation = model
    }

    private static func selectTab(named title: String) {
      guard let navigation else {
        selectedTabReport = "no-navigation-model"
        return
      }
      let section = NavigationModel.Section.allCases.first {
        "\($0)".caseInsensitiveCompare(title) == .orderedSame
      }
      guard let section else {
        let names = NavigationModel.Section.allCases.map { "\($0)" }
        selectedTabReport = "no-section-\(title) have=\(names.joined(separator: ","))"
        return
      }
      navigation.section = section
      selectedTabReport = "wanted=\(title) now=\(navigation.section)"
    }

    /// What `selectTab` did, folded into the final status. Without it a run that measured the
    /// wrong screen is indistinguishable from a good one.
    private static var selectedTabReport = "not-requested"

    /// The largest vertical scroll view actually on screen. Not `mainVerticalScrollView`, whose
    /// 85%-of-window width gate would reject Library beside a sidebar at regular width. Ranking by
    /// visible area picks content over sidebar; the content-size orientation test keeps a shelf's
    /// horizontal carousel from winning.
    private static func sweepScrollView(in window: UIWindow) -> UIScrollView? {
      // Hit-testing first, because ranking by area cannot tell the front tab from the back one.
      // A `TabView` keeps unselected tabs' views in the hierarchy, unhidden and at a comparable
      // size, so area alone can pick Home while measuring Library. What is under the middle of
      // the window is what the reader is looking at.
      if let hit = window.hitTest(CGPoint(x: window.bounds.midX, y: window.bounds.midY), with: nil) {
        var view: UIView? = hit
        while let candidate = view {
          if let scroll = candidate as? UIScrollView, isSweepable(scroll) { return scroll }
          view = candidate.superview
        }
      }
      var best: (scroll: UIScrollView, area: CGFloat)?
      forEachScrollView(in: window) { scroll, visible in
        guard isSweepable(scroll) else { return }
        let area = visible.width * visible.height
        if area > (best?.area ?? 0) { best = (scroll, area) }
      }
      return best?.scroll
    }

    private static func isSweepable(_ scroll: UIScrollView) -> Bool {
      scroll.isScrollEnabled
        && scroll.contentSize.height > scroll.bounds.height + 1
        && scroll.contentSize.height >= scroll.contentSize.width
    }

    /// Emitted alongside a `no-scroll-view` status: without it a failed device run says only
    /// that nothing matched, leaving a guess about which predicate was wrong.
    private static func scrollViewCensus(in window: UIWindow) -> String {
      var lines: [String] = ["window=\(Int(window.bounds.width))x\(Int(window.bounds.height))"]
      forEachScrollView(in: window) { scroll, visible in
        lines.append(
          "scroll frame=\(Int(visible.width))x\(Int(visible.height))"
            + " content=\(Int(scroll.contentSize.width))x\(Int(scroll.contentSize.height))"
            + " bounds=\(Int(scroll.bounds.width))x\(Int(scroll.bounds.height))"
            + " enabled=\(scroll.isScrollEnabled)")
      }
      return lines.joined(separator: "\n")
    }

    private static func forEachScrollView(
      in window: UIWindow, _ body: (UIScrollView, CGRect) -> Void
    ) {
      guard let root = window.rootViewController?.view else { return }
      func visit(_ view: UIView) {
        guard !view.isHidden, view.alpha > 0, view.window === window else { return }
        if let scroll = view as? UIScrollView {
          let visible = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
          if !visible.isNull && !visible.isEmpty { body(scroll, visible) }
        }
        view.subviews.forEach(visit)
      }
      visit(root)
    }

    /// Lets a device run tell "the sweep finished" from "the app never found a scroll view",
    /// which look identical from the host: both leave the probe's JSON behind.
    private static func writeSelfScrollStatus(_ status: String) {
      try? Data(status.utf8).write(
        to: URL.cachesDirectory.appending(path: "selfscroll-status.txt"), options: .atomic)
    }

    private static func postPerf(_ suffix: String) {
      CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(rawValue: ("com.remoteconcern.whirr.perf." + suffix) as CFString),
        nil, nil, true)
    }

    private static func post(_ result: String) {
      let name = ("com.remoteconcern.whirr.perf.reset." + result) as CFString
      CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(rawValue: name),
        nil, nil, true)
    }
  }

  /// Steps `contentOffset` once per displayed frame for the duration of one fling.
  ///
  /// Not `UIView.animate` or `setContentOffset(_:animated:)`: both hand the offset to Core
  /// Animation, which can interpolate off the main thread and hide the main-thread cost the
  /// probe exists to record.
  @MainActor
  private final class ScrollSweep: NSObject {
    private let scroll: UIScrollView
    private let origin: CGFloat
    private let distance: CGFloat
    private let duration: CFTimeInterval
    private var started: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Never>?
    private static let scrollSource = "perfSweep"

    init(scroll: UIScrollView, distance: CGFloat, duration: CFTimeInterval) {
      self.scroll = scroll
      self.origin = scroll.contentOffset.y
      self.distance = distance
      self.duration = duration
    }

    func run() async {
      // Writing `contentOffset` per frame never enters SwiftUI's `ScrollPhase` machinery, so no
      // `onScrollPhaseChange` fires and screens that defer work during a fling would believe
      // the surface is at rest, the opposite of what the sweep models. Declare the motion
      // directly, as a finger scroll does.
      ArtworkScrollActivity.shared.setScrolling(true, source: Self.scrollSource)
      defer { ArtworkScrollActivity.shared.setScrolling(false, source: Self.scrollSource) }

      await withCheckedContinuation { continuation in
        self.continuation = continuation
        started = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
      }
    }

    @objc private func tick() {
      let progress = min(1, (CACurrentMediaTime() - started) / duration)
      // Ease out: fast at the start and settling at the end, which is the shape of a flick.
      let eased = 1 - pow(1 - progress, 3)
      let bottom =
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
      let limit = max(-scroll.adjustedContentInset.top, bottom)
      scroll.contentOffset = CGPoint(
        x: scroll.contentOffset.x, y: min(origin + distance * CGFloat(eased), limit))
      if progress >= 1 { finish() }
    }

    private func finish() {
      link?.invalidate()
      link = nil
      continuation?.resume()
      continuation = nil
    }
  }
#endif
