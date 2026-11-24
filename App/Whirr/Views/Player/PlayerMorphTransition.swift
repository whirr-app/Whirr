import ABSApi
import SwiftUI
import UIKit

/// The numbers behind a collapse into the mini player, kept pure so they are testable without a
/// transition.
enum PlayerMorphTiming {
  struct Spring: Equatable {
    let duration: TimeInterval
    let dampingRatio: CGFloat
  }

  /// A button close lands critically damped; a drag release is a little quicker and a little
  /// looser, so it reads as thrown.
  static func spring(afterRelease: Bool) -> Spring {
    afterRelease
      ? Spring(
        duration: ExpandedPlayerHostPresentation.morphReleaseDuration,
        dampingRatio: ExpandedPlayerHostPresentation.morphReleaseDampingRatio)
      : Spring(duration: ExpandedPlayerHostPresentation.morphDuration, dampingRatio: 1)
  }

  /// The spring the flying cover's position lands on: the panel's, loosened to
  /// `morphCoverDampingRatio` so the cover dips past its place in the bar and returns.
  static func coverSpring(for spring: Spring) -> Spring {
    Spring(
      duration: spring.duration,
      dampingRatio: min(spring.dampingRatio, ExpandedPlayerHostPresentation.morphCoverDampingRatio))
  }

  /// A spring by its physics, for unit mass.
  struct SpringPhysics: Equatable {
    let stiffness: CGFloat
    let damping: CGFloat
  }

  /// `spring` as physics: the stiffness at which its oscillation has decayed to a thousandth by
  /// `duration`. The flight is driven by these, not by a duration. A spring given a duration is
  /// cut off there, and a hard fling's velocity leaves it well short of rest at that point, so
  /// the cover would jump the remainder; one given its physics runs until it has settled.
  static func physics(for spring: Spring) -> SpringPhysics {
    let frequency = log(1000) / (spring.dampingRatio * spring.duration)
    return SpringPhysics(
      stiffness: frequency * frequency, damping: 2 * spring.dampingRatio * frequency)
  }

  struct Lag: Equatable {
    let delay: TimeInterval
    let duration: TimeInterval
  }

  /// When the panel's height runs: it starts after the top edge and ends with it.
  static func heightLag(for spring: Spring) -> Lag {
    let delay = spring.duration * ExpandedPlayerHostPresentation.morphHeightLagFraction
    return Lag(delay: delay, duration: spring.duration - delay)
  }

  /// The finger's vertical speed as the spring's normalised velocity: the share of the panel's
  /// own vertical travel per second. Only downward speed carries over, and it is capped.
  static func initialVelocity(velocityY: CGFloat, travel: CGFloat) -> CGFloat {
    guard velocityY.isFinite, travel.isFinite, travel > 0, velocityY > 0 else { return 0 }
    return min(velocityY / travel, ExpandedPlayerHostPresentation.morphVelocityCap)
  }

  /// The completion speed that makes UIKit's remaining alongside animations (the shell dim) end
  /// with the morph. After `finishInteractiveTransition()` UIKit plays the last `1 − progress` of
  /// a transition `transitionDuration` long at this speed, so the remainder takes
  /// `(1 − progress) × transitionDuration / speed`, which must equal `morphDuration`.
  static func releaseCompletionSpeed(
    progress: CGFloat, transitionDuration: TimeInterval, morphDuration: TimeInterval
  ) -> CGFloat {
    guard progress.isFinite, transitionDuration.isFinite, transitionDuration > 0,
      morphDuration.isFinite, morphDuration > 0
    else { return 1 }
    let remaining = 1 - min(max(progress, 0), 1)
    // A release at the very end leaves nothing for the dim to do; any positive speed is right,
    // and UIKit must not be handed zero.
    return max(remaining * CGFloat(transitionDuration / morphDuration), 0.05)
  }
}

