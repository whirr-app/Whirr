import Foundation
import SyncEngine

/// A single recovery message: a stable `key` for tests/analytics to key off, and the
/// user-facing `text` a screen renders verbatim. Two errors never share a `key`.
public struct RecoveryMessage: Sendable, Equatable {
  public enum Key: String, Sendable, Equatable {
    case malformedURL
    case unreachable
    case tlsUntrusted
    case incompatibleServer
    case invalidCredentials
    case accountMismatch
    case deviceBoundToDifferentAccount
    case loginRateLimited
    case localPersistenceFailed
    case notAudiobookshelfServer
    case blockedByProxy
    case redirected
    case localStateUnreadable
    case keychainUnavailable
    case singleSignOnRedirectNotAllowed
    case singleSignOnUnavailable
    case singleSignOnCallbackRejected
    case singleSignOnExpired
    case singleSignOnRefused
    case singleSignOnProxyCookieConflict
    case singleSignOnRequiresHTTPS
    case generic
  }

  public let key: Key
  public let text: String

  public init(key: Key, text: String) {
    self.key = key
    self.text = text
  }
}

/// Recovery/informational copy for `SetupFlowModel`. Each `AccountLifecycleError` case maps to
/// one distinct, actionable, non-technical message. Components render this text and never
/// hardcode their own.
public enum SetupFlowCopy {
  public static func recoveryMessage(for error: AccountLifecycleError) -> RecoveryMessage {
    switch error {
    case .malformedURL:
      return RecoveryMessage(
        key: .malformedURL,
        text: "That doesn't look like a valid server address. Check the URL for typos and try again."
      )
    case .unreachable:
      return RecoveryMessage(
        key: .unreachable,
        text:
          "Couldn't reach that server. Check that it's online and that your network or Tailscale connection is working, then try again.\nIf your server is behind an authenticating proxy, add its required headers under Advanced."
      )
    case .tlsUntrusted:
      return RecoveryMessage(
        key: .tlsUntrusted,
        text:
          "This server's security certificate isn't trusted. Verify the certificate before continuing, or contact your server admin."
      )
    case .incompatibleServer(let detectedVersion):
      let version = detectedVersion ?? "an unrecognized version"
      return RecoveryMessage(
        key: .incompatibleServer,
        text:
          "This server is running \(version), which is older than the minimum supported version. Ask your server admin to upgrade Audiobookshelf."
      )
    case .invalidCredentials:
      return RecoveryMessage(
        key: .invalidCredentials,
        text: "Those sign-in credentials weren't recognized. Check your credentials and try again."
      )
    case .loginRateLimited(let retryAfter):
      return RecoveryMessage(
        key: .loginRateLimited,
        text:
          "This sign-in attempt wasn't sent because we're pacing requests to the server. Try again in \(Self.retryWindow(retryAfter))."
      )
    case .accountMismatch:
      return RecoveryMessage(
        key: .accountMismatch,
        text:
          "Those credentials belong to a different account. To use it, log out of this one first — logging out removes this device's downloads and local data."
      )
    case .deviceBoundToDifferentAccount:
      return RecoveryMessage(
        key: .deviceBoundToDifferentAccount,
        text:
          "This device holds data for a different account. Remove the existing account data first, then sign in again."
      )
    case .localPersistenceFailed:
      return RecoveryMessage(
        key: .localPersistenceFailed,
        text:
          "You're signed in successfully, but this device couldn't save your account details. Make sure the device is unlocked and has free space, then try again."
      )
    case .notAudiobookshelfServer:
      return RecoveryMessage(
        key: .notAudiobookshelfServer,
        text:
          "Something answered at that address, but it doesn't look like an Audiobookshelf server. Check that the URL points at Audiobookshelf itself — including any port or path your server uses — rather than a router, NAS, or reverse-proxy landing page."
      )
    case .blockedByProxy:
      return RecoveryMessage(
        key: .blockedByProxy,
        text:
          "Something in front of Audiobookshelf refused the request. If your server is behind a reverse proxy or access gateway, add the headers it requires under Advanced, then try again."
      )
    case .redirected(let target):
      return RecoveryMessage(key: .redirected, text: redirectedText(target))
    case .localStateUnreadable:
      return RecoveryMessage(
        key: .localStateUnreadable,
        text:
          "This device couldn't read the account details it already has, so the sign-in wasn't attempted. Make sure the device is unlocked, then try again."
      )
    case .keychainUnavailable:
      return RecoveryMessage(
        key: .keychainUnavailable,
        text:
          "This copy of the app can't use the device keychain, so it can't store your sign-in. That's a problem with the build rather than your device or your server — reinstall from the App Store, or report it if you installed this build yourself."
      )
    case .singleSignOnFailed(let failure):
      return singleSignOnMessage(for: failure)
    }
  }

