import Foundation
import Observation
import Persistence
import SyncEngine

/// The setup/login state machine. Driven entirely through `AccountLifecycle`, the lowest module
/// AppModel may see (ARCHITECTURE.md), so no ABSApi/wire type appears here.
@MainActor
@Observable
public final class SetupFlowModel {
  public enum State: Sendable, Equatable {
    case idle
    case validatingServer
    case needsCredentials(server: ValidatedServer)
    case loggingIn(server: ValidatedServer, username: String)
    case loadingLibraries
    case choosingLibraries(libraries: [SelectableLibrary], selectedIDs: Set<String>)
    case savingLibrarySelection
    case authenticated
    case serverValidationFailed(url: URL, customHeaders: [String: String], message: RecoveryMessage)
    case loginFailed(server: ValidatedServer, message: RecoveryMessage)
    case libraryDiscoveryFailed(message: RecoveryMessage)
  }

  public private(set) var state: State = .idle

  /// The newest single-sign-on attempt this model began; only its browser may complete sign-in.
  @ObservationIgnored private var currentSingleSignOn: SingleSignOnAttempt?

  /// True only while the discovery-failure escape route is removing the account. Logout leaves
  /// the visible state in place while its lifecycle call suspends, so this guard stops a second
  /// tap starting another removal.
  public private(set) var isSigningOut = false

  /// Bound directly to the credentials screen's password field. Cleared immediately after
  /// `submitCredentials` calls `AccountLifecycle.login`, whether it succeeds or fails, so the
  /// model never holds a submitted password longer than the in-flight call needs it.
  public var password: String = ""

  /// Bound directly to the API-token field. Cleared immediately after `submitAPIToken` calls
  /// `AccountLifecycle.login`, whether it succeeds or fails, just like `password`.
  public var apiToken: String = ""

  private let accountLifecycle: any AccountLifecycle
  private let libraryDiscovery: any LibrarySelectionDiscovering
  private let librarySelectionWriting: any LibrarySelectionWriting
  private let notificationLifecycle: any RSSNotificationLifecycleHandling

  public init(
    accountLifecycle: any AccountLifecycle,
    libraryDiscovery: any LibrarySelectionDiscovering = NoOpLibrarySelectionDiscovery(),
    librarySelectionWriting: any LibrarySelectionWriting = NoOpLibrarySelectionStore(),
    notificationLifecycle: any RSSNotificationLifecycleHandling = NoOpRSSNotificationLifecycle()
  ) {
    self.accountLifecycle = accountLifecycle
    self.libraryDiscovery = libraryDiscovery
    self.librarySelectionWriting = librarySelectionWriting
    self.notificationLifecycle = notificationLifecycle
  }

  /// (idle | serverValidationFailed) → validatingServer → (needsCredentials |
  /// serverValidationFailed). Accepting a fresh submission from the failed state lets the user
  /// correct a mistyped URL in place. A no-op from any in-flight or post-validation state, so a
  /// double-tap can't restart or corrupt the running step.
  public func submitServerURL(_ url: URL, customHeaders: [String: String] = [:]) async {
    switch state {
    case .idle, .serverValidationFailed: break
    default: return
    }
    state = .validatingServer
    do {
      let server = try await accountLifecycle.validateServer(url: url, customHeaders: customHeaders)
      state = .needsCredentials(server: server)
    } catch let error as AccountLifecycleError {
      state = .serverValidationFailed(
        url: url, customHeaders: customHeaders, message: SetupFlowCopy.recoveryMessage(for: error))
    } catch {
      state = .serverValidationFailed(
        url: url, customHeaders: customHeaders, message: SetupFlowCopy.genericRecoveryMessage)
    }
  }

  /// needsCredentials → loggingIn → (authenticated | loginFailed). A no-op from any other
  /// state, so submitting credentials mid-validation (or twice) does nothing rather than
  /// asserting or racing the in-flight call.
  public func submitCredentials(username: String) async {
    guard case .needsCredentials(let server) = state else { return }
    state = .loggingIn(server: server, username: username)
    let submittedPassword = password
    do {
      try await accountLifecycle.login(server: server, username: username, password: submittedPassword)
      password = ""
      await discoverLibraries()
    } catch let error as AccountLifecycleError {
      password = ""
      state = .loginFailed(server: server, message: SetupFlowCopy.recoveryMessage(for: error))
    } catch {
      password = ""
      state = .loginFailed(server: server, message: SetupFlowCopy.genericRecoveryMessage)
    }
  }