/// The panel the page is folded into, or grows out of. A type of its own so teardown, and tests,
/// can tell it from anything else in the transition container.
final class PlayerMorphPanelView: UIVisualEffectView {
  enum Material: Equatable {
    /// Liquid Glass, for an open: it grows out of the bar over the content behind it.
    case glass
    /// A flat tint with no material, for a collapse: it lands on the bar's own glass and is laid
    /// over the tab bar's on the way. Glass on glass composites milkier than either, so a glass
    /// panel turns opaque in flight and clears only as it is taken away; a tint adds only itself.
    case veil
  }

  private(set) var material: Material = .glass

  /// The bar's label, rendered when a pull-down built this panel so the release does not pay for
  /// that either.
  var barLabelImage: UIImage?

  /// A panel ready to be posed. A pull-down builds it when the drag begins rather than at
  /// release, and holds it at zero alpha: unhiding glass walks its whole subtree, which the
  /// release frame cannot spare.
  static func make(_ material: Material) -> PlayerMorphPanelView {
    let panel: PlayerMorphPanelView
    switch material {
    case .glass:
      panel = PlayerMorphPanelView(effect: UIGlassEffect(style: .regular))
    case .veil:
      panel = PlayerMorphPanelView(effect: nil)
      // Without a glass effect nothing else shapes the panel to its corners.
      panel.clipsToBounds = true
      panel.contentView.backgroundColor = ExpandedPlayerHostPresentation.morphCloseVeilColor
    }
    panel.material = material
    panel.isUserInteractionEnabled = false
    return panel
  }
}

/// The copy of the cover that flies from the page to the bar. It carries the bar cover's hairline
/// rim, faded in over the flight so the rim does not pop on at landing.
final class PlayerMorphCoverView: UIImageView {
  let rim = UIView()

  override init(image: UIImage?) {
    super.init(image: image)
    contentMode = .scaleAspectFill
    clipsToBounds = true
    isUserInteractionEnabled = false
    layer.cornerCurve = .continuous
    rim.alpha = 0
    rim.frame = bounds
    rim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    rim.isUserInteractionEnabled = false
    rim.layer.cornerCurve = .continuous
    rim.layer.borderWidth = ExpandedPlayerHostPresentation.morphBarCoverRimWidth
    rim.layer.borderColor =
      UIColor.white.withAlphaComponent(ExpandedPlayerHostPresentation.morphBarCoverRimOpacity)
      .cgColor
    addSubview(rim)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Sets the cover's and the rim's radius together, so both animate in one block.
  func setCornerRadius(_ radius: CGFloat) {
    layer.cornerRadius = radius
    rim.layer.cornerRadius = radius
  }
}

/// The bar's label, carried on the panel's top edge from early in the collapse so the panel is
/// never a blank veil, and handed over to the bar's own content as the morph comes to rest.
final class PlayerMorphBarLabelView: UIImageView {
  override init(image: UIImage?) {
    super.init(image: image)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// `image` with `rect` (in its points) cleared: the cover's slot, which the flying cover fills.
  static func cuttingOut(_ rect: CGRect, from image: UIImage) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    format.opaque = false
    return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
      image.draw(at: .zero)
      context.cgContext.clear(rect)
    }
  }
}

/// One collapse into the mini player. Folds the page in place: the page is masked down to the
/// bar's shape, never reparented, while a tinted veil underneath travels the same path and the
/// page fades into it. The cover flies separately when the bar shows the same image. Built for one
/// run and then dropped.
@MainActor
final class PlayerMorphTransition {
  private let snapshot: PlayerMorphGeometry.Snapshot
  private weak var geometry: PlayerMorphGeometry?
  private let artwork: any PreparedArtworkCaching
  private let spring: PlayerMorphTiming.Spring
  private let releaseVelocityY: CGFloat
  private let afterRelease: Bool

  private var panel: PlayerMorphPanelView?
  private var cover: PlayerMorphCoverView?
  private var label: PlayerMorphBarLabelView?
  private var secondaryAnimators: [UIViewPropertyAnimator] = []
  private var revealTask: Task<Void, Never>?
  private var isFinished = false
  /// The springs still running that the morph ends on: the panel's, and the cover's when it flies.
  private var springsInMotion = 1

