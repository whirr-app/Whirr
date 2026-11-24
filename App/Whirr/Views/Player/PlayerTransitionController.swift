import AppModel
import SwiftUI
import UIKit

@MainActor
final class PlayerHostingController<Content: View>: UIHostingController<Content> {
  /// The polarity of the page this host shows, and so of every system surface it raises (sheets,
  /// menus, alerts, their Liquid Glass, the status bar). Set as a UIKit trait at the presentation
  /// boundary, as none of those sit in the page's SwiftUI environment. It follows the artwork's
  /// polarity, not the device's: a fixed `.dark` would raise a dark menu over black ink, and the
  /// device appearance would give a dark-pole cover under Light a white sheet.
  var chromeColorScheme: ColorScheme {
    didSet {
      guard chromeColorScheme != oldValue else { return }
      overrideUserInterfaceStyle = Self.interfaceStyle(for: chromeColorScheme)
      // `preferredStatusBarStyle` is answered by this controller (`childForStatusBarStyle` is nil)
      // and read only when UIKit is told to ask again.
      setNeedsStatusBarAppearanceUpdate()
    }
  }

  init(rootView: Content, chromeColorScheme: ColorScheme) {
    self.chromeColorScheme = chromeColorScheme
    super.init(rootView: rootView)
    modalPresentationStyle = .custom
    modalPresentationCapturesStatusBarAppearance = true
    overrideUserInterfaceStyle = Self.interfaceStyle(for: chromeColorScheme)
    // The page has no text input (its only search field is in the chapters sheet, a separate
    // presentation with its own host), so keyboard avoidance here can only do harm. A
    // keyboard-hide notification resolved against this host mid-transition can leave the keyboard
    // inset stuck until relaunch: the page then lays out against a ~340pt phantom inset (cover
    // cropped, chrome in the top half).
    safeAreaRegions = .container
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("PlayerHostingController does not support NSCoder initialization")
  }

  private static func interfaceStyle(for scheme: ColorScheme) -> UIUserInterfaceStyle {
    scheme == .dark ? .dark : .light
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // The player supplies its own opaque canvas. A host backing would show as a slab while the
    // root view is translated during dismissal. Set here, not in `init`, which would force the
    // hosting view to load before the controller is presented.
    view.backgroundColor = .clear
  }

  /// The page runs edge to edge through the status-bar region, so the clock and indicators are
  /// ink on the page's own colour and take its polarity.
  override var preferredStatusBarStyle: UIStatusBarStyle {
    chromeColorScheme == .dark ? .lightContent : .darkContent
  }

  override var childForStatusBarStyle: UIViewController? {
    nil
  }

  override var prefersHomeIndicatorAutoHidden: Bool {
    false
  }
}

