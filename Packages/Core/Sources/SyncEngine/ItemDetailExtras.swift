import ABSApi
import Foundation

/// Series/narrator/chapter-list extension to `ItemSummary` for the item detail screen. A plain
/// `Sendable`/`Equatable` domain value, not a wire DTO, so AppModel can consume it directly
/// (ARCHITECTURE.md §1: wire DTOs never appear above SyncEngine). Podcasts have no
/// series/narrator/chapters in ABS's data model, so `ItemDetailExtrasService` maps a `.podcast`
/// item to `seriesName: nil, narrator: nil, chapters: []`.
public struct ItemDetailExtras: Sendable, Equatable {
  public let seriesName: String?
  public let narrator: String?
  public let chapters: [ItemChapterInfo]
  /// The blurb from `media.metadata.description`. An ebook-only item has neither chapters nor
  /// listening sessions, so this is the substance of its detail screen.
  public let description: String?

  public init(
    seriesName: String?,
    narrator: String?,
    chapters: [ItemChapterInfo],
    description: String? = nil
  ) {
    self.seriesName = seriesName
    self.narrator = narrator
    self.chapters = chapters
    self.description = description
  }

  /// Maps wire-derived `Chapter`s (ABSApi) into ordered, gap-tolerant `ItemChapterInfo`s:
  ///
  /// - A chapter with a `nil` start is dropped: no place on the timeline (the "required identity
  ///   missing, skip the record" rule of ARCHITECTURE.md §7, applied to position).
  /// - An absent `end` is the next remaining chapter's `start`; array order is kept (assumed
  ///   server-ordered). The last chapter falls back to the item's `duration`, else its own
  ///   `start` (zero length).
  public static func makeChapters(from chapters: [Chapter], duration: Double?) -> [ItemChapterInfo] {
    let positioned = chapters.compactMap { chapter -> (start: Double, end: Double?, title: String?)? in
      guard let start = chapter.start else { return nil }
      return (start, chapter.end, chapter.title)
    }

    var result: [ItemChapterInfo] = []
    result.reserveCapacity(positioned.count)
    for (index, entry) in positioned.enumerated() {
      let end: Double
      if let explicitEnd = entry.end {
        end = explicitEnd
      } else if index + 1 < positioned.count {
        end = positioned[index + 1].start
      } else if let duration {
        end = duration
      } else {
        end = entry.start
      }
      result.append(ItemChapterInfo(title: entry.title, start: entry.start, end: end))
    }
    return result
  }
}

/// One chapter on the item-detail chapter list: a resolved, always-present start/end pair, unlike
/// the wire `Chapter`'s optionals. `ItemDetailExtras.makeChapters(from:duration:)` resolves `nil`s.
public struct ItemChapterInfo: Sendable, Equatable {
  public let title: String?
  public let start: Double
  public let end: Double

  public init(title: String?, start: Double, end: Double) {
    self.title = title
    self.start = start
    self.end = end
  }
}
