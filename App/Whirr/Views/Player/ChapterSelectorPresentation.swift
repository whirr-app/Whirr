import AppModel
import Foundation
import PlayerCore

struct ChapterSelectorRow: Identifiable, Equatable {
  let id: Int
  let chapter: PlaybackChapter
  let number: Int
  let title: String
  let startLabel: String
  let durationLabel: String
  let isCurrent: Bool
  let isCompleted: Bool
  /// What VoiceOver speaks for the row. Held here rather than assembled at the call site because
  /// whether the number is worth speaking depends on the title, and that is a presentation
  /// decision with a test rather than a format string.
  let accessibilityLabel: String
}

/// The chapter list's rows, shared by the player's and the item-detail page's chapter sheets.
/// `currentTime` is `nil` when the item isn't the one actively playing, so every row reports
/// `isCurrent` `false` rather than inventing a played state.
nonisolated enum ChapterSelectorPresentation {
  /// `isFinished` is the item's server-synced finished flag. It completes every chapter regardless
  /// of position, and keeps them completed while a finished title is re-listened to: finished is
  /// a property of the item, not of the playhead.
  static func rows(
    chapters: [PlaybackChapter],
    currentTime: Double? = nil,
    isFinished: Bool = false
  ) -> [ChapterSelectorRow] {
    let currentIndex = currentTime.flatMap { time in
      chapters.indices.last { chapters[$0].start <= time && time <= chapters[$0].end }
    }
    return chapters.enumerated().map { index, chapter in
      let number = index + 1
      let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let displayTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(number)"

      return ChapterSelectorRow(
        id: index,
        chapter: chapter,
        number: number,
        title: displayTitle,
        startLabel: PlayerTimeFormatting.clock(chapter.start),
        durationLabel: duration(chapter.end - chapter.start),
        isCurrent: index == currentIndex,
        isCompleted: isFinished || (currentIndex.map { index < $0 } ?? false),
        accessibilityLabel: spokenLabel(number: number, title: displayTitle)
      )
    }
  }

  /// The row's spoken label. The number is dropped only when the title already opens with this
  /// row's number. A title of "Chapter 12" on row five still gets the prefix: the listener needs
  /// their position in the list, which a source-assigned chapter number does not supply.
  static func spokenLabel(number: Int, title: String) -> String {
    title.hasPrefix("Chapter \(number)")
      && title.dropFirst("Chapter \(number)".count).first.map { $0.isNumber == false } != false
      ? title
      : "Chapter \(number), \(title)"
  }

  /// "42 min"/"2 hr". The History sheet's listened-duration label uses it too, so the two read
  /// consistently, and both truncate exactly as an episode length does.
  static func duration(_ seconds: Double) -> String {
    DurationText.long(max(seconds, 1))
  }
}
