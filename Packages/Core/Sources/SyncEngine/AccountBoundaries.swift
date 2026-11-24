import ABSApi
import Foundation
import Persistence

/// A server that passed setup validation (`AccountLifecycle.validateServer`): a normalized URL,
/// scheme, server-reported version, and the validated proxy fields used for the probe. AppModel
/// can hold and forward this boundary value without importing ABSApi (ARCHITECTURE.md §1 table).
public struct ValidatedServer: Sendable, Equatable {
  public let serverURL: URL
  public let serverVersion: String
  public let customHeaders: CustomHeaders
  /// True when the URL was typed with an `http` scheme. An informational note, never a blocking
  /// error (SECURITY.md Transport).
  public let isPlainHTTP: Bool
  /// The sign-in methods `/status` advertised; nil when the response did not say.
  public let authMethods: Set<ServerAuthMethod>?

  public init(
    serverURL: URL,
    serverVersion: String,
    isPlainHTTP: Bool,
    customHeaders: CustomHeaders = .none,
    authMethods: Set<ServerAuthMethod>? = nil
  ) {
    self.serverURL = serverURL
    self.serverVersion = serverVersion
    self.customHeaders = customHeaders
    self.isPlainHTTP = isPlainHTTP
    self.authMethods = authMethods
  }

  /// True only when the server positively advertises OpenID and not password sign-in. An absent
  /// or empty list is a malformed response, so it never counts: the password form stays.
  public var offersOnlySingleSignOn: Bool {
    guard let authMethods else { return false }
    return authMethods.contains(.openID) && authMethods.contains(.local) == false
  }

  /// Whether the server needs custom proxy headers. The SSO browser cannot send them on its later
  /// hops back to the server, so setup says so.
  public var hasCustomHeaders: Bool {
    customHeaders.headers.isEmpty == false
  }

  /// Whether the credentials step offers single sign-on. Never over plain HTTP (SECURITY.md rule
  /// 3). An absent or empty list is a malformed response, so it offers both methods and leaves the
  /// first leg to report a server without OpenID precisely.
  public var offersSingleSignOn: Bool {
    guard isPlainHTTP == false else { return false }
    guard let authMethods, authMethods.isEmpty == false else { return true }
    return authMethods.contains(.openID)
  }
}

/// `ValidatedServer` carries the advertised sign-in methods to AppModel, which may not import
/// ABSApi; ABSApi remains the owning module (the `PlaybackStreamAuthorization` precedent).
public typealias ServerAuthMethod = ABSApi.ServerAuthMethod

/// The stored credential mode exposed to AppModel without exposing ABSApi's `TokenPair`. A nil
/// refresh token is the API-token mode, derived from the token store. A pair with a refresh token
/// is `.openID` when the account row records an OIDC login, because the pair alone cannot tell it
/// from a password login.
public enum AccountAuthenticationMode: Sendable, Equatable {
  case password
  case apiToken
  case openID
}

/// The distinct recovery categories setup needs: invalid TLS, old server, bad credentials,
/// malformed URL and unreachable server each get their own message. Consumed by AppModel's copy
/// catalog.
public enum AccountLifecycleError: Error, Sendable, Equatable {
  case malformedURL
  case unreachable
  case tlsUntrusted
  case incompatibleServer(detectedVersion: String?)
  case invalidCredentials
  /// The user initiated a login while the shared login-route backoff window was still open. The
  /// request was not sent to the server.
  case loginRateLimited(retryAfter: TimeInterval)
  /// Same-account re-authentication returned a different server user than the stored account.
  /// Distinct from `.invalidCredentials`: the credentials were valid, just for the wrong person,
  /// so recovery copy can route this to explicit logout instead of "check your password".
  case accountMismatch
  /// A tokenless account row binds this device's local data to a different server account.
  case deviceBoundToDifferentAccount
  /// The URL answered, but not as Audiobookshelf: `GET /status` did not return JSON with
  /// `app == "audiobookshelf"`. Distinct from `.unreachable` (something replied) and
  /// `.incompatibleServer` (which has a real ABS version to name). A Synology DSM portal can pass
  /// validation and fail later at the login POST with a 405, so setup must refuse the address.
  case notAudiobookshelfServer
  /// `GET /status` answered 401 or 403. Audiobookshelf never gates that route, so a reverse proxy
  /// or access gateway in front of it refused the request, usually for a missing header. Not
  /// `.unreachable`, whose copy sends the user to check a network that answered immediately.
  case blockedByProxy
  /// `GET /status` answered with a redirect the app refuses to follow (another scheme, host, or
  /// port). `target` is where it pointed, so the copy can offer that address instead; nil when the
  /// response named none.
  case redirected(target: URL?)
  /// This device could not read its own stored account state before the sign-in request was
  /// sent. Not `.localPersistenceFailed`: nothing was authenticated yet, so copy that says
  /// "you're signed in, but we couldn't save it" would misdescribe the failure.
  case localStateUnreadable
  /// The Keychain refused with `errSecMissingEntitlement` (-34018): this build lacks its Keychain
  /// access group or the profile does not grant it, and the user can do nothing. Not
  /// `.localPersistenceFailed`, whose "unlock the device, free up space" recovery misleads here.
  case keychainUnavailable
  /// The server accepted the credentials, but a Keychain or database write (or the header read
  /// that snapshots rollback state) threw on the way back. Recovery is local (free space, unlock,
  /// retry) and the copy must not imply the sign-in failed.
  case localPersistenceFailed
  /// A single sign-on failed in one of the ways that has distinct copy. A cancelled browser
  /// session is never thrown: the App stays silent.
  case singleSignOnFailed(SingleSignOnFailure)
}

