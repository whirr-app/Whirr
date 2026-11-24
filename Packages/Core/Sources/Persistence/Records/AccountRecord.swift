import CryptoKit
import Foundation
import GRDB

/// One row per signed-in account. The credential namespace is the opaque credential and
/// account-fence identity; `serverBaseURL` is the active endpoint. Account-owned tables carry an
/// `accountId` FK to keep multi-account migration possible.
///
/// `clientUUID` is generated once at first login and never regenerated on relaunch. It is the
/// origin key compared in progress-conflict resolution.
public struct AccountRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
  public static let databaseTableName = "account"

  public var id: Int64?
  public var clientUUID: String
  public var credentialNamespace: String
  public var serverBaseURL: String
  public var serverUserId: String
  public var serverVersion: String
  /// The server-provided login hint for a default/first library, retained for compatible account
  /// decoding. It is not this device's rendered-library or inclusion selection.
  public var defaultLibraryId: String?
  /// The device-local inclusion policy for this account's accessible libraries.
  public var librarySelectionMode: LibrarySelectionMode
  /// True when the last login used the server's OpenID flow. Password versus API token is derived
  /// from the Keychain pair, but this cannot be, because an OIDC pair has a refresh token just
  /// like a password pair.
  public var signsInWithOpenID: Bool

  public init(
    id: Int64? = nil,
    clientUUID: String,
    credentialNamespace: String? = nil,
    serverBaseURL: String,
    serverUserId: String,
    serverVersion: String,
    defaultLibraryId: String? = nil,
    librarySelectionMode: LibrarySelectionMode = .all,
    signsInWithOpenID: Bool = false
  ) {
    self.id = id
    self.clientUUID = clientUUID
    self.credentialNamespace = credentialNamespace ?? Self.credentialNamespace(forClientUUID: clientUUID)
    self.serverBaseURL = serverBaseURL
    self.serverUserId = serverUserId
    self.serverVersion = serverVersion
    self.defaultLibraryId = defaultLibraryId
    self.librarySelectionMode = librarySelectionMode
    self.signsInWithOpenID = signsInWithOpenID
  }

  public static func credentialNamespace(forClientUUID clientUUID: String) -> String {
    "account:\(clientUUID)"
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

extension AccountRecord {
  /// Opaque persisted credential/user identity for the account lifecycle fence. Length-prefixing
  /// prevents ambiguous concatenations, and hashing keeps the credential namespace and user id
  /// out of the operation row while still making replacement detection deterministic across
  /// relaunches. Changing the active endpoint is not account replacement; a different user id is.
  public var serverIdentityFingerprint: String {
    var material = Data()
    Self.appendLengthPrefixed(credentialNamespace, to: &material)
    Self.appendLengthPrefixed(serverUserId, to: &material)
    return SHA256.hash(data: material)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
    var byteCount = UInt64(value.utf8.count).bigEndian
    withUnsafeBytes(of: &byteCount) { data.append(contentsOf: $0) }
    data.append(contentsOf: value.utf8)
  }
}
