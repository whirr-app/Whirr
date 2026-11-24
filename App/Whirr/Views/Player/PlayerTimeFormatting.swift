import AppModel
import DesignSystem
import Foundation

/// Pure elapsed/remaining-time formatting for the player surfaces. App-layer only: DesignSystem's
/// player components take pre-formatted strings and own no time formatting.
nonisolated enum PlayerTimeFormatting {
  typealias ClockParts = WhirrClockFormatting.ClockParts

  struct ScopedChapterClocks: Equatable {
    let elapsed: String
    let remaining: String
  }

  /// "12:34 of 3:04:00", the mini-player's progress accessibility value. A `nil` or non-finite
  /// `duration` falls back to just the elapsed time.
  static func elapsedOfTotal(currentTime: Double, duration: Double?) -> String {
    guard let duration, duration.isFinite, duration > 0 else {
      return clock(currentTime)
    }
    return "\(clock(currentTime)) of \(clock(duration))"
  }

  /// "12:34 elapsed, 2:51:26 remaining", the expanded player's scrubber accessibility value.
  static func elapsedAndRemaining(currentTime: Double, duration: Double?) -> String {
    guard let duration, duration.isFinite, duration > 0 else {
      return "\(clock(currentTime)) elapsed"
    }
    let remaining = max(0, duration - currentTime)
    return "\(clock(currentTime)) elapsed, \(clock(remaining)) remaining"
  }

  /// A compact visual counterpart to `elapsedAndRemaining`, with the leading minus sign native
  /// media players use. Unknown duration is never shown as zero.
  static func remainingClock(currentTime: Double, duration: Double?) -> String {
    guard let duration, duration.isFinite, duration > 0 else { return "−−:−−" }
    return "−\(clock(max(0, duration - currentTime)))"
  }

  /// The time a player surface should show: where an in-flight scrub points, otherwise the live
  /// playhead. `scrubFraction` is `nil` when no drag is in flight. Every time-derived readout on a
  /// page must agree on this, or the listener cannot aim a seek.
  static func displayedTime(scrubFraction: Double?, currentTime: Double, duration: Double?) -> Double {
    guard let scrubFraction, scrubFraction.isFinite, let duration, duration.isFinite, duration > 0 else {
      return currentTime
    }
    return duration * min(max(scrubFraction, 0), 1)
  }

  /// `0...1` scrubber fraction. `0` whenever duration is unknown/non-positive, rather than NaN.
  static func progressFraction(currentTime: Double, duration: Double?) -> Double {
    guard let duration, duration.isFinite, duration > 0 else { return 0 }
    return min(max(currentTime / duration, 0), 1)
  }

  // MARK: - Chapter scoping
  //
  // The scrubber spans the current chapter, not the whole book: a ten-hour book across a few
  // hundred points is ~100 seconds per point, too coarse to aim; a ~50-minute chapter is ~9. The
  // window `[start, end]` is the chapter owning the playhead; a book with no chapters (or a
  // position in a gap) falls back to `[0, totalDuration]`. Plain arithmetic, kept here for tests.

  /// How far `currentTime` sits through the window `[start, end]`, as `0...1`. A non-positive or
  /// non-finite span (a missing or degenerate chapter) yields `0` rather than NaN.
  static func scopedFraction(currentTime: Double, start: Double, end: Double) -> Double {
    guard currentTime.isFinite, start.isFinite, end.isFinite, end > start else { return 0 }
    return min(max((currentTime - start) / (end - start), 0), 1)
  }

  /// The global time a chapter-relative scrub `fraction` (`0...1`) points to inside `[start, end]`,
  /// clamped to the window. Inverse of `scopedFraction`. A chapter-scoped `onSeek` fraction must
  /// pass through this before becoming a global seek offset.
  static func scopedTime(fraction: Double, start: Double, end: Double) -> Double {
    guard fraction.isFinite, start.isFinite, end.isFinite, end > start else { return start }
    return start + (end - start) * min(max(fraction, 0), 1)
  }

  /// Elapsed time within the chapter, counted from zero at `start`. Used by the scrub-feedback
  /// bubble; the timeline uses `scopedChapterClocks` so its two clocks share one media second.
  static func scopedElapsedClock(currentTime: Double, start: Double) -> String {
    clock(max(0, currentTime - start))
  }

  /// The two raw-media chapter coordinates shown beside the scrubber. Elapsed is quantised once
  /// and subtracted from the whole chapter duration, so both labels change on the same boundary
  /// and a playback-rate change never rewrites either coordinate.
  static func scopedChapterClocks(
    currentTime: Double, start: Double, end: Double
  ) -> ScopedChapterClocks {
    guard currentTime.isFinite, start.isFinite, end.isFinite, end > start else {
      return ScopedChapterClocks(elapsed: clock(0), remaining: "−\(clock(0))")
    }

    let chapterSeconds = (end - start).rounded(.down)
    let elapsedSeconds = min(
      max((currentTime - start).rounded(.down), 0), chapterSeconds)
    let remainingSeconds = chapterSeconds - elapsedSeconds
    return ScopedChapterClocks(
      elapsed: clock(elapsedSeconds), remaining: "−\(clock(remainingSeconds))")
  }

  /// "9h 36m left in book", the estimated listening-time remainder, centred under the bar so
  /// chapter scoping never hides how much of the book is left. Minute precision keeps it an
  /// estimate rather than a third seconds clock. `nil` when total duration is unknown. An episode
  /// says "left", and a converted remainder names its speed.
  static func bookRemainingLabel(
    currentTime: Double, totalDuration: Double?, playbackRate: Double = 1.0,
    isEpisode: Bool = false
  ) -> String? {
    guard
      let remaining = ItemDetailDurationPresentation.remainingSeconds(
        durationSeconds: totalDuration, progressSeconds: currentTime, playbackRate: playbackRate)
    else { return nil }
    var label = "\(DurationText.compact(remaining)) left"
    if isEpisode == false { label += " in book" }
    let rate = ItemDetailDurationPresentation.normalizedPlaybackRate(playbackRate)
    if rate != 1 { label += " at \(PlaybackRateCopy.display(rate))" }
    return label
  }

  /// The chapter-scoped scrubber accessibility value: the three facts the visible labels carry,
  /// spoken as one phrase. The chapter values are raw media coordinates; the book clause names
  /// approximate listening time and the rate used to estimate it.
  static func scopedAccessibilityValue(
    currentTime: Double, start: Double, end: Double, totalDuration: Double?,
    playbackRate: Double = 1.0
  ) -> String {
    let chapterClocks = scopedChapterClocks(currentTime: currentTime, start: start, end: end)
    let leftInChapter = String(chapterClocks.remaining.dropFirst())
    var phrase = "\(chapterClocks.elapsed) into chapter, \(leftInChapter) left in chapter"
    if let remaining = ItemDetailDurationPresentation.remainingSeconds(
      durationSeconds: totalDuration, progressSeconds: currentTime, playbackRate: playbackRate)
    {
      let normalizedRate = ItemDetailDurationPresentation.normalizedPlaybackRate(playbackRate)
      phrase +=
        ", \(accessibleListeningDuration(remaining)) at \(accessibleRate(normalizedRate))"
    }
    return phrase
  }

  private static func accessibleListeningDuration(_ seconds: Double) -> String {
    guard seconds > 0 else { return "no listening time left in book" }
    guard seconds >= 60 else { return "less than 1 minute of listening time left in book" }

    let totalMinutes = Int((seconds / 60).rounded())
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    var components: [String] = []
    if hours > 0 { components.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
    if minutes > 0 { components.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
    return "approximately \(components.joined(separator: " ")) of listening time left in book"
  }

  private static func accessibleRate(_ rate: Double) -> String {
    PlaybackRateCopy.spoken(rate)
  }

  /// `h:mm:ss` (or `m:ss` under an hour), matching the platform's own clock-time convention.
  static func clock(_ seconds: Double) -> String {
    WhirrClockFormatting.clock(seconds)
  }

  /// Facade for App test and presentation callers. The conversion lives in DesignSystem so Core
  /// tests exercise the same guard.
  static func clockParts(_ seconds: Double) -> ClockParts {
    WhirrClockFormatting.clockParts(seconds)
  }
}
