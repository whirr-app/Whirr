import Foundation

/// What tapping a link that leaves the publication may do.
enum ReaderExternalLinkDecision: Equatable, Sendable {
  /// Not worth handing to the system at all. Nothing is presented and nothing opens.
  case refuse
  /// Confirm with the reader first; only the confirm action reaches `UIApplication.open`.
  case promptThenOpen
}

/// Where a link tapped inside a publication goes.
enum ReaderLinkRoute: Equatable, Sendable {
  case navigateInPublication
  case treatAsExternal(URL)
}

/// The pure half of the reader's link handling, kept out of the Readium delegate so it can be
/// tested without an `EPUBNavigatorViewController`. The delegate methods are thin adapters over it.
enum ReaderLinkPolicy {
  /// Schemes an EPUB may legitimately leave the app for. Everything else (`javascript:`, `data:`,
  /// `file:`, any custom scheme reaching another installed app) is refused: publication content
  /// is untrusted, and this allowlist is the one place that distinction is made.
  static let openableSchemes: Set<String> = ["http", "https", "mailto", "tel"]

  /// How long a destination may be before the prompt truncates it. Long enough to read a real URL,
  /// short enough that a hostile one cannot push the alert's buttons off-screen.
  static let maximumDisplayedTargetLength = 60

  static func decision(for url: URL) -> ReaderExternalLinkDecision {
    guard let scheme = url.scheme?.lowercased(), openableSchemes.contains(scheme) else {
      return .refuse
    }
    return .promptThenOpen
  }

  /// A link Readium resolved inside the publication is ordinary reading; one carrying its own
  /// scheme leaves the book, so it takes the external path rather than being followed silently.
  static func route(forHREF href: String) -> ReaderLinkRoute {
    guard let url = URL(string: href), let scheme = url.scheme, scheme.isEmpty == false else {
      return .navigateInPublication
    }
    return .treatAsExternal(url)
  }

  /// The destination as the prompt shows it: host first so the answer to "where am I going" is the
  /// part that cannot be dressed up, bidirectional and other invisible formatting controls removed
  /// so the string cannot be reordered to read as a different site, and truncated so it cannot
  /// grow the alert past its buttons.
  static func displayedTarget(for url: URL) -> String {
    let raw = url.host ?? url.absoluteString
    let sanitized = String(
      raw.unicodeScalars.filter { scalar in
        scalar.properties.isBidiControl == false && scalar.properties.isDefaultIgnorableCodePoint == false
      })
    guard sanitized.count > maximumDisplayedTargetLength else { return sanitized }
    return String(sanitized.prefix(maximumDisplayedTargetLength)) + "…"
  }
}
