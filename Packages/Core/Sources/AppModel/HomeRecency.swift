import Foundation
import Persistence

/// The shared meaning of “new” on Home: content first seen or published in the last seven days.
public enum HomeRecency {
  public static let window: TimeInterval = PodcastEpisodeRecency.window

  public static func cutoff(now: Date) -> Date {
    PodcastEpisodeRecency.cutoff(now: now)
  }
}