  init(
    snapshot: PlayerMorphGeometry.Snapshot,
    geometry: PlayerMorphGeometry?,
    artwork: any PreparedArtworkCaching,
    afterRelease: Bool,
    releaseVelocityY: CGFloat = 0,
    preparedPanel: PlayerMorphPanelView? = nil
  ) {
    panel = preparedPanel
    self.snapshot = snapshot
    self.geometry = geometry
    self.artwork = artwork
    spring = PlayerMorphTiming.spring(afterRelease: afterRelease)
    self.releaseVelocityY = releaseVelocityY
    self.afterRelease = afterRelease
  }

  /// Runs the morph from wherever `page` is now (its transform included) and calls `completion`
  /// once everything the morph added has been removed. The caller removes the page and completes
  /// the transition there.
  func run(
    page: UIView, in container: UIView, completion: @escaping @MainActor () -> Void
  ) {
    let start = page.convert(page.bounds, to: container)
    let inset = ExpandedPlayerHostPresentation.morphBarInset
    let end = container.convert(snapshot.bar, from: nil).insetBy(dx: inset, dy: inset)
    let startRadius = max(page.layer.cornerRadius, 0)
    let endRadius = end.height / 2

    // The panel: a veil under the page, on the page's own path. A pull-down built it when the drag
    // began. Pinned by its top edge, as the mask is, so that edge and the height can run on
    // springs of their own.
    let panel = self.panel ?? PlayerMorphPanelView.make(.veil)
    Self.pose(panel, at: start)
    panel.cornerConfiguration = .corners(radius: .fixed(startRadius))
    if panel.superview !== container {
      container.insertSubview(panel, belowSubview: page)
    }
    panel.alpha = 1
    self.panel = panel

    // The page: clipped by a mask that follows the panel, in the page's own coordinates. The
    // in-motion clip gives way to it, so the mask alone carries the shape.
    let mask = UIView()
    Self.pose(mask, at: page.convert(start, from: container))
    mask.backgroundColor = .black
    mask.layer.cornerRadius = startRadius
    mask.layer.cornerCurve = .continuous
    page.mask = mask
    page.layer.cornerRadius = 0
    page.layer.masksToBounds = false
    let maskEnd = page.convert(end, from: container)

    let cover = makeFlyingCover(in: container, above: page)
    let label = makeBarLabel(
      panel: panel, in: container, above: page, top: start.minY)
    let labelEnd = container.convert(snapshot.bar, from: nil)
    // After a release the shell dim is an alongside animation of the frozen slide, so the morph
    // carries it out. A close's dim is UIKit's own and still runs.
    let dim = afterRelease ? container.subviews.first { $0 is PlayerShellDimView } : nil
    let coverEnd = container.convert(snapshot.barCover, from: nil)

    geometry?.isMorphTarget = true
    if cover != nil {
      geometry?.isCoverInFlight = true
    }

    let travel = end.minY - start.minY
    let velocity = PlayerMorphTiming.initialVelocity(velocityY: releaseVelocityY, travel: travel)
    let springVelocity = CGVector(dx: velocity, dy: velocity)
    // The top edge, the width and everything riding them.
    let main = UIViewPropertyAnimator(
      duration: spring.duration,
      timingParameters: UISpringTimingParameters(
        dampingRatio: spring.dampingRatio, initialVelocity: springVelocity))
    main.addAnimations {
      panel.center = CGPoint(x: end.midX, y: end.minY)
      panel.bounds.size.width = end.width
      panel.cornerConfiguration = .corners(radius: .fixed(endRadius))
      mask.center = CGPoint(x: maskEnd.midX, y: maskEnd.minY)
      mask.bounds.size.width = maskEnd.width
      mask.layer.cornerRadius = endRadius
      dim?.alpha = 0
      label?.frame = labelEnd
      if let cover {
        cover.bounds.size = coverEnd.size
        cover.setCornerRadius(ExpandedPlayerHostPresentation.morphBarCoverCornerRadius)
        cover.rim.alpha = 1
      }
    }
    // Holds the morph strongly: the transition cannot be left without its completion. The
    // animator lets the closure go once it has run.
    main.addCompletion { _ in
      self.springCameToRest(page: page, completion: completion)
    }

    // The height trails the top edge and is never sprung loosely: it has the furthest to go, and
    // an overshoot here would pinch the panel thinner than the bar.
    let lag = PlayerMorphTiming.heightLag(for: spring)
    let height = UIViewPropertyAnimator(duration: lag.duration, dampingRatio: 1)
    height.addAnimations {
      panel.bounds.size.height = end.height
      mask.bounds.size.height = maskEnd.height
    }
    secondaryAnimators.append(height)

    // The cover's position alone takes the looser spring; its size rides the panel's.
    var flight: UIViewPropertyAnimator?
    if let cover {
      let coverSpring = PlayerMorphTiming.coverSpring(for: spring)
      let physics = PlayerMorphTiming.physics(for: coverSpring)
      // The duration is ignored: these parameters run the spring until it settles.
      let animator = UIViewPropertyAnimator(
        duration: coverSpring.duration,
        timingParameters: UISpringTimingParameters(
          mass: 1, stiffness: physics.stiffness, damping: physics.damping,
          initialVelocity: springVelocity))
      animator.addAnimations { cover.center = CGPoint(x: coverEnd.midX, y: coverEnd.midY) }
      // The flight settles on its own time, which can be after the panel's. The morph waits for
      // it, or the cover would be taken away short of its slot and the bar's own would appear a
      // jump away.
      springsInMotion += 1
      animator.addCompletion { _ in
        self.springCameToRest(page: page, completion: completion)
      }
      secondaryAnimators.append(animator)
      flight = animator
    }

    // The page fades into the veil over the opening share: its canvas is its background, so
    // this is the colour-to-veil cross-fade.
    let fade = UIViewPropertyAnimator(
      duration: spring.duration * ExpandedPlayerHostPresentation.morphPageFadeFraction,
      curve: .easeInOut)
    fade.addAnimations { page.alpha = 0 }
    secondaryAnimators.append(fade)

    var labelFade: UIViewPropertyAnimator?
    if let label {
      let animator = UIViewPropertyAnimator(
        duration: spring.duration * ExpandedPlayerHostPresentation.morphBarLabelFadeFraction,
        curve: .easeOut)
      animator.addAnimations { label.alpha = 1 }
      secondaryAnimators.append(animator)
      labelFade = animator
    }

    // Over the closing share the veil fades out over the bar's glass. Its animator is built when
    // the reveal is due, not now with a delay: a delayed animator still runs its block at once,
    // which would set the veil's alpha to zero from the start.
    let revealDuration = spring.duration * ExpandedPlayerHostPresentation.morphBarRevealFraction
    let revealDelay = spring.duration - revealDuration
    // With no carried label the bar's content returns as the veil fades. A carried label holds
    // until the spring has all but stopped, or the two copies of the same words would show apart.
    let handOffDuration =
      label == nil
      ? revealDuration
      : spring.duration * ExpandedPlayerHostPresentation.morphBarLabelHandOffFraction
    let handOffDelay = spring.duration - handOffDuration

    main.startAnimation()
    height.startAnimation(afterDelay: lag.delay)
    flight?.startAnimation()
    fade.startAnimation()
    labelFade?.startAnimation(
      afterDelay: spring.duration * ExpandedPlayerHostPresentation.morphBarLabelFadeDelayFraction)
    revealTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(revealDelay))
      guard let self, self.isFinished == false else { return }
      let reveal = UIViewPropertyAnimator(duration: revealDuration, curve: .easeOut)
      reveal.addAnimations { panel.alpha = 0 }
      self.secondaryAnimators.append(reveal)
      reveal.startAnimation()

