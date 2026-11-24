import Foundation

/// A single match from a publication search.
///
/// Hits are not `Codable`: their context is book text, which must not be persisted or
/// transmitted.
public struct ReaderSearchHit: Equatable, Sendable, Identifiable {
  /// Opaque and stable only within one search. Derived from the search generation and the
  /// hit's ordinal, never from the matched text, so an id can be logged when a hit cannot.
  public let id: String
  public let chapterTitle: String?
  public let before: String
  public let highlight: String
  public let after: String
  /// 0-1, on `ReadingPosition.totalProgression`'s scale, when the locator carries it.
  public let totalProgression: Double?

  public init(
    id: String,
    chapterTitle: String?,
    before: String,
    highlight: String,
    after: String,
    totalProgression: Double?
  ) {
    self.id = id
    self.chapterTitle = chapterTitle
    self.before = before
    self.highlight = highlight
    self.after = after
    self.totalProgression = totalProgression
  }

  /// The id a hit carries. Kept here rather than in the renderer so the model and the tests agree
  /// on the format without importing Readium.
  public static func hitID(generation: Int, ordinal: Int) -> String {
    "\(generation):\(ordinal)"
  }

  /// The table-of-contents entry containing `totalProgression`: the last entry whose
  /// `startProgression` is less than or equal to it. Returns nil for a hit with no progression, an
  /// empty table of contents, or a progression before the first entry.
  public static func chapterTitle(for totalProgression: Double?, in toc: [TOCEntry]) -> String? {
    guard let totalProgression else { return nil }
    return toc.last { entry in
      guard let startProgression = entry.startProgression else { return false }
      return startProgression <= totalProgression
    }?.title
  }
}

public enum ReaderSearchFailure: Error, Equatable, Sendable {
  case notSearchable
  case badQuery
  case reading
}
