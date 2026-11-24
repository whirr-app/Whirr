import Foundation

public enum WatchSetupStatus: String, Codable, Sendable, Equatable {
  case ready
  case installed
  case wrongAccount
  case busy
  case rejected
}

/// What an installed Watch last learned from its own server requests, reported alongside an
/// `installed` status answer. Absent means not yet known: a Watch that has not loaded its
/// libraries since launch, or an older Watch that does not report it.
public enum WatchLinkHealth: String, Codable, Sendable, Equatable {
  /// The last library request succeeded.
  case healthy
  /// The server refused the Watch's token pair; only new credentials from the phone fix it.
  case signInRejected
  /// The Watch could not reach the server address.
  case serverUnreachable
}

private enum WatchSetupValidation {
  static let maxTextBytes = WatchProtocolVersion.maxMetadataStringBytes
  static let maxTokenBytes = 2_048
  static let helloAge: TimeInterval = WatchSetupLimits.window
  static let futureSkew: TimeInterval = WatchProtocolVersion.commandFutureSkewTolerance
  static let challengeLifetime: TimeInterval = WatchSetupLimits.window

  static func finite(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }

  static func text(_ value: String, required: Bool = true, allowURLMarkers: Bool = false) throws {
    guard required ? !value.isEmpty : true, value.utf8.count <= maxTextBytes,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw value.utf8.count > maxTextBytes
        ? WatchProtocolCodingError.oversizedMetadata : WatchProtocolCodingError.invalidValue
    }
    if !allowURLMarkers && (value.contains("://") || value.lowercased().hasPrefix("file:") || value.hasPrefix("/")) {
      throw WatchProtocolCodingError.forbiddenMetadata
    }
  }

  static func token(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= maxTokenBytes,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw value.utf8.count > maxTokenBytes
        ? WatchProtocolCodingError.oversizedMetadata : WatchProtocolCodingError.invalidValue
    }
  }

  static func serverURL(_ value: String) throws {
    guard value.utf8.count <= maxTextBytes else { throw WatchProtocolCodingError.oversizedMetadata }
    guard !value.isEmpty,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      let components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil
    else {
      throw WatchProtocolCodingError.forbiddenMetadata
    }
  }

  static func version(_ value: Int) throws {
    guard value == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(value) }
  }
}

private protocol WatchSetupRedactedReflectable: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{}

extension WatchSetupRedactedReflectable {
  public var description: String { "\(Self.self)(redacted)" }
  public var debugDescription: String { "\(Self.self)(redacted)" }
  public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

public struct WatchSetupHello: WatchWireValue, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable, WatchSetupRedactedReflectable
{
  public let version: Int
  public let id: UUID
  public let accountStamp: WatchAccountStamp
  public let issuedAt: Date

  public init(id: UUID, accountStamp: WatchAccountStamp, issuedAt: Date) throws {
    guard WatchSetupValidation.finite(issuedAt) else { throw WatchProtocolCodingError.invalidValue }
    self.version = WatchProtocolVersion.current
    self.id = id
    self.accountStamp = accountStamp
    self.issuedAt = issuedAt
  }

  private enum CodingKeys: String, CodingKey { case version, id, accountStamp, issuedAt }
  public static let maxWireBytes = 8 * 1024
  public func validate() throws {
    try WatchSetupValidation.version(version)
    try accountStamp.validate()

    guard WatchSetupValidation.finite(issuedAt) else {
      throw WatchProtocolCodingError.invalidValue
    }
  }
}

public struct WatchSetupChallenge: WatchWireValue, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable, WatchSetupRedactedReflectable
{
  public let version: Int
  public let id: UUID
  public let accountStamp: WatchAccountStamp
  public let nonce: UUID
  public let expiresAt: Date
  public let status: WatchSetupStatus
  public let health: WatchLinkHealth?

