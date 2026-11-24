import UIKit

/// Drives one dismissal from the pull-down. Owns the transition instead of using
/// `UIPercentDrivenInteractiveTransition`, whose release resumes the animator's own curve and
/// visibly changes speed; here release continues the animator with a spring starting at the
/// finger's velocity. While the finger is down the animator is paused and scrubbed by fraction;
/// `scrubsLinearly` keeps that one-to-one with the drag whatever curve it was built with.
@MainActor
final class PlayerInteractiveDismissal: NSObject, UIViewControllerInteractiveTransitioning {
  /// The animated transitioning UIKit chose for this dismissal. Set by the delegate before UIKit
  /// asks this object to start, so `startInteractiveTransition` can borrow its interruptible
  /// animator rather than build a second one.
  var animatedTransitioning: (any UIViewControllerAnimatedTransitioning)?

  private var transitionContext: (any UIViewControllerContextTransitioning)?
  private var animator: UIViewPropertyAnimator?
  /// Set at release so UIKit paces the alongside animations (the shell dim) with the same
  /// remainder it gave the page. Read through the protocol's optional requirements.
  private var releaseCompletionSpeed: CGFloat = 1

  // MARK: UIViewControllerInteractiveTransitioning

  var wantsInteractiveStart: Bool { true }

  var completionSpeed: CGFloat { releaseCompletionSpeed }

  var completionCurve: UIView.AnimationCurve { .easeOut }

  func startInteractiveTransition(_ transitionContext: any UIViewControllerContextTransitioning) {
    self.transitionContext = transitionContext
    guard
      let propertyAnimator = animatedTransitioning?.interruptibleAnimator?(using: transitionContext)
        as? UIViewPropertyAnimator
    else {
      // Without an animator to scrub there is nothing to drive; end the transition where it began.
      transitionContext.cancelInteractiveTransition()
      transitionContext.completeTransition(false)
      return
    }
    propertyAnimator.scrubsLinearly = true
    // `pauseAnimation` on an inactive animator activates it without starting it, which is what
    // lets `fractionComplete` be written before any frame is drawn.
    propertyAnimator.pauseAnimation()
    propertyAnimator.fractionComplete = 0
    animator = propertyAnimator
    transitionContext.updateInteractiveTransition(0)
    // Builds the glass now, while the drag is barely under way, rather than at release.
    (animatedTransitioning as? PlayerTransitionAnimator)?
      .prepareMorphPanel(using: transitionContext)
  }

  // MARK: Driving

  func update(_ progress: CGFloat) {
    guard let animator, let transitionContext else { return }
    animator.fractionComplete = progress
    transitionContext.updateInteractiveTransition(progress)
  }

  /// Completes the dismissal from the current fraction. `initialVelocity` is in the spring's
  /// normalised units (whole remaining travel per second), positive toward the end state.
  /// `releaseVelocityY` is the finger's own speed in points per second, which a collapse into the
  /// mini player normalises against its own travel.
  func finish(duration: TimeInterval, initialVelocity: CGFloat, releaseVelocityY: CGFloat = 0) {
    guard let animator, let transitionContext else { return }
    if let morphing = animatedTransitioning as? PlayerTransitionAnimator,
      let snapshot = morphing.releaseMorphGeometry()
    {
      handOver(
        to: morphing, snapshot: snapshot, animator: animator, context: transitionContext,
        releaseVelocityY: releaseVelocityY)
      return
    }
    continueToEnd(reversed: false, duration: duration, initialVelocity: initialVelocity)
  }

  /// Sets the completion speed so the shell dim ends with the morph, tells UIKit the transition is
  /// finishing, then freezes the slide and lets the morph carry it.
  private func handOver(
    to morphing: PlayerTransitionAnimator,
    snapshot: PlayerMorphGeometry.Snapshot,
    animator: UIViewPropertyAnimator,
    context: any UIViewControllerContextTransitioning,
    releaseVelocityY: CGFloat
  ) {
    defer {
      self.animator = nil
      self.transitionContext = nil
    }
    releaseCompletionSpeed = PlayerMorphTiming.releaseCompletionSpeed(
      progress: animator.fractionComplete,
      transitionDuration: animator.duration,
      morphDuration: PlayerMorphTiming.spring(afterRelease: true).duration)
    context.finishInteractiveTransition()
    morphing.handOverToMorph(
      snapshot, frozenSlide: animator, using: context, releaseVelocityY: releaseVelocityY)
  }

  /// Returns the page to rest from the current fraction. `initialVelocity` has the same units as
  /// for `finish`, positive toward the resting state.
  func cancel(duration: TimeInterval, initialVelocity: CGFloat) {
    continueToEnd(reversed: true, duration: duration, initialVelocity: initialVelocity)
  }

