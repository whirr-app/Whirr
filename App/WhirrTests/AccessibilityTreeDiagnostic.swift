import Foundation
import SwiftUI
import TestSupport
import Testing
import UIKit

@testable import Whirr

/// A read-only probe of the real UIKit accessibility tree behind each harness screen.
///
/// Hosts the screen and asks UIKit what VoiceOver would find: label, value, traits and the
/// `accessibilityFrame` that Switch Control, Voice Control and the Inspector's Hit Region audit
/// measure.
///
/// Diagnostic, not a gate: runs only under `WHIRR_A11Y_DUMP=1`, never records an `Issue`. The
/// thresholds below are those an enforcing version would use.
@MainActor
@Suite("Accessibility tree diagnostic", .serialized)
struct AccessibilityTreeDiagnostic {

  /// The AA floor from WCAG 2.2 SC 2.5.8, in points.
  private static let targetSizeMinimumAA: CGFloat = 24
  /// The HIG figure, which is also WCAG AAA SC 2.5.5.
  private static let targetSizeMinimumHIG: CGFloat = 44

  private struct Node {
    var depth: Int
    var kind: String
    var label: String
    var value: String
    var hint: String
    var identifier: String
    var traits: [String]
    var frame: CGRect

    var isActionable: Bool {
      traits.contains("button") || traits.contains("link")
        || traits.contains("adjustable")
    }
  }

  @Test("dump the accessibility tree for every harness screen")
  func dumpAccessibilityTrees() async throws {
    guard ProcessInfo.processInfo.environment["WHIRR_A11Y_DUMP"] == "1" else { return }

    let screens = [
      "home", "home-shell", "library", "detail", "storage",
      "player", "podcasts", "podcast-show", "search", "reader",
    ]
    let scheme = ProcessInfo.processInfo.environment["WHIRR_A11Y_DUMP_SCHEME"] ?? "dark"
    setenv("WHIRR_UI_HARNESS", "1", 1)
    setenv("WHIRR_UI_HARNESS_SCHEME", scheme, 1)

    print("A11YDUMP-BEGIN scheme=\(scheme)")
    for screen in screens {
      setenv("WHIRR_UI_HARNESS_SCREEN", screen, 1)
      let nodes = await captureTree(screen: screen)
      emit(screen: screen, nodes: nodes)
    }
    print("A11YDUMP-END")
  }

  private func captureTree(screen: String) async -> [Node] {
    // iPhone 17 points. The frame numbers only mean something at a real device size.
    let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
    return await withKeyWindow(bounds: bounds) { scope in
      let controller = scope.host(UIHarnessRootView())
      // Harness screens load through the real models, so the tree fills in after the first
      // layout pass. Read too early it is empty, not wrong. Wait for the tree to stop changing
      // rather than for a fixed number of turns. A screen that never settles shows up as a short
      // node list in its dump. `recordingIssue` stays off: this suite reports, it does not assert.
      await awaitQuiescence(
        "accessibility tree for \(screen)",
        stableFor: 30,
        timeout: 4,
        recordingIssue: false
      ) {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        var probe: [Node] = []
        walk(scope.window, depth: 0, into: &probe)
        return probe.map { "\($0.depth)\($0.kind)\($0.label)\($0.value)" }
          .joined(separator: "\u{1F}")
      }
      var nodes: [Node] = []
      walk(scope.window, depth: 0, into: &nodes)
      return nodes
    }
  }

