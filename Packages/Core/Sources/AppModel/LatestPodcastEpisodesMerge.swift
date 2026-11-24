import Foundation
import Persistence

/// Pure policy for the mixed Latest Episodes shelf and disclosure page.
///
/// Persistence supplies two independently bounded ABS arrays. While native subscriptions are
/// enabled, the native-preferred ABS policy is merged with RSS; while disabled, the ordinary ABS
/// policy is shown alone. RSS wins an exact duplicate identity before chronology is applied.
public enum LatestPodcastEpisodesMerge {
  public static func merge(
    snapshot: HomeLatestPodcastEpisodesSnapshot,
    rss: [HomePodcastEpisode],
    nativeSubscriptionsEnabled: Bool,
    limit: Int
  ) -> [HomePodcastEpisode] {
    let effectiveLimit = max(0, limit)
    guard effectiveLimit > 0 else { return [] }

    struct Candidate {
      let episode: HomePodcastEpisode
      let sourceRank: Int
      let sourceIndex: Int
    }

    let abs = nativeSubscriptionsEnabled ? snapshot.nativePreferred : snapshot.all
    let sources: [([HomePodcastEpisode], Int)] =
      nativeSubscriptionsEnabled ? [(rss, 0), (abs, 1)] : [(abs, 0)]
    let candidates = sources.flatMap { episodes, sourceRank in
      episodes.enumerated().map {
        Candidate(episode: $0.element, sourceRank: sourceRank, sourceIndex: $0.offset)
      }
    }

    // Source order is intentional: if malformed/upstream data gives RSS and ABS the same public
    // identity, retain the native row. The persisted twin policy normally removes the ABS row
    // before this boundary; this is a final deterministic guard, not fuzzy association.
    var seen = Set<String>()
    let unique = candidates.filter { seen.insert($0.episode.id).inserted }
    return Array(
      unique.sorted { lhs, rhs in
        if lhs.episode.publishedAt != rhs.episode.publishedAt {
          return lhs.episode.publishedAt > rhs.episode.publishedAt
        }
        if lhs.sourceRank != rhs.sourceRank { return lhs.sourceRank < rhs.sourceRank }
        if lhs.episode.itemID != rhs.episode.itemID {
          return lhs.episode.itemID < rhs.episode.itemID
        }
        if lhs.episode.episodeID != rhs.episode.episodeID {
          return lhs.episode.episodeID < rhs.episode.episodeID
        }
        return lhs.sourceIndex < rhs.sourceIndex
      }.prefix(effectiveLimit).map(\.episode))
  }
}
