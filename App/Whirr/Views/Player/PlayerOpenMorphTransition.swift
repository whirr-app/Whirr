import ABSApi
import SwiftUI
import UIKit

/// One open out of the mini player, the collapse's mirror image. A glass panel grows from the bar
/// to the screen while the page rides its top edge, clipped by a view that follows the panel, and
/// fades in over it. The cover flies from the bar to the page when both draw the same image. Built
/// for one run and then dropped.
@MainActor
final class PlayerOpenMorphTransition {
  private let snapshot: PlayerMorphGeometry.Snapshot
  private weak var geometry: PlayerMorphGeometry?
  private let artwork: any PreparedArtworkCaching

  private var panel: PlayerMorphPanelView?
  private var clip: PlayerOpenMorphClipView?
  private var cover: PlayerMorphCoverView?
  private var secondaryAnimators: [UIViewPropertyAnimator] = []
  private var handleTask: Task<Void, Never>?
  private var coverSwapTask: Task<Void, Never>?
  private var isFinished = false

  init(
    snapshot: PlayerMorphGeometry.Snapshot,
    geometry: PlayerMorphGeometry?,
    artwork: any PreparedArtworkCaching
  ) {
    self.snapshot = snapshot
    self.geometry = geometry
    self.artwork = artwork
  }

  /// Adds `page` to `container` at `finalFrame` and grows it out of the bar. `completion` runs
  /// once everything the morph added has been removed and the page is at rest.
  func run(
    page: UIView, finalFrame: CGRect, in container: UIView,
    completion: @escaping @MainActor () -> Void
  ) {
    let duration = ExpandedPlayerHostPresentation.morphOpenDuration

    // Blank, then lay out at full size. The page enters a window only here, at alpha 0 and in the
    // same turn, so UIKit never draws it unposed.
    page.alpha = 0
    page.transform = .identity
    page.frame = finalFrame
    container.addSubview(page)
    page.setNeedsLayout()
    page.layoutIfNeeded()

    // Measure the page's cover now, while the page is at rest. Once it is posed at the bar its
    // cover lies at the screen's bottom edge and would be rejected as off screen.
    let measured = geometry?.snapshot()
    let pageCover = measured?.pageCover
    let coversMatch = measured?.coversMatch == true

    let inset = ExpandedPlayerHostPresentation.morphBarInset
    let start = container.convert(snapshot.bar, from: nil).insetBy(dx: inset, dy: inset)
    let startRadius = start.height / 2
    let endRadius = PlayerDisplayCornerRadius.shared.radius(for: container.window)

    // The panel: glass under the page, from the bar to the page's final frame.
    let panel = PlayerMorphPanelView.make(.glass)
    panel.frame = start
    panel.cornerConfiguration = .corners(radius: .fixed(startRadius))
    container.insertSubview(panel, belowSubview: page)
    self.panel = panel

    // The page rides the panel's top edge inside a view that clips it to the panel. Not a mask on
    // the page: a SwiftUI page is a hosting view, and UIKit places a mask view inside it, which
    // SwiftUI reports as unsupported. The page moves within one window, so its anchors stay
    // registered.
    let clip = PlayerOpenMorphClipView(frame: start)
    clip.clipsToBounds = true
    clip.layer.cornerRadius = startRadius
    clip.layer.cornerCurve = .continuous
    container.insertSubview(clip, aboveSubview: panel)
    clip.addSubview(page)
    page.frame = finalFrame.offsetBy(dx: -start.minX, dy: -finalFrame.minY)
    self.clip = clip

    let cover =
      coversMatch
      ? makeFlyingCover(
        pageCoverKey: measured?.pageCoverKey, warmed: measured?.warmedPageCoverImage,
        in: container, above: clip) : nil
    let coverEnd = pageCover.map { container.convert($0, from: nil) }

    // The bar blanks at once, under the panel that has just covered it.
    geometry?.isMorphTarget = true
    geometry?.isOpening = true
    if cover != nil {
      geometry?.isCoverInFlight = true
      geometry?.isCoverShadowHeld = true
    }

    let main = UIViewPropertyAnimator(duration: duration, dampingRatio: 1)
    main.addAnimations {
      panel.frame = finalFrame
      panel.cornerConfiguration = .corners(radius: .fixed(endRadius))
      clip.frame = finalFrame
      clip.layer.cornerRadius = endRadius
      page.frame = CGRect(origin: .zero, size: finalFrame.size)
      if let cover, let coverEnd {
        cover.frame = coverEnd
        cover.setCornerRadius(ExpandedPlayerHostPresentation.morphPageCoverCornerRadius)
        cover.rim.alpha = 0
      }
    }
    // Holds the morph strongly: the transition cannot be left without its completion.
    main.addCompletion { _ in
      self.finish(page: page, finalFrame: finalFrame, in: container, completion: completion)
    }

    // The page fades in over the glass: its own fade is the cross-fade to its colour. Its own
    // animator, started on the same turn as the spring, so the two never drift apart.
    let fade = UIViewPropertyAnimator(
      duration: duration * ExpandedPlayerHostPresentation.morphOpenPageFadeDurationFraction,
      curve: .easeOut)
    fade.addAnimations { page.alpha = 1 }
    secondaryAnimators.append(fade)

    main.startAnimation()
    fade.startAnimation(
      afterDelay: duration * ExpandedPlayerHostPresentation.morphOpenPageFadeDelayFraction)
    handleTask = Task { [weak self] in
      try? await Task.sleep(
        for: .seconds(duration * ExpandedPlayerHostPresentation.morphOpenHandleDelayFraction))
      guard let self, self.isFinished == false, let geometry = self.geometry else { return }
      withAnimation(.easeInOut(duration: ExpandedPlayerHostPresentation.morphOpenHandleFadeDuration)) {
        geometry.isOpening = false
      }
    }
  }