@MainActor
final class PlayerTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  enum Direction {
    case present
    case dismiss
  }

  let direction: Direction
  /// The shape of a dismissal. Presentation ignores it. An interactive dismissal is always a slide
  /// (the interactor scrubs a translation); only the coordinator's non-interactive dismiss can
  /// set a dissolve.
  let style: NavigationModel.PlayerCollapseStyle
  /// The shell's relay for the mini player's geometry, if it supplied one. Read when an open or
  /// a dismissal starts; see `PlayerMorphGeometry`.
  private(set) weak var morphGeometry: PlayerMorphGeometry?
  /// Set by the delegate when UIKit pairs this animator with the pull-down's interaction
  /// controller. An interactive dismissal scrubs a slide and decides on a morph only at release,
  /// so it never resolves one up front.
  var startsInteractively = false

  private var cachedAnimator: UIViewPropertyAnimator?
  private var cachedContextIdentifier: ObjectIdentifier?
  /// The relay's answer for this transition, read once. Only the geometry is kept: UIKit asks for
  /// the duration before the container has its final bounds, so the slide distance is resolved
  /// each time.
  private var resolvedGeometry: (context: ObjectIdentifier, snapshot: PlayerMorphGeometry.Snapshot?)?
  /// The collapse into the mini player while it runs. It owns `completeTransition(true)`.
  private var activeMorph: PlayerMorphTransition?
  /// The open out of the mini player while it runs. It owns `completeTransition(true)`.
  private var activeOpenMorph: PlayerOpenMorphTransition?
  /// Set when a frozen interactive slide hands over to the morph, so the slide's own completion
  /// can never complete the transition as well.
  private(set) var handedOverToMorph = false
  /// The collapse's veil, built transparent when a pull-down begins so the release does not pay
  /// for it. Handed to the morph at release, or removed when the drag ends any other way.
  private(set) var preparedPanel: PlayerMorphPanelView?

  /// Read for every decision this animator makes; a seam so tests can turn it on.
  var isReduceMotionEnabled: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
  /// Where the flying cover's image comes from.
  var artwork: any PreparedArtworkCaching = PreparedArtworkCache.shared

  init(
    direction: Direction, style: NavigationModel.PlayerCollapseStyle = .slide,
    morphGeometry: PlayerMorphGeometry? = nil
  ) {
    self.direction = direction
    self.style = style
    self.morphGeometry = morphGeometry
    super.init()
  }

  func transitionDuration(
    using transitionContext: (any UIViewControllerContextTransitioning)?
  ) -> TimeInterval {
    let reduceMotion = isReduceMotionEnabled()
    switch direction {
    case .present:
      if reduceMotion {
        return 0.2
      }
      if let transitionContext, case .morph = presentationMotion(for: transitionContext) {
        return ExpandedPlayerHostPresentation.morphOpenDuration
      }
      return 0.42
    case .dismiss:
      let morphs = transitionContext.map { dismissalMotion(for: $0).isMorph } ?? false
      return PlayerCollapseMotion.duration(
        style: style, reduceMotion: reduceMotion, morphs: morphs)
    }
  }

  /// The shape of this dismissal. UIKit asks for the duration (to time the shell dim) before the
  /// animation, and both must describe the same motion, so whether it morphs is decided by one
  /// read of the relay per transition context.
  func dismissalMotion(
    for transitionContext: any UIViewControllerContextTransitioning
  ) -> PlayerCollapseMotion {
    let identifier = ObjectIdentifier(transitionContext)
    let snapshot: PlayerMorphGeometry.Snapshot?
    if let resolvedGeometry, resolvedGeometry.context == identifier {
      snapshot = resolvedGeometry.snapshot
    } else {
      let interactive = startsInteractively || transitionContext.isInteractive
      snapshot = interactive ? nil : morphGeometry?.snapshot()
      resolvedGeometry = (identifier, snapshot)
    }
    return PlayerCollapseMotion.resolve(
      style: style,
      containerHeight: transitionContext.containerView.bounds.height,
      reduceMotion: isReduceMotionEnabled(),
      geometry: snapshot)
  }

  /// The shape of this open, decided by one read of the relay per transition context (see
  /// `dismissalMotion(for:)`). It rests on the bar alone: the page has not entered a window yet,
  /// so its cover is measured later, once laid out.
  func presentationMotion(
    for transitionContext: any UIViewControllerContextTransitioning
  ) -> PlayerOpenMotion {
    guard direction == .present, isReduceMotionEnabled() == false else { return .slide }
    let identifier = ObjectIdentifier(transitionContext)
    let snapshot: PlayerMorphGeometry.Snapshot?
    if let resolvedGeometry, resolvedGeometry.context == identifier {
      snapshot = resolvedGeometry.snapshot
    } else {
      snapshot = morphGeometry?.snapshot()
      resolvedGeometry = (identifier, snapshot)
    }
    return snapshot.map(PlayerOpenMotion.morph) ?? .slide
  }

  func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
    if direction == .present, case .morph(let snapshot) = presentationMotion(for: transitionContext),
      let toController = transitionContext.viewController(forKey: .to),
      let toView = toController.view
    {
      let morph = PlayerOpenMorphTransition(
        snapshot: snapshot, geometry: morphGeometry, artwork: artwork)
      activeOpenMorph = morph
      morph.run(
        page: toView, finalFrame: transitionContext.finalFrame(for: toController),
        in: transitionContext.containerView
      ) { [weak self] in
        self?.activeOpenMorph = nil
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
      }
      return
    }
    if direction == .dismiss, case .morph(let snapshot) = dismissalMotion(for: transitionContext),
      let fromView = transitionContext.viewController(forKey: .from)?.view
    {
      // A non-interactive morph has no slide to build: it starts from the page at rest.
      Self.applyInMotionCorners(to: fromView)
      runMorph(
        snapshot, page: fromView, using: transitionContext, afterRelease: false,
        releaseVelocityY: 0)
      return
    }
    interruptibleAnimator(using: transitionContext).startAnimation()
  }

  // MARK: Collapsing into the mini player

  /// The geometry for a morph at the moment a pull-down is released past the threshold, or `nil`
  /// when the slide should simply continue. Read now, not when the pan began: the bar can have
  /// gone in between.
  func releaseMorphGeometry() -> PlayerMorphGeometry.Snapshot? {
    guard direction == .dismiss, style == .slide, isReduceMotionEnabled() == false else {
      return nil
    }
    return morphGeometry?.snapshot()
  }

  /// Builds the collapse's panel, transparent, under the page while the finger is still down.
  /// Only when a release could morph, so a pull-down that can never morph pays nothing.
  func prepareMorphPanel(using transitionContext: any UIViewControllerContextTransitioning) {
    guard preparedPanel == nil, direction == .dismiss, style == .slide,
      isReduceMotionEnabled() == false, morphGeometry != nil,
      let page = transitionContext.viewController(forKey: .from)?.view,
      page.superview === transitionContext.containerView
    else { return }
    let panel = PlayerMorphPanelView.make(.veil)
    panel.alpha = 0
    panel.frame = page.frame
    transitionContext.containerView.insertSubview(panel, belowSubview: page)
    panel.layoutIfNeeded()
    if let morphGeometry, let bar = morphGeometry.snapshot()?.bar {
      panel.barLabelImage = morphGeometry.barLabelImage(
        size: bar.size, scale: page.traitCollection.displayScale)
    }
    preparedPanel = panel
  }

  /// Removes a panel the release did not use: a cancel, or a release that continued the slide.
  func discardPreparedMorphPanel() {
    preparedPanel?.removeFromSuperview()
    preparedPanel = nil
  }

  /// Takes over a released interactive dismissal. The caller has already called
  /// `finishInteractiveTransition()`. `stopAnimation(true)` freezes the slide where the finger
  /// left it without running its completion, so the page's model transform is what is on screen
  /// and the morph starts from there.
  func handOverToMorph(
    _ snapshot: PlayerMorphGeometry.Snapshot,
    frozenSlide: UIViewPropertyAnimator,
    using transitionContext: any UIViewControllerContextTransitioning,
    releaseVelocityY: CGFloat
  ) {
    handedOverToMorph = true
    frozenSlide.stopAnimation(true)
    guard let fromView = transitionContext.viewController(forKey: .from)?.view else {
      transitionContext.completeTransition(true)
      return
    }
    // Stopped, the page is where the finger left it; paused, it reported the slide's end. Only
    // now can the page's cover be measured for the flight.
    let measured = morphGeometry?.snapshot() ?? snapshot
    runMorph(
      measured, page: fromView, using: transitionContext, afterRelease: true,
      releaseVelocityY: releaseVelocityY)
  }

  private func runMorph(
    _ snapshot: PlayerMorphGeometry.Snapshot,
    page: UIView,
    using transitionContext: any UIViewControllerContextTransitioning,
    afterRelease: Bool,
    releaseVelocityY: CGFloat
  ) {
    let morph = PlayerMorphTransition(
      snapshot: snapshot, geometry: morphGeometry, artwork: artwork, afterRelease: afterRelease,
      releaseVelocityY: releaseVelocityY, preparedPanel: preparedPanel)
    preparedPanel = nil
    activeMorph = morph
    morph.run(page: page, in: transitionContext.containerView) { [weak self] in
      // Same end state as the slide's completion, so shell cleanup runs once.
      page.removeFromSuperview()
      self?.activeMorph = nil
      transitionContext.completeTransition(true)
    }
  }

  func interruptibleAnimator(
    using transitionContext: any UIViewControllerContextTransitioning
  ) -> any UIViewImplicitlyAnimating {
    let contextIdentifier = ObjectIdentifier(transitionContext)
    if let cachedAnimator, cachedContextIdentifier == contextIdentifier {
      return cachedAnimator
    }

    let animator = makeAnimator(using: transitionContext)
    cachedAnimator = animator
    cachedContextIdentifier = contextIdentifier
    return animator
  }

  func animationEnded(_ transitionCompleted: Bool) {
    discardPreparedMorphPanel()
    cachedAnimator = nil
    cachedContextIdentifier = nil
    resolvedGeometry = nil
  }

  private func makeAnimator(
    using transitionContext: any UIViewControllerContextTransitioning
  ) -> UIViewPropertyAnimator {
    let duration = transitionDuration(using: transitionContext)
    let animator: UIViewPropertyAnimator

    if isReduceMotionEnabled() {
      animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut)
    } else {
      switch direction {
      case .present:
        // A unit damping ratio preserves a smooth motion curve without spring overshoot.
        animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 1)
      case .dismiss:
        // Not the presentation's spring. A duration-fitted critically damped spring spends about
        // nine tenths of its travel in the first two fifths of its time and then idles, so a
        // full-screen slide looks yanked and then hangs at the bottom edge. The cubic eases in
        // briefly and eases out over a tail long enough to watch. An interactive dismissal never
        // plays this curve: the drag scrubs linearly and the release supplies its own spring.
        animator = UIViewPropertyAnimator(
          duration: duration,
          timingParameters: UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.3, y: 0), controlPoint2: CGPoint(x: 0.2, y: 1)))
      }
    }

    switch direction {
    case .present:
      // UIKit asks for this animator during a morph open too, to carry animations such as the
      // shell dim. The morph poses, shows and completes the page itself; the slide setup would
      // park the page a screen height down until the morph ended.
      if case .morph = presentationMotion(for: transitionContext) { break }
      configurePresentation(animator, using: transitionContext)
    case .dismiss:
      configureDismissal(animator, using: transitionContext)
    }

    return animator
  }

  private func configurePresentation(
    _ animator: UIViewPropertyAnimator,
    using transitionContext: any UIViewControllerContextTransitioning
  ) {
    guard
      let toController = transitionContext.viewController(forKey: .to),
      let toView = toController.view
    else {
      // UIKit may hand us a context without a destination; fail the transition rather than trap.
      animator.addCompletion { _ in transitionContext.completeTransition(false) }
      return
    }

    let containerView = transitionContext.containerView
    containerView.addSubview(toView)
    toView.alpha = 1
    toView.frame = transitionContext.finalFrame(for: toController)
    toView.transform = CGAffineTransform(translationX: 0, y: containerView.bounds.height)
    Self.applyInMotionCorners(to: toView)

    animator.addAnimations {
      toView.transform = .identity
    }
    animator.addCompletion { _ in
      Self.clearInMotionCorners(on: toView)
      if transitionContext.transitionWasCancelled {
        toView.removeFromSuperview()
      }
      transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
    }
  }

  private func configureDismissal(
    _ animator: UIViewPropertyAnimator,
    using transitionContext: any UIViewControllerContextTransitioning
  ) {
    guard
      let fromController = transitionContext.viewController(forKey: .from),
      let fromView = fromController.view
    else {
      // A context with no source view fails the transition rather than trapping.
      animator.addCompletion { _ in transitionContext.completeTransition(false) }
      return
    }

    let containerView = transitionContext.containerView
    let motion = dismissalMotion(for: transitionContext)
    // Outside the animation block: an interactive dismissal scrubs everything inside it by drag
    // progress, leaving corners square for the first hundred points of the pull, when they are
    // most visible. A dissolving page keeps them too: square corners read as a shrinking
    // screenshot against the shell.
    Self.applyInMotionCorners(to: fromView)

    animator.addAnimations {
      switch motion {
      case .slide(let translationY):
        fromView.transform = CGAffineTransform(translationX: 0, y: translationY)
      case .dissolve(let alpha, let scale):
        fromView.alpha = alpha
        fromView.transform = CGAffineTransform(scaleX: scale, y: scale)
      case .morph:
        // A morph runs from `animateTransition` and never asks for this animator. If UIKit asks
        // anyway, the page leaves as it would without a bar.
        fromView.transform = CGAffineTransform(translationX: 0, y: containerView.bounds.height)
      }
    }
    animator.addCompletion { [weak self] _ in
      // A slide frozen for the morph is finished by the morph.
      if self?.handedOverToMorph == true { return }
      if transitionContext.transitionWasCancelled {
        fromView.transform = .identity
        fromView.alpha = 1
        // The page is flush with the screen again by the time this runs, so the corners are back
        // under the bezel's own clipping and squaring them here is not visible.
        Self.clearInMotionCorners(on: fromView)
      } else {
        fromView.removeFromSuperview()
      }
      transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
    }
  }

  /// The page carries rounded corners only while moving (`inMotionCornerRadius` says why;
  /// `PlayerDisplayCornerRadius` gives the radius). Also rasterised only while moving: masking a
  /// layer whose subtree has the cover's blurred shadow forces an offscreen pass per frame, while
  /// a rasterised bitmap takes the animated transform and alpha, redrawn once per mid-transition
  /// content change (a progress tick under a slow drag), not per frame.
  private static func applyInMotionCorners(to view: UIView) {
    view.layer.cornerRadius = PlayerDisplayCornerRadius.shared.radius(for: view.window)
    view.layer.cornerCurve = .continuous
    view.layer.masksToBounds = true
    view.layer.rasterizationScale = view.traitCollection.displayScale
    view.layer.shouldRasterize = true
  }

  private static func clearInMotionCorners(on view: UIView) {
    view.layer.cornerRadius = 0
    view.layer.masksToBounds = false
    view.layer.shouldRasterize = false
  }
}

