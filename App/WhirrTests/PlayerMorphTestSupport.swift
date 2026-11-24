import ABSApi
import UIKit

@testable import Whirr

/// Fixtures shared by the morph suites: an iPhone-sized window with the mini player's measured
/// geometry, and anchors that put it into a relay.
@MainActor
enum PlayerMorphFixture {
  nonisolated static let window = CGRect(x: 0, y: 0, width: 402, height: 874)
  nonisolated static let bar = CGRect(x: 21, y: 733, width: 360, height: 52)
  nonisolated static let barCover = CGRect(x: 33, y: 737, width: 44, height: 44)
  nonisolated static let pageCover = CGRect(x: 41, y: 140, width: 320, height: 320)

  /// Core Animation time in a staged window runs this many times faster than real time.
  ///
  /// The open and close suites hold the process-wide key window for every case, and each case
  /// plays the production morph (about half a second) end to end, so their real-time animation
  /// was most of the App run's tail. Speeding the window's layer scales every animation under it,
  /// UIKit's transition and the morph's animators alike, without touching production durations.
  /// A case that checks the order of phases only a few frames apart passes `realTime: true`: at
  /// this speed the gap between them is shorter than one poll.
  nonisolated static let windowSpeed: Float = 5

  nonisolated static func key(
    item: String = "item-1", revision: String = "r1", variant: ArtworkVariant
  ) -> ArtworkKey {
    ArtworkKey(
      accountScope: ArtworkAccountScope("account"), itemID: item, variant: variant,
      revision: ArtworkRevision(revision))
  }

  nonisolated static let barKey = key(variant: .libraryThumbnail(displaySize: 44, displayScale: 3))
  nonisolated static let pageKey = key(variant: .highFidelity(displaySize: 380, displayScale: 3))

  static func snapshot(
    bar: CGRect = bar, pageCoverKey: ArtworkKey? = pageKey
  ) -> PlayerMorphGeometry.Snapshot {
    PlayerMorphGeometry.Snapshot(
      bar: bar, barCover: barCover, barCoverKey: barKey, pageCover: pageCover,
      pageCoverKey: pageCoverKey)
  }

  /// A relay that can land, with one anchor per role added to `window`. The anchors are returned
  /// so a case can move or detach one.
  @discardableResult
  static func install(
    in window: UIWindow, geometry: PlayerMorphGeometry, pageCoverKey: ArtworkKey? = pageKey
  ) -> [PlayerMorphGeometry.Role: PlayerMorphAnchorView] {
    geometry.canLand = { true }
    var anchors: [PlayerMorphGeometry.Role: PlayerMorphAnchorView] = [:]
    let layout: [(PlayerMorphGeometry.Role, CGRect, ArtworkKey?)] = [
      (.bar, bar, nil), (.barCover, barCover, barKey), (.pageCover, pageCover, pageCoverKey),
    ]
    for (role, frame, key) in layout {
      let anchor = PlayerMorphAnchorView(frame: frame)
      anchor.configure(geometry: geometry, role: role, coverKey: key)
      window.addSubview(anchor)
      anchors[role] = anchor
    }
    return anchors
  }
}

/// A transition context with nothing behind it, for asking an animator what it would do. It never
/// completes anything; suites that need UIKit's real bookkeeping present for real.
final class PlayerMorphStubContext: NSObject, UIViewControllerContextTransitioning {
  let containerView: UIView
  var isInteractive: Bool
  private let from: UIViewController?

  init(container: UIView, from: UIViewController? = nil, isInteractive: Bool = false) {
    containerView = container
    self.from = from
    self.isInteractive = isInteractive
  }

  var isAnimated: Bool { true }
  var transitionWasCancelled: Bool { false }
  var presentationStyle: UIModalPresentationStyle { .custom }
  func updateInteractiveTransition(_ percentComplete: CGFloat) {}
  func finishInteractiveTransition() {}
  func cancelInteractiveTransition() {}
  func pauseInteractiveTransition() {}
  func completeTransition(_ didComplete: Bool) {}
  func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? {
    key == .from ? from : nil
  }
  func view(forKey key: UITransitionContextViewKey) -> UIView? { nil }
  var targetTransform: CGAffineTransform { .identity }
  func initialFrame(for vc: UIViewController) -> CGRect { containerView.bounds }
  func finalFrame(for vc: UIViewController) -> CGRect { .zero }
}
