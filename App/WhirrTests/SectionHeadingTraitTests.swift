import DesignSystem
import SwiftUI
import Testing
import UIKit

@testable import Whirr

/// Browse section titles must be headings (SC 1.3.1). `BrowseSectionHeaderView` published its
/// tappable variant as a plain button and its plain variant as loose text, neither with the
/// `header` trait, so the heading rotor had nothing to land on.
///
/// Asserted on the resolved UIKit tree, not source: a trait on the wrong side of
/// `.accessibilityElement(children: .combine)` silently does not survive.
@MainActor
@Suite("Section heading traits", .serialized)
struct SectionHeadingTraitTests {

  private static let bounds = CGRect(x: 0, y: 0, width: 402, height: 200)

  @Test("a tappable section heading is a header as well as a button")
  func tappableHeadingCarriesBothTraits() async {
    let node = await hostAndFindHeading(
      BrowseSectionHeaderView(
        title: "Continue listening", accessibilityHint: "Opens the full list", onSelect: {}))

    #expect(node?.accessibilityTraits.contains(.header) == true, "the heading trait is missing")
    #expect(node?.accessibilityTraits.contains(.button) == true, "the button trait is missing")
  }

  @Test("a plain section heading is still a header")
  func plainHeadingCarriesTheHeaderTrait() async {
    let node = await hostAndFindHeading(BrowseSectionHeaderView(title: "Continue listening"))

    #expect(node?.accessibilityTraits.contains(.header) == true, "the heading trait is missing")
  }

  // MARK: - Hosting

  private func hostAndFindHeading(_ view: some View) async -> NSObject? {
    await withKeyWindow(bounds: Self.bounds) { scope in
      // Names the harness rather than the app when the tree is missing wholesale.
      #expect(
        enableAccessibilityRuntimeForTests(),
        "the accessibility runtime is off, so no tree exists to assert against")
      let controller = scope.host(view)
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
      var nodes: [NSObject] = []
      walk(scope.window, depth: 0, into: &nodes)
      return nodes.first { $0.accessibilityLabel == "Continue listening" }
    }
  }

  /// Containers included: a heading that combines its children is one element, so a walk that
  /// stops at leaves never reaches it.
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
