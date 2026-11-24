import SwiftUI
import TestSupport
import Testing
import UIKit

@testable import Whirr

/// Item detail at the largest accessibility type size, measured.
///
/// The audit found nine elements with negative x origins (title at -114, Play button and every
/// chapter row at -139), each about 681 pt wide on a 402 pt display: clipped at both edges, and
/// the screen scrolls only vertically. SC 1.4.10 asks for reflow to 320 pt without
/// two-dimensional scrolling.
///
/// Frames come from `accessibilityFrame`, which Switch Control, Voice Control and the Accessibility
/// Inspector's hit-region audit measure, so an element outside the window here is outside for them.
@MainActor
@Suite("Reflow at accessibility type sizes", .serialized)
struct ReflowTests {

  /// iPhone 17 points, matching the rest of the hosted suites.
  private static let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)

  /// A point of slop for rounding in the frames UIKit reports back.
  private static let tolerance: CGFloat = 1

  /// Every screen the harness can mount, not just the one the dump caught. Three of the four reflow
  /// risks the source review raised (the action row, the conflict copy and the timeline readout)
  /// could not be settled by reading. Sweeping the whole harness settles them by measurement.
  @Test(
    "no element outruns the screen at the largest accessibility type size",
    arguments: [
      "home", "home-shell", "library", "detail", "storage",
      "player", "podcasts", "podcast-show", "search", "reader",
    ])
  func contentStaysWithinTheScreen(_ screen: String) async {
    let nodes = await hostScreen(screen, at: .accessibility5)

    let overruns = nodes.filter { node in
      let frame = node.frame
      guard frame.width > 0, frame.height > 0, node.insideHorizontalScroller == false else {
        return false
      }
      return frame.minX < -Self.tolerance
        || frame.maxX > Self.bounds.width + Self.tolerance
    }

    #expect(
      overruns.isEmpty,
      """
      \(screen): \(overruns.count) element(s) reach outside \(Int(Self.bounds.width)) pt: \
      \(overruns.map { "\($0.label.isEmpty ? $0.kind : $0.label) \(Int($0.frame.width))pt@\(Int($0.frame.minX))" }.joined(separator: "; "))
      """)
  }

  // MARK: - Hosting

  private struct Node {
    var label: String
    var kind: String
    var frame: CGRect
    /// Whether an ancestor is a scroll view that scrolls horizontally.
    ///
    /// Separates carousels (Home's shelves and chip rows, where x=384 is one swipe away) from the
    /// SC 1.4.10 failure: item detail has no horizontal scroller, so x=-139 is unreachable.
    var insideHorizontalScroller: Bool
  }

  private func hostScreen(_ screen: String, at size: DynamicTypeSize) async -> [Node] {
    // Inside the scope. The harness screen is a process-wide environment variable, and the
    // key-window gate is what serialises the suites that write it.
    await withKeyWindow(bounds: Self.bounds) { scope in
      setenv("WHIRR_UI_HARNESS", "1", 1)
      setenv("WHIRR_UI_HARNESS_SCREEN", screen, 1)
      defer {
        unsetenv("WHIRR_UI_HARNESS_SCREEN")
        unsetenv("WHIRR_UI_HARNESS")
      }
      let controller = scope.host(UIHarnessRootView().environment(\.dynamicTypeSize, size))
      let settled = await awaitQuiescence(
        "\(screen) at \(size)", stableFor: 30, timeout: 4, recordingIssue: false
      ) {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        var probe: [Node] = []
        walk(scope.window, depth: 0, insideHorizontalScroller: false, into: &probe)
        return probe.map { "\($0.label)\($0.frame)" }.joined(separator: "\u{1F}")
      }
      #expect(settled.isObserved, "\(screen) at \(size) never settled: \(settled)")
      var nodes: [Node] = []
      walk(scope.window, depth: 0, insideHorizontalScroller: false, into: &nodes)
      return nodes
    }
  }

  private func walk(
    _ object: Any, depth: Int, insideHorizontalScroller: Bool, into nodes: inout [Node]
  ) {
    guard depth < 40, let element = object as? NSObject else { return }

    if element.isAccessibilityElement {
      nodes.append(
        Node(
          label: element.accessibilityLabel ?? "",
          kind: String(describing: type(of: element)),
          frame: element.accessibilityFrame,
          insideHorizontalScroller: insideHorizontalScroller))
      return
    }

    var scrolls = insideHorizontalScroller
    if let scrollView = element as? UIScrollView,
      scrollView.contentSize.width > scrollView.bounds.width + Self.tolerance
    {
      scrolls = true
    }

    let count = element.accessibilityElementCount()
    if count != NSNotFound, count > 0 {
      var emittedAny = false
      for index in 0..<count {
        if let child = element.accessibilityElement(at: index) {
          walk(child, depth: depth + 1, insideHorizontalScroller: scrolls, into: &nodes)
          emittedAny = true
        }
      }
      if emittedAny { return }
    }
    if let elements = element.accessibilityElements, elements.isEmpty == false {
      for child in elements {
        walk(child, depth: depth + 1, insideHorizontalScroller: scrolls, into: &nodes)
      }
      return
    }
    if let view = element as? UIView {
      for subview in view.subviews where subview.isHidden == false && subview.alpha > 0.01 {
        walk(subview, depth: depth + 1, insideHorizontalScroller: scrolls, into: &nodes)
      }
    }
  }
}
