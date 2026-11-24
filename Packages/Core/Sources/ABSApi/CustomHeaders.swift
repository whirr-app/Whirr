import CryptoKit
import Foundation

/// Failures from validating user-supplied HTTP fields. Header names and values are checked before
/// they enter the request pipeline because malformed values can become header injection, while
/// reserved names can be rewritten or interpreted by URLSession.
public enum CustomHeadersError: Error, Sendable, Equatable {
  case emptyName
  case invalidName
  case emptyValue
  case invalidValue
  case duplicateName
  case authorizationNotAllowed
  case reservedName
}

/// A validated, server-scoped collection of additional HTTP fields. Field names are
/// case-sensitive in the stored dictionary only because their original spelling is useful when
/// diagnosing a request; validation treats them case-insensitively as HTTP requires.
public struct CustomHeaders: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
  private let storage: [String: String]

  /// Stable, non-secret identity for the complete configuration. It is useful for invalidating
  /// disposable artifacts when credentials change without putting a credential in a key or log.
  public let fingerprint: String

  /// The validated fields, returned as a copy so callers cannot mutate the value without
  /// repeating validation.
  public var headers: [String: String] { storage }

  /// Alias matching the terminology used by the lower-level HTTP primitives.
  public var headerFields: [String: String] { storage }

  /// URLSession otherwise combines its cookie jar with a manually supplied Cookie field.
  public var cookieHeaderIsPresent: Bool {
    storage.keys.contains { $0.lowercased() == "cookie" }
  }

  /// The absence of extra fields is the default for every server configuration.
  public static let none = CustomHeaders(storage: [:])
  public static let empty = CustomHeaders.none

  public init() {
    self = .none
  }

  public init(_ headers: [String: String]) throws {
    var seenNames = Set<String>()

    for (name, value) in headers {
      guard name.isEmpty == false else { throw CustomHeadersError.emptyName }
      guard HTTPHeaderFieldValidation.isToken(name) else { throw CustomHeadersError.invalidName }

      let normalizedName = name.lowercased()
      guard seenNames.insert(normalizedName).inserted else {
        throw CustomHeadersError.duplicateName
      }
      if normalizedName == "authorization" {
        throw CustomHeadersError.authorizationNotAllowed
      }
      if Self.reservedNames.contains(normalizedName) {
        throw CustomHeadersError.reservedName
      }

      guard value.isEmpty == false else { throw CustomHeadersError.emptyValue }
      guard HTTPHeaderFieldValidation.isValue(value) else { throw CustomHeadersError.invalidValue }
    }

    self.init(storage: headers)
  }

  public init(headers: [String: String]) throws {
    try self.init(headers)
  }

  private init(storage: [String: String]) {
    self.storage = storage
    fingerprint = Self.makeFingerprint(for: storage)
  }

  public var description: String {
    "CustomHeaders(headerFields: \(storage.keys.sorted().joined(separator: ", ")))"
  }

  public var debugDescription: String { description }

  private static let reservedNames: Set<String> = [
    "host", "content-length", "connection", "transfer-encoding", "proxy-connection",
    "upgrade", "keep-alive", "www-authenticate", "x-return-tokens", "x-refresh-token",
  ]

  private static func makeFingerprint(for headers: [String: String]) -> String {
    var canonical = Data()
    for name in headers.keys.sorted() {
      appendLengthPrefixed(name, to: &canonical)
      appendLengthPrefixed(headers[name]!, to: &canonical)
    }

    return HTTPFingerprint.sha256Hex(canonical)
  }

  private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
    var byteCount = UInt64(value.utf8.count).bigEndian
    withUnsafeBytes(of: &byteCount) { bytes in
      data.append(contentsOf: bytes)
    }
    data.append(contentsOf: value.utf8)
  }
}

enum HTTPFingerprint {
  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { byte in
        let hex = String(byte, radix: 16)
        return hex.count == 1 ? "0" + hex : hex
      }
      .joined()
  }
}

/// Shared RFC 7230 validation for the two user-authored header classes, so feed Authorization
/// values cannot become more permissive than proxy custom headers. Module-internal: callers
/// construct `CustomHeaders` or `FeedCredential`, never a boolean validator as a boundary.
enum HTTPHeaderFieldValidation {
  /// RFC 7230 §3.2.6's `token` grammar is ASCII-only. Foundation's URL/header APIs accept more,
  /// but whitespace, separators, or Unicode would make serialization depend on platform-specific
  /// normalization.
  static func isToken(_ name: String) -> Bool {
    name.isEmpty == false
      && name.unicodeScalars.allSatisfy { scalar in
        let value = scalar.value
        return (0x30...0x39).contains(value)
          || (0x41...0x5A).contains(value)
          || (0x61...0x7A).contains(value)
          || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
      }
  }

  /// Permit only HTAB and visible ASCII. CR and LF are excluded, so a credential value can never
  /// terminate its field and inject another (SECURITY.md's transport-boundary rule).
  static func isValue(_ value: String) -> Bool {
    value.isEmpty == false
      && value.unicodeScalars.allSatisfy { scalar in
        scalar.value == 0x09 || (0x20...0x7E).contains(scalar.value)
      }
  }
}

extension CustomHeaders {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode([String: String].self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(storage)
  }
}
