import Foundation

/// An episode row's second line and its progress marker, in the phone's own words
/// (`PodcastCopy`): when it came out, then how long it is, how much is left, or that it has been
/// played.
public struct CarPlayEpisodeDetail: Sendable, Equatable {
  public let text: String?
  /// Nil for an episode not started; 1 once it is finished.
  public let progress: Double?

  public init(
    publishedAt: Date?, durationSeconds: Double?, progressSeconds: Double, isFinished: Bool, now: Date,
    calendar: Calendar = .current
  ) {
    let duration = durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    let heard = progressSeconds.isFinite ? max(0, progressSeconds) : 0
    let time: String?
    if isFinished {
      time = PodcastCopy.played
      progress = 1
    } else if let duration, heard > 0 {
      let remaining = duration - heard
      // Inside the last minute there is no remainder worth naming.
      time = remaining >= 60 ? PodcastCopy.remaining(seconds: remaining) : PodcastCopy.duration(seconds: duration)
      progress = min(1, heard / duration)
    } else {
      time = duration.map { PodcastCopy.duration(seconds: $0) }
      progress = nil
    }
    let date = publishedAt.map { PodcastCopy.dayHeading(for: $0, now: now, calendar: calendar) }
    let parts = [date, time].compactMap { $0 }
    text = parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