  /// API-token equivalent of `submitCredentials`. The token never enters `State`; it is copied
  /// only for the in-flight boundary call and cleared on every result path.
  public func submitAPIToken() async {
    guard case .needsCredentials(let server) = state, apiToken.isEmpty == false else { return }
    state = .loggingIn(server: server, username: "")
    let submittedToken = apiToken
    do {
      try await accountLifecycle.login(server: server, apiToken: submittedToken)
      apiToken = ""
      await discoverLibraries()
    } catch let error as AccountLifecycleError {
      apiToken = ""
      state = .loginFailed(server: server, message: SetupFlowCopy.recoveryMessage(for: error))
    } catch {
      apiToken = ""
      state = .loginFailed(server: server, message: SetupFlowCopy.genericRecoveryMessage)
    }
  }

  /// Single-sign-on equivalent of `submitCredentials`: needsCredentials → loggingIn →
  /// (authenticated | loginFailed), with the identity provider's page in between. A closed
  /// browser returns to needsCredentials without a message. The attempt is abandoned on every
  /// path that does not complete it, so a late callback can never use it.
  public func submitSingleSignOn(using browser: any SingleSignOnBrowsing) async {
    guard case .needsCredentials(let server) = state, server.offersSingleSignOn else { return }
    state = .loggingIn(server: server, username: "")
    let attempt: SingleSignOnAttempt
    do {
      attempt = try await accountLifecycle.beginSingleSignOn(server: server)
    } catch {
      failLogin(on: server, with: error)
      return
    }
    currentSingleSignOn = attempt
    let callbackURL: URL?
    do {
      // Ephemeral for setup: a new account never inherits whoever Safari is already signed in
      // as at the identity provider.
      callbackURL = try await browser.authenticate(
        at: attempt.authorizationURL, callbackScheme: SingleSignOnAttempt.callbackScheme,
        prefersEphemeralSession: true)
    } catch {
      attempt.abandon()
      failLogin(on: server, with: error)
      return
    }
    // The browser can be up for minutes; anything that moved the flow on meanwhile wins. The
    // state alone is not enough: leaving and re-entering the form returns it to `.loggingIn` for
    // the same server under a newer attempt, which this older browser must not complete.
    guard case .loggingIn(server, _) = state, currentSingleSignOn == attempt else {
      attempt.abandon()
      return
    }
    guard let callbackURL else {
      attempt.abandon()
      state = .needsCredentials(server: server)
      return
    }
    do {
      try await accountLifecycle.login(server: server, singleSignOn: attempt, callbackURL: callbackURL)
      await discoverLibraries()
    } catch {
      failLogin(on: server, with: error)
    }
  }

  private func failLogin(on server: ValidatedServer, with error: Error) {
    let message =
      (error as? AccountLifecycleError).map(SetupFlowCopy.recoveryMessage(for:))
      ?? SetupFlowCopy.genericRecoveryMessage
    state = .loginFailed(server: server, message: message)
  }

  /// Returns to `.idle` from any state, discarding whatever password was typed.
  public func cancel() {
    password = ""
    apiToken = ""
    state = .idle
  }

  /// Resumes the post-token onboarding step after process death. The caller has already proved
  /// the durable account is in `pending` mode, so this never asks for credentials.
  public func resumePendingLibrarySelection() async {
    guard case .idle = state, accountLifecycle.isAuthenticated else { return }
    await discoverLibraries()
  }

  public func toggleLibrarySelection(_ libraryID: String) {
    guard case .choosingLibraries(let libraries, var selectedIDs) = state,
      libraries.contains(where: { $0.serverLibraryID == libraryID && $0.isAccessible })
    else { return }
    if selectedIDs.contains(libraryID) {
      selectedIDs.remove(libraryID)
    } else {
      selectedIDs.insert(libraryID)
    }
    state = .choosingLibraries(libraries: libraries, selectedIDs: selectedIDs)
  }

  public var canContinueLibrarySelection: Bool {
    guard case .choosingLibraries(_, let selectedIDs) = state else { return false }
    return selectedIDs.isEmpty == false
  }

  public func continueLibrarySelection() async {
    guard case .choosingLibraries(_, let selectedIDs) = state, selectedIDs.isEmpty == false else { return }
    await saveLibrarySelection(selectedIDs)
  }

  /// The discovery recovery surface signs out locally without returning to the credentials step.
  /// The lifecycle swallows a failed remote confirmation only after local removal completes, so
  /// every thrown error leaves this recovery surface in place for a safe retry.
  @discardableResult
  public func signOut() async -> Bool {
    guard case .libraryDiscoveryFailed = state, isSigningOut == false else { return false }
    isSigningOut = true
    defer { isSigningOut = false }
    // Disarm first so a failed logout cannot leave live notifications armed; this matches the
    // playback preflight's fail-safe trade and may temporarily disarm a still-signed-in account.
    await notificationLifecycle.disarm(feedID: nil)
    do {
      try await accountLifecycle.logout()
      cancel()
      return true
    } catch {
      return false
    }
  }