/// Setup, login, and logout, as seen by the app layer.
///
/// AppModel may not import ABSApi (ARCHITECTURE.md §1), so the protocol lives here, the lowest
/// module it may see. The production conformance wraps `ABSClient`.
public protocol AccountLifecycle: Sendable {
  var isAuthenticated: Bool { get }
  var authenticationMode: AccountAuthenticationMode { get }

  /// Normalizes `url`, fetches the pre-login `/status` version, and runs the compatibility
  /// gate. Never mutates persisted state; the setup flow calls it before asking for credentials.
  func validateServer(url: URL, customHeaders: [String: String]) async throws -> ValidatedServer

  /// Logs in through `ABSClient`, validates any tokenless-row identity binding, persists headers
  /// and the single account row, then commits tokens. First creation generates the stable client
  /// UUID; an update preserves it, as sync relies on it never regenerating.
  func login(server: ValidatedServer, username: String, password: String) async throws

  /// Validates a pasted API token through `/api/me`, then persists the same account record as a
  /// password login. The token is consumed by the production ABSApi operation and is never part of
  /// a durable boundary value.
  func login(server: ValidatedServer, apiToken: String) async throws

  /// Calls `ABSClient.logout`, which wipes tokens even when the server call fails, then removes
  /// every account-owned DB row. A failed remote confirmation is swallowed only after local
  /// removal completes, so every error reaching the caller is blocking and retryable. The
  /// warn-first confirmation contract stays in AppModel.
  func logout() async throws

  /// The relaunch-surviving signal that a confirmed removal has not completed both verification
  /// sweeps (`AccountRemovalCoordinator.isRemovalPending()`), used by `RootModel` as the
  /// launch-time shell gate. Defaults to `false` unless a conformance wires a coordinator.
  func isRemovalPending() async throws -> Bool

  /// Resumes a pending removal from wherever it left off, or does nothing if none is pending
  /// (`AccountRemovalCoordinator.resumeIfNeeded()`). `RootModel` calls this once, at launch.
  /// Defaults to a no-op.
  func resumeRemovalIfNeeded() async throws

  /// Same-account recovery. Targets the stored account row, never a caller-supplied server or
  /// user id, and never mutates the row or removes local data on any path (`login`/`logout` are
  /// the only operations that touch it). A returned user other than the stored `serverUserId`
  /// throws `.accountMismatch` without persisting anything. Backed by
  /// `ABSClient.reauthenticate(credentials:expectedAccount:)`, so success also replaces the live
  /// client's cached tokens and clears its rejection latch, with no second client or refresh
  /// pipeline. Defaults to `.unreachable` so older conformances (App harnesses, fakes) build.
  func reauthenticate(username: String, password: String) async throws

  /// Same-account recovery for an account whose stored pair has no refresh token.
  func reauthenticate(apiToken: String) async throws

  /// Asks the validated server to start a mobile OIDC sign-in and returns the
  /// attempt whose `authorizationURL` the App opens in the browser. Persists nothing.
  func beginSingleSignOn(server: ValidatedServer) async throws -> SingleSignOnAttempt

  /// Exchanges the browser's callback for the attempt, then persists exactly as `login` does for
  /// a password, recording that the account signs in through OpenID. The attempt is used up
  /// whatever the outcome.
  func login(server: ValidatedServer, singleSignOn attempt: SingleSignOnAttempt, callbackURL: URL) async throws

  /// `beginSingleSignOn` for the stored account's server, for same-account recovery.
  func beginSingleSignOnReauthentication() async throws -> SingleSignOnAttempt

  /// Same-account recovery through single sign-on, with the same guarantees as
  /// `reauthenticate(username:password:)`: a different user is refused without persisting anything.
  func reauthenticate(singleSignOn attempt: SingleSignOnAttempt, callbackURL: URL) async throws

