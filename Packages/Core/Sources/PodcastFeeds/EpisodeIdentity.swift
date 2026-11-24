import CryptoKit
import Foundation

/// The stable identity selected for one parsed feed item.
public struct EpisodeIdentity: Sendable, Equatable {
  public enum Source: Sendable, Equatable {
    case guid
    case enclosure
  }

  /// The key the persistence layer stores as the episode's identity.
  public let key: String
  public let source: Source
  /// An enclosure-derived compatibility key retained across identity-scheme or GUID changes.
  public let alternateKey: String?

  public init(key: String, source: Source, alternateKey: String?) {
    self.key = key
    self.source = source
    self.alternateKey = alternateKey
  }
}

public enum EpisodeIdentityPolicy {
  /// Returns one index-aligned identity per item, or nil when the item has no GUID or enclosure.
  ///
  /// A GUID is trimmed of whitespace and newlines and usable only when that candidate occurs
  /// exactly once across the whole input; items with a duplicate candidate fall back to their
  /// enclosure, if present. An enclosure key is `sha256:` plus lowercase SHA-256 hex over its URL,
  /// a newline, and the canonical parsed publication instant (or the trimmed raw date when parsing
  /// fails). A fallback identity with a parsed date keeps the former raw-date hash as its
  /// alternate key so persisted episodes reconcile to the canonical key instead of duplicating.
  /// GUID identities likewise keep that legacy enclosure hash as alternate during this migration,
  /// so a feed that changes its GUID on the first refresh after upgrade still reconciles. The
  /// `guid:` and `sha256:` prefixes keep the namespaces separate, and equal enclosure material
  /// gives equal keys so republished duplicates collapse.
  public static func identities(for items: [ParsedFeedItem]) -> [EpisodeIdentity?] {
    let candidates = items.map { candidateGUID(for: $0) }
    var counts: [String: Int] = [:]
    for candidate in candidates.compactMap({ $0 }) {
      counts[candidate, default: 0] += 1
    }

    return items.indices.map { index in
      let item = items[index]
      let candidate = candidates[index]
      let computedEnclosureKeys = item.enclosure.map { makeEnclosureKeys(for: item, enclosure: $0) }
      if let candidate, counts[candidate] == 1 {
        return EpisodeIdentity(
          key: "guid:\(candidate)", source: .guid,
          alternateKey: computedEnclosureKeys.map { $0.legacy ?? $0.primary }
        )
      }
      if let computedEnclosureKeys {
        return EpisodeIdentity(
          key: computedEnclosureKeys.primary, source: .enclosure,
          alternateKey: computedEnclosureKeys.legacy)
      }
      return nil
    }
  }

  /// Returns true for unchanged identities, a removed or added GUID, or a changed GUID when
  /// the enclosure key is shared. Equal bare enclosure keys also identify the same episode.
  /// Equal primary keys absorb unchanged identities. An alternate key matching the other
  /// primary key absorbs a GUID being removed or added. Equal alternate keys absorb a changed
  /// GUID when both versions retain the same enclosure material.
  public static func sameEpisode(_ a: EpisodeIdentity, _ b: EpisodeIdentity) -> Bool {
    if a.key == b.key { return true }
    if a.alternateKey == b.key { return true }
    if b.alternateKey == a.key { return true }
    if let aAlternate = a.alternateKey, aAlternate == b.alternateKey {
      return true
    }
    return false
  }

  /// Trims an item's GUID and treats an empty result as absent.
  private static func candidateGUID(for item: ParsedFeedItem) -> String? {
    guard let guid = item.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty else {
      return nil
    }
    return guid
  }

  /// Hashes a parsed publication instant so equivalent supported date spellings share one key.
  /// When parsing fails, the former trimmed raw-date material remains the primary identity.
  private static func makeEnclosureKeys(
    for item: ParsedFeedItem, enclosure: ParsedEnclosure
  ) -> (primary: String, legacy: String?) {
    let rawPubDate = item.pubDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let legacy = makeEnclosureKey(enclosureURL: enclosure.url, publicationMaterial: rawPubDate)
    guard let instant = FeedValueParsing.pubDate(rawPubDate) else {
      return (primary: legacy, legacy: nil)
    }

    // Persist a named, rounded integer unit rather than Date's floating-point representation.
    // Milliseconds retain the precision supported by ordinary podcast feeds while remaining
    // independent of locale, time zone, reference date, and floating-point string formatting.
    let unixMilliseconds = Int64((instant.timeIntervalSince1970 * 1_000).rounded())
    let canonicalMaterial = "unix-ms:\(unixMilliseconds)"
    let primary = makeEnclosureKey(
      enclosureURL: enclosure.url, publicationMaterial: canonicalMaterial)
    return (primary: primary, legacy: legacy)
  }

  private static func makeEnclosureKey(
    enclosureURL: URL, publicationMaterial: String
  ) -> String {
    let material = enclosureURL.absoluteString + "\n" + publicationMaterial
    let digest = SHA256.hash(data: Data(material.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "sha256:\(hex)"
  }
}
