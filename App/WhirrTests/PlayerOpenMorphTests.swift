import AppModel
import SwiftUI
import TestSupport
import Testing
import UIKit

@testable import Whirr

/// The open out of the mini player, run for real through `PlayerTransitioningDelegate` in a test
/// window.
@MainActor
@Suite("Player open morph", .serialized, .timeLimit(.minutes(1)))
struct PlayerOpenMorphTests {
  private typealias Fixture = PlayerMorphFixture

  // MARK: - Decision and duration

  private func presentation(
    _ geometry: PlayerMorphGeometry?, reduceMotion: Bool = false
  ) -> PlayerTransitionAnimator {
    let animator = PlayerTransitionAnimator(direction: .present, morphGeometry: geometry)
    animator.isReduceMotionEnabled = { reduceMotion }
    return animator
  }

  @Test("an open with a bar on screen morphs, and UIKit is given the morph's duration")
  func openWithBarMorphs() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let geometry = PlayerMorphGeometry()
      Fixture.install(in: scope.window, geometry: geometry)
      let animator = presentation(geometry)
      let context = PlayerMorphStubContext(container: scope.window)
      #expect(animator.presentationMotion(for: context) == .morph(Fixture.snapshot()))
      #expect(
        animator.transitionDuration(using: context)
          == ExpandedPlayerHostPresentation.morphOpenDuration)
    }
  }

  @Test("an open with no bar, no relay, or under Reduce Motion slides as today")
  func openWithoutBarSlides() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let geometry = PlayerMorphGeometry()
      Fixture.install(in: scope.window, geometry: geometry)
      let reduced = presentation(geometry, reduceMotion: true)
      let reducedContext = PlayerMorphStubContext(container: scope.window)
      #expect(reduced.presentationMotion(for: reducedContext) == .slide)
      #expect(reduced.transitionDuration(using: reducedContext) == 0.2)

      let noRelay = PlayerMorphStubContext(container: scope.window)
      #expect(presentation(nil).presentationMotion(for: noRelay) == .slide)
      #expect(presentation(nil).transitionDuration(using: noRelay) == 0.42)

      geometry.canLand = { false }
      let noBar = PlayerMorphStubContext(container: scope.window)
      #expect(presentation(geometry).presentationMotion(for: noBar) == .slide)
      #expect(presentation(geometry).transitionDuration(using: noBar) == 0.42)
    }
  }

  @Test("the open's motion is read once per transition, so the dim and the motion agree")
  func openResolvedOnce() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let geometry = PlayerMorphGeometry()
      Fixture.install(in: scope.window, geometry: geometry)
      let animator = presentation(geometry)
      let context = PlayerMorphStubContext(container: scope.window)
      #expect(animator.presentationMotion(for: context) != .slide)
      geometry.canLand = { false }
      #expect(animator.presentationMotion(for: context) != .slide)
      #expect(
        animator.transitionDuration(using: context)
          == ExpandedPlayerHostPresentation.morphOpenDuration)
      #expect(
        animator.presentationMotion(for: PlayerMorphStubContext(container: scope.window)) == .slide)
    }
  }

  // MARK: - Harness

  private final class Stage {
    let geometry = PlayerMorphGeometry()
    let delegate = PlayerTransitioningDelegate()
    let artwork = PreparedArtworkCache(totalCostLimit: 10_000_000, countLimit: 10)
    let page: UIViewController
    let window: UIWindow
    var presentCompletions = 0
    var anchors: [PlayerMorphGeometry.Role: PlayerMorphAnchorView] = [:]

    init(window: UIWindow, page: (PlayerMorphGeometry) -> UIViewController) {
      self.window = window
      self.page = page(geometry)
      delegate.morphGeometry = geometry
      delegate.artwork = artwork
      self.page.modalPresentationStyle = .custom
      self.page.transitioningDelegate = delegate
    }

    private var allViews: [UIView] {
      var found: [UIView] = []
      var queue: [UIView] = [window]
      while let view = queue.popLast() {
        found.append(view)
        queue.append(contentsOf: view.subviews)
      }
      return found
    }

    var hasPanel: Bool { allViews.contains { $0 is PlayerMorphPanelView } }
    var panel: PlayerMorphPanelView? {
      allViews.lazy.compactMap { $0 as? PlayerMorphPanelView }.first
    }
    var hasFlyingCover: Bool { allViews.contains { $0 is PlayerMorphCoverView } }
    var flyingCover: PlayerMorphCoverView? {
      allViews.lazy.compactMap { $0 as? PlayerMorphCoverView }.first
    }
    var clip: PlayerOpenMorphClipView? {
      allViews.lazy.compactMap { $0 as? PlayerOpenMorphClipView }.first
    }
    var hasMorphViews: Bool { hasPanel || hasFlyingCover || clip != nil }

    /// The shell dim's opacity as drawn.
    var dimOpacity: Float? {
      guard let dim = allViews.first(where: { $0 is PlayerShellDimView }) else { return nil }
      return dim.layer.presentation()?.opacity ?? dim.layer.opacity
    }
  }

  private func stage(
    _ scope: KeyWindowScope,
    page: ((PlayerMorphGeometry) -> UIViewController)? = nil,
    coverCached: Bool = true, reduceMotion: Bool = false, realTime: Bool = false
  ) -> (Stage, UIViewController) {
    let presenter = scope.host(Color.green)
    scope.window.layer.speed = realTime ? 1 : Fixture.windowSpeed
    let stage = Stage(window: scope.window, page: page ?? { _ in Self.plainPage() })
    stage.delegate.isReduceMotionEnabled = { reduceMotion }
    stage.anchors = Fixture.install(in: scope.window, geometry: stage.geometry)
    if coverCached {
      stage.artwork.insert(Self.image(), for: Fixture.pageKey)
    }
    return (stage, presenter)
  }

  private static func holdMainThread(for interval: TimeInterval) {
    Thread.sleep(forTimeInterval: interval)
  }

  /// On the page's red, below its cover and clear of the bar, at rest and late in the open.
  private static let redProbe = CGPoint(x: Fixture.window.midX, y: 800)

  /// The colour the window shows at `point`, as composited on screen.
  private static func drawnColour(
    in window: UIWindow, at point: CGPoint
  ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    // A bitmap whose layout is fixed here, RGBA in that byte order, rather than the renderer's.
    var bytes = [UInt8](repeating: 0, count: 4)
    let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      // UIKit draws top-down; the bitmap's origin is at its bottom.
      context.translateBy(x: 0, y: 1)
      context.scaleBy(x: 1, y: -1)
      UIGraphicsPushContext(context)
      defer { UIGraphicsPopContext() }
      return window.drawHierarchy(
        in: CGRect(origin: CGPoint(x: -point.x, y: -point.y), size: window.bounds.size),
        afterScreenUpdates: true)
    }
    guard drew else { return (0, 0, 0, 0) }
    let alpha = CGFloat(bytes[3]) / 255
    guard alpha > 0 else { return (0, 0, 0, 0) }
    // Premultiplied: divide the alpha back out.
    return (
      CGFloat(bytes[0]) / 255 / alpha, CGFloat(bytes[1]) / 255 / alpha,
      CGFloat(bytes[2]) / 255 / alpha, alpha
    )
  }

  private static func plainPage() -> UIViewController {
    let page = UIViewController()
    page.view.backgroundColor = .red
    return page
  }

  private static func image() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
  }

  private func present(_ stage: Stage, from presenter: UIViewController) {
    presenter.present(stage.page, animated: true) { [stage] in stage.presentCompletions += 1 }
  }

  private func awaitPresented(_ stage: Stage) async {
    _ = await awaitCondition(
      "the open completes", observing: { "completions \(stage.presentCompletions)" },
      until: { stage.presentCompletions == 1 })
  }

  /// The rest state every open must reach, morph or not.
  private func expectCleanOpen(
    _ stage: Stage, presenter: UIViewController,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let page = stage.page.view!
    #expect(presenter.presentedViewController === stage.page, sourceLocation: sourceLocation)
    #expect(stage.presentCompletions == 1, sourceLocation: sourceLocation)
    #expect(stage.hasMorphViews == false, sourceLocation: sourceLocation)
    #expect(stage.geometry.isMorphTarget == false, sourceLocation: sourceLocation)
    #expect(stage.geometry.isCoverInFlight == false, sourceLocation: sourceLocation)
    #expect(stage.geometry.isCoverShadowHeld == false, sourceLocation: sourceLocation)
    #expect(stage.geometry.isOpening == false, sourceLocation: sourceLocation)
    #expect(page.mask == nil, sourceLocation: sourceLocation)
    #expect(page.frame == Fixture.window, sourceLocation: sourceLocation)
    #expect(page.transform == .identity, sourceLocation: sourceLocation)
    #expect(page.alpha == 1, sourceLocation: sourceLocation)
    #expect(page.layer.cornerRadius == 0, sourceLocation: sourceLocation)
    #expect(page.layer.shouldRasterize == false, sourceLocation: sourceLocation)
    #expect(page.window === stage.window, sourceLocation: sourceLocation)
    #expect(
      stage.dimOpacity.map { abs(CGFloat($0) - ExpandedPlayerHostPresentation.presenterDimOpacity) }
        .map { $0 < 0.01 } == true,
      "dim \(String(describing: stage.dimOpacity))", sourceLocation: sourceLocation)
  }

  // MARK: - The morph

  @Test("a tap open grows the page out of the bar, flies the cover, then cleans up once")
  func openMorphs() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      // Real time: it reads the page's first drawn frame, which a sped-up open has already left.
      let (stage, presenter) = stage(scope, realTime: true)
      present(stage, from: presenter)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.hasFlyingCover)
      #expect(stage.geometry.isMorphTarget)
      #expect(stage.geometry.isCoverInFlight)
      // An open grows glass out of the bar: the collapse's veil is for landing on glass only.
      #expect(stage.panel?.material == .glass)
      #expect(stage.panel?.effect != nil)
      // The page's cover returns at once on landing; its shadow is held and faded in after.
      #expect(stage.geometry.isCoverShadowHeld)
      #expect(stage.geometry.isOpening)
      let page = try #require(stage.page.view)
      // Clipped by a view of its own, never by a mask: a hosting view draws nothing under one.
      let clip = try #require(stage.clip)
      #expect(page.superview === clip)
      #expect(page.mask == nil)
      // The page's top rides the panel's top: it starts at the bar, not at the screen's edge.
      let startY = clip.layer.presentation()?.frame.minY ?? clip.frame.minY
      #expect(startY > Fixture.bar.minY - 40, "page started at \(startY)")
      #expect((page.layer.presentation()?.opacity ?? 1) < 0.1)
      #expect(stage.presentCompletions == 0)
      await awaitPresented(stage)
      await awaitQuiescence("no stray second completion") {
        "completions \(stage.presentCompletions)"
      }
      expectCleanOpen(stage, presenter: presenter)
    }
  }

  /// The page must be seen growing with the panel, not only once the open ends. On device the
  /// layers said opaque while the screen showed only glass and then cut to the page, so this
  /// samples what is drawn.
  @Test("a SwiftUI page is drawn over the panel before the open ends")
  func openShowsHostedPageMidFlight() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = stage(
        scope,
        page: { geometry in
          UIHostingController(rootView: HostedPage().environment(\.playerMorphGeometry, geometry))
        })
      stage.anchors[.pageCover]?.removeFromSuperview()
      // The probe's own control: before the open, the screen's centre is the presenter's green.
      let before = Self.drawnColour(
        in: stage.window, at: CGPoint(x: Fixture.window.midX, y: Fixture.window.midY))
      #expect(before.green > 0.4 && before.red < 0.3, "drawn before the open: \(before)")
      present(stage, from: presenter)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      let page = try #require(stage.page.view)
      // Past the fade's end, and short of the open's.
      let fadeEnd =
        ExpandedPlayerHostPresentation.morphOpenDuration
        * (ExpandedPlayerHostPresentation.morphOpenPageFadeDelayFraction
          + ExpandedPlayerHostPresentation.morphOpenPageFadeDurationFraction)
      // Held on the main thread, so the open cannot finish before the check below.
      Self.holdMainThread(for: fadeEnd + 0.05)
      #expect(stage.presentCompletions == 0)
      let opacity = page.layer.presentation()?.opacity ?? page.layer.opacity
      #expect(opacity > 0.95, "page opacity \(opacity) mid-open")
      // What is drawn, not only what the layers say: below its cover, the page is red.
      let drawn = Self.drawnColour(in: stage.window, at: Self.redProbe)
      #expect(drawn.red > 0.8 && drawn.green < 0.3 && drawn.blue < 0.3, "drawn mid-open: \(drawn)")
      let clip = try #require(stage.clip, "the page has no clip mid-open")
      let clipFrame = clip.layer.presentation()?.frame ?? clip.frame
      #expect(clipFrame.height > Fixture.window.height / 2, "clip \(clipFrame) mid-open")
      await awaitPresented(stage)
      let rest = Self.drawnColour(
        in: stage.window, at: Self.redProbe)
      #expect(rest.red > 0.8 && rest.green < 0.3 && rest.blue < 0.3, "drawn at rest: \(rest)")
      expectCleanOpen(stage, presenter: presenter)
    }
  }

  /// On device the page's cover anchor lives inside the page. Measured after the page is posed
  /// at the bar, it reads at the screen's bottom edge and is rejected as off screen.
  @Test("the page cover is measured at rest, so a cover inside the page still flies")
  func openMeasuresCoverInsidePage() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = stage(scope)
      let anchor = try #require(stage.anchors[.pageCover])
      anchor.removeFromSuperview()
      anchor.frame = Fixture.pageCover
      stage.page.view.addSubview(anchor)
      present(stage, from: presenter)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.hasFlyingCover)
      await awaitPresented(stage)
      expectCleanOpen(stage, presenter: presenter)
    }
  }

  /// The SwiftUI page cover's anchor is placed by layout. One forced pass after the page enters
  /// the container is enough for it to report its frame.
  @Test("a SwiftUI page's cover anchor is measurable after one layout pass")
  func openMeasuresHostedCover() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = stage(
        scope,
        page: { geometry in
          UIHostingController(rootView: HostedPage().environment(\.playerMorphGeometry, geometry))
        })
      // The hosted page carries its own cover anchor.
      stage.anchors[.pageCover]?.removeFromSuperview()
      present(stage, from: presenter)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.hasFlyingCover)
      await awaitPresented(stage)
      expectCleanOpen(stage, presenter: presenter)
    }
  }

  private struct HostedPage: View {
    var body: some View {
      VStack {
        Color.blue
          .frame(width: Fixture.pageCover.width, height: Fixture.pageCover.height)
          .playerMorphAnchor(.pageCover) { Fixture.pageKey }
        Spacer()
      }
      .padding(.top, Fixture.pageCover.minY)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.red)
      .ignoresSafeArea()
    }
  }

  @Test("a cover missing from the prepared cache, or a different picture, opens without a flight")
  func openWithoutFlight() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = stage(scope, coverCached: false)
      present(stage, from: presenter)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.hasFlyingCover == false)
      #expect(stage.geometry.isCoverInFlight == false)
      // With no flight the page's cover and its shadow are in view throughout.
      #expect(stage.geometry.isCoverShadowHeld == false)
      await awaitPresented(stage)
      expectCleanOpen(stage, presenter: presenter)
    }
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = stage(scope)
      let older = Fixture.key(revision: "r0", variant: .highFidelity(displaySize: 380, displayScale: 3))
      stage.artwork.insert(Self.image(), for: older)
      stage.anchors[.pageCover]?.configure(
        geometry: stage.geometry, role: .pageCover, coverKey: older)
      present(stage, from: presenter)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.hasFlyingCover == false)
      await awaitPresented(stage)
      expectCleanOpen(stage, presenter: presenter)
    }
  }

  /// The prepared cache empties when the app is backgrounded, while the bar goes on drawing the
  /// cover it holds. The first open after that must still fly it.
  @Test("with the prepared cache emptied, the open flies the cover the bar is drawing")
  func openFliesBarsDrawnCover() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = stage(scope, coverCached: false)
      let drawn = DrawnArtwork()
      drawn.note(Self.image(), for: Fixture.barKey)
      try #require(stage.anchors[.barCover]).configure(
        geometry: stage.geometry, role: .barCover, coverKey: Fixture.barKey, drawnCover: drawn)
      present(stage, from: presenter)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.hasFlyingCover)
      #expect(stage.geometry.isCoverInFlight)
      await awaitPresented(stage)
      expectCleanOpen(stage, presenter: presenter)
    }
  }

  /// The bar prepares the page's cover ahead of the tap and holds it through the cache emptying,
  /// so the flight is sharp from its first frame rather than the bar's thumbnail scaled up.
  @Test("with the prepared cache emptied, the open flies the page cover the bar warmed")
  func openFliesWarmedPageCover() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = stage(scope, coverCached: false)
      let drawn = DrawnArtwork()
      drawn.note(Self.image(), for: Fixture.barKey)
      let warmed = DrawnArtwork()
      let sharp = Self.image()
      warmed.note(sharp, for: Fixture.pageKey)
      try #require(stage.anchors[.barCover]).configure(
        geometry: stage.geometry, role: .barCover, coverKey: Fixture.barKey, drawnCover: drawn,
        warmedPageCover: warmed)
      present(stage, from: presenter)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.flyingCover?.image === sharp)
      await awaitPresented(stage)
      expectCleanOpen(stage, presenter: presenter)
    }
  }

  /// A tap before the page's cover is prepared starts the flight on the bar's thumbnail. The page
  /// prepares its own cover as it mounts; the flight takes it up when it lands.
  @Test("a flight begun on the bar's cover takes up the page's cover when it is prepared")
  func openSwapsToPageCoverMidFlight() async throws {
    try await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = stage(scope, coverCached: false)
      let drawn = DrawnArtwork()
      let soft = Self.image()
      drawn.note(soft, for: Fixture.barKey)
      try #require(stage.anchors[.barCover]).configure(
        geometry: stage.geometry, role: .barCover, coverKey: Fixture.barKey, drawnCover: drawn)
      present(stage, from: presenter)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      let cover = try #require(stage.flyingCover)
      #expect(cover.image === soft)
      let sharp = Self.image()
      stage.artwork.insert(sharp, for: Fixture.pageKey)
      _ = await awaitCondition(
        "the flying cover takes the page's image",
        until: { cover.image === sharp || stage.presentCompletions > 0 })
      #expect(cover.image === sharp)
      #expect(stage.presentCompletions == 0)
      await awaitPresented(stage)
      expectCleanOpen(stage, presenter: presenter)
    }
  }

  @Test("with no bar on screen, or under Reduce Motion, the open slides up as today")
  func openSlides() async {
    for reduceMotion in [false, true] {
      await withKeyWindow(bounds: Fixture.window) { scope in
        let (stage, presenter) = stage(scope, reduceMotion: reduceMotion)
        if reduceMotion == false { stage.geometry.canLand = { false } }
        present(stage, from: presenter)
        _ = await awaitCondition(
          "the slide runs",
          until: {
            (stage.page.view.layer.presentation()?.affineTransform().ty ?? 0) > 0
              || stage.presentCompletions > 0
          })
        #expect(stage.hasPanel == false)
        #expect(stage.geometry.isMorphTarget == false)
        await awaitPresented(stage)
        expectCleanOpen(stage, presenter: presenter)
      }
    }
  }

  @Test("the bar going away mid-open still leaves it unblanked and the covers shown")
  func barLostMidOpen() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      let (stage, presenter) = stage(scope)
      present(stage, from: presenter)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      stage.geometry.canLand = { false }
      for anchor in stage.anchors.values { anchor.removeFromSuperview() }
      await awaitPresented(stage)
      expectCleanOpen(stage, presenter: presenter)
    }
  }

  @Test("the handle is released before the open ends")
  func handleReleasedBeforeEnd() async {
    await withKeyWindow(bounds: Fixture.window) { scope in
      // Real time: the gap between the handle's release and the panel's exit is a few frames.
      let (stage, presenter) = stage(scope, realTime: true)
      present(stage, from: presenter)
      _ = await awaitCondition("the morph starts", until: { stage.hasPanel })
      #expect(stage.geometry.isOpening)
      _ = await awaitCondition(
        "the handle flag clears while the panel is still up",
        until: { stage.geometry.isOpening == false })
      #expect(stage.hasPanel)
      await awaitPresented(stage)
      expectCleanOpen(stage, presenter: presenter)
    }
  }
}