  public init(
    id: UUID, accountStamp: WatchAccountStamp, nonce: UUID, expiresAt: Date, status: WatchSetupStatus = .ready,
    health: WatchLinkHealth? = nil
  ) throws {
    guard WatchSetupValidation.finite(expiresAt) else { throw WatchProtocolCodingError.invalidValue }
    self.version = WatchProtocolVersion.current
    self.id = id
    self.accountStamp = accountStamp
    self.nonce = nonce
    self.expiresAt = expiresAt
    self.status = status
    self.health = health
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decode(Int.self, forKey: .version)
    try WatchSetupValidation.version(version)
    self = try Self(
      id: c.decode(UUID.self, forKey: .id), accountStamp: c.decode(WatchAccountStamp.self, forKey: .accountStamp),
      nonce: c.decode(UUID.self, forKey: .nonce), expiresAt: c.decode(Date.self, forKey: .expiresAt),
      status: c.decodeIfPresent(WatchSetupStatus.self, forKey: .status) ?? .ready,
      // Tolerant on purpose: a health value this build does not know must not make the whole
      // answer undecodable, which would turn an installed Watch into no answer at all.
      health: (try? c.decodeIfPresent(String.self, forKey: .health)).flatMap(WatchLinkHealth.init(rawValue:)))
  }

  private enum CodingKeys: String, CodingKey { case version, id, accountStamp, nonce, expiresAt, status, health }
  public static let maxWireBytes = 8 * 1024
  public func validate() throws {
    try WatchSetupValidation.version(version)
    try accountStamp.validate()

    guard WatchSetupValidation.finite(expiresAt) else {
      throw WatchProtocolCodingError.invalidValue
    }
  }
}

public struct WatchSetupCredentials: WatchWireValue, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable, WatchSetupRedactedReflectable
{
  public let version: Int
  public let id: UUID
  public let accountStamp: WatchAccountStamp
  public let nonce: UUID
  public let expiresAt: Date
  public let serverURL: String
  public let userID: String
  public let username: String?
  public let defaultLibraryID: String?
  public let accessToken: String
  public let refreshToken: String
  public let accessExpiry: Date?

  public init(
    id: UUID, accountStamp: WatchAccountStamp, nonce: UUID, expiresAt: Date, serverURL: String, userID: String,
    username: String? = nil, defaultLibraryID: String? = nil, accessToken: String, refreshToken: String,
    accessExpiry: Date? = nil
  ) throws {
    guard WatchSetupValidation.finite(expiresAt), accessExpiry.map(WatchSetupValidation.finite) ?? true else {
      throw WatchProtocolCodingError.invalidValue
    }
    try WatchSetupValidation.serverURL(serverURL)
    try WatchSetupValidation.text(userID)
    if let username { try WatchSetupValidation.text(username) }
    if let defaultLibraryID { try WatchSetupValidation.text(defaultLibraryID) }
    try WatchSetupValidation.token(accessToken)
    try WatchSetupValidation.token(refreshToken)
    self.version = WatchProtocolVersion.current
    self.id = id
    self.accountStamp = accountStamp
    self.nonce = nonce
    self.expiresAt = expiresAt
    self.serverURL = serverURL
    self.userID = userID
    self.username = username
    self.defaultLibraryID = defaultLibraryID
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.accessExpiry = accessExpiry
  }

  private enum CodingKeys: String, CodingKey {
    case version, id, accountStamp, nonce, expiresAt, serverURL, userID, username, defaultLibraryID, accessToken,
      refreshToken, accessExpiry
  }
  public static let maxWireBytes = 8 * 1024
  public func validate() throws {
    try WatchSetupValidation.version(version)
    try accountStamp.validate()
    _ = try Self(
      id: id, accountStamp: accountStamp, nonce: nonce, expiresAt: expiresAt, serverURL: serverURL, userID: userID,
      username: username, defaultLibraryID: defaultLibraryID, accessToken: accessToken, refreshToken: refreshToken,
      accessExpiry: accessExpiry)
  }
}

public struct WatchSetupReceipt: WatchWireValue, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable, WatchSetupRedactedReflectable
{
  public let version: Int
  public let id: UUID
  public let accountStamp: WatchAccountStamp
  public let nonce: UUID
  public let status: WatchSetupStatus

  public init(id: UUID, accountStamp: WatchAccountStamp, nonce: UUID, status: WatchSetupStatus) throws {
    self.version = WatchProtocolVersion.current
    self.id = id
    self.accountStamp = accountStamp
    self.nonce = nonce
    self.status = status
  }

  private enum CodingKeys: String, CodingKey { case version, id, accountStamp, nonce, status }
  public static let maxWireBytes = 8 * 1024
  public func validate() throws {
    try WatchSetupValidation.version(version)
    try accountStamp.validate()
  }
}

public struct WatchSetupAdmission: Sendable, Equatable {
  public private(set) var receipt: WatchSetupReceipt?
  private var challenge: WatchSetupChallenge?

  public init(receipt: WatchSetupReceipt? = nil) {
    self.receipt = receipt
    self.challenge = nil
  }

