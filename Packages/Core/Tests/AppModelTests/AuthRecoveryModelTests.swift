import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The same-account recovery state machine. Driven entirely through `FakeAccountLifecycle`, so
/// no ABSApi/wire type appears here (ARCHITECTURE.md), as in `SetupFlowModelTests`.
@MainActor
@Suite struct AuthRecoveryModelTests {

  @Test func rebindingUsesTheNewLifecycleForSubsequentReauthentication() async {
    let initial = FakeAccountLifecycle()
    let replacement = FakeAccountLifecycle()
    let model = AuthRecoveryModel(accountLifecycle: initial)

    model.bindAccountLifecycle(replacement)
    model.recoveryRequired()
    await model.submit(username: "rhys", password: "hunter2")

    #expect(initial.reauthenticateCallCount == 0)
    #expect(replacement.reauthenticateCallCount == 1)
    #expect(model.accountLifecycle as AnyObject === replacement as AnyObject)
  }

  @Test func invalidCredentialsCanBeCancelledAndRecoveredWithoutChangingShellPresentation() async {
    let fake = FakeAccountLifecycle()
    let model = AuthRecoveryModel(accountLifecycle: fake)
    let navigation = NavigationModel(presentation: .shell)

    model.recoveryRequired()
    #expect(model.state == .required)
    #expect(navigation.presentation == .shell)

    fake.stubReauthenticate(throwing: AccountLifecycleError.invalidCredentials)
    model.password = "wrong"
    await model.submit(username: "rhys", password: "wrong")
    #expect(model.state == .failed(.invalidCredentials))
    #expect(model.password == "")
    #expect(navigation.presentation == .shell)

    model.cancel()
    #expect(model.state == .required)
    #expect(model.password == "")
    #expect(navigation.presentation == .shell)

    fake.stubReauthenticate(throwing: nil)
    model.password = "hunter2"
    await model.submit(username: "rhys", password: "hunter2")
    #expect(model.state == .idle)
    #expect(model.password == "")
    #expect(fake.reauthenticateCallCount == 2)
    #expect(navigation.presentation == .shell)
  }

  @Test func cancellingCredentialEntryKeepsRecoveryRequired() async {
    let fake = FakeAccountLifecycle()
    let model = AuthRecoveryModel(accountLifecycle: fake)
    model.recoveryRequired()
    model.password = "typed-but-uncommitted"

    model.cancel()

    #expect(model.state == .required)
    #expect(model.password == "")
    #expect(fake.reauthenticateCallCount == 0)
  }

  @Test func successfulRecoveryReturnsToIdleWithoutResettingNavigation() async {
    let fake = FakeAccountLifecycle()
    let model = AuthRecoveryModel(accountLifecycle: fake)
    let navigation = NavigationModel(presentation: .shell, section: .library)
    navigation.navigate(to: .storage)
    model.recoveryRequired()

    await model.submit(username: "rhys", password: "hunter2")

    #expect(model.state == .idle)
    #expect(model.password == "")
    #expect(fake.reauthenticateCallCount == 1)
    #expect(fake.lastReauthentication?.username == "rhys")
    #expect(fake.lastReauthentication?.password == "hunter2")
    // Recovery success touches nothing about where the user already was.
    #expect(navigation.presentation == .shell)
    #expect(navigation.section == .library)
    #expect(navigation[pathFor: .library] == [.storage])
  }

  @Test func apiTokenRecoveryUsesTheStoredModeAndClearsTheToken() async {
    let fake = FakeAccountLifecycle()
    fake.authenticationMode = .apiToken
    let model = AuthRecoveryModel(accountLifecycle: fake)
    model.recoveryRequired()
    model.apiToken = "api-token-canary"

    await model.submit(apiToken: model.apiToken)

    #expect(model.state == .idle)
    #expect(model.apiToken.isEmpty)
    #expect(fake.authenticationMode == .apiToken)
  }

  @Test func mismatchedApiTokenRecoveryDoesNotMutateTheStoredAccount() async {
    let fake = FakeAccountLifecycle()
    fake.authenticationMode = .apiToken
    fake.stubReauthenticate(throwing: AccountLifecycleError.accountMismatch)
    let model = AuthRecoveryModel(accountLifecycle: fake)
    model.recoveryRequired()
    model.apiToken = "other-api-token"

    await model.submit(apiToken: model.apiToken)

    #expect(model.state == .failed(.accountMismatch))
    #expect(model.apiToken.isEmpty)
  }

  /// A mismatched user is a distinct, non-mutating failure category, not a silent success and
  /// not folded into `.invalidCredentials`.
  @Test func differentUserFailureIsSurfacedDistinctly() async {
    let fake = FakeAccountLifecycle()
    fake.stubReauthenticate(throwing: AccountLifecycleError.accountMismatch)
    let model = AuthRecoveryModel(accountLifecycle: fake)
    model.recoveryRequired()

    await model.submit(username: "someone-else", password: "hunter2")

    #expect(model.state == .failed(.accountMismatch))
    #expect(model.password == "")
  }

  /// Regression lock: explicit confirmed logout forwards to
  /// `AccountLifecycle.logout()` and, once the App-target caller runs `resetForLogout()` on
  /// success, still clears every shell path/presentation back to `.setup`.
  @Test func explicitLogoutStillResetsNavigationAndRemovesAccount() async {
    let fake = FakeAccountLifecycle()
    fake.isAuthenticated = true
    let settings = SettingsModel(downloadPreferences: FakeDownloadPreferences(), account: fake)
    let navigation = NavigationModel(presentation: .shell, section: .settings)
    navigation.navigate(to: .storage)
    navigation.expandPlayer()

    settings.requestLogout()
    let removed = await settings.confirmLogout()
    #expect(removed == true)
    #expect(fake.logoutCallCount == 1)
    #expect(fake.isAuthenticated == false)

    // Mirrors what `SettingsView` does after a successful `confirmLogout()`.
    navigation.resetForLogout()

    #expect(navigation.presentation == .setup)
    #expect(navigation.section == .home)
    #expect(navigation[pathFor: .settings] == [])
    #expect(navigation.playerPresentation == .collapsed)
  }
}
