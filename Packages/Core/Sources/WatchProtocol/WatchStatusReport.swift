import Foundation

/// The capabilities a Watch can offer its phone. A report carries them in a set of short names, so
/// a newer Watch and an older phone still agree on the value's shape. `enclosureFetch` means the
/// Watch downloads an offered RSS episode's enclosure itself (ADR 0020 Decision 1). `absSend` means
/// it applies `WatchABSSendOffer` and reports its Audiobookshelf groups (ADR 0021 Decision 6); a
/// Watch with only `enclosureFetch` keeps taking RSS sends.
public enum WatchStatusCapability {
  public static let enclosureFetch = "enclosureFetch"
  public static let absSend = "absSend"
}

/// What the Watch knows about its own link, published in its application context so the phone can
/// date a status it cannot wake the Watch to ask for. Every field except `reportedAt` may be absent:
/// a signed-out Watch has no stamp, and a Watch that has not reached its server since launch has no
/// health or check time.
public struct WatchStatusReport: WatchWireValue, Equatable {
  public static let maxWireBytes = 4 * 1024
  public static let transportKey = WatchTransportKey.statusReport
  public static let maxCapabilities = 16
  public static let maxCapabilityBytes = 64

  private static let capabilityCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")

  /// A capability is a bounded, URL-free token: a name, never a destination.
  static func isValidCapability(_ value: String) -> Bool {
    guard (1...maxCapabilityBytes).contains(value.utf8.count) else { return false }
    return value.unicodeScalars.allSatisfy(capabilityCharacters.contains)
  }

  public let version: Int
  /// Nil when the Watch is signed out. A signed-out report never clears a phone's record.
  public let accountStamp: WatchAccountStamp?
  /// The last verdict the Watch's own server requests produced, or nil if it has no verdict yet.
  public let health: WatchLinkHealth?
  /// When the Watch last checked its server, or nil if it has not since launch.
  public let checkedAt: Date?
  public let reportedAt: Date
  public let capabilities: Set<String>

  public init(
    accountStamp: WatchAccountStamp?, health: WatchLinkHealth? = nil, checkedAt: Date? = nil,
    reportedAt: Date = Date(), capabilities: Set<String> = []
  ) throws {
    self.version = WatchProtocolVersion.current
    self.accountStamp = accountStamp
    self.health = health
    self.checkedAt = checkedAt
    self.reportedAt = reportedAt
    self.capabilities = capabilities
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    self.version = version
    self.accountStamp = try container.decodeIfPresent(WatchAccountStamp.self, forKey: .accountStamp)
    // Tolerant on purpose: a health value this build does not know must not make the whole report
    // undecodable, which would turn a Watch with a status into no report at all.
    self.health = (try? container.decodeIfPresent(String.self, forKey: .health))
      .flatMap(WatchLinkHealth.init(rawValue:))
    self.checkedAt = try container.decodeIfPresent(Date.self, forKey: .checkedAt)
    self.reportedAt = try container.decode(Date.self, forKey: .reportedAt)
    // Unknown-shaped names are dropped rather than failing the report; a newer Watch's capability
    // list must not cost the phone the account and health it does understand.
    let names = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    self.capabilities = Set(names.filter(Self.isValidCapability))
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    try validate()
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encodeIfPresent(accountStamp, forKey: .accountStamp)
    try container.encodeIfPresent(health, forKey: .health)
    try container.encodeIfPresent(checkedAt, forKey: .checkedAt)
    try container.encode(reportedAt, forKey: .reportedAt)
    try container.encode(capabilities.sorted(), forKey: .capabilities)
  }

  private enum CodingKeys: String, CodingKey {
    case version, accountStamp, health, checkedAt, reportedAt, capabilities
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    try accountStamp?.validate()
    guard reportedAt.timeIntervalSinceReferenceDate.isFinite,
      checkedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true
    else { throw WatchProtocolCodingError.invalidValue }
    guard capabilities.count <= Self.maxCapabilities,
      capabilities.allSatisfy(Self.isValidCapability)
    else { throw WatchProtocolCodingError.invalidValue }
  }
}