  /// Answers whether this Watch already holds a usable account for the asking stamp, without
  /// starting, replacing or expiring a setup attempt: it is `static` so that asking provably
  /// cannot change admission. The reply expires at `now`, so `WatchSetupAttempt` can never mistake
  /// a status answer for a challenge it may complete. `health` is attached only to an
  /// `installed` answer: it means nothing for a Watch holding no account or someone else's.
  public static func status(
    for hello: WatchSetupHello, existingAccount: WatchAccountStamp?, isInstalled: Bool, now: Date,
    health: WatchLinkHealth? = nil
  ) -> WatchSetupChallenge {
    let statusDate = WatchSetupValidation.finite(now) ? now : hello.issuedAt
    if let existingAccount, existingAccount != hello.accountStamp {
      return makeStatus(hello, now: statusDate, status: .wrongAccount)
    }
    guard isInstalled else { return makeStatus(hello, now: statusDate, status: .ready) }
    return makeStatus(hello, now: statusDate, status: .installed, health: health)
  }

  public mutating func begin(_ hello: WatchSetupHello, existingAccount: WatchAccountStamp?, now: Date)
    -> WatchSetupChallenge
  {
    let statusDate = WatchSetupValidation.finite(now) ? now : hello.issuedAt
    guard WatchSetupValidation.finite(now) else { return Self.makeStatus(hello, now: statusDate, status: .rejected) }
    if let existingAccount, existingAccount != hello.accountStamp {
      return Self.makeStatus(hello, now: now, status: .wrongAccount)
    }
    let age = now.timeIntervalSince(hello.issuedAt)
    guard age <= WatchSetupValidation.helloAge, age >= -WatchSetupValidation.futureSkew else {
      return Self.makeStatus(hello, now: now, status: .rejected)
    }
    if let challenge, challenge.status == .ready, challenge.expiresAt > now {
      if challenge.id == hello.id, challenge.accountStamp == hello.accountStamp {
        return challenge
      }
      return
        (try? WatchSetupChallenge(
          id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(), expiresAt: challenge.expiresAt, status: .busy))
        ?? Self.makeStatus(hello, now: now, status: .rejected)
    }
    guard
      let next = try? WatchSetupChallenge(
        id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(),
        expiresAt: now.addingTimeInterval(WatchSetupValidation.challengeLifetime), status: .ready)
    else {
      return Self.makeStatus(hello, now: now, status: .rejected)
    }
    challenge = next
    receipt = nil
    return next
  }

  public func admit(_ credentials: WatchSetupCredentials, now: Date) throws -> Bool {
    if let receipt, receipt.status == .installed, receipt.id == credentials.id, receipt.nonce == credentials.nonce,
      receipt.accountStamp == credentials.accountStamp
    {
      return true
    }
    guard let challenge, challenge.status == .ready, WatchSetupValidation.finite(now), credentials.id == challenge.id,
      credentials.accountStamp == challenge.accountStamp, credentials.nonce == challenge.nonce,
      credentials.expiresAt == challenge.expiresAt, now <= challenge.expiresAt, credentials.expiresAt >= now
    else { throw WatchProtocolCodingError.invalidValue }
    // The phone computes the stamp from normalized server + user identity. Exact stamp equality
    // is the Foundation-side binding; raw server and token values are never trusted here.
    return false
  }

  public mutating func complete(_ credentials: WatchSetupCredentials, now: Date = Date()) throws -> WatchSetupReceipt {
    guard let challenge, challenge.status == .ready,
      credentials.id == challenge.id,
      credentials.accountStamp == challenge.accountStamp,
      credentials.nonce == challenge.nonce,
      credentials.expiresAt == challenge.expiresAt,
      WatchSetupValidation.finite(now)
    else {
      throw WatchProtocolCodingError.invalidValue
    }
    let next = try WatchSetupReceipt(
      id: credentials.id, accountStamp: credentials.accountStamp, nonce: credentials.nonce, status: .installed)
    receipt = next
    self.challenge = nil
    return next
  }

  private static func makeStatus(
    _ hello: WatchSetupHello, now: Date, status: WatchSetupStatus, health: WatchLinkHealth? = nil
  ) -> WatchSetupChallenge {
    (try? WatchSetupChallenge(
      id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(), expiresAt: now, status: status, health: health))
      ?? (try! WatchSetupChallenge(
        id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(), expiresAt: hello.issuedAt, status: status,
        health: health))
  }
}
