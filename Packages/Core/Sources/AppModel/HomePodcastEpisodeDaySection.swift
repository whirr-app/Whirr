import Foundation
import Persistence

/// One day's episodes in a cross-show episode list, under the heading `PodcastCopy.dayHeading`
/// gives that day. The list says the day once, so the cards beneath it need not each repeat it.
public struct HomePodcastEpisodeDaySection: Sendable, Equatable, Identifiable {
  /// The heading, which is unique within one grouping: every day of the past week reads
  /// differently, and older days name their date.
  public var id: String { title }
  public let title: String
  public let episodes: [HomePodcastEpisode]

  /// Groups `episodes` by heading, sections in the order their first episode arrives and episodes
  /// in their arrival order within each. Grouping by heading rather than by run means an episode
  /// out of date order joins its day instead of opening a second section with the same title.
  public static func sections(
    _ episodes: [HomePodcastEpisode], now: Date, calendar: Calendar
  ) -> [HomePodcastEpisodeDaySection] {
    var order: [String] = []
    var grouped: [String: [HomePodcastEpisode]] = [:]
    for episode in episodes {
      let title = PodcastCopy.dayHeading(for: episode.publishedAt, now: now, calendar: calendar)
      if grouped[title] == nil { order.append(title) }
      grouped[title, default: []].append(episode)
    }
    return order.map { HomePodcastEpisodeDaySection(title: $0, episodes: grouped[$0] ?? []) }
  }
}
