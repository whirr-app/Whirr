import Foundation

/// Shared URL-path validation for every route that interpolates a server-supplied identifier or a
/// server-declared filesystem path. `RequestBuilder` assigns the finished path to
/// `URLComponents.percentEncodedPath`, whose setter traps (not throws) on a character it cannot
/// accept, so an identifier has to be rejected before it reaches the request builder.

/// A single path component. The allowlist is RFC 3986's unreserved set plus the sub-delimiters and
/// `:`/`@`, which are legal in a path segment and need no encoding. Everything else is refused,
/// including whitespace and `%`: Audiobookshelf identifiers are nanoid-shaped, so no real value is
/// excluded, and a percent sign would otherwise reach the trapping setter as a partial escape.
func isUsablePathSegment(_ value: String) -> Bool {
  guard value.isEmpty == false, value != ".", value != ".." else { return false }

  return value.unicodeScalars.allSatisfy { scalar in
    switch scalar.value {
    case 48...57, 65...90, 97...122, 45, 46, 95, 126,
      33, 36, 38, 39, 40, 41, 42, 43, 44, 59, 61, 58, 64:
      return true
    default:
      return false
    }
  }
}

/// An absolute server-side path. Unlike a segment this tolerates percent-encoding, because the
/// value is a filesystem path the server declared rather than an identifier this client mints; the
/// traversal check therefore runs on the decoded form of each component.
func isUsableAbsolutePath(_ value: String, maximumBytes: Int) -> Bool {
  guard value.isEmpty == false,
    value.utf8.count <= maximumBytes,
    value.hasPrefix("/"),
    value.contains("?") == false,
    value.contains("#") == false,
    value.contains("\0") == false
  else { return false }

  return value.split(separator: "/", omittingEmptySubsequences: true).allSatisfy { segment in
    guard let decoded = segment.removingPercentEncoding else { return false }
    return decoded != "." && decoded != ".." && decoded.contains("/") == false
  }
}