  /// The bar's cover, copied, at the bar's cover frame. The page's high-fidelity image when it is
  /// ready, from the cache or as the bar warmed it. Otherwise the bar's own, from the cache or
  /// failing that the one the bar is drawing: a thumbnail, soft at the page's size, so the flight
  /// then watches for the page's image and takes it up.
  private func makeFlyingCover(
    pageCoverKey: ArtworkKey?, warmed: UIImage?, in container: UIView, above clip: UIView
  ) -> PlayerMorphCoverView? {
    let pageImage = pageCoverKey.flatMap { artwork.image(for: $0) } ?? warmed
    let image =
      pageImage
      ?? snapshot.barCoverKey.flatMap { artwork.image(for: $0) }
      ?? snapshot.barCoverImage
    guard let image else { return nil }
    let cover = PlayerMorphCoverView(image: image)
    if pageImage == nil, let pageCoverKey {
      swapToPageCover(cover, key: pageCoverKey)
    }
    cover.frame = container.convert(snapshot.barCover, from: nil)
    cover.setCornerRadius(ExpandedPlayerHostPresentation.morphBarCoverCornerRadius)
    cover.rim.alpha = 1
    container.insertSubview(cover, aboveSubview: clip)
    self.cover = cover
    return cover
  }

  /// Cross-fades the flying cover to the page's image once the prepared cache has it. The page
  /// starts preparing its cover as it mounts, at the start of this open; the cache announces
  /// nothing, so it is asked once a frame until the open ends.
  private func swapToPageCover(_ cover: PlayerMorphCoverView, key: ArtworkKey) {
    coverSwapTask = Task { [weak self, weak cover, artwork] in
      while Task.isCancelled == false {
        if let sharp = artwork.image(for: key) {
          guard let self, self.isFinished == false, let cover else { return }
          UIView.transition(
            with: cover, duration: ExpandedPlayerHostPresentation.morphOpenCoverSwapDuration,
            options: [.transitionCrossDissolve, .allowAnimatedContent, .beginFromCurrentState]
          ) {
            cover.image = sharp
          }
          return
        }
        try? await Task.sleep(for: .milliseconds(16))
      }
    }
  }

  private func finish(
    page: UIView, finalFrame: CGRect, in container: UIView, completion: @MainActor () -> Void
  ) {
    guard isFinished == false else { return }
    isFinished = true
    handleTask?.cancel()
    coverSwapTask?.cancel()
    for animator in secondaryAnimators where animator.state == .active {
      animator.stopAnimation(true)
    }
    secondaryAnimators = []
    // The page goes back to the container where the clip was, then the clip goes.
    if let clip {
      container.insertSubview(page, belowSubview: clip)
    } else {
      container.addSubview(page)
    }
    page.frame = finalFrame
    page.alpha = 1
    clip?.removeFromSuperview()
    panel?.removeFromSuperview()
    cover?.removeFromSuperview()
    // Whatever happened in between, including the bar going away mid-open, the bar is never left
    // blank, the covers never left hidden, and the handle never left out.
    geometry?.isCoverInFlight = false
    geometry?.isMorphTarget = false
    geometry?.isOpening = false
    // The cover is back in this same frame; its shadow follows on a curve of its own.
    if let geometry, geometry.isCoverShadowHeld {
      withAnimation(.easeOut(duration: ExpandedPlayerHostPresentation.morphOpenCoverShadowFadeDuration)) {
        geometry.isCoverShadowHeld = false
      }
    }
    completion()
  }
}

/// Clips the page to the panel's shape while it grows out of the bar. Draws nothing of its own.
final class PlayerOpenMorphClipView: UIView {}
