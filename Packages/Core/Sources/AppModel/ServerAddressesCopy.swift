import SyncEngine

/// User-facing messages for server-address management. These messages never echo
/// an address, credential, or server-provided value.
public enum ServerAddressesCopy {
  public static let listTitle = "Server addresses"
  public static let addAddress = "Add address"
  public static let removeAddress = "Remove"
  public static let preferred = "Preferred"
  /// The row badge, not the sentence: `unreachable` below is the failure message shown after a
  /// probe, while this labels a saved address whose last probe failed.
  public static let unreachableBadge = "Unreachable"
  public static let active = "Active"
  public static let setPreferred = "Set as preferred"
  public static let addTitle = "Add address"
  public static let cancel = "Cancel"
  public static let credentialsTitle = "Credentials"
  public static let verifyAndAdd = "Verify and add"
  public static let username = "Username"
  public static let password = "Password"
  public static let apiToken = "API token"
  public static let noAccount = "There is no signed-in account to manage."
  public static let duplicateAddress = "That address is already saved."
  public static let activeAddressUnreachable = "This address could not be reached. Nothing was saved."
  public static let differentServerOrUser =
    "This address answered for a different server or user. Nothing was saved."
  public static let lastAddress = "Keep at least one address."
  public static let activeAddress = "This address is in use. Switch to another one first."
  public static let endpointNotFound = "That address is no longer saved."
  public static let reorderMismatch = "The address order could not be saved."
  public static let localPersistenceFailed = "The address could not be saved on this device."
  public static let credentialsRequired = "Sign-in credentials are required to prove this address."
  public static let malformedURL = "Enter a valid server address."
  public static let incompatibleServer = "This server version is not supported."
  public static let notAudiobookshelfServer = "This address is not an Audiobookshelf server."
  public static let blockedByProxy =
    "A proxy in front of the server refused the request. Add the headers it requires, then try again."
  public static let invalidCredentials = "Those sign-in credentials were not recognized."
  public static let unreachable = "Could not reach this address. Try again when the server is available."
  public static let tlsUntrusted = "This server's security certificate is not trusted."
  public static let accountMismatch = "Those credentials belong to a different Audiobookshelf user."
  public static let loginRateLimited = "Too many sign-in attempts. Try again shortly."
  public static let deviceBoundToDifferentAccount =
    "This device is already bound to a different account."
  public static let localStateUnreadable = "The saved account details could not be read."
  public static let keychainUnavailable = "This device could not access its secure sign-in storage."
  public static let generic = "Something went wrong while managing server addresses."

  public static func message(for error: AccountEndpointError) -> String {
    switch error {
    case .noAccount: noAccount
    case .duplicateAddress: duplicateAddress
    case .credentialsRequired: credentialsRequired
    case .differentServerOrUser: differentServerOrUser
    case .activeAddressUnreachable: activeAddressUnreachable
    case .lastAddress: lastAddress
    case .activeAddress: activeAddress
    case .endpointNotFound: endpointNotFound
    case .reorderMismatch: reorderMismatch
    case .localPersistenceFailed: localPersistenceFailed
    }
  }

  public static func message(for error: AccountLifecycleError) -> String {
    switch error {
    case .malformedURL: malformedURL
    case .unreachable: unreachable
    case .tlsUntrusted: tlsUntrusted
    case .incompatibleServer: incompatibleServer
    case .invalidCredentials: invalidCredentials
    case .loginRateLimited: loginRateLimited
    case .accountMismatch: accountMismatch
    case .deviceBoundToDifferentAccount: deviceBoundToDifferentAccount
    case .notAudiobookshelfServer: notAudiobookshelfServer
    case .blockedByProxy: blockedByProxy
    case .redirected(let target): SetupFlowCopy.redirectedText(target)
    case .localStateUnreadable: localStateUnreadable
    case .keychainUnavailable: keychainUnavailable
    case .localPersistenceFailed: localPersistenceFailed
    // Address management never runs a single sign-on.
    case .singleSignOnFailed: generic
    }
  }
}
