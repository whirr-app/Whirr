import Foundation
import PlayerCore
import WatchPlayback
import WatchProtocol

enum WatchDisplayFormatting {
  static func selectedPlaybackRate(_ rate: Double?, isStale: Bool) -> Double? {
    WatchNowPlayingProjection.selectedPlaybackRate(rate, isStale: isStale)
  }

  static func skipInterval(snapshot: WatchCatalogueSnapshot?, forward: Bool) -> Int {
    forward ? snapshot?.skipForwardSeconds ?? 30 : snapshot?.skipBackwardSeconds ?? 15
  }

  static func playbackRates(current: Double?, presets: [Double]? = nil) -> [Double] {
    // Legacy phone snapshots use PlaybackRatePresetConfiguration.defaults.
    let presets = presets ?? [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    guard let current = selectedPlaybackRate(current, isStale: false), !presets.contains(current) else {
      return presets
    }
    return (presets + [current]).sorted()
  }

  static func phonePlaybackStatus(_ state: WatchPlaybackState?, isStale: Bool) -> String? {
    WatchNowPlayingProjection.phonePlaybackStatus(state, isStale: isStale)
  }

  static func playbackProgress(position: Double, duration: Double?, chapterStart: Double?, chapterEnd: Double?)
    -> (elapsed: Double, duration: Double?, isChapter: Bool)
  {
    let elapsed = position.isFinite ? max(0, position) : 0
    let total = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    if position.isFinite, let start = chapterStart, let end = chapterEnd,
      start.isFinite, end.isFinite, start >= 0, end > start, elapsed >= start, elapsed <= end,
      total.map({ end <= $0 }) ?? true
    {
      return (elapsed - start, end - start, true)
    }
    return (total.map { min(elapsed, $0) } ?? elapsed, total, false)
  }

  struct ChapterRow: Identifiable, Equatable {
    let id: Int
    let title: String
    let start: Double
    let isCurrent: Bool
  }

  /// The chapters a listener can jump to: those starting inside the loaded duration, numbered in
  /// map order so an untitled chapter reads as the progress line names it.
  static func chapterRows(_ map: PlaybackChapterMap, duration: Double, position: Double) -> [ChapterRow] {
    guard duration.isFinite, duration > 0 else { return [] }
    // `PlaybackChapterMap.currentChapter(at:)`'s rule, by index so identical markers stay distinct.
    let current = map.chapters.lastIndex { $0.start <= position && position <= $0.end }
    return map.chapters.enumerated().compactMap { index, chapter in
      guard chapter.start < duration else { return nil }
      let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return ChapterRow(
        id: index, title: title.isEmpty ? "Chapter \(index + 1)" : title, start: chapter.start,
        isCurrent: index == current)
    }
  }

  static func playerClock(_ seconds: Double) -> String {
    let seconds = seconds.isFinite ? max(0, seconds) : 0
    return seconds < 3600 ? Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)) : clock(seconds)
  }

  static func clock(_ seconds: Double) -> String {
    let seconds = seconds.isFinite ? max(0, seconds) : 0
    return Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
  }

  static func remaining(_ seconds: Double) -> String {
    "\(clock(seconds)) remaining"
  }

  /// The Watch's own copy of `PodcastCopy.podcastPublishedDate`: the Watch target cannot import
  /// AppModel, so this is a deliberate duplicate pinned to the same POSIX/GMT output by
  /// `Scripts/watch-regressions/ChapterListRegression.swift`.
  private static let publishedDateStyle: Date.FormatStyle = {
    var style = Date.FormatStyle()
      .year(.defaultDigits)
      .month(.abbreviated)
      .day(.defaultDigits)
      .locale(Locale(identifier: "en_US_POSIX"))
    style.calendar = Calendar(identifier: .gregorian)
    style.timeZone = TimeZone(secondsFromGMT: 0)!
    return style
  }()

  static func date(_ date: Date) -> String {
    date.formatted(publishedDateStyle)
  }

  static func duration(_ seconds: Double) -> String {
    clock(seconds)
  }

  static func metadata(_ parts: [String?]) -> String {
    parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}
