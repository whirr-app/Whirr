import Foundation
import PlayerCore

/// One row of the car's chapter list. `chapter` is what a tap hands to
/// `CarPlayPlaybackActions.selectChapter`.
public struct CarPlayChapterRow: Sendable, Equatable, Identifiable {
  /// The chapter's place in the book, which is stable while the book is loaded.
  public let id: Int
  public let chapter: PlaybackChapter
  public let title: String
  public let isCurrent: Bool
}

/// The loaded book's chapters. It names the title it was built for, so a row left on screen
/// after the title changes is refused when tapped rather than seeking the new title.
public struct CarPlayChapterList: Sendable, Equatable {
  public let generation: Int
  public let itemID: String
  public let episodeID: String?
  public let rows: [CarPlayChapterRow]
}

/// The two custom Now Playing controls, derived from the player. `Equatable`, and changes only
/// with the title, chapter or rate, so comparing before updating templates skips playback ticks.
public struct CarPlayNowPlayingControls: Sendable, Equatable {
  /// Nil when there is no Chapters button: nothing loaded, a podcast episode, a book without
  /// chapters, or a position between chapters. The same cases in which the system Now Playing
  /// timeline covers the whole item (`PlayerState.chapterWindow`).
  public let chapters: CarPlayChapterList?
  /// Nil when nothing is loaded, so there is no rate to show or change.
  public let rate: Double?
  /// What a tap on the rate button sets; nil when there is nothing to cycle to.
  public let nextRate: Double?

  /// `effectiveRate` is the rate the loaded title actually plays at, and `presets` the listener's
  /// own cycle; the car adds no rate preference of its own.
  public init(state: PlayerState, effectiveRate: Double, presets: [Double], generation: Int) {
    guard let item = state.item else {
      chapters = nil
      rate = nil
      nextRate = nil
      return
    }
    rate = effectiveRate
    nextRate = Self.rate(after: effectiveRate, in: presets)
    let all = item.chapters.chapters
    // The later chapter owns a shared boundary, as in `PlaybackChapterMap.currentChapter(at:)`.
    guard state.chapterWindow != nil,
      let currentIndex = all.lastIndex(where: {
        $0.start <= state.globalPosition && state.globalPosition <= $0.end
      })
    else {
      chapters = nil
      return
    }
    chapters = CarPlayChapterList(
      generation: generation, itemID: item.id, episodeID: item.episodeID,
      rows: all.enumerated().map { index, chapter in
        CarPlayChapterRow(
          id: index, chapter: chapter, title: Self.title(of: chapter, number: index + 1),
          isCurrent: index == currentIndex)
      })
  }

  /// The next preset above `rate`, wrapping to the lowest. A rate between presets, set from the
  /// phone's speed sheet, moves up to the next preset rather than jumping to the start.
  static func rate(after rate: Double, in presets: [Double]) -> Double? {
    let sorted = presets.filter { $0.isFinite && $0 > 0 }.sorted()
    // Rates are twentieths; anything closer than a hundredth is the same preset.
    let next = sorted.first { $0 > rate + 0.01 } ?? sorted.first
    guard let next, abs(next - rate) > 0.01 else { return nil }
    return next
  }

  private static func title(of chapter: PlaybackChapter, number: Int) -> String {
    let trimmed = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "Chapter \(number)" : trimmed
  }
}