  /// Single sign-on failures read the same at setup and in recovery: none is about this device or
  /// its downloads, so `AuthRecoveryCopy` reuses these.
  public static func singleSignOnMessage(for failure: SingleSignOnFailure) -> RecoveryMessage {
    switch failure {
    case .redirectURINotAllowed:
      return RecoveryMessage(
        key: .singleSignOnRedirectNotAllowed,
        text:
          "This server's single sign-on doesn't allow Whirr yet. Ask your server admin to add \(SingleSignOnAttempt.redirectURI) to Allowed Mobile Redirect URIs in the server's authentication settings."
      )
    case .unavailable:
      return RecoveryMessage(
        key: .singleSignOnUnavailable,
        text:
          "Single sign-on isn't available on this server right now. Ask your server admin to check its OpenID Connect settings, or sign in another way."
      )
    case .callbackRejected:
      return RecoveryMessage(
        key: .singleSignOnCallbackRejected,
        text: "The sign-in page sent back something Whirr didn't ask for, so it wasn't used. Try signing in again."
      )
    case .attemptExpired:
      return RecoveryMessage(
        key: .singleSignOnExpired,
        text: "That sign-in expired before it finished, possibly because the server restarted. Try signing in again."
      )
    case .refused:
      return RecoveryMessage(
        key: .singleSignOnRefused,
        text:
          "Your sign-in provider or the server didn't accept that sign-in. Try again, or ask your server admin whether your account can use single sign-on."
      )
    case .proxyCookieConflict:
      return RecoveryMessage(
        key: .singleSignOnProxyCookieConflict,
        text:
          "A custom header for this server sets a cookie that single sign-on also uses. Remove that cookie from the server's custom headers, then try again."
      )
    case .requiresHTTPS:
      return RecoveryMessage(
        key: .singleSignOnRequiresHTTPS,
        text:
          "Whirr only uses single sign-on with an https:// server address, so the sign-in page can't be swapped on the way. Sign in with an API token instead."
      )
    }
  }

  /// Shared with `ServerAddressesCopy` so both screens offer the same address.
  static func redirectedText(_ target: URL?) -> String {
    guard let address = redirectDisplayAddress(target) else {
      return
        "This address redirects somewhere else, which Whirr doesn't follow. If your server uses HTTPS, enter the address starting with https:// instead."
    }
    return "This address redirects to \(address) — use that address instead."
  }

  /// The server base a refused `/status` redirect pointed to: scheme, host, port and any path
  /// prefix, without the `/status` that was requested or any credentials, query or fragment.
  static func redirectDisplayAddress(_ target: URL?) -> String? {
    guard let target, var components = URLComponents(url: target, resolvingAgainstBaseURL: true),
      components.scheme != nil, components.host?.isEmpty == false
    else { return nil }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    var path = components.path
    if path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix("/status") { path.removeLast("/status".count) }
    components.path = path
    return components.string
  }

  public static let genericRecoveryMessage = RecoveryMessage(
    key: .generic,
    text: "Something went wrong. Try again in a moment."
  )

  public static let libraryDiscoveryRecoveryMessage = RecoveryMessage(
    key: .generic,
    text: "Couldn't load your libraries. Check your connection and try again."
  )

  public static let noAccessibleLibrariesRecoveryMessage = RecoveryMessage(
    key: .generic,
    text: "This account doesn't have access to any libraries. Try again or sign out."
  )

  /// Shown at the credentials step for a server that advertises only OpenID sign-in.
  public static let singleSignOnOnlyNotice =
    "This server signs in with single sign-on. If sign-in doesn't open, ask your server admin to add \(SingleSignOnAttempt.redirectURI) to Allowed Mobile Redirect URIs."

  public static let singleSignOnNeedsHTTPSNotice =
    "This server signs in with single sign-on, which Whirr only uses with an https:// address. Sign in with an API token, or go back and enter the server's https:// address."

  public static let singleSignOnButtonTitle = "Sign in with SSO"

  /// A server restart can surface inside the browser as a server-rendered error page. The user
  /// closes it, Whirr sees only a cancel and stays silent, so the button carries this line.
  public static let singleSignOnFootnote = "If the sign-in page showed an error, close it and try again."

  public static let singleSignOnProxyHeadersNote =
    "This server needs custom headers, which the sign-in page can't send. If your proxy requires them on every request, single sign-on won't work here, but an API token will."

  /// SSO-only servers still accept API tokens: ABS takes API keys whichever sign-in methods are on.
  public static let useAPITokenTitle = "Use an API token instead"

  private static func retryWindow(_ retryAfter: TimeInterval) -> String {
    guard retryAfter.isFinite else { return "a short while" }
    let seconds = max(1, Int(retryAfter.rounded(.up)))
    return seconds == 1 ? "about 1 second" : "about \(seconds) seconds"
  }
}
