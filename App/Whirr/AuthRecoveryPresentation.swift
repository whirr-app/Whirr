import AppModel
import Foundation
import SyncEngine

/// Presentation state behind the shell's recovery indicator and credential sheet, which
/// `AuthRecoveryModel` doesn't track: whether the sheet is shown (a failed submission keeps it open
/// to show the error), and the entered username, which the model doesn't keep across attempts.
///
/// No logout or navigation-reset callback: recovery is overlay state, and the destructive logout
/// stays behind Settings' confirmation.
@MainActor
@Observable
final class AuthRecoveryPresentation {
  let model: AuthRecoveryModel
  private(set) var isSheetPresented = false
  var username: String = ""

  init(model: AuthRecoveryModel) {
    self.model = model
  }

  /// The indicator is up for every non-idle state (required, submitting, failed); only a
  /// successful recovery, back to `.idle`, removes it. It is a navigation-bar glyph, not a banner,
  /// because a banner pinned over the shell covered the toolbar's Settings button and stranded a
  /// user whose stored account no longer exists on the server.
  var isIndicatorVisible: Bool {
    model.state != .idle
  }

  var canTryOtherAddresses: Bool {
    model.canTryOtherAddresses
  }

  func tryOtherAddresses() async {
    await model.tryOtherAddresses()
  }

  /// Reconnect's action. A no-op if already presented.
  func presentSheet() {
    isSheetPresented = true
  }

  /// Cancel, or the sheet's own interactive swipe-down dismissal. `AuthRecoveryModel.cancel()`
  /// returns to `.required`, never `.idle`, so the indicator stays up and the offline shell stays
  /// available.
  func cancel() {
    model.cancel()
    isSheetPresented = false
  }

  /// Submits whatever is currently entered. Success dismisses the sheet and clears the retained
  /// username. Failure leaves the sheet open with `username` untouched so the user can just fix
  /// the password; `AuthRecoveryModel` has already released the submitted password on every exit
  /// path.
  func submit() async {
    if model.authenticationMode == .openID { return }
    if model.authenticationMode == .apiToken {
      await model.submit(apiToken: model.apiToken)
    } else {
      let submittedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
      await model.submit(username: submittedUsername, password: model.password)
    }
    dismissIfRecovered()
  }

  /// "Sign in with SSO" for an `.openID` account. A closed browser leaves the sheet open, back at
  /// its button.
  func submitSingleSignOn(using browser: any SingleSignOnBrowsing) async {
    await model.submitSingleSignOn(using: browser)
    dismissIfRecovered()
  }

  private func dismissIfRecovered() {
    if model.state == .idle {
      isSheetPresented = false
      username = ""
    }
  }
}