  private func continueToEnd(reversed: Bool, duration: TimeInterval, initialVelocity: CGFloat) {
    guard let animator, let transitionContext else { return }
    (animatedTransitioning as? PlayerTransitionAnimator)?.discardPreparedMorphPanel()
    defer {
      self.animator = nil
      self.transitionContext = nil
    }

    let baseDuration = animator.duration
    let safeDuration = duration.isFinite && duration > 0 ? duration : baseDuration
    if baseDuration.isFinite, baseDuration > 0 {
      releaseCompletionSpeed = baseDuration / safeDuration
    }

    animator.isReversed = reversed
    if reversed {
      transitionContext.cancelInteractiveTransition()
    } else {
      transitionContext.finishInteractiveTransition()
    }

    // The spring is fitted to the remaining duration, so `durationFactor` carries the policy's
    // timing and the velocity only shapes how the remainder starts. A unit damping ratio keeps
    // the page from overshooting the shell edge on finish or its own top edge on cancel.
    let spring = UISpringTimingParameters(
      dampingRatio: 1, initialVelocity: CGVector(dx: 0, dy: initialVelocity))
    let durationFactor = baseDuration > 0 ? CGFloat(safeDuration / baseDuration) : 0
    animator.continueAnimation(withTimingParameters: spring, durationFactor: durationFactor)
  }
}

/// The seam the interactive pan controller plugs into.
@MainActor
protocol PlayerInteractiveDismissalProviding: AnyObject {
  /// The live percent-driven controller while a dismissal pan is in flight, otherwise `nil`.
  var activeInteractionController: (any UIViewControllerInteractiveTransitioning)? { get }
}

@MainActor
protocol PlayerDismissalAnimatorProviding: AnyObject {
  func setDismissalAnimator(_ animator: any UIViewControllerAnimatedTransitioning)
}

