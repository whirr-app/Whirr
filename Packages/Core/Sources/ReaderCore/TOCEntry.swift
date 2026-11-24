import Foundation

/// One flattened table-of-contents item. Readium links normally provide an href; a one-based
/// publication position is also carried when the renderer can resolve the entry's resource in the
/// positions list, and is what the chapter list renders as a page number.
public struct TOCEntry: Codable, Equatable, Sendable {
  public let title: String
  public let href: String?
  /// One-based, matching `ReadingPosition.position`, never an index into the positions array.
  public let position: Int?
  public let depth: Int
  /// Where this entry begins in the publication (0 to 1), on the scale of
  /// `ReadingPosition.totalProgression`, so a contents list can mark entries read without
  /// reopening it. Absent when the entry's resource is not in the positions list; such an entry
  /// stays listed but never claims a read state.
  public let startProgression: Double?

  /// The bound on a table-of-contents title, which is publication-controlled untrusted text.
  /// A title is display-only, so an oversized one is truncated rather than voiding the entry: the
  /// chapter still needs to be listed and navigable.
  public static let maximumTitleBytes = 4 * 1024

  /// The bound on table-of-contents nesting. Flattening recurses once per level, so without it the
  /// publication sets the stack depth and a deeply nested book crashes at open. Real books nest a
  /// handful of levels; 32 is far beyond any legitimate structure.
  public static let maximumDepth = 32

  /// The bound on how many flattened entries one publication may contribute. A large reference
  /// work runs to a few thousand; beyond this the list is untrusted bulk rather than navigation.
  public static let maximumCount = 10_000

  public init(
    title: String,
    href: String? = nil,
    position: Int? = nil,
    depth: Int,
    startProgression: Double? = nil
  ) {
    self.title = Self.boundedTitle(title)
    self.href = href
    self.position = position
    self.depth = max(depth, 0)
    self.startProgression = startProgression.map { min(max($0, 0), 1) }
  }

  /// Truncates on a character boundary so a multi-byte character is never split into invalid UTF-8.
  private static func boundedTitle(_ title: String) -> String {
    guard title.utf8.count > maximumTitleBytes else { return title }
    var bounded = ""
    var usedBytes = 0
    for character in title {
      let characterBytes = String(character).utf8.count
      guard usedBytes + characterBytes <= maximumTitleBytes else { break }
      bounded.append(character)
      usedBytes += characterBytes
    }
    return bounded
  }
}
