import Foundation

/// Audiobook vs. podcast vs. ebook, derived and never trusted from `mediaKind` alone. ABS reports
/// an EPUB-only item's `mediaKind` as `"book"`, identically to an audiobook; the minified media
/// signals (`numAudioFiles`, `ebookFormat`) are what distinguish them. `derive` owns this logic.
public enum ItemMediaCategory: String, Sendable, CaseIterable {
  case audiobook
  case podcast
  case ebook

  /// Whether ABS reports any document format for the item. This is an identity fact, not a
  /// promise that Whirr can open the document.
  public static func hasDocument(ebookFormat: String?) -> Bool {
    EbookFormatNormalizer.normalize(ebookFormat) != nil
  }

  /// Whether the item has an ebook edition Whirr can currently read and download.
  /// PDF files beside audiobooks are supplements, so only EPUB activates mixed-book UI.
  public static func hasReadableEbook(ebookFormat: String?) -> Bool {
    EbookFormatNormalizer.normalize(ebookFormat) == "epub"
  }

  /// - `mediaKind == "podcast"` wins outright.
  /// - Any audio files (`numAudioFiles > 0`) make it an audiobook, even with an ebook format.
  /// - No audio files (nil or `0`) plus a normalized document format make it an ebook/document.
  /// - Everything else, including all signals nil (the safe default while the live wire shape is
  ///   unconfirmed), is `.audiobook`. Empty or whitespace-only `ebookFormat` counts as absent.
  public static func derive(
    mediaKind: String,
    numAudioFiles: Int?,
    ebookFormat: String?
  ) -> ItemMediaCategory {
    guard mediaKind != "podcast" else { return .podcast }
    if (numAudioFiles ?? 0) > 0 {
      return .audiobook
    }
    if hasDocument(ebookFormat: ebookFormat) {
      return .ebook
    }
    return .audiobook
  }
}