/// Owns the pull-down recognizer on the presented player and drives the dismissal animator
/// interactively. Nothing inside the player observes progress: the only thing that moves is the
/// presented root view's transform, which the animator owns.
@MainActor
final class PlayerDismissInteractor: NSObject, PlayerInteractiveDismissalProviding,
  UIGestureRecognizerDelegate, PlayerDismissalAnimatorProviding
{
  /// Asks the presentation coordinator to begin an interactive dismissal. It returns `false`
  /// when a transition is already in flight, which this type must treat as a refusal.
  private let requestDismissal: () -> Bool

  private weak var host: UIViewController?
  private weak var registeredScrollView: UIScrollView?
  private var panRecognizer: UIPanGestureRecognizer?
  private var interactionController: PlayerInteractiveDismissal?
  private var capturedContainerHeight: CGFloat?
  private var currentProgress: CGFloat = 0

  init(requestDismissal: @escaping () -> Bool) {
    self.requestDismissal = requestDismissal
    super.init()
  }

  var activeInteractionController: (any UIViewControllerInteractiveTransitioning)? {
    interactionController
  }

  func attach(to host: UIViewController) {
    guard panRecognizer == nil else { return }

    self.host = host

    let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    panRecognizer.cancelsTouchesInView = false
    panRecognizer.delegate = self
    host.view.addGestureRecognizer(panRecognizer)
    self.panRecognizer = panRecognizer

    // Layout can materialize SwiftUI's public scroll view after attachment, so make one deferred
    // discovery attempt while still avoiding a hierarchy scan for every gesture event.
    host.view.layoutIfNeeded()
    registerScrollViewIfNeeded(in: host.view)
    guard registeredScrollView == nil else { return }

    Task { @MainActor [weak self, weak host] in
      await Task.yield()
      guard let self, let host, self.host === host, self.registeredScrollView == nil else {
        return
      }
      host.view.layoutIfNeeded()
      self.registerScrollViewIfNeeded(in: host.view)
    }
  }

  func setDismissalAnimator(_ animator: any UIViewControllerAnimatedTransitioning) {
    interactionController?.animatedTransitioning = animator
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard
      gestureRecognizer === panRecognizer,
      let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer,
      let host
    else { return false }

    guard
      interactionController == nil,
      !host.isBeingDismissed,
      host.presentedViewController == nil,
      PlayerDismissalPolicy.shouldBegin(velocity: panRecognizer.velocity(in: host.view))
    else { return false }

    // Discovery runs at attachment and once more after layout, but a hosted hierarchy that is
    // still assembling can outlive both. Retrying here (only while the reference is nil, and only
    // as a gesture begins rather than per event) keeps the top-boundary gate from silently
    // degrading to "always eligible", which would let a mid-content drag dismiss the player.
    if registeredScrollView == nil {
      registerScrollViewIfNeeded(in: host.view)
    }

    // The scroll view under the finger decides, so a drag on a scrolled inline queue scrolls it
    // instead of dismissing; a drag elsewhere keeps the page scroll view's boundary.
    let gate = Self.gatingScrollView(
      at: panRecognizer.location(in: host.view), in: host.view, fallback: registeredScrollView)
    guard let scrollView = gate else { return true }
    return PlayerDismissalPolicy.isAtScrollTop(
      contentOffsetY: scrollView.contentOffset.y,
      adjustedContentInsetTop: scrollView.adjustedContentInset.top)
  }

  /// The scroll view waits for this recognizer: upward and horizontal movement fails this pan
  /// immediately, leaving ordinary scrolling and scrubbing to their existing recognizers.
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    guard
      gestureRecognizer === panRecognizer,
      let host,
      let scrollView = otherGestureRecognizer.view as? UIScrollView,
      otherGestureRecognizer === scrollView.panGestureRecognizer
    else { return false }
    // Every scroll view in the page, not only the registered one: the inline queue is a second.
    return scrollView === registeredScrollView || scrollView.isDescendant(of: host.view)
  }

  /// The scroll view whose top boundary gates a pull-down that starts at `point`: the nearest one
  /// containing the touched view, else `fallback` (the page scroll view) for a touch on the chrome.
  static func gatingScrollView(
    at point: CGPoint, in rootView: UIView, fallback: UIScrollView?
  ) -> UIScrollView? {
    var view = rootView.hitTest(point, with: nil)
    while let current = view {
      if let scrollView = current as? UIScrollView { return scrollView }
      guard current !== rootView else { break }
      view = current.superview
    }
    return fallback
  }

  /// Dismissal and scrolling must remain mutually exclusive so a downward drag cannot move both
  /// the presented root and the player's content at once.
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    false
  }

  @objc
  private func handlePan(_ panRecognizer: UIPanGestureRecognizer) {
    guard let host else {
      cancelInteraction()
      return
    }

    switch panRecognizer.state {
    case .began:
      guard interactionController == nil else { return }

      // The interactive progress is normalized to this geometry; retaining it prevents a bounds
      // change from making the same finger translation scrub against a different page height.
      capturedContainerHeight = host.view.bounds.height
      currentProgress = 0

      let interactionController = PlayerInteractiveDismissal()
      self.interactionController = interactionController
      guard requestDismissal() else {
        // The controller has to exist before the request, because UIKit reads it synchronously
        // inside `dismiss(animated:)`. So a refused request must clear it again: a retained
        // controller would be handed to the next dismissal, which would then run interactively
        // with no gesture driving it and park mid-transition.
        clearInteraction()
        return
      }

    case .changed:
      guard
        let interactionController,
        let capturedContainerHeight,
        host.view.bounds.height == capturedContainerHeight
      else {
        cancelInteraction()
        return
      }

      currentProgress = PlayerDismissalPolicy.progress(
        translationY: panRecognizer.translation(in: host.view).y,
        containerHeight: capturedContainerHeight)
      interactionController.update(currentProgress)

    case .ended:
      guard
        let interactionController,
        let capturedContainerHeight,
        host.view.bounds.height == capturedContainerHeight
      else {
        cancelInteraction()
        return
      }

      let velocityY = panRecognizer.velocity(in: host.view).y
      let completion = PlayerDismissalPolicy.completion(
        progress: currentProgress,
        velocityY: velocityY,
        containerHeight: capturedContainerHeight)
      let desiredDuration = PlayerDismissalPolicy.completionDuration(
        progress: currentProgress,
        velocityY: velocityY,
        containerHeight: capturedContainerHeight,
        completion: completion)
      let initialVelocity = PlayerDismissalPolicy.releaseVelocity(
        progress: currentProgress,
        velocityY: velocityY,
        containerHeight: capturedContainerHeight,
        completion: completion)

      switch completion {
      case .finish:
        interactionController.finish(
          duration: desiredDuration, initialVelocity: initialVelocity,
          releaseVelocityY: velocityY)
      case .cancel:
        interactionController.cancel(duration: desiredDuration, initialVelocity: initialVelocity)
      }
      clearInteraction()

    case .cancelled, .failed:
      cancelInteraction()

    default:
      break
    }
  }

  private func registerScrollViewIfNeeded(in rootView: UIView) {
    guard registeredScrollView == nil else { return }

    var views = [rootView]
    var nextIndex = 0
    while nextIndex < views.count {
      let view = views[nextIndex]
      nextIndex += 1

      if let scrollView = view as? UIScrollView {
        registeredScrollView = scrollView
        return
      }
      views.append(contentsOf: view.subviews)
    }
  }

  private func cancelInteraction() {
    // A system cancellation carries no release velocity; return at the policy's shortest pace.
    interactionController?.cancel(
      duration: PlayerDismissalPolicy.completionDuration(
        progress: currentProgress, velocityY: 0, containerHeight: capturedContainerHeight ?? 0,
        completion: .cancel),
      initialVelocity: 0)
    clearInteraction()
  }

  private func clearInteraction() {
    interactionController = nil
    capturedContainerHeight = nil
    currentProgress = 0
  }
}
