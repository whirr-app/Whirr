import Foundation
import Persistence

/// Whether the item-detail hero shows a duration at all.
///
/// Ebook-only items carry a server `media.duration` of `0`, not nil, so `if let durationSeconds`
/// does not keep "0m" off the screen.
public enum ItemDetailDurationPresentation {
  /// Returns the media remainder as listening time. Invalid rates are treated as the default
  /// speed so a malformed preference cannot create an infinite or undefined caption.
  public static func remainingSeconds(
    durationSeconds: Double?, progressSeconds: Double, playbackRate: Double = 1.0
  ) -> Double? {
    guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0,
      progressSeconds.isFinite
    else { return nil }
    let remainingAudioSeconds = max(durationSeconds - max(progressSeconds, 0), 0)
    return remainingAudioSeconds / normalizedPlaybackRate(playbackRate)
  }

  public static func normalizedPlaybackRate(_ playbackRate: Double) -> Double {
    guard playbackRate.isFinite, playbackRate > 0 else { return 1.0 }
    return playbackRate
  }

  public static func showsDuration(category: ItemMediaCategory, durationSeconds: Double?) -> Bool {
    guard category != .ebook else { return false }
    guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return false }
    return true
  }

  /// The way a library item's duration becomes a metadata string: `nil` when there is no duration
  /// to print, the formatted time otherwise. Pairing the gate with the formatting stops a surface
  /// forgetting that ebook-only items carry `0` and printing "Duration unknown". Podcast episode
  /// rows call `PodcastCopy.duration(seconds:)` directly, since an unknown length is worth stating
  /// there.
  public static func durationText(category: ItemMediaCategory, durationSeconds: Double?) -> String? {
    guard showsDuration(category: category, durationSeconds: durationSeconds) else { return nil }
    return PodcastCopy.duration(seconds: durationSeconds)
  }
}
