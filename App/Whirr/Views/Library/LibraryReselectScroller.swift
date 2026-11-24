import SwiftUI
import UIKit

/// Where the compact Library list rests at its true top, and how to get there.
///
/// The system's tab-reselect scroll falls short twice: the list is self-sizing, so a scroll across
/// rows with estimated heights lands short as they are measured; and the collapsed `.searchable`
/// drawer is outside `adjustedContentInset` until revealed, so the system's top leaves it hidden.
enum LibraryReselectScroll {
  enum Step: Equatable {
    case finished
    case move(to: CGFloat, animated: Bool)
  }

  static let maximumCorrections = 3
  static let tolerance: CGFloat = 0.5
  /// Beyond this many viewports a move is a jump. See `step`.
  static let animatedViewportLimit: CGFloat = 2

  /// The part of the search drawer the navigation bar is not currently showing. A collapsed search
  /// bar is laid out at zero height, so what is hidden is its fitting height less its current one.
  static func hiddenDrawerHeight(fullHeight: CGFloat, visibleHeight: CGFloat) -> CGFloat {
    max(0, fullHeight - max(0, visibleHeight))
  }

  static func restingOffset(adjustedTopInset: CGFloat, hiddenDrawerHeight: CGFloat) -> CGFloat {
    -(adjustedTopInset + hiddenDrawerHeight)
  }

  /// A far move is never animated: an animated scroll lays out the rows it passes, their measured
  /// heights shift the content under it, and it stops short. The top edge is an absolute offset,
  /// so a jump reaches it exactly.
  static func step(
    offset: CGFloat, restingOffset: CGFloat, viewportHeight: CGFloat, corrections: Int, animated: Bool
  ) -> Step {
    let distance = abs(offset - restingOffset)
    guard distance > tolerance, corrections < maximumCorrections else { return .finished }
    return .move(
      to: restingOffset,
      animated: animated && distance <= viewportHeight * animatedViewportLimit)
  }
}

/// Drives the compact Library list to its true top after a tab reselect, then checks where it
/// settled and corrects, a bounded number of times.
///
/// It waits for the offset to hold still before each move, so it never fights the system's own
/// reselect scroll, and it stands down the moment a finger takes the list.
@MainActor
final class LibraryReselectScroller {
  /// Set by `LibraryReselectScrollCapture`. Weak: the list owns its scroll view, and the regular
  /// width has no such list at all.
  weak var scrollView: UIScrollView?

  private static let stillFramesBeforeMove = 2
  private static let timeout: CFTimeInterval = 2

  private var link: CADisplayLink?
  private var animated = true
  private var corrections = 0
  private var stillFrames = 0
  private var lastOffset = CGFloat.nan
  private var started: CFTimeInterval = 0

  func scrollToTop(animated: Bool) {
    guard let scrollView, scrollView.window != nil else { return }
    self.animated = animated
    corrections = 0
    stillFrames = 0
    lastOffset = .nan
    started = CACurrentMediaTime()
    link?.invalidate()
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  @objc private func tick() {
    guard let scrollView, scrollView.window != nil,
      scrollView.isTracking == false, scrollView.isDragging == false,
      CACurrentMediaTime() - started < Self.timeout
    else { return stop() }

    let offset = scrollView.contentOffset.y
    stillFrames = abs(offset - lastOffset) < LibraryReselectScroll.tolerance ? stillFrames + 1 : 0
    lastOffset = offset
    guard stillFrames >= Self.stillFramesBeforeMove else { return }

    let step = LibraryReselectScroll.step(
      offset: offset,
      restingOffset: LibraryReselectScroll.restingOffset(
        adjustedTopInset: scrollView.adjustedContentInset.top,
        hiddenDrawerHeight: Self.hiddenDrawerHeight(above: scrollView)),
      viewportHeight: scrollView.bounds.height,
      corrections: corrections,
      animated: animated)
    switch step {
    case .finished:
      stop()
    case .move(let target, let animated):
      corrections += 1
      stillFrames = 0
      scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: animated)
    }
  }

  private func stop() {
    link?.invalidate()
    link = nil
  }

  /// `.searchable` installs its search controller on the navigation item of the hosting controller
  /// that contains the list, which is the first one up the responder chain to carry one.
  private static func hiddenDrawerHeight(above scrollView: UIScrollView) -> CGFloat {
    var responder: UIResponder? = scrollView
    while let current = responder {
      if let controller = current as? UIViewController,
        controller.navigationItem.hidesSearchBarWhenScrolling,
        let searchBar = controller.navigationItem.searchController?.searchBar,
        let bar = controller.navigationController?.navigationBar
      {
        return LibraryReselectScroll.hiddenDrawerHeight(
          fullHeight: searchBar.sizeThatFits(bar.bounds.size).height,
          visibleHeight: searchBar.bounds.height)
      }
      responder = current.next
    }
    return 0
  }
}

/// Hands the list's own scroll view to the scroller. It sits in the list's first row because only
/// a row is a descendant of that scroll view; the reference outlives the row scrolling away.
struct LibraryReselectScrollCapture: UIViewRepresentable {
  let scroller: LibraryReselectScroller

  func makeUIView(context: Context) -> CaptureView {
    let view = CaptureView()
    view.scroller = scroller
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ view: CaptureView, context: Context) {
    view.scroller = scroller
  }

  final class CaptureView: UIView {
    weak var scroller: LibraryReselectScroller?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      var ancestor = superview
      while let current = ancestor {
        if let scrollView = current as? UIScrollView {
          scroller?.scrollView = scrollView
          return
        }
        ancestor = current.superview
      }
    }
  }
}
