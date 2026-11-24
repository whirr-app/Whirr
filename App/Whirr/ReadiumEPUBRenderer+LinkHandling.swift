import Foundation
import ReadiumNavigator
import ReadiumShared
import UIKit
import WebKit

extension ReadiumEPUBRenderer {
  /// Readium's default implementation opens the URL in Safari the moment it is tapped. Publication
  /// content is untrusted, so a tap inside a book must not be able to throw the reader out of the
  /// app on its own: the destination is shown and confirmed first, and cancelling leaves the
  /// reader where it was, since this presents over the navigator without navigating it.
  func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
    guard ReaderLinkPolicy.decision(for: url) == .promptThenOpen else { return }
    presentExternalURLConfirmation(for: url)
  }

  /// Implemented rather than inherited so the "follow it" answer is written down. Readium only
  /// asks about links it resolved against the publication, but a resolved link may still carry its
  /// own scheme; that one leaves the book, so it takes the confirmation path instead of the
  /// navigator's silent one.
  func navigator(_ navigator: VisualNavigator, shouldNavigateToLink link: ReadiumLink) -> Bool {
    switch ReaderLinkPolicy.route(forHREF: link.href) {
    case .navigateInPublication:
      return true
    case .treatAsExternal(let url):
      self.navigator(navigator, presentExternalURL: url)
      return false
    }
  }

  /// Adds a stylesheet and no script message handler. Readium registers its own handlers (`log`,
  /// `tap`, `selectionChanged`, `decorationActivated`) on this controller, and publication
  /// JavaScript runs in the same document, so any handler added here is callable by name from the
  /// book's own scripts. Whirr owns no handler, and adding one needs that answered first.
  /// Readium's handlers stay: removing them would break selection, decorations and tap handling.
  func navigator(
    _ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController
  ) {
    Self.installUserStyles(into: userContentController)
  }

  private func presentExternalURLConfirmation(for url: URL) {
    let alert = UIAlertController(
      title: "Leave Whirr?",
      message: "This link opens \(ReaderLinkPolicy.displayedTarget(for: url)) outside the app.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Open", style: .default) { _ in
        MainActor.assumeIsolated {
          // No `canOpenURL` pre-check: it is deprecated in iOS 27 ("prefer attempting to open URLs
          // and handling any failures"), and it was never the gate here. `ReaderLinkPolicy`'s
          // scheme allowlist at the `presentExternalURL` entry point is, and publication content
          // reaches this call only through it. A system refusal is silent.
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
      })
    hostViewController.presentConfirmation(alert)
  }
}
