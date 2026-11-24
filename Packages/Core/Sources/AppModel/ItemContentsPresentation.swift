import Foundation
import ReaderCore

/// One row of the ebook detail screen's Contents tab, with the read state the reading position
/// implies. Same shape as the App's `ChapterSelectorRow`, since a contents entry and an audiobook
/// chapter answer the same question about the same kind of list.
public struct ItemContentsRow: Identifiable, Equatable, Sendable {
  public let id: Int
  public let entry: TOCEntry
  public let isCurrent: Bool
  public let isCompleted: Bool
}

public enum ItemContentsPresentation {
  /// Marks contents entries against the stored whole-book reading position, mirroring
  /// `ChapterSelectorPresentation.rows` over the playhead.
  ///
  /// `progress` is `mediaProgress.ebookProgress` (`ReadingPosition.totalProgression`), on the same
  /// 0-1 scale as `startProgression`; `nil` means nothing read yet. `isFinished` is the item's
  /// server-synced flag and completes every entry, even through a reread.
  public static func rows(
    entries: [TOCEntry], progress: Double?, isFinished: Bool = false
  ) -> [ItemContentsRow] {
    // Entries whose resource the positions list could not resolve carry no progression. They are
    // skipped as boundaries, not treated as starting at zero, which would hand every later
    // entry's read state to the first unresolved one.
    let currentIndex = progress.flatMap { progress in
      entries.indices.last { index in
        entries[index].startProgression.map { $0 <= progress } ?? false
      }
    }

    return entries.enumerated().map { index, entry in
      ItemContentsRow(
        id: index,
        entry: entry,
        isCurrent: index == currentIndex,
        isCompleted: isFinished || (currentIndex.map { index < $0 } ?? false)
      )
    }
  }
}
