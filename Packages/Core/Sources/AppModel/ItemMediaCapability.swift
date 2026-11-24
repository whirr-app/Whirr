import Persistence

/// User-facing media actions supported for one item. The primary category describes what the
/// item is; `hasReadableEbook` describes whether its document is an EPUB Whirr can act on.
///
/// The single derivation of that pair for every media-action surface (detail tabs, download
/// bubble, read affordance, long-press menu). It does not say whether a `.podcast` row is a show
/// or an episode; that stays with the row's `episodeID`.
public enum ItemMediaCapability: Sendable, Equatable {
  case audio
  case ebook
  case audioAndEbook
  case unsupportedDocument
  case podcast

  public static func derive(
    category: ItemMediaCategory, hasReadableEbook: Bool
  ) -> ItemMediaCapability {
    switch category {
    case .audiobook:
      return hasReadableEbook ? .audioAndEbook : .audio
    case .ebook:
      return hasReadableEbook ? .ebook : .unsupportedDocument
    case .podcast:
      return .podcast
    }
  }

  public var supportsDownload: Bool {
    switch self {
    case .audio, .ebook, .audioAndEbook, .podcast: true
    case .unsupportedDocument: false
    }
  }

  public var supportsReading: Bool {
    self == .ebook || self == .audioAndEbook
  }

  /// The download choices this item can be offered, in menu order. One entry means a single medium
  /// downloaded without asking; three mean the surface must offer the choice. Empty for a document
  /// Whirr cannot open, matching `supportsDownload`.
  ///
  /// Audio first for a mixed item, combined last: a "both" first row invites a larger transfer by
  /// position, not intent.
  public var downloadFormats: [ItemDownloadFormat] {
    switch self {
    case .audio, .podcast: [.audio]
    case .ebook: [.ebook]
    case .audioAndEbook: [.audio, .ebook, .both]
    case .unsupportedDocument: []
    }
  }

  /// Whether Download must ask audio, eBook or both for this capability.
  public var offersFormatChoice: Bool { downloadFormats.count > 1 }

  /// Resolves a bulk download request against `downloadFormats`. `nil` chooses a sole available
  /// format; mixed media requires an explicit choice. `both` means all available formats in a
  /// mixed selection, without asking an ebook to fetch audio.
  public func downloadFormat(requested: ItemDownloadFormat?) -> ItemDownloadFormat? {
    let formats = downloadFormats
    guard let requested else { return formats.count == 1 ? formats.first : nil }
    if requested == .both { return formats.contains(.both) ? .both : formats.first }
    return formats.contains(requested) ? requested : nil
  }

  /// Whether the item has audio to play or queue. False for a document with no narration,
  /// including one whose format Whirr cannot open, so an ebook row never offers a Play that could
  /// not produce sound.
  public var supportsPlayback: Bool {
    switch self {
    case .audio, .audioAndEbook, .podcast: true
    case .ebook, .unsupportedDocument: false
    }
  }
}