@MainActor
final class PlayerTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
  weak var interactionProvider: (any PlayerInteractiveDismissalProviding)?
  private(set) var dismissAnimator: PlayerTransitionAnimator?
  var onDismissalEnded: ((Bool) -> Void)?
  /// The shape of the next dismissal. The coordinator sets it just before its own non-interactive
  /// `dismiss` and resets it when that ends. The interactive path never writes it, so a pull-down
  /// is a slide whatever the model last recorded.
  var dismissStyle: NavigationModel.PlayerCollapseStyle = .slide
  /// Handed to every animator. Weak because the shell owns it.
  weak var morphGeometry: PlayerMorphGeometry?
  /// Where animators find the flying cover's image.
  var artwork: any PreparedArtworkCaching = PreparedArtworkCache.shared
  /// Handed to every animator; a seam so tests can turn Reduce Motion on.
  var isReduceMotionEnabled: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

  func presentationController(
    forPresented presented: UIViewController,
    presenting: UIViewController?,
    source: UIViewController
  ) -> UIPresentationController? {
    let controller = PlayerPresentationController(
      presentedViewController: presented,
      presenting: presenting)
    controller.onDismissalEnded = { [weak self] completed in
      self?.onDismissalEnded?(completed)
    }
    return controller
  }

  func animationController(
    forPresented presented: UIViewController,
    presenting: UIViewController,
    source: UIViewController
  ) -> (any UIViewControllerAnimatedTransitioning)? {
    let animator = PlayerTransitionAnimator(direction: .present, morphGeometry: morphGeometry)
    animator.artwork = artwork
    animator.isReduceMotionEnabled = isReduceMotionEnabled
    return animator
  }

  func animationController(
    forDismissed dismissed: UIViewController
  ) -> (any UIViewControllerAnimatedTransitioning)? {
    let animator = PlayerTransitionAnimator(
      direction: .dismiss, style: dismissStyle, morphGeometry: morphGeometry)
    animator.artwork = artwork
    animator.isReduceMotionEnabled = isReduceMotionEnabled
    dismissAnimator = animator
    return animator
  }

  func interactionControllerForDismissal(
    using animator: any UIViewControllerAnimatedTransitioning
  ) -> (any UIViewControllerInteractiveTransitioning)? {
    if let animatorProvider = interactionProvider as? any PlayerDismissalAnimatorProviding {
      animatorProvider.setDismissalAnimator(animator)
    }
    let interactionController = interactionProvider?.activeInteractionController
    (animator as? PlayerTransitionAnimator)?.startsInteractively = interactionController != nil
    return interactionController
  }
}
