import Foundation
import ReadiumNavigator
import ReadiumShared

extension ReadiumEPUBRenderer {
  /// A passage longer than this is cut at a word boundary: the sample needs a few lines, not a page.
  static let sampleCharacterLimit = 420
  /// Shorter text elements are headings, captions, and dialogue tags, which show little spacing.
  static let sampleMinimumParagraphLength = 80
  /// How many content elements to read before giving up on finding prose.
  static let sampleElementLimit = 40

  /// The appearance sample's passage: text from the reading position onward, through Readium's
  /// Content API. `nil` when nothing is open or the position has no prose near it (image-only
  /// pages, a failed read), and the caller shows its fixed passage instead.
  func sampleParagraphs() async -> String? {
    guard let publication, let content = publication.content(from: navigator?.currentLocation)
    else { return nil }
    let iterator = content.iterator()
    var texts: [String] = []
    for _ in 0..<Self.sampleElementLimit {
      guard let element = try? await iterator.next() else { break }
      if let text = (element as? TextualContentElement)?.text {
        texts.append(text)
      }
      if let passage = Self.sampleParagraphs(from: texts), passage.contains("\n") {
        return passage
      }
    }
    return Self.sampleParagraphs(from: texts)
  }

  /// The first two substantial paragraphs, so paragraph spacing has a gap to show, bounded to
  /// `sampleCharacterLimit`.
  static func sampleParagraphs(from texts: [String]) -> String? {
    let paragraphs =
      texts
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.count >= sampleMinimumParagraphLength }
      .prefix(2)
    guard paragraphs.isEmpty == false else { return nil }
    let joined = paragraphs.joined(separator: "\n")
    guard joined.count > sampleCharacterLimit else { return joined }
    let cut = joined.prefix(sampleCharacterLimit)
    let boundary = cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex
    return cut[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}
