import AppModel
import DesignSystem
import SwiftUI
import TestSupport
import Testing
import UIKit

@testable import Whirr

/// The collapse into the mini player, run for real through `PlayerTransitioningDelegate` in a
/// test window.
@MainActor
@Suite("Player morph transition", .serialized, .timeLimit(.minutes(1)))
struct PlayerMorphTransitionTests {
  private typealias Fixture = PlayerMorphFixture

  // MARK: - Pure timing

  @Test("release velocity is normalised to the panel's travel, downward only, and capped")
  func velocityNormalisation() {
    #expect(PlayerMorphTiming.initialVelocity(velocityY: 940, travel: 470) == 2)
    #expect(
      PlayerMorphTiming.initialVelocity(velocityY: 20_000, travel: 470)
        == ExpandedPlayerHostPresentation.morphVelocityCap)
    #expect(PlayerMorphTiming.initialVelocity(velocityY: -500, travel: 470) == 0)
    #expect(PlayerMorphTiming.initialVelocity(velocityY: 500, travel: 0) == 0)
    #expect(PlayerMorphTiming.initialVelocity(velocityY: .nan, travel: 470) == 0)
  }

  @Test("the completion speed makes the dim's remainder last exactly as long as the morph")
  func releaseCompletionSpeed() {
    let speed = PlayerMorphTiming.releaseCompletionSpeed(
      progress: 0.3, transitionDuration: 0.48, morphDuration: 0.40)
    #expect(abs(speed - 0.7 * 0.48 / 0.40) < 1e-9)
    // The remainder UIKit plays: (1 − p) × D / speed.
    #expect(abs((0.7 * 0.48) / Double(speed) - 0.40) < 1e-9)
    #expect(
      PlayerMorphTiming.releaseCompletionSpeed(
        progress: 1, transitionDuration: 0.48, morphDuration: 0.40) > 0)
    #expect(
      PlayerMorphTiming.releaseCompletionSpeed(
        progress: 0.3, transitionDuration: 0, morphDuration: 0.40) == 1)
  }

  @Test("a button close lands critically damped; a release uses the quicker, looser spring")
  func springs() {
    #expect(
      PlayerMorphTiming.spring(afterRelease: false)
        == .init(duration: ExpandedPlayerHostPresentation.morphDuration, dampingRatio: 1))
    #expect(
      PlayerMorphTiming.spring(afterRelease: true)
        == .init(
          duration: ExpandedPlayerHostPresentation.morphReleaseDuration,
          dampingRatio: ExpandedPlayerHostPresentation.morphReleaseDampingRatio))
  }

  @Test("the cover's position is sprung looser than the panel, never tighter than asked")
  func coverSpring() {
    let close = PlayerMorphTiming.spring(afterRelease: false)
    #expect(
      PlayerMorphTiming.coverSpring(for: close)
        == .init(
          duration: close.duration,
          dampingRatio: ExpandedPlayerHostPresentation.morphCoverDampingRatio))
    let loose = PlayerMorphTiming.Spring(duration: 0.4, dampingRatio: 0.5)
    #expect(PlayerMorphTiming.coverSpring(for: loose) == loose)
  }

  @Test("the cover's flight is a spring by its physics, at the damping asked for")
  func coverSpringPhysics() {
    let spring = PlayerMorphTiming.Spring(duration: 0.5, dampingRatio: 0.7)
    let physics = PlayerMorphTiming.physics(for: spring)
    let frequency = physics.stiffness.squareRoot()
    #expect(abs(physics.damping / (2 * frequency) - 0.7) < 0.0001)
    // Decayed to a thousandth by the duration.
    #expect(abs(exp(-0.7 * frequency * 0.5) - 0.001) < 0.00001)
  }

  @Test("the panel's height starts after its top edge and ends with it")
  func heightLag() {
    for afterRelease in [false, true] {
      let spring = PlayerMorphTiming.spring(afterRelease: afterRelease)
      let lag = PlayerMorphTiming.heightLag(for: spring)
      #expect(lag.delay > 0)
      #expect(lag.duration > 0)
      #expect(abs(lag.delay + lag.duration - spring.duration) < 1e-9)
    }
  }

  @Test("the carried label is rendered at the bar's size, and only when the bar supplied one")
  func barLabelImage() {
    let geometry = PlayerMorphGeometry()
    let size = CGSize(width: 300, height: 56)
    #expect(geometry.barLabelImage(size: size, scale: 2) == nil)
    geometry.barLabel = AnyView(Color.red)
    let image = geometry.barLabelImage(size: size, scale: 2)
    #expect(image?.size == size)
    #expect(image?.scale == 2)
    #expect(geometry.barLabelImage(size: .zero, scale: 2) == nil)
  }

  @Test("a bar on screen hands its label to the relay, with nothing else asking for it")
  func barLabelReachesTheRelay() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let geometry = PlayerMorphGeometry()
      _ = scope.host(
        Color.green
          .playerMorphBarLabel(Text("Provenance"))
          .environment(\.playerMorphGeometry, geometry))
      _ = await awaitCondition("the label arrives", until: { geometry.barLabel != nil })
      #expect(geometry.barLabel != nil)
    }
  }

  @Test("the carried label draws the bar's own content, not an empty picture")
  func barLabelDrawsTheBar() throws {
    let geometry = PlayerMorphGeometry()
    geometry.barLabel = AnyView(
      MiniPlayerView(
        title: "Provenance", subtitle: "Ann Leckie", isPlaying: false,
        playPauseAccessibilityLabel: "Play", skipBackAccessibilityLabel: "Back",
        skipBackAccessibilityHint: "", skipBackSystemImage: "gobackward.15",
        skipForwardAccessibilityLabel: "Forward", skipForwardAccessibilityHint: "",
        skipForwardSystemImage: "goforward.30", progressAccessibilityValue: { "" },
        expandAccessibilityHint: "", coverAccessibilityLabel: nil, contentColorScheme: .dark,
        cover: { Color.clear }, onPlayPauseTap: {}, onSkipBackTap: {}, onSkipForwardTap: {},
        onExpandTap: {}))
    let size = CGSize(width: 360, height: 48)
    let image = try #require(geometry.barLabelImage(size: size, scale: 1))
    // The title's row, right of the cover's slot, and the transport at the trailing end.
    let title = try Self.inkedPoints(of: image, in: CGRect(x: 60, y: 4, width: 150, height: 22))
    let transport = try Self.inkedPoints(of: image, in: CGRect(x: 240, y: 8, width: 120, height: 32))
    #expect(title > 20)
    #expect(transport > 20)
  }

  /// How many whole points of `image` inside `rect` carry any ink.
  private static func inkedPoints(of image: UIImage, in rect: CGRect) throws -> Int {
    var count = 0
    for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
      for x in stride(from: rect.minX, to: rect.maxX, by: 1)
      where try alpha(of: image, at: CGPoint(x: x, y: y)) > 0 {
        count += 1
      }
    }
    return count
  }

  @Test("the cover's slot is cut out of the carried label, so the flying cover lands in a gap")
  func barLabelCoverCutOut() throws {
    let size = CGSize(width: 40, height: 20)
    let filled = UIGraphicsImageRenderer(size: size).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
    let cut = PlayerMorphBarLabelView.cuttingOut(CGRect(x: 4, y: 4, width: 10, height: 10), from: filled)
    #expect(cut.size == size)
    #expect(cut.scale == filled.scale)
    #expect(try Self.alpha(of: cut, at: CGPoint(x: 9, y: 9)) == 0)
    #expect(try Self.alpha(of: cut, at: CGPoint(x: 30, y: 10)) == 255)
  }

  /// The alpha at `point`, read by drawing that one point into a single pixel.
  private static func alpha(of image: UIImage, at point: CGPoint) throws -> UInt8 {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    // Eight bits a component, so the bytes read below are the components.
    format.preferredRange = .standard
    let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image {
      _ in image.draw(at: CGPoint(x: -point.x, y: -point.y))
    }
    let data = try #require(pixel.cgImage?.dataProvider?.data as Data?)
    // White or nothing: every component of the pixel equals its alpha, whatever the byte order.
    return try #require(data.prefix(4).min())
  }

  // MARK: - Harness

  /// Stands in for `PlayerDismissInteractor`: hands UIKit a live interactive dismissal and gives
  /// the test the animator UIKit chose.
  private final class PullDown: PlayerInteractiveDismissalProviding,
    PlayerDismissalAnimatorProviding
  {
    var controller: PlayerInteractiveDismissal?
    var reduceMotion = false
    private(set) var animator: PlayerTransitionAnimator?

    var activeInteractionController: (any UIViewControllerInteractiveTransitioning)? {
      controller
    }

    func setDismissalAnimator(_ animator: any UIViewControllerAnimatedTransitioning) {
      controller?.animatedTransitioning = animator
      let player = animator as? PlayerTransitionAnimator
      let reduceMotion = reduceMotion
      player?.isReduceMotionEnabled = { reduceMotion }
      self.animator = player
    }
  }

  private final class Stage {
    let geometry = PlayerMorphGeometry()
    let delegate = PlayerTransitioningDelegate()
    let pullDown = PullDown()
    let artwork = PreparedArtworkCache(totalCostLimit: 10_000_000, countLimit: 10)
    let page = UIViewController()
    let window: UIWindow
    var dismissalEnded: [Bool] = []
    var dismissCompletions = 0
    var anchors: [PlayerMorphGeometry.Role: PlayerMorphAnchorView] = [:]

    init(window: UIWindow) {
      self.window = window
      delegate.morphGeometry = geometry
      delegate.artwork = artwork
      delegate.interactionProvider = pullDown
      page.view.backgroundColor = .red
      page.modalPresentationStyle = .custom
      page.transitioningDelegate = delegate
    }

    var morphViews: [UIView] {
      var found: [UIView] = []
      var queue: [UIView] = [window]
      while let view = queue.popLast() {
        if view is PlayerMorphPanelView || view is PlayerMorphCoverView
          || view is PlayerMorphBarLabelView
        {
          found.append(view)
        }
        queue.append(contentsOf: view.subviews)
      }
      return found
    }

    var hasPanel: Bool { morphViews.contains { $0 is PlayerMorphPanelView } }

    /// The shell dim's opacity as drawn, mid-animation included.
    var dimOpacity: Float? {
      var queue: [UIView] = [window]
      while let view = queue.popLast() {
        if view is PlayerShellDimView { return view.layer.presentation()?.opacity ?? view.layer.opacity }
        queue.append(contentsOf: view.subviews)
      }
      return nil
    }
    var hasFlyingCover: Bool { morphViews.contains { $0 is PlayerMorphCoverView } }
    var flyingCover: PlayerMorphCoverView? {
      morphViews.lazy.compactMap { $0 as? PlayerMorphCoverView }.first
    }
    var hasBarLabel: Bool { morphViews.contains { $0 is PlayerMorphBarLabelView } }

    /// The carried label's opacity as last set, whatever is on screen.
    var barLabelAlpha: CGFloat? { morphViews.first { $0 is PlayerMorphBarLabelView }?.alpha }

    /// The carried label's opacity as drawn, mid-animation included.
    var barLabelOpacity: Float? {
      morphViews.first { $0 is PlayerMorphBarLabelView }.map {
        $0.layer.presentation()?.opacity ?? $0.layer.opacity
      }
    }
  }

  private func stage(
    _ scope: KeyWindowScope, coverCached: Bool = true, realTime: Bool = false
  ) async -> (Stage, UIViewController) {
    let presenter = scope.host(Color.green)
    scope.window.layer.speed = realTime ? 1 : Fixture.windowSpeed
    let stage = Stage(window: scope.window)
    stage.delegate.onDismissalEnded = { [stage] in stage.dismissalEnded.append($0) }
    stage.anchors = Fixture.install(in: scope.window, geometry: stage.geometry)
    if coverCached {
      stage.artwork.insert(Self.image(), for: Fixture.pageKey)
    }
    var presented = false
    presenter.present(stage.page, animated: true) { presented = true }
    _ = await awaitCondition("the page is presented", until: { presented })
    // Opens morph out of the bar, so every case here starts from the rest state it leaves.
    #expect(stage.morphViews.isEmpty)
    #expect(stage.geometry.isMorphTarget == false)
    #expect(stage.geometry.isCoverInFlight == false)
    #expect(stage.geometry.isOpening == false)
    #expect(stage.page.view.mask == nil)
    #expect(stage.page.view.transform == .identity)
    #expect(stage.page.view.alpha == 1)
    return (stage, presenter)
  }

  private static func image() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
  }

  private func dismiss(_ stage: Stage) {
    stage.page.dismiss(animated: true) { [stage] in stage.dismissCompletions += 1 }
  }

  private func awaitDismissed(_ stage: Stage, presenter: UIViewController) async {
    _ = await awaitCondition(
      "the dismissal completes", observing: { "ended \(stage.dismissalEnded)" },
      until: { stage.dismissCompletions == 1 && presenter.presentedViewController == nil })
  }

  /// The end state every completion path must reach.
  private func expectCleanEnd(_ stage: Stage, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(stage.dismissalEnded == [true], sourceLocation: sourceLocation)
    #expect(stage.dismissCompletions == 1, sourceLocation: sourceLocation)
    #expect(stage.morphViews.isEmpty, sourceLocation: sourceLocation)
    #expect(stage.geometry.isMorphTarget == false, sourceLocation: sourceLocation)
    #expect(stage.geometry.isCoverInFlight == false, sourceLocation: sourceLocation)
    #expect(stage.page.view.mask == nil, sourceLocation: sourceLocation)
    #expect(stage.page.view.superview == nil, sourceLocation: sourceLocation)
  }

  // MARK: - Close (non-interactive)

  @Test("Close folds the page into the bar, flies the cover, then cleans up exactly once")
  func closeMorphs() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      dismiss(stage)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.hasFlyingCover)
      #expect(stage.geometry.isMorphTarget)
      #expect(stage.geometry.isCoverInFlight)
      // The collapse lands on the bar's own glass, so its panel is a tinted veil, never glass:
      // glass laid on glass composites milkier than either.
      let panel = stage.morphViews.lazy.compactMap { $0 as? PlayerMorphPanelView }.first
      #expect(panel?.material == .veil)
      #expect(panel?.effect == nil)
      // Only an open holds the shadow back; a collapse hides it with the cover.
      #expect(stage.geometry.isCoverShadowHeld == false)
      #expect(stage.page.view.mask != nil)
      // The morph owns completion: nothing has ended while it is in flight.
      #expect(stage.dismissalEnded.isEmpty)
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  @Test(
    "the flying cover is at rest in the bar's slot when the morph takes it away",
    arguments: [CGFloat(0), 1000, 6000])
  func coverLandsBeforeTheMorphEnds(releaseVelocityY: CGFloat) async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      // The morph alone, so the release velocity is exact. A fling at the cap must still end
      // with the cover in its slot.
      let container = UIView(frame: Fixture.window)
      scope.host(Color.green).view.addSubview(container)
      let pulled: CGFloat = 150
      let page = UIView(frame: Fixture.window.offsetBy(dx: 0, dy: pulled))
      container.addSubview(page)
      let artwork = PreparedArtworkCache(totalCostLimit: 10_000_000, countLimit: 10)
      artwork.insert(Self.image(), for: Fixture.pageKey)
      let snapshot = PlayerMorphGeometry.Snapshot(
        bar: Fixture.bar, barCover: Fixture.barCover, barCoverKey: Fixture.barKey,
        pageCover: Fixture.pageCover.offsetBy(dx: 0, dy: pulled), pageCoverKey: Fixture.pageKey)
      let morph = PlayerMorphTransition(
        snapshot: snapshot, geometry: PlayerMorphGeometry(), artwork: artwork, afterRelease: true,
        releaseVelocityY: releaseVelocityY)
      // Committed first: a spring on a view that has never been drawn ends at once.
      try await Task.sleep(for: .milliseconds(200))
      var ended = false
      morph.run(page: page, in: container) { ended = true }
      let cover = container.subviews.lazy.compactMap { $0 as? PlayerMorphCoverView }.first
      #expect(cover != nil)
      // Where the cover was last drawn before the morph removed it. The bar's own cover appears in
      // the slot on that frame, so any distance between the two is seen as a jump.
      var lastDrawn: CGPoint?
      var samples = 0
      while ended == false, samples < 400 {
        if let position = cover?.layer.presentation()?.position {
          lastDrawn = position
        }
        samples += 1
        try await Task.sleep(for: .milliseconds(8))
      }
      #expect(ended)
      #expect(samples > 10, "the morph ran")
      let slot = CGPoint(x: Fixture.barCover.midX, y: Fixture.barCover.midY)
      #expect(lastDrawn != nil)
      if let lastDrawn {
        #expect(abs(lastDrawn.x - slot.x) < 1, "ended \(lastDrawn.x - slot.x) pt off in x")
        #expect(abs(lastDrawn.y - slot.y) < 1, "ended \(lastDrawn.y - slot.y) pt off in y")
      }
      #expect(container.subviews.contains { $0 is PlayerMorphCoverView } == false)
    }
  }

  @Test("Close carries the bar's label on the panel and hands over to the bar before it ends")
  func closeCarriesBarLabel() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      // Real time: the hand-off it checks is a few frames wide, too brief to poll when sped up.
      let (stage, presenter) = await stage(scope, realTime: true)
      stage.geometry.barLabel = AnyView(Text("Provenance"))
      dismiss(stage)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.hasBarLabel)
      // The bar stays blank under the carried label until the hand-off.
      #expect(stage.geometry.isMorphTarget)
      _ = await awaitCondition(
        "the label is drawn in full while the bar is still blank",
        until: { (stage.barLabelOpacity ?? 0) > 0.95 })
      #expect(stage.geometry.isMorphTarget)
      _ = await awaitCondition(
        "the bar takes over while the panel is still up",
        until: { stage.geometry.isMorphTarget == false })
      // Exchanged in one step: faded across they dim the words, and overlapped they brighten them.
      // The value set, not the one drawn: the screen has not been told of this turn's change yet.
      #expect(stage.barLabelAlpha == 0)
      #expect(stage.dismissalEnded.isEmpty)
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  @Test("a bar that supplied no label is revealed with the glass, with nothing carried")
  func closeWithoutBarLabel() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      dismiss(stage)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.hasBarLabel == false)
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  @Test("a cover the prepared cache dropped still flies, from the page's own drawn image")
  func coverMissFliesDrawnPageCover() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope, coverCached: false)
      let drawn = DrawnArtwork()
      let image = Self.image()
      drawn.note(image, for: Fixture.pageKey)
      stage.anchors[.pageCover]?.configure(
        geometry: stage.geometry, role: .pageCover, coverKey: Fixture.pageKey, drawnCover: drawn)
      dismiss(stage)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.flyingCover?.image === image)
      #expect(stage.geometry.isCoverInFlight)
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  @Test("a cover neither cached nor drawn by the page folds without a flight")
  func coverMissNoFlight() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope, coverCached: false)
      dismiss(stage)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.hasFlyingCover == false)
      #expect(stage.geometry.isCoverInFlight == false)
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  @Test("covers that are not the same picture fold without a flight")
  func coverMismatchNoFlight() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      let older = Fixture.key(revision: "r0", variant: .highFidelity(displaySize: 380, displayScale: 3))
      stage.artwork.insert(Self.image(), for: older)
      stage.anchors[.pageCover]?.configure(
        geometry: stage.geometry, role: .pageCover, coverKey: older)
      dismiss(stage)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.hasFlyingCover == false)
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  @Test("with no bar to land on, Close slides as today")
  func closeWithoutBarSlides() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      stage.geometry.canLand = { false }
      dismiss(stage)
      _ = await awaitCondition(
        "the slide runs", until: { stage.page.view.transform.ty > 0 || stage.dismissCompletions > 0 })
      #expect(stage.hasPanel == false)
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  @Test("the bar going away mid-morph still leaves it unblanked and the covers shown")
  func barLostMidMorph() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      dismiss(stage)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      // Playback ends: the accessory and its anchors leave.
      stage.geometry.canLand = { false }
      for anchor in stage.anchors.values { anchor.removeFromSuperview() }
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  @Test("the bar's content is revealed before the morph ends")
  func barRevealedBeforeEnd() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      dismiss(stage)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      _ = await awaitCondition(
        "the bar flag clears while the panel is still up",
        until: { stage.geometry.isMorphTarget == false })
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  // MARK: - Pull-down (interactive handover)

  private func beginPull(
    _ stage: Stage, reduceMotion: Bool = false
  ) async throws -> PlayerInteractiveDismissal {
    let controller = PlayerInteractiveDismissal()
    stage.pullDown.controller = controller
    stage.pullDown.reduceMotion = reduceMotion
    dismiss(stage)
    _ = await awaitCondition("the pull-down starts", until: { stage.pullDown.animator != nil })
    // UIKit read the controller synchronously inside `dismiss(animated:)`. Clearing it, as the
    // real interactor does at release, keeps it from driving a later dismissal.
    stage.pullDown.controller = nil
    try await Task.sleep(for: .milliseconds(100))
    controller.update(0.3)
    try await Task.sleep(for: .milliseconds(100))
    return controller
  }

  @Test("a release past the threshold freezes the slide and the morph carries it from there")
  func releaseHandsOver() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      let controller = try await beginPull(stage)
      controller.finish(duration: 0.3, initialVelocity: 1, releaseVelocityY: 1_200)

      // The page is frozen where the finger left it, not at the slide's end value.
      let frozenAt = stage.page.view.transform.ty
      #expect(
        abs(frozenAt - 0.3 * Fixture.window.height) < 1,
        "frozen at \(frozenAt), container \(stage.page.view.superview?.bounds ?? .zero)")
      #expect(stage.hasPanel)
      #expect(stage.pullDown.animator?.handedOverToMorph == true)
      let expectedSpeed = PlayerMorphTiming.releaseCompletionSpeed(
        progress: 0.3, transitionDuration: ExpandedPlayerHostPresentation.slideDuration,
        morphDuration: ExpandedPlayerHostPresentation.morphReleaseDuration)
      #expect(abs(controller.completionSpeed - expectedSpeed) < 1e-6)
      // The frozen slide has not completed the transition itself.
      #expect(stage.dismissalEnded.isEmpty)
      #expect(stage.dismissCompletions == 0)

      await awaitDismissed(stage, presenter: presenter)
      await awaitQuiescence("no stray second completion") {
        "completions \(stage.dismissCompletions), ended \(stage.dismissalEnded)"
      }
      expectCleanEnd(stage)
    }
  }

  /// Building the glass panel costs more than a frame, so it is built transparent during the
  /// drag and the release only poses it.
  @Test("a pull-down builds the panel transparent before release, and the release morphs with it")
  func pullDownPreparesPanel() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      // Real time: the veil's fade before the panel leaves is too brief to poll when sped up.
      let (stage, presenter) = await stage(scope, realTime: true)
      let controller = try await beginPull(stage)
      let preparedPanels = stage.morphViews.filter { $0 is PlayerMorphPanelView }
      let prepared = try #require(preparedPanels.first)
      #expect(prepared.alpha == 0)
      #expect(stage.morphViews.count == 1)

      controller.finish(duration: 0.3, initialVelocity: 1, releaseVelocityY: 1_200)
      let panels = stage.morphViews.filter { $0 is PlayerMorphPanelView }
      #expect(panels.count == 1)
      #expect(panels.first === prepared)
      #expect(prepared.alpha == 1)
      #expect(stage.pullDown.animator?.preparedPanel == nil)
      // The prepared panel is the collapse's veil, not glass. It fades onto the bar's glass
      // over the closing share.
      let veil = try #require(prepared as? PlayerMorphPanelView)
      #expect(veil.material == .veil)
      #expect(veil.effect == nil)
      _ = await awaitCondition(
        "the veil fades out while the panel is still up",
        until: { veil.alpha == 0 && veil.superview != nil })

      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  @Test("a pull-down under Reduce Motion builds no panel")
  func pullDownUnderReduceMotionPreparesNothing() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      let controller = try await beginPull(stage, reduceMotion: true)
      #expect(stage.hasPanel == false)
      controller.cancel(duration: 0.3, initialVelocity: 0)
      _ = await awaitCondition(
        "the cancel settles", until: { stage.dismissalEnded == [false] })
      presenter.dismiss(animated: false)
    }
  }

  /// On device the page's cover anchor lives inside the page. While the pull-down slide is paused,
  /// the page reports its end position, so a read puts the cover a screen height low.
  @Test("a release with the cover inside the page still morphs and flies the cover")
  func releaseWithCoverInsidePage() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      let anchor = try #require(stage.anchors[.pageCover])
      anchor.frame = stage.page.view.convert(Fixture.pageCover, from: scope.window)
      stage.page.view.addSubview(anchor)
      let controller = try await beginPull(stage)
      controller.finish(duration: 0.3, initialVelocity: 1, releaseVelocityY: 1_200)

      #expect(stage.hasPanel)
      #expect(stage.hasFlyingCover)
      #expect(stage.pullDown.animator?.handedOverToMorph == true)
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  /// The morph must take the shell dim with it. Frozen with the slide, it held its level
  /// through the morph and vanished at the end.
  @Test("a release fades the shell dim out over the morph")
  func releaseFadesDim() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      let controller = try await beginPull(stage)
      controller.finish(duration: 0.3, initialVelocity: 1, releaseVelocityY: 1_200)
      #expect(stage.pullDown.animator?.handedOverToMorph == true)
      let atRelease = try #require(stage.dimOpacity)
      #expect(atRelease > 0.05)
      _ = await awaitCondition(
        "the dim fades through the morph", observing: { "dim \(String(describing: stage.dimOpacity))" },
        until: { (stage.dimOpacity ?? 1) < atRelease - 0.05 })
      await awaitDismissed(stage, presenter: presenter)
      #expect(stage.dimOpacity == nil)
    }
  }

  @Test("Close fades the shell dim out over the morph")
  func closeFadesDim() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      dismiss(stage)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      let atStart = try #require(stage.dimOpacity)
      _ = await awaitCondition(
        "the dim fades through the morph", observing: { "dim \(String(describing: stage.dimOpacity))" },
        until: { (stage.dimOpacity ?? 1) < atStart - 0.05 })
      await awaitDismissed(stage, presenter: presenter)
      #expect(stage.dimOpacity == nil)
    }
  }

  @Test("a release with no bar to land on continues the slide")
  func releaseWithoutBarSlides() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      let controller = try await beginPull(stage)
      // The bar went between pan begin and release: the read at release decides.
      stage.geometry.canLand = { false }
      controller.finish(duration: 0.3, initialVelocity: 1, releaseVelocityY: 1_200)
      #expect(stage.hasPanel == false)
      #expect(stage.pullDown.animator?.handedOverToMorph == false)
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  @Test("under Reduce Motion a release continues the slide")
  func releaseUnderReduceMotionSlides() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      let controller = try await beginPull(stage, reduceMotion: true)
      controller.finish(duration: 0.3, initialVelocity: 1, releaseVelocityY: 1_200)
      #expect(stage.hasPanel == false)
      await awaitDismissed(stage, presenter: presenter)
      expectCleanEnd(stage)
    }
  }

  @Test("a cancelled pull-down is untouched: the page returns and nothing morphs")
  func cancelUnchanged() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = await stage(scope)
      let controller = try await beginPull(stage)
      // The panel built for a release that never came.
      #expect(stage.hasPanel)
      controller.cancel(duration: 0.3, initialVelocity: 0)
      #expect(stage.hasPanel == false)
      _ = await awaitCondition(
        "the cancel settles", until: { stage.dismissalEnded == [false] })
      #expect(stage.hasPanel == false)
      #expect(presenter.presentedViewController === stage.page)
      #expect(stage.geometry.isMorphTarget == false)
      presenter.dismiss(animated: false)
    }
  }
}