      try? await Task.sleep(for: .seconds(handOffDelay - revealDelay))
      guard self.isFinished == false else { return }
      guard let label else {
        guard let geometry = self.geometry else { return }
        withAnimation(.easeOut(duration: handOffDuration)) {
          geometry.isMorphTarget = false
        }
        return
      }
      // A swap in one step, not a fade in either direction. Cross-faded, two half-drawn copies of
      // the same words are dimmer than either; overlapped, the translucent ink of the subtitle and
      // the controls is drawn twice and brighter. Both read as a flash.
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        self.geometry?.isMorphTarget = false
      }
      label.alpha = 0
    }
  }

  /// Places `view` at `frame` with its anchor on the middle of its top edge, so its `center` is
  /// that edge and its height can be animated without moving it.
  private static func pose(_ view: UIView, at frame: CGRect) {
    view.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
    view.bounds = CGRect(origin: .zero, size: frame.size)
    view.center = CGPoint(x: frame.midX, y: frame.minY)
  }

  /// The bar's label at the bar's own width, on the panel's top edge and transparent. `nil` when
  /// the bar supplied none; the bar's content is then revealed as the veil fades.
  private func makeBarLabel(
    panel: PlayerMorphPanelView, in container: UIView, above page: UIView, top: CGFloat
  ) -> PlayerMorphBarLabelView? {
    let rendered =
      panel.barLabelImage
      ?? geometry?.barLabelImage(
        size: snapshot.bar.size, scale: container.traitCollection.displayScale)
    guard let rendered else { return nil }
    // The slot is cut out whether or not the cover flies: the label was rendered without a cover,
    // and the slot's hairline rim around nothing would travel as an empty square.
    let slot = snapshot.barCover
      .offsetBy(dx: -snapshot.bar.minX, dy: -snapshot.bar.minY).insetBy(dx: -1, dy: -1)
    let label = PlayerMorphBarLabelView(
      image: PlayerMorphBarLabelView.cuttingOut(slot, from: rendered))
    var frame = container.convert(snapshot.bar, from: nil)
    frame.origin.y = top
    label.frame = frame
    label.alpha = 0
    container.insertSubview(label, aboveSubview: page)
    self.label = label
    return label
  }

  private func makeFlyingCover(in container: UIView, above page: UIView) -> PlayerMorphCoverView? {
    // When the bar draws a different picture, or nothing holds the page's, there is no flight: the
    // page's cover fades with the page and the bar's appears with the bar. The prepared cache
    // empties when the app is backgrounded while the page goes on drawing the cover it holds, so
    // the page's own record of it is the fallback.
    guard snapshot.coversMatch, let start = snapshot.pageCover, let key = snapshot.pageCoverKey,
      let image = artwork.image(for: key) ?? snapshot.pageCoverImage
    else { return nil }
    let cover = PlayerMorphCoverView(image: image)
    cover.frame = container.convert(start, from: nil)
    cover.setCornerRadius(ExpandedPlayerHostPresentation.morphPageCoverCornerRadius)
    container.insertSubview(cover, aboveSubview: page)
    self.cover = cover
    return cover
  }

  /// One of the springs the morph waits on has settled: the panel's, or the cover's flight. The
  /// morph ends with the last of them.
  private func springCameToRest(page: UIView, completion: @MainActor () -> Void) {
    springsInMotion -= 1
    guard springsInMotion <= 0 else { return }
    finish(page: page, completion: completion)
  }

  private func finish(page: UIView, completion: @MainActor () -> Void) {
    guard isFinished == false else { return }
    isFinished = true
    revealTask?.cancel()
    for animator in secondaryAnimators where animator.state == .active {
      animator.stopAnimation(true)
    }
    secondaryAnimators = []
    panel?.removeFromSuperview()
    cover?.removeFromSuperview()
    label?.removeFromSuperview()
    page.mask = nil
    // Whatever happened in between, including the bar going away mid-morph, the bar is never
    // left blank and the real covers are never left hidden.
    geometry?.isCoverInFlight = false
    geometry?.isMorphTarget = false
    completion()
  }
}
