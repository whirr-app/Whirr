import Foundation
import Observation
import SyncEngine

/// The same-account recovery state machine. Driven entirely through `AccountLifecycle` (the
/// lowest module AppModel may see, ARCHITECTURE.md §1), so no ABSApi/wire type appears here.
///
/// Independent of `NavigationModel`: recovery is shell-overlay state, not a `Presentation` case
/// beside `.setup`/`.shell`/`.removalPending`, so no transition touches the current `Presentation`.
@MainActor
@Observable
public final class AuthRecoveryModel {
  public enum State: Sendable, Equatable {
    case idle
    case required
    case submitting
    case failed(AccountLifecycleError)
  }

  public private(set) var state: State = .idle

  /// Bound directly to the recovery sheet's password field. Cleared on every exit path
  /// (success, failure and cancel).
  public var password: String = ""

  /// Bound directly to the recovery sheet for accounts whose stored pair has no refresh token.
  /// Cleared on every exit path just like `password`.
  public var apiToken: String = ""

  /// The lifecycle is late-bound because the cached auth-event bridge must exist before the live
  /// `ABSClient`, while the runtime lifecycle can only be composed after that client exists.
  /// Keeping this as one mutable dependency preserves the bridge's one-model-per-process contract.
  public private(set) var accountLifecycle: any AccountLifecycle

  private var otherAddressAvailability: @MainActor () -> Bool
  private var otherAddressAction: @MainActor () async -> Void

  public init(
    accountLifecycle: any AccountLifecycle,
    canTryOtherAddresses: @escaping @MainActor () -> Bool = { false },
    tryOtherAddresses: @escaping @MainActor () async -> Void = {}
  ) {
    self.accountLifecycle = accountLifecycle
    otherAddressAvailability = canTryOtherAddresses
    otherAddressAction = tryOtherAddresses
  }

  /// Rebinds recovery to the lifecycle that owns the process-wide live client. AppEnvironment
  /// calls this on every runtime rebuild, including rebuilds that reuse a cached bridge/model.
  public func bindAccountLifecycle(_ accountLifecycle: any AccountLifecycle) {
    self.accountLifecycle = accountLifecycle
  }

  /// The recovery sheet always shows the account that is already stored, never a caller-supplied
  /// server, and never editable. `nil` only if no account row exists, which cannot happen while
  /// recovery is required.
  public var serverDisplayString: String? {
    accountLifecycle.storedServerDisplayString
  }

  /// The active endpoint shown as fixed context in the recovery sheet.
  public var activeServerDisplayString: String? {
    serverDisplayString
  }

  /// True when the account has another saved endpoint that reconnect can try.
  public var canTryOtherAddresses: Bool {
    otherAddressAvailability()
  }

  /// Lets App composition bind the endpoint selector after the shared auth bridge exists.
  public func bindOtherAddressActions(
    canTryOtherAddresses: @escaping @MainActor () -> Bool,
    tryOtherAddresses: @escaping @MainActor () async -> Void
  ) {
    otherAddressAvailability = canTryOtherAddresses
    otherAddressAction = tryOtherAddresses
  }

  public func tryOtherAddresses() async {
    guard canTryOtherAddresses else { return }
    await otherAddressAction()
  }

  /// Derived from the stored token pair through the SyncEngine boundary; no second persistence
  /// field is needed for the recovery sheet to choose its credential field.
  public var authenticationMode: AccountAuthenticationMode {
    accountLifecycle.authenticationMode
  }

  /// Raises the recovery requirement. The real caller is a latched definitive refresh rejection.
  /// A no-op while a submission is in flight, so a duplicate signal can't restart it.
  public func recoveryRequired() {
    guard state != .submitting else { return }
    state = .required
  }

  /// (required | failed) → submitting → (idle | failed). A no-op from `.idle`/mid-flight, so a
  /// duplicate submit can't restart or race the in-flight call.
  public func submit(username: String, password: String) async {
    switch state {
    case .required, .failed: break
    default: return
    }
    state = .submitting
    do {
      try await accountLifecycle.reauthenticate(username: username, password: password)
      self.password = ""
      state = .idle
    } catch let error as AccountLifecycleError {
      self.password = ""
      state = .failed(error)
    } catch {
      self.password = ""
      state = .failed(.unreachable)
    }
  }

  /// API-token equivalent of `submit(username:password:)`. The token is passed straight through
  /// the lifecycle boundary and cleared on success, failure, and cancellation.
  public func submit(apiToken: String) async {
    switch state {
    case .required, .failed: break
    default: return
    }
    state = .submitting
    do {
      try await accountLifecycle.reauthenticate(apiToken: apiToken)
      self.apiToken = ""
      state = .idle
    } catch let error as AccountLifecycleError {
      self.apiToken = ""
      state = .failed(error)
    } catch {
      self.apiToken = ""
      state = .failed(.unreachable)
    }
  }

  /// Single-sign-on equivalent of `submit(username:password:)` for an `.openID` account. The
  /// browser session is shared with Safari so the identity provider's session is reused, and the
  /// lifecycle refuses a different user without changing anything. A closed browser returns to
  /// `.required` silently. A browser that cannot open at all falls back to `.unreachable`, as
  /// every non-lifecycle error here does.
  public func submitSingleSignOn(using browser: any SingleSignOnBrowsing) async {
    switch state {
    case .required, .failed: break
    default: return
    }
    state = .submitting
    let attempt: SingleSignOnAttempt
    let callbackURL: URL?
    do {
      attempt = try await accountLifecycle.beginSingleSignOnReauthentication()
    } catch {
      fail(with: error)
      return
    }
    do {
      callbackURL = try await browser.authenticate(
        at: attempt.authorizationURL, callbackScheme: SingleSignOnAttempt.callbackScheme,
        prefersEphemeralSession: false)
    } catch {
      attempt.abandon()
      fail(with: error)
      return
    }
    guard let callbackURL else {
      attempt.abandon()
      state = .required
      return
    }
    do {
      try await accountLifecycle.reauthenticate(singleSignOn: attempt, callbackURL: callbackURL)
      state = .idle
    } catch {
      fail(with: error)
    }
  }

  private func fail(with error: Error) {
    state = .failed((error as? AccountLifecycleError) ?? .unreachable)
  }

  /// Returns to `.required`, never `.idle`, discarding whatever password was typed. Recovery
  /// stays latched until a same-account login succeeds; only a `submit` success path may clear
  /// it. A no-op from `.idle`/mid-flight.
  public func cancel() {
    switch state {
    case .required, .failed:
      password = ""
      apiToken = ""
      state = .required
    default:
      break
    }
  }
}