  /// Depth-first over the accessibility tree, preferring the container API over `subviews`:
  /// SwiftUI publishes synthesized `UIAccessibilityElement`s through `accessibilityElements`,
  /// which a `subviews` walk misses. Everything read comes from the `UIAccessibility` informal
  /// protocol on `NSObject`, so one cast reaches real views and synthesized elements alike.
  private func walk(_ object: Any, depth: Int, into nodes: inout [Node]) {
    guard depth < 40, let element = object as? NSObject else { return }

    if element.isAccessibilityElement {
      nodes.append(node(from: element, depth: depth))
      return
    }

    let count = element.accessibilityElementCount()
    if count != NSNotFound, count > 0 {
      var emittedAny = false
      for index in 0..<count {
        if let child = element.accessibilityElement(at: index) {
          walk(child, depth: depth + 1, into: &nodes)
          emittedAny = true
        }
      }
      if emittedAny { return }
    }
    if let elements = element.accessibilityElements, elements.isEmpty == false {
      for child in elements { walk(child, depth: depth + 1, into: &nodes) }
      return
    }

    if let view = element as? UIView {
      // Hidden subtrees are not in the accessibility tree either. Skipping them keeps the dump
      // to what VoiceOver reaches.
      for subview in view.subviews where subview.isHidden == false && subview.alpha > 0.01 {
        walk(subview, depth: depth + 1, into: &nodes)
      }
    }
  }

  private func node(from element: NSObject, depth: Int) -> Node {
    Node(
      depth: depth,
      kind: String(describing: type(of: element)),
      label: element.accessibilityLabel ?? "",
      value: element.accessibilityValue ?? "",
      hint: element.accessibilityHint ?? "",
      identifier: (element as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? "",
      traits: Self.traitNames(element.accessibilityTraits),
      frame: element.accessibilityFrame)
  }

  private static func traitNames(_ traits: UIAccessibilityTraits) -> [String] {
    var names: [String] = []
    let table: [(UIAccessibilityTraits, String)] = [
      (.button, "button"), (.link, "link"), (.header, "header"),
      (.selected, "selected"), (.image, "image"), (.staticText, "staticText"),
      (.searchField, "searchField"), (.adjustable, "adjustable"),
      (.notEnabled, "notEnabled"), (.updatesFrequently, "updatesFrequently"),
      (.playsSound, "playsSound"), (.keyboardKey, "keyboardKey"),
      (.summaryElement, "summaryElement"), (.startsMediaSession, "startsMediaSession"),
      (.allowsDirectInteraction, "allowsDirectInteraction"),
      (.causesPageTurn, "causesPageTurn"), (.tabBar, "tabBar"),
    ]
    for (trait, name) in table where traits.contains(trait) { names.append(name) }
    return names
  }

  private func emit(screen: String, nodes: [Node]) {
    print("A11YSCREEN \(screen) elements=\(nodes.count)")
    for node in nodes {
      let frame = String(
        format: "%.0fx%.0f@%.0f,%.0f", node.frame.width, node.frame.height,
        node.frame.minX, node.frame.minY)
      let flags = node.traits.joined(separator: "|")
      print(
        "A11YNODE \(screen) | \(frame) | traits=[\(flags)] | label=\"\(node.label)\""
          + " | value=\"\(node.value)\" | hint=\"\(node.hint)\" | id=\"\(node.identifier)\""
          + " | class=\(node.kind)")
    }

    // The two checks an enforcing version would make. Reported here, not asserted.
    let unlabelled = nodes.filter { $0.isActionable && $0.label.isEmpty }
    for node in unlabelled {
      print("A11YFINDING \(screen) UNLABELLED_ACTION frame=\(node.frame) class=\(node.kind)")
    }
    for node in nodes where node.isActionable {
      let side = min(node.frame.width, node.frame.height)
      guard side > 0 else { continue }
      if side < Self.targetSizeMinimumAA {
        print(
          "A11YFINDING \(screen) TARGET_BELOW_AA(24pt) side=\(side) "
            + "label=\"\(node.label)\" frame=\(node.frame)")
      } else if side < Self.targetSizeMinimumHIG {
        print(
          "A11YFINDING \(screen) TARGET_BELOW_HIG(44pt) side=\(side) "
            + "label=\"\(node.label)\" frame=\(node.frame)")
      }
    }
  }
}
