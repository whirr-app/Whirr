import SwiftUI
import UIKit

@MainActor
final class ReadiumEPUBRendererHostViewController: UIViewController, UIGestureRecognizerDelegate {
  private var childViewController: UIViewController?
  /// Called when the reader starts dragging the page. Readium turns pages by swipe inside its own
  /// scroll views and only reports the new location later, indistinguishable from a programmatic
  /// move such as a rail seek, so the drag itself is the only reliable "the reader swiped" signal.
  var onPageSwipe: (() -> Void)?

  /// Observes, never claims: it must not cancel or delay the touches the navigator's scroll views
  /// and tap observer depend on.
  private(set) lazy var pageSwipeRecognizer: UIPanGestureRecognizer = {
    let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePageSwipe(_:)))
    recognizer.cancelsTouchesInView = false
    recognizer.delaysTouchesBegan = false
    recognizer.delaysTouchesEnded = false
    recognizer.delegate = self
    return recognizer
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.addGestureRecognizer(pageSwipeRecognizer)
  }

  @objc private func handlePageSwipe(_ recognizer: UIPanGestureRecognizer) {
    pageSwipeStateChanged(to: recognizer.state)
  }

  func pageSwipeStateChanged(to state: UIGestureRecognizer.State) {
    guard state == .began else { return }
    onPageSwipe?()
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }

  func install(_ child: UIViewController) {
    removeChildViewController()
    childViewController = child
    addChild(child)
    view.addSubview(child.view)
    child.view.frame = view.bounds
    child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    child.didMove(toParent: self)
  }

  func removeChildViewController() {
    guard let child = childViewController else { return }
    child.willMove(toParent: nil)
    child.view.removeFromSuperview()
    child.removeFromParent()
    childViewController = nil
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    childViewController?.view.frame = view.bounds
  }

  /// Presents from whatever is already on screen above this host. The reader's chrome may be
  /// presenting a sheet, and presenting on an already-presenting controller is a no-op that would
  /// drop the confirmation, the only thing standing between a tap and Safari.
  func presentConfirmation(_ alert: UIAlertController) {
    var presenter: UIViewController = self
    while let presented = presenter.presentedViewController, presented.isBeingDismissed == false {
      presenter = presented
    }
    presenter.present(alert, animated: true)
  }
}

/// Minimal SwiftUI bridge for the UIKit navigator host. Touch handling remains inside Readium.
struct ReadiumEPUBRendererView: UIViewControllerRepresentable {
  let renderer: ReadiumEPUBRenderer

  func makeUIViewController(context: Context) -> UIViewController {
    renderer.viewController
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
