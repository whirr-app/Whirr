import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#endif

public struct WatchAccountStamp: Codable, Sendable, Equatable, Hashable {
  public let accountIdentityHash: String
  public let serverIdentityHash: String

  public init(accountIdentityHash: String, serverIdentityHash: String) throws {
    guard Self.isSafeIdentity(accountIdentityHash), Self.isSafeIdentity(serverIdentityHash) else {
      throw WatchProtocolCodingError.invalidValue
    }
    self.accountIdentityHash = accountIdentityHash
    self.serverIdentityHash = serverIdentityHash
  }

  private static func isSafeIdentity(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= WatchProtocolVersion.maxMetadataStringBytes
      && !value.contains("://") && !WatchProtocolValidation.containsControlCharacter(value)
  }

  private enum CodingKeys: String, CodingKey { case accountIdentityHash, serverIdentityHash }
  public func validate() throws {
    guard Self.isSafeIdentity(accountIdentityHash), Self.isSafeIdentity(serverIdentityHash) else {
      throw WatchProtocolCodingError.invalidValue
    }
  }
}

extension WatchAccountStamp {
  /// The one recipe both devices use; the inputs are the normalized server identity and the
  /// server user ID, never a token, password or user-facing URL.
  public static func authenticated(serverIdentity: String, userID: String) throws -> WatchAccountStamp {
    #if canImport(CryptoKit)
      func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
      }
      return try WatchAccountStamp(
        accountIdentityHash: hash("\(serverIdentity)\u{1F}\(userID)"),
        serverIdentityHash: hash(serverIdentity))
    #else
      throw WatchProtocolCodingError.cryptographyUnavailable
    #endif
  }
}
