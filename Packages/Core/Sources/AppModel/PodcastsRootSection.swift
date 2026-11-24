/// The sections of the Podcasts tab's All layout, in their built-in order.
///
/// Declaration order is the default order, and `PodcastsRootSectionOrder` appends any case a
/// stored preference omits in this order, so a case added later (Smart Lists, between Latest
/// Episodes and Your Shows) shows on every device that has already stored an order.
public enum PodcastsRootSection: String, Sendable, Equatable, Hashable, CaseIterable {
  case continueListening
  case latestEpisodes
  case smartLists
  case yourShows
}
