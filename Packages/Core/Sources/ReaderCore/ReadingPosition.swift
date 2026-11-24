import Foundation

/// The app-owned, persistable subset of a Readium Locator.
///
/// Text context is absent: a Readium locator can carry book text, and omitting the field makes
/// persisting or transmitting it impossible.
public struct ReadingPosition: Codable, Comparable, Equatable, Sendable {
  /// The shared string bound for locator hrefs and optional CFI values (see ARCHITECTURE.md).
  public static let maximumStringBytes = 16 * 1024

  public let href: String
  public let progression: Double
  public let totalProgression: Double
  /// The publication position, one-based, as Readium reports it (`Locator.position` is documented
  /// as ">= 1"). Page copy renders it as-is; nothing in the app shifts it.
  public let position: Int?
  public let cfi: String?

  public init(
    href: String,
    progression: Double,
    totalProgression: Double,
    position: Int? = nil,
    cfi: String? = nil
  ) {
    self.href = href
    self.progression = Self.clampToUnitInterval(progression)
    self.totalProgression = Self.clampToUnitInterval(totalProgression)
    self.position = position
    self.cfi = cfi
  }

  /// Builds a position from values that arrived from untrusted publication content, returning nil
  /// when the href exceeds the shared string bound.
  ///
  /// `init` is non-failable and for app-owned values, and `Decodable` only guards persisted ones;
  /// a locator crossing the WebKit/Readium seam is neither. Its href is publication-controlled and
  /// unbounded, so it would sit in memory, the TOC and every position update until a save
  /// rejected it. An href is identity, so an oversized one voids the position rather than being
  /// truncated into a different resource. An oversized CFI is optional, so `validatedEPUBCFI`
  /// drops it and the position survives.
  public static func validated(
    href: String,
    progression: Double,
    totalProgression: Double,
    position: Int? = nil,
    cfi: String? = nil
  ) -> ReadingPosition? {
    guard href.utf8.count <= maximumStringBytes else { return nil }
    return ReadingPosition(
      href: href,
      progression: progression,
      totalProgression: totalProgression,
      position: position,
      cfi: validatedEPUBCFI(cfi)
    )
  }

  /// The progress fraction sent to Audiobookshelf for this position.
  public var ebookProgress: Double { totalProgression }

  /// A CFI suitable for ABS's `ebookLocation` field, or nil when the optional locator value is
  /// absent or is not a complete EPUB CFI.
  public var ebookLocation: String? { validatedEPUBCFI(cfi) }

  public static func < (lhs: ReadingPosition, rhs: ReadingPosition) -> Bool {
    if lhs.totalProgression != rhs.totalProgression {
      return lhs.totalProgression < rhs.totalProgression
    }
    if lhs.progression != rhs.progression {
      return lhs.progression < rhs.progression
    }
    switch (lhs.position, rhs.position) {
    case (let left?, let right?) where left != right:
      return left < right
    case (nil, .some):
      return true
    case (.some, nil):
      return false
    default:
      break
    }
    if lhs.href != rhs.href {
      return lhs.href < rhs.href
    }
    switch (lhs.cfi, rhs.cfi) {
    case (let left?, let right?) where left != right:
      return left < right
    case (nil, .some):
      return true
    default:
      return false
    }
  }

  private enum CodingKeys: String, CodingKey {
    case href
    case progression
    case totalProgression
    case position
    case cfi
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedHref = try container.decode(String.self, forKey: .href)
    guard decodedHref.utf8.count <= Self.maximumStringBytes else {
      throw DecodingError.dataCorruptedError(
        forKey: .href,
        in: container,
        debugDescription: "Reading position href exceeds the \(Self.maximumStringBytes)-byte bound"
      )
    }

    href = decodedHref
    progression = Self.clampToUnitInterval(
      try container.decode(Double.self, forKey: .progression)
    )
    totalProgression = Self.clampToUnitInterval(
      try container.decode(Double.self, forKey: .totalProgression)
    )
    position = Self.decodeLossyOptionalInt(container, forKey: .position)
    cfi = try Self.decodeLossyBoundedOptionalString(container, forKey: .cfi)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(href, forKey: .href)
    try container.encode(progression, forKey: .progression)
    try container.encode(totalProgression, forKey: .totalProgression)
    try container.encodeIfPresent(position, forKey: .position)
    try container.encodeIfPresent(cfi, forKey: .cfi)
  }

  private static func clampToUnitInterval(_ value: Double) -> Double {
    guard value.isFinite else {
      return value == .infinity ? 1 : 0
    }
    return min(max(value, 0), 1)
  }

  private static func decodeLossyOptionalInt(
    _ container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) -> Int? {
    guard container.contains(key), (try? container.decodeNil(forKey: key)) != true else {
      return nil
    }
    return try? container.decode(Int.self, forKey: key)
  }

  private static func decodeLossyBoundedOptionalString(
    _ container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> String? {
    guard container.contains(key), (try? container.decodeNil(forKey: key)) != true else {
      return nil
    }
    guard let value = try? container.decode(String.self, forKey: key) else {
      return nil
    }
    guard value.utf8.count <= Self.maximumStringBytes else {
      throw DecodingError.dataCorruptedError(
        forKey: key,
        in: container,
        debugDescription: "Reading position string exceeds the \(Self.maximumStringBytes)-byte bound"
      )
    }
    return value
  }
}

/// Maps a local reading position to the fraction Audiobookshelf stores as `ebookProgress`.
public func ebookProgress(for position: ReadingPosition) -> Double {
  position.totalProgression
}

/// Accepts only a complete, bounded EPUB CFI. Readium's `partialCfi` is not wrapped
/// here: a value without the `epubcfi(...)` envelope produces no server `ebookLocation`.
public func validatedEPUBCFI(_ value: String?) -> String? {
  guard let value, value.utf8.isEmpty == false else { return nil }
  guard value.utf8.count <= ReadingPosition.maximumStringBytes else { return nil }
  guard value.hasPrefix("epubcfi("), value.hasSuffix(")") else { return nil }

  let bodyStart = value.index(value.startIndex, offsetBy: 8)
  let bodyEnd = value.index(before: value.endIndex)
  let body = value[bodyStart..<bodyEnd]
  guard body.isEmpty == false, body.first == "/" else { return nil }
  guard body.unicodeScalars.contains(where: { (48...57).contains($0.value) }) else {
    return nil
  }
  guard body.unicodeScalars.allSatisfy({ $0.properties.isWhitespace == false && $0.value >= 0x20 }) else {
    return nil
  }
  return value
}
