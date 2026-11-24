import AppModel
import SwiftUI
import Testing
import UIKit

@testable import Whirr

/// Which motion a collapse resolves to, how long it takes, and that the animator resolves it once
/// per transition.
@MainActor
@Suite("Player morph motion resolution", .serialized)
struct PlayerMorphMotionTests {
  private typealias Fixture = PlayerMorphFixture

  // MARK: - Collapse motion table

  @Test("a dissolve stays a dissolve whether or not there is a bar to land on")
  func dissolveIgnoresGeometry() {
    for reduceMotion in [false, true] {
      #expect(
        PlayerCollapseMotion.resolve(
          style: .dissolve, containerHeight: 874, reduceMotion: reduceMotion,
          geometry: Fixture.snapshot())
          == PlayerCollapseMotion.resolve(
            style: .dissolve, containerHeight: 874, reduceMotion: reduceMotion))
    }
  }

  @Test("Reduce Motion keeps the short slide even with a bar to land on")
  func reduceMotionSlides() {
    #expect(
      PlayerCollapseMotion.resolve(
        style: .slide, containerHeight: 874, reduceMotion: true, geometry: Fixture.snapshot())
        == .slide(translationY: 874))
  }

  @Test("no geometry (logout, nothing playing, selecting, a lost anchor) slides as today")
  func noGeometrySlides() {
    #expect(
      PlayerCollapseMotion.resolve(
        style: .slide, containerHeight: 874, reduceMotion: false, geometry: nil)
        == .slide(translationY: 874))
  }

  @Test("a slide with somewhere to land morphs, at compact and regular width")
  func geometryMorphs() {
    let compact = Fixture.snapshot()
    // Measured iPad bar: at its 760 pt regular-width cap.
    let regular = Fixture.snapshot(bar: CGRect(x: 37, y: 1132, width: 760, height: 52))
    for snapshot in [compact, regular] {
      #expect(
        PlayerCollapseMotion.resolve(
          style: .slide, containerHeight: 874, reduceMotion: false, geometry: snapshot)
          == .morph(snapshot))
    }
  }

  @Test("a morph takes the morph duration, and Reduce Motion's 0.2 s still wins")
  func morphDuration() {
    #expect(
      PlayerCollapseMotion.duration(style: .slide, reduceMotion: false, morphs: true)
        == ExpandedPlayerHostPresentation.morphDuration)
    #expect(PlayerCollapseMotion.duration(style: .slide, reduceMotion: true, morphs: true) == 0.2)
    #expect(
      PlayerCollapseMotion.duration(style: .slide, reduceMotion: false, morphs: false)
        == ExpandedPlayerHostPresentation.slideDuration)
  }

  // MARK: - The animator

  private func dismissal(
    _ geometry: PlayerMorphGeometry?, interactive: Bool = false
  ) -> PlayerTransitionAnimator {
    let animator = PlayerTransitionAnimator(
      direction: .dismiss, style: .slide, morphGeometry: geometry)
    animator.startsInteractively = interactive
    animator.isReduceMotionEnabled = { false }
    return animator
  }

  @Test("a non-interactive dismissal with a landing relay morphs, and UIKit is given its duration")
  func animatorMorphs() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let geometry = PlayerMorphGeometry()
      Fixture.install(in: scope.window, geometry: geometry)
      let animator = dismissal(geometry)
      let context = PlayerMorphStubContext(container: scope.window)
      #expect(animator.dismissalMotion(for: context).isMorph)
      #expect(
        animator.transitionDuration(using: context) == ExpandedPlayerHostPresentation.morphDuration)
      animator.isReduceMotionEnabled = { true }
      #expect(animator.dismissalMotion(for: context) == .slide(translationY: 874))
      #expect(animator.transitionDuration(using: context) == 0.2)
    }
  }

  @Test("an interactive dismissal scrubs a slide; the morph is decided at release")
  func interactiveSlides() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let geometry = PlayerMorphGeometry()
      Fixture.install(in: scope.window, geometry: geometry)
      let byDelegate = dismissal(geometry, interactive: true)
      #expect(
        byDelegate.dismissalMotion(for: PlayerMorphStubContext(container: scope.window))
          == .slide(translationY: 874))
      let byContext = dismissal(geometry)
      #expect(
        byContext.dismissalMotion(
          for: PlayerMorphStubContext(container: scope.window, isInteractive: true))
          == .slide(translationY: 874))
    }
  }

  @Test("a relay that cannot land, or no relay at all, slides")
  func noLandingSlides() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let geometry = PlayerMorphGeometry()
      Fixture.install(in: scope.window, geometry: geometry)
      geometry.canLand = { false }
      let context = PlayerMorphStubContext(container: scope.window)
      #expect(dismissal(geometry).dismissalMotion(for: context) == .slide(translationY: 874))
      #expect(dismissal(nil).dismissalMotion(for: context) == .slide(translationY: 874))
    }
  }

  @Test("the motion is resolved once per transition, so duration and animation agree")
  func resolvedOncePerContext() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let geometry = PlayerMorphGeometry()
      Fixture.install(in: scope.window, geometry: geometry)
      let animator = dismissal(geometry)
      let context = PlayerMorphStubContext(container: scope.window)
      let first = animator.dismissalMotion(for: context)
      #expect(first.isMorph)
      // The bar goes away between the duration and the animation: the answer must not change.
      geometry.canLand = { false }
      #expect(animator.dismissalMotion(for: context) == first)
      // A new transition reads again.
      #expect(
        animator.dismissalMotion(for: PlayerMorphStubContext(container: scope.window))
          == .slide(translationY: 874))
    }
  }

  /// UIKit asks for the duration before the container has its bounds, so the motion must not be
  /// cached. A cached slide would freeze the pull-down at a distance of zero.
  @Test("the slide distance follows the container's bounds, not its size at the first query")
  func slideDistanceIsNotCached() {
    let container = UIView(frame: .zero)
    let animator = dismissal(nil, interactive: true)
    let context = PlayerMorphStubContext(container: container)
    #expect(animator.dismissalMotion(for: context) == .slide(translationY: 0))
    container.frame = Fixture.window
    #expect(animator.dismissalMotion(for: context) == .slide(translationY: 874))
  }

  @Test("the delegate marks its animator interactive only when the pull-down drives it")
  func delegateMarksInteractive() {
    final class Provider: PlayerInteractiveDismissalProviding {
      var activeInteractionController: (any UIViewControllerInteractiveTransitioning)?
    }
    let delegate = PlayerTransitioningDelegate()
    let provider = Provider()
    delegate.interactionProvider = provider

    let button = delegate.animationController(forDismissed: UIViewController())
    _ = delegate.interactionControllerForDismissal(using: button!)
    #expect((button as? PlayerTransitionAnimator)?.startsInteractively == false)

    provider.activeInteractionController = PlayerInteractiveDismissal()
    let pull = delegate.animationController(forDismissed: UIViewController())
    _ = delegate.interactionControllerForDismissal(using: pull!)
    #expect((pull as? PlayerTransitionAnimator)?.startsInteractively == true)
  }
}