  /// The stored account's server identity, formatted for the recovery banner and sheet. `nil`
  /// only when no account row exists, which cannot happen while recovery is required. Read
  /// synchronously from the same row `isAuthenticated` does, never cached. Defaults to `nil`.
  var storedServerDisplayString: String? { get }
}

extension AccountLifecycle {
  public var authenticationMode: AccountAuthenticationMode { .password }

  /// Compatibility convenience for non-setup callers that have no caller-supplied proxy fields.
  /// The protocol requirement itself stays explicit because setup must pass its in-memory fields
  /// into the pre-authentication probe.
  public func validateServer(url: URL) async throws -> ValidatedServer {
    try await validateServer(url: url, customHeaders: [:])
  }

  public func isRemovalPending() async throws -> Bool { false }
  public func resumeRemovalIfNeeded() async throws {}
  public func reauthenticate(username: String, password: String) async throws {
    throw AccountLifecycleError.unreachable
  }
  public func login(server: ValidatedServer, apiToken: String) async throws {
    throw AccountLifecycleError.unreachable
  }
  public func reauthenticate(apiToken: String) async throws {
    throw AccountLifecycleError.unreachable
  }
  public func beginSingleSignOn(server: ValidatedServer) async throws -> SingleSignOnAttempt {
    throw AccountLifecycleError.unreachable
  }
  public func login(
    server: ValidatedServer, singleSignOn attempt: SingleSignOnAttempt, callbackURL: URL
  ) async throws {
    throw AccountLifecycleError.unreachable
  }
  public func beginSingleSignOnReauthentication() async throws -> SingleSignOnAttempt {
    throw AccountLifecycleError.unreachable
  }
  public func reauthenticate(singleSignOn attempt: SingleSignOnAttempt, callbackURL: URL) async throws {
    throw AccountLifecycleError.unreachable
  }
  public var storedServerDisplayString: String? { nil }
}

/// The profile fields the account Settings surface is allowed to render. Smaller than ABSApi's
/// `UserProfile`: the wire decoder proves the presence of active/locked flags, but this boundary
/// only exposes identity and library access, and does not carry the server's `permissions`
/// object across.
public struct ServerAccountProfile: Sendable, Equatable {
  public let username: String?
  public let type: String?
  public let librariesAccessible: [String]

  public init(username: String?, type: String?, librariesAccessible: [String]) {
    self.username = username
    self.type = type
    self.librariesAccessible = librariesAccessible
  }
}

/// A durable library projection for the account surface. `LibraryRecord` stays inside Persistence;
/// this value carries only the fields the screen renders.
public struct ServerAccountLibrary: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let mediaType: String

  public init(id: String, name: String, mediaType: String) {
    self.id = id
    self.name = name
    self.mediaType = mediaType
  }
}

/// Header presence crosses the AppModel boundary as names only. There is no value accessor on
/// this type: a stored proxy/service-token value must never become UI state (SECURITY.md).
public struct CustomHeaderSummary: Sendable, Equatable {
  public let names: [String]

  public init(names: [String]) {
    self.names = names.sorted()
  }

  public var count: Int { names.count }
}

/// The part of the account screen that remains useful without a live `/api/me` response.
public struct ServerAccountDurableSettings: Sendable, Equatable {
  public let serverVersion: String
  public let libraries: [ServerAccountLibrary]
  public let syncStatus: LibrarySyncStatus
  public let customHeaders: CustomHeaderSummary

  public init(
    serverVersion: String,
    libraries: [ServerAccountLibrary],
    syncStatus: LibrarySyncStatus,
    customHeaders: CustomHeaderSummary
  ) {
    self.serverVersion = serverVersion
    self.libraries = libraries
    self.syncStatus = syncStatus
    self.customHeaders = customHeaders
  }
}

public enum ServerAccountReadingError: Error, Sendable, Equatable {
  case notAuthenticated
  case malformedAccount
}

/// AppModel's read-only account boundary. Durable rows and the live profile are separate calls so
/// a failed/offline profile request cannot erase the server, library, sync, or header information
/// already present on the device.
public protocol ServerAccountReading: Sendable {
  func readDurableSettings() async throws -> ServerAccountDurableSettings
  func fetchProfile() async throws -> ServerAccountProfile
}

/// Setup-only and test compositions have no authenticated account surface to read.
public struct NoOpServerAccountReading: ServerAccountReading, Sendable {
  public init() {}

  public func readDurableSettings() async throws -> ServerAccountDurableSettings {
    throw ServerAccountReadingError.notAuthenticated
  }

  public func fetchProfile() async throws -> ServerAccountProfile {
    throw ServerAccountReadingError.notAuthenticated
  }
}
