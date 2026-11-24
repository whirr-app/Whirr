import CryptoKit
import Foundation

/// The one feed identity rule shared by RSS persistence and server-catalogue matching.
///
/// Normalization is narrower than URL canonicalization: it removes only representation
/// differences the product treats as equal (a redirect or differently-cased path is a different
/// feed). Callers above Persistence should carry `fingerprint`, never the normalized URL.
public enum PodcastFeedIdentity {
  /// The canonical feed identity's SHA-256 representation is 64 lowercase hexadecimal bytes.
  public static let fingerprintCharacterCount = SHA256.Digest.byteCount * 2

  /// Normalizes an HTTP(S) feed URL for exact identity comparison.
  ///
  /// Scheme and host case, default ports, trailing path slashes and an empty query are the only
  /// transformations; path/query case, non-empty query data and fragments stay significant.
  /// Userinfo is rejected so a credential cannot become a persisted or matched feed identity.
  public static func normalized(_ rawValue: String) -> String? {
    guard rawValue.isEmpty == false,
      var components = URLComponents(string: rawValue),
      let rawScheme = components.scheme,
      let rawHost = components.host,
      rawHost.isEmpty == false,
      components.user == nil,
      components.password == nil
    else { return nil }

    let scheme = rawScheme.lowercased()
    guard scheme == "http" || scheme == "https" else { return nil }
    components.scheme = scheme
    components.host = rawHost.lowercased()
    if (scheme == "http" && components.port == 80)
      || (scheme == "https" && components.port == 443)
    {
      components.port = nil
    }

    var path = components.percentEncodedPath
    while path.isEmpty == false, path.hasSuffix("/") {
      path.removeLast()
    }
    components.percentEncodedPath = path
    if components.percentEncodedQuery?.isEmpty == true {
      components.percentEncodedQuery = nil
    }
    return components.url?.absoluteString
  }

  /// Returns the lowercase SHA-256 fingerprint of the canonical normalized URL.
  public static func fingerprint(_ rawValue: String) -> String? {
    guard let normalized = normalized(rawValue) else { return nil }
    return SHA256.hash(data: Data(normalized.utf8)).map { byte in
      let hex = String(byte, radix: 16)
      return hex.count == 1 ? "0" + hex : hex
    }.joined()
  }

  public static func fingerprint(_ url: URL) -> String? {
    fingerprint(url.absoluteString)
  }

  /// Accepts only fingerprints produced by this utility. Persisted values are treated as
  /// untrusted cache data; malformed values fail open instead of becoming a show association.
  public static func validatedFingerprint(_ value: String?) -> String? {
    guard let value,
      value.utf8.count == fingerprintCharacterCount,
      value.count == fingerprintCharacterCount,
      value.unicodeScalars.allSatisfy({ scalar in
        switch scalar.value {
        case 48...57, 97...102: return true
        default: return false
        }
      })
    else { return nil }
    return value
  }
}
