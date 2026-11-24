import UIKit

/// The shell dim behind the player. A type of its own so the morph, and tests, can find it.
final class PlayerShellDimView: UIView {}

@MainActor
final class PlayerPresentationController: UIPresentationController {
  var onDismissalEnded: ((Bool) -> Void)?

  /// Dims the shell for as long as the player covers it. Never seen while the player is at rest;
  /// it exists so the shell revealed by a pull-down brightens back as the page clears it.
  private lazy var dimmingView: PlayerShellDimView = {
    let view = PlayerShellDimView()
    view.backgroundColor = .black
    view.alpha = 0
    // The shell behind must not receive touches while the player owns the screen, but this view
    // must not swallow the pull-down either. It sits below the presented view, which takes the
    // gesture, so refusing interaction here is enough.
    view.isUserInteractionEnabled = false
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    return view
  }()

  override var frameOfPresentedViewInContainerView: CGRect {
    containerView?.bounds ?? .zero
  }

  /// Keeping the presenter mounted lets the real shell show through as the player moves away.
  override var shouldRemovePresentersView: Bool {
    false
  }

  override func containerViewWillLayoutSubviews() {
    super.containerViewWillLayoutSubviews()
    // Only the page at rest in the container: an open morph carries it in a clip of its own, in
    // that clip's coordinates.
    guard let presentedView, presentedView.superview === containerView,
      presentedView.transform == .identity
    else { return }

    // Reframing a transformed view changes the transform's basis and can make an active drag jump.
    presentedView.frame = frameOfPresentedViewInContainerView
  }

  override func presentationTransitionWillBegin() {
    super.presentationTransitionWillBegin()
    guard let containerView else { return }

    dimmingView.frame = containerView.bounds
    containerView.insertSubview(dimmingView, at: 0)

    let dimOpacity = ExpandedPlayerHostPresentation.presenterDimOpacity
    guard let coordinator = presentedViewController.transitionCoordinator else {
      dimmingView.alpha = dimOpacity
      return
    }
    coordinator.animate(alongsideTransition: { [dimmingView] _ in
      dimmingView.alpha = dimOpacity
    })
  }

  override func presentationTransitionDidEnd(_ completed: Bool) {
    super.presentationTransitionDidEnd(completed)
    if completed == false {
      dimmingView.removeFromSuperview()
    }
  }

  override func dismissalTransitionWillBegin() {
    super.dismissalTransitionWillBegin()

    // Registered alongside the transition rather than animated directly, so an interactive
    // dismissal scrubs the dim by drag progress: the shell brightens under the finger and darkens
    // again if the drag is released short of the threshold.
    guard let coordinator = presentedViewController.transitionCoordinator else {
      dimmingView.alpha = 0
      return
    }
    coordinator.animate(alongsideTransition: { [dimmingView] _ in
      dimmingView.alpha = 0
    })
  }

  override func dismissalTransitionDidEnd(_ completed: Bool) {
    super.dismissalTransitionDidEnd(completed)
    if completed {
      dimmingView.removeFromSuperview()
    } else {
      // A cancelled dismissal leaves the player covering the shell again, so the dim it started
      // with has to be restored. The alongside animation is reversed for the frames UIKit drives,
      // but the resting value is this type's to own.
      dimmingView.alpha = ExpandedPlayerHostPresentation.presenterDimOpacity
    }
    onDismissalEnded?(completed)
  }
}
