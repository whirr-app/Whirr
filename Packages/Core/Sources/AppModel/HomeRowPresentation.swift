import Persistence

/// Pure, stateless formatting for one `HomeItem` card. Every function is a plain value transform
/// with no SwiftUI and no locale/formatter singletons beyond what a deterministic result needs, so
/// DesignSystem's card never re-derives this logic.
public enum HomeRowPresentation {

  /// The continue-listening progress bar's fill fraction, clamped to `0...1`. `nil` when duration
  /// is unknown or non-positive (often absent on the minified wire shape), so the caller renders
  /// no bar rather than a divide-by-zero or a misleading full/empty one.
  public static func progressFraction(progressSeconds: Double, durationSeconds: Double?) -> Double? {
    guard let durationSeconds, durationSeconds > 0 else { return nil }
    let fraction = progressSeconds / durationSeconds
    return min(max(fraction, 0), 1)
  }

  public static func ebookProgressFraction(ebookProgress: Double) -> Double {
    min(max(ebookProgress, 0), 1)
  }

  public static func ebookProgressCaption(ebookProgress: Double, isFinished: Bool) -> String {
    if isFinished { return "Finished" }
    return "\(Int((ebookProgressFraction(ebookProgress: ebookProgress) * 100).rounded()))%"
  }

  /// The card's trailing caption, chosen by media category, not by magnitude.
  ///
  /// Timed media (audiobooks, podcast episodes) reads a countdown ("6h 50m left"); ebooks have no
  /// meaningful clock, so they read percent-complete. Choosing by magnitude would show a
  /// freshly-started long audiobook as "0%" and flip the format partway through listening.
  ///
  /// Finished items always read "Finished" (`observeContinueListening` already excludes them). With
  /// duration unknown the caption is empty and the caller renders none.
  public static func remainingCaption(
    progressSeconds: Double, durationSeconds: Double?, isFinished: Bool, category: ItemMediaCategory,
    playbackRate: Double = 1.0
  ) -> String {
    if isFinished { return "Finished" }
    guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return "" }

    if category == .ebook {
      let fraction = progressFraction(progressSeconds: progressSeconds, durationSeconds: durationSeconds) ?? 0
      return "\(Int((fraction * 100).rounded()))%"
    }

    guard
      let remaining = ItemDetailDurationPresentation.remainingSeconds(
        durationSeconds: durationSeconds, progressSeconds: progressSeconds,
        playbackRate: playbackRate)
    else { return "" }
    return DurationText.remaining(remaining)
  }

  /// The badge's accessible label per media category. `MediaKindBadgeView` renders the symbol;
  /// this is the text a VoiceOver user hears.
  public static func badgeLabel(for category: ItemMediaCategory) -> String {
    switch category {
    case .audiobook: return "Audiobook"
    case .podcast: return "Podcast"
    case .ebook: return "eBook"
    }
  }
}