  /// Re-runs whichever step failed: another `validateServer` call for a server-validation
  /// failure (same URL), or straight back to credential entry for a login failure (same
  /// validated server, so no re-validation). A no-op from any non-error state.
  public func retry() async {
    guard isSigningOut == false else { return }
    switch state {
    case .serverValidationFailed(let url, let customHeaders, _):
      state = .idle
      await submitServerURL(url, customHeaders: customHeaders)
    case .loginFailed(let server, _):
      state = .needsCredentials(server: server)
    case .libraryDiscoveryFailed:
      await discoverLibraries()
    default:
      break
    }
  }

  private func discoverLibraries() async {
    state = .loadingLibraries
    do {
      let libraries = try await libraryDiscovery.discoverAccessibleLibraries()
      guard libraries.isEmpty == false else {
        state = .libraryDiscoveryFailed(message: SetupFlowCopy.noAccessibleLibrariesRecoveryMessage)
        return
      }
      let allIDs = Set(libraries.map(\.serverLibraryID))
      if libraries.count == 1 {
        await saveLibrarySelection(allIDs)
      } else {
        state = .choosingLibraries(libraries: libraries, selectedIDs: allIDs)
      }
    } catch {
      state = .libraryDiscoveryFailed(message: SetupFlowCopy.libraryDiscoveryRecoveryMessage)
    }
  }

  private func saveLibrarySelection(_ selectedIDs: Set<String>) async {
    state = .savingLibrarySelection
    do {
      try await librarySelectionWriting.completeOnboarding(includedIDs: selectedIDs)
      state = .authenticated
    } catch {
      state = .libraryDiscoveryFailed(message: SetupFlowCopy.libraryDiscoveryRecoveryMessage)
    }
  }

}

extension SetupFlowModel.State {
  /// A stable identifier for the copy this state renders, distinct per visible state. Components
  /// switch on this rather than hardcoding strings.
  public var copyKey: String {
    switch self {
    case .idle: return "setup.idle"
    case .validatingServer: return "setup.validatingServer"
    case .needsCredentials: return "setup.needsCredentials"
    case .loggingIn: return "setup.loggingIn"
    case .loadingLibraries: return "setup.loadingLibraries"
    case .choosingLibraries: return "setup.choosingLibraries"
    case .savingLibrarySelection: return "setup.savingLibrarySelection"
    case .authenticated: return "setup.authenticated"
    case .serverValidationFailed(_, _, let message): return "setup.serverValidationFailed.\(message.key.rawValue)"
    case .loginFailed(_, let message): return "setup.loginFailed.\(message.key.rawValue)"
    case .libraryDiscoveryFailed(let message): return "setup.libraryDiscoveryFailed.\(message.key.rawValue)"
    }
  }

  /// A notice for the credentials step about how this server signs in, or nil when there is
  /// nothing to say. Only an SSO-only server has one: its single button depends on a server
  /// setting the user may need to ask for.
  public var credentialsNotice: String? {
    guard case .needsCredentials(let server) = self, server.offersOnlySingleSignOn else { return nil }
    return server.isPlainHTTP ? SetupFlowCopy.singleSignOnNeedsHTTPSNotice : SetupFlowCopy.singleSignOnOnlyNotice
  }

  /// The server the credentials form is for, while it is showing.
  private var credentialsServer: ValidatedServer? {
    switch self {
    case .needsCredentials(let server), .loginFailed(let server, _): server
    default: nil
    }
  }

  /// Whether the credentials form offers "Sign in with SSO". Never for a plain-HTTP server.
  public var offersSingleSignOn: Bool {
    credentialsServer?.offersSingleSignOn ?? false
  }

  /// Whether the credentials form offers a username and password. An SSO-only server does not: a
  /// password there would fail as if it were wrong. An API token still works on every server.
  public var offersPasswordSignIn: Bool {
    credentialsServer.map { $0.offersOnlySingleSignOn == false } ?? false
  }

  /// A line under the SSO button when the server needs custom proxy headers: the browser cannot
  /// send them on its later hops back to the server, and Whirr cannot fix that.
  public var singleSignOnProxyNote: String? {
    guard offersSingleSignOn, credentialsServer?.hasCustomHeaders == true else { return nil }
    return SetupFlowCopy.singleSignOnProxyHeadersNote
  }

  /// The literal copy a screen renders for this state. Non-empty for every case.
  public var copyText: String {
    switch self {
    case .idle:
      return "Enter your Audiobookshelf server address to get started."
    case .validatingServer:
      return "Checking server…"
    case .needsCredentials:
      return "Enter your sign-in details."
    case .loggingIn:
      return "Signing in…"
    case .loadingLibraries:
      return "Finding your libraries…"
    case .choosingLibraries:
      return "Choose what Whirr shows and keeps up to date on this device."
    case .savingLibrarySelection:
      return "Saving your library choices…"
    case .authenticated:
      return "You're signed in."
    case .serverValidationFailed(_, _, let message):
      return message.text
    case .loginFailed(_, let message):
      return message.text
    case .libraryDiscoveryFailed(let message):
      return message.text
    }
  }
}
