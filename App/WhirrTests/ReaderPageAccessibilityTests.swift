import Foundation
import SwiftUI
import TestSupport
import Testing
import UIKit

@testable import Whirr

/// Guards against a WCAG audit finding: `.accessibilityRepresentation` on the Readium surface
/// replaced the book with three synthetic buttons, so VoiceOver saw no prose. A representation
/// substitutes a view's whole subtree, wrong for the one view whose subtree is the content.
///
/// Page turns and the chrome toggle are `.accessibilityAction(named:)` on the "Book page"
/// container, which publishes its children and carries the actions. Both halves are asserted, as
/// either alone can be satisfied by a broken tree.
@MainActor
@Suite("Reader page accessibility", .serialized)
struct ReaderPageAccessibilityTests {

  /// iPhone 17 points, matching the rest of the hosted suites.
  private static let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)

  @Test("the reader page keeps its own content in the accessibility tree")
  func readerPageExposesItsContent() async {
    let nodes = await hostReaderAndWalkTree()

    // The harness renders a stand-in for the Readium web view. On the real path this is the book's
    // own text. Either way, something inside the surface must reach the tree rather than the
    // surface being replaced wholesale.
    #expect(
      nodes.contains { $0.isAccessibilityElement && $0.accessibilityLabel == "Simulated EPUB page" },
      "the reader page's content is missing from the accessibility tree")

    // The representation's buttons. As elements they are the regression: they belong on the actions
    // rotor, not in the element order. Their presence there means the page's own subtree has been
    // displaced again.
    let synthetic = nodes.filter { node in
      guard node.isAccessibilityElement, let label = node.accessibilityLabel else { return false }
      return label == "Turn page left" || label == "Turn page right"
        || label.hasSuffix("reader controls")
    }
    #expect(
      synthetic.isEmpty,
      "page controls are published as elements again: \(synthetic.compactMap(\.accessibilityLabel))")
  }

  @Test("turning pages and toggling chrome stay reachable as custom actions")
  func readerPageKeepsItsCustomActions() async {
    let nodes = await hostReaderAndWalkTree()
    let actionNames = Set(nodes.flatMap { $0.accessibilityCustomActions ?? [] }.map(\.name))

    #expect(
      actionNames.contains("Turn page left"),
      "page-left action is gone; found \(actionNames.sorted())")
    #expect(
      actionNames.contains("Turn page right"),
      "page-right action is gone; found \(actionNames.sorted())")
    #expect(
      actionNames.contains { $0.hasSuffix("reader controls") },
      "chrome-toggle action is gone; found \(actionNames.sorted())")
  }

  // MARK: - Hosting

  private func hostReaderAndWalkTree() async -> [NSObject] {
    // Set inside the key-window scope, not around it. `WHIRR_UI_HARNESS_SCREEN` is process-wide and
    // every hosted harness suite writes it. Only `withKeyWindow`'s gate serialises those suites, so
    // a screen chosen outside the gate can be overwritten by another suite before this one mounts,
    // which reads as an empty tree rather than as interference.
    return await withKeyWindow(bounds: Self.bounds) { scope in
      #expect(
        enableAccessibilityRuntimeForTests(),
        "the accessibility runtime is off, so no tree exists to assert against")
      setenv("WHIRR_UI_HARNESS", "1", 1)
      setenv("WHIRR_UI_HARNESS_SCREEN", "reader", 1)
      defer {
        unsetenv("WHIRR_UI_HARNESS_SCREEN")
        unsetenv("WHIRR_UI_HARNESS")
      }
      let controller = scope.host(UIHarnessRootView())
      // The reader mounts through the real model, so the tree may still be filling in when the
      // first layout pass returns. Wait for it to settle, not for a fixed number of turns.
      let settled = await awaitQuiescence(
        "reader accessibility tree", stableFor: 30, timeout: 4, recordingIssue: false
      ) {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        var probe: [NSObject] = []
        walk(scope.window, depth: 0, into: &probe)
        return probe.compactMap { $0.accessibilityLabel }.joined(separator: "\u{1F}")
      }
      #expect(settled.isObserved, "the reader accessibility tree never settled: \(settled)")
      var nodes: [NSObject] = []
      walk(scope.window, depth: 0, into: &nodes)
      return nodes
    }
  }

  /// Every node in the accessibility tree, containers included.
  ///
  /// SwiftUI attaches `.accessibilityAction(named:)` to the container itself for a view marked
  /// `children: .contain`, and its `isAccessibilityElement` is `false`. A walk that stops at leaves
  /// reports no actions on a tree that carries three.
  private func walk(_ object: Any, depth: Int, into nodes: inout [NSObject]) {
    guard depth < 40, let node = object as? NSObject else { return }
    nodes.append(node)
    if node.isAccessibilityElement { return }

    let count = node.accessibilityElementCount()
    if count != NSNotFound, count > 0 {
      var emittedAny = false
      for index in 0..<count {
        if let child = node.accessibilityElement(at: index) {
          walk(child, depth: depth + 1, into: &nodes)
          emittedAny = true
        }
      }
      if emittedAny { return }
    }
    if let children = node.accessibilityElements, children.isEmpty == false {
      for child in children { walk(child, depth: depth + 1, into: &nodes) }
      return
    }
    if let view = node as? UIView {
      for subview in view.subviews where subview.isHidden == false && subview.alpha > 0.01 {
        walk(subview, depth: depth + 1, into: &nodes)
      }
    }
  }
}
