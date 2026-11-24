import AppModel
import DesignSystem
import Foundation
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

/// Presentation-only state for the recovery indicator and credential sheet: sheet visibility and
/// the transient username draft. The recovery transitions are covered by `AuthRecoveryModelTests`.
@MainActor
@Suite("Auth recovery presentation")
struct AuthRecoveryPresentationTests {

  @Test("Reconnect presents the credential sheet")
  func reconnectActionPresentsCredentialSheet() {
    let fake = FakeAccountLifecycle()
    let model = AuthRecoveryModel(accountLifecycle: fake)
    let presentation = AuthRecoveryPresentation(model: model)
    model.recoveryRequired()

    #expect(presentation.isSheetPresented == false)
    presentation.presentSheet()
    #expect(presentation.isSheetPresented == true)
  }

  @Test("dismissing the sheet leaves the recovery indicator visible")
  func dismissingSheetLeavesRecoveryIndicatorVisible() {
    let fake = FakeAccountLifecycle()
    let model = AuthRecoveryModel(accountLifecycle: fake)
    let presentation = AuthRecoveryPresentation(model: model)
    model.recoveryRequired()
    presentation.presentSheet()

    presentation.cancel()

    #expect(presentation.isSheetPresented == false)
    #expect(presentation.isIndicatorVisible == true)
    #expect(model.state == .required)
  }

  @Test("a successful submission dismisses the sheet and the indicator")
  func successfulSubmissionDismissesSheetAndIndicator() async {
    let fake = FakeAccountLifecycle()
    let model = AuthRecoveryModel(accountLifecycle: fake)
    let presentation = AuthRecoveryPresentation(model: model)
    model.recoveryRequired()
    presentation.presentSheet()
    presentation.username = "rhys"
    model.password = "hunter2"

    await presentation.submit()

    #expect(presentation.isSheetPresented == false)
    #expect(presentation.isIndicatorVisible == false)
    #expect(model.state == .idle)
    #expect(presentation.username == "")
  }

  @Test("a failed submission keeps the entered username but releases the password")
  func failedSubmissionKeepsEnteredUsernameButReleasesPassword() async {
    let fake = FakeAccountLifecycle()
    fake.stubReauthenticate(throwing: AccountLifecycleError.invalidCredentials)
    let model = AuthRecoveryModel(accountLifecycle: fake)
    let presentation = AuthRecoveryPresentation(model: model)
    model.recoveryRequired()
    presentation.presentSheet()
    presentation.username = "rhys"
    model.password = "wrong"

    await presentation.submit()

    #expect(presentation.username == "rhys")
    #expect(model.password == "")
    #expect(presentation.isSheetPresented == true)
    #expect(presentation.isIndicatorVisible == true)
    #expect(model.state == .failed(.invalidCredentials))
  }

  /// The recovery presentation path must never reach the destructive logout boundary.
  /// `AccountLifecycle.logout()` is the only call that produces the app's real "logged out"
  /// callback (`RootView.handleLoggedOut`). `AuthRecoveryPresentation` holds no reference to that
  /// callback, so this drives every recovery transition and confirms `logout()` is never called.
  @Test("presenting, cancelling, and submitting recovery never calls the account's logout operation")
  func recoveryPresentationDoesNotCallLoggedOutCallback() async {
    let fake = FakeAccountLifecycle()
    let model = AuthRecoveryModel(accountLifecycle: fake)
    let presentation = AuthRecoveryPresentation(model: model)

    model.recoveryRequired()
    presentation.presentSheet()
    presentation.cancel()

    presentation.presentSheet()
    fake.stubReauthenticate(throwing: AccountLifecycleError.invalidCredentials)
    presentation.username = "rhys"
    model.password = "wrong"
    await presentation.submit()

    fake.stubReauthenticate(throwing: nil)
    presentation.username = "rhys"
    model.password = "hunter2"
    await presentation.submit()

    #expect(fake.logoutCallCount == 0)
  }

  // MARK: - Recovery indicator

  /// Copy comes from `AuthRecoveryCopy`, and rendering is covered by `DesignSystemTests`. This
  /// surface's own requirement: the indicator sits in the navigation bar, not over it, so Settings
  /// (the only route to signing out of an account the server does not recognise) stays reachable
  /// during recovery.
  @Test("the recovery indicator renders the catalog's copy and reaches the sheet")
  func recoveryIndicatorRendersCatalogCopyAndReachesTheSheet() {
    let fake = FakeAccountLifecycle()
    let model = AuthRecoveryModel(accountLifecycle: fake)
    let presentation = AuthRecoveryPresentation(model: model)
    model.recoveryRequired()

    let indicator = ShellStatusIndicatorView(
      title: AuthRecoveryCopy.indicatorTitle,
      message: AuthRecoveryCopy.indicatorMessage,
      systemImage: AuthRecoveryCopy.indicatorSystemImage,
      actionTitle: AuthRecoveryCopy.reconnectActionLabel,
      actionAccessibilityHint: AuthRecoveryCopy.reconnectActionAccessibilityHint,
      onAction: { presentation.presentSheet() }
    )

    #expect(indicator.accessibilityLabel == AuthRecoveryCopy.indicatorTitle)
    #expect(indicator.actionButtonMinHeight >= WhirrMetric.minimumTouchTarget)
    indicator.onAction()
    #expect(presentation.isSheetPresented == true)
  }

  /// The recovery surface has no destructive action of its own. A stale account is signed out
  /// through Settings' confirmed logout.
  @Test("the indicator's only action is Reconnect")
  func indicatorOnlyActionIsReconnect() {
    for copy in AuthRecoveryCopy.allCopy {
      #expect(copy.lowercased().contains("sign out") == false)
    }
  }

}
