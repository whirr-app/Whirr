import Foundation
import SyncEngine

/// All user-facing copy for the persistent shell recovery indicator and its credential sheet.
/// Shell components render this text verbatim, as with `SetupFlowCopy`, but this catalog speaks to
/// an already-signed-in user with local data at stake. It never says "logout," "account removed,"
/// or "downloads deleted", and the unreachable/invalid-credentials copy must say downloads remain
/// available and retry is safe.
///
/// The surface is the navigation bar's recovery glyph and its popover (`ShellStatusIndicatorView`),
/// not a banner: a banner would cover the toolbar, making Settings, the only route to signing out
/// of an account the server no longer recognises, unreachable during recovery. It is persistent
/// for every non-idle state, non-blocking, and has no destructive action of its own.
public enum AuthRecoveryCopy {

  // MARK: - Persistent shell status indicator

  public static let indicatorTitle = "Reconnect to Audiobookshelf"
  public static let indicatorMessage =
    "Existing downloads remain available. Reconnect to download or sync."
  public static let indicatorSystemImage = "person.crop.circle.badge.exclamationmark"
  public static let reconnectActionLabel = "Reconnect"
  public static let reconnectActionAccessibilityHint = "Opens the sign-in sheet to reconnect to the server"

  // MARK: - Credential sheet

  public static let sheetTitle = "Sign In Again"
  public static let sheetServerLabel = "Server"
  public static let usernameLabel = "Username"
  public static let passwordLabel = "Password"
  public static let apiTokenLabel = "API token"
  public static let tryOtherAddressesLabel = "Try other addresses"
  public static let tryOtherAddressesAccessibilityHint =
    "Tries the other saved server addresses before asking for credentials"
  public static let cancelLabel = "Cancel"
  public static let submitLabel = "Reconnect"
  public static let submittingLabel = "Signing in…"

  // MARK: - Error copy per `AccountLifecycleError` category

  /// Distinct, actionable copy per category. Not `SetupFlowCopy` text, which has no reason to
  /// reassure about downloads during first-time setup.
  public static func errorMessage(for error: AccountLifecycleError) -> RecoveryMessage {
    switch error {
    case .invalidCredentials:
      return RecoveryMessage(
        key: .invalidCredentials,
        text:
          "Those sign-in credentials weren't recognized. Your downloads are unaffected — check your credentials and try again."
      )
    case .loginRateLimited(let retryAfter):
      return RecoveryMessage(
        key: .loginRateLimited,
        text:
          "This sign-in attempt wasn't sent because we're pacing requests to the server. Try again in \(Self.retryWindow(retryAfter)); your downloads remain available."
      )
    case .unreachable:
      return RecoveryMessage(
        key: .unreachable,
        text:
          "Couldn't reach the server. Your downloads remain available while you're offline — check your connection and try again."
      )
    case .tlsUntrusted:
      return RecoveryMessage(
        key: .tlsUntrusted,
        text:
          "This server's security certificate isn't trusted. Verify the certificate before continuing, or contact your server admin."
      )
    case .accountMismatch:
      return RecoveryMessage(
        key: .accountMismatch,
        text:
          "Those credentials belong to a different Audiobookshelf user. To use that account instead, first Log Out from Server & Account in Settings — logging out removes this device's downloads."
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
          "You're signed in again, but this device couldn't save the new sign-in. Your downloads are unaffected — make sure the device is unlocked and has free space, then try again."
      )
    case .localStateUnreadable:
      return RecoveryMessage(
        key: .localStateUnreadable,
        text:
          "This device couldn't read the account details it already has, so the sign-in wasn't attempted. Your downloads are unaffected — make sure the device is unlocked, then try again."
      )
    case .keychainUnavailable:
      return RecoveryMessage(
        key: .keychainUnavailable,
        text:
          "This copy of the app can't use the device keychain, so it can't store the new sign-in. That's a problem with the build rather than your device or your server; your downloads are unaffected. Reinstall from the App Store, or report it if you installed this build yourself."
      )
    // Server identity is settled during setup and never re-validated here, so these cannot
    // describe a recovery attempt.
    case .malformedURL, .incompatibleServer, .notAudiobookshelfServer, .blockedByProxy, .redirected:
      return genericRecoveryMessage
    case .singleSignOnFailed(let failure):
      return SetupFlowCopy.singleSignOnMessage(for: failure)
    }
  }

  public static let genericRecoveryMessage = RecoveryMessage(
    key: .generic,
    text: "Something went wrong. Your downloads are unaffected — try again in a moment."
  )

  /// Every literal string this catalog can render, so a test can scan the whole catalog for
  /// forbidden wording ("logout," "account removed," "downloads deleted") without a hand-kept list.
  public static var allCopy: [String] {
    [
      indicatorTitle,
      indicatorMessage,
      reconnectActionLabel,
      reconnectActionAccessibilityHint,
      sheetTitle,
      sheetServerLabel,
      usernameLabel,
      passwordLabel,
      apiTokenLabel,
      tryOtherAddressesLabel,
      tryOtherAddressesAccessibilityHint,
      cancelLabel,
      submitLabel,
      submittingLabel,
      SetupFlowCopy.singleSignOnButtonTitle,
      SetupFlowCopy.singleSignOnFootnote,
      genericRecoveryMessage.text,
      errorMessage(for: .invalidCredentials).text,
      errorMessage(for: .loginRateLimited(retryAfter: 30)).text,
      errorMessage(for: .unreachable).text,
      errorMessage(for: .tlsUntrusted).text,
      errorMessage(for: .accountMismatch).text,
      errorMessage(for: .deviceBoundToDifferentAccount).text,
      errorMessage(for: .localPersistenceFailed).text,
      errorMessage(for: .localStateUnreadable).text,
      errorMessage(for: .keychainUnavailable).text,
      errorMessage(for: .malformedURL).text,
      errorMessage(for: .incompatibleServer(detectedVersion: nil)).text,
    ] + SingleSignOnFailure.allCases.map { errorMessage(for: .singleSignOnFailed($0)).text }
  }

  private static func retryWindow(_ retryAfter: TimeInterval) -> String {
    guard retryAfter.isFinite else { return "a short while" }
    let seconds = max(1, Int(retryAfter.rounded(.up)))
    return seconds == 1 ? "about 1 second" : "about \(seconds) seconds"
  }
}
