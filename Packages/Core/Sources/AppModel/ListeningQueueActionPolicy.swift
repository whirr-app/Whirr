import Persistence

/// The two queue mutations an item menu can offer. Separate from `MediaItemAction` because the
/// queue policy and the queue's own surfaces reason about these two alone; `apply(_:to:)` filters
/// the matching `MediaItemAction` entries out of a menu.
public enum ListeningQueueMenuAction: Sendable, Equatable, Hashable, CaseIterable {
  case playNext
  case addToUpNext
}

/// What one row's menu may offer at this moment. Ordered, so a surface renders the two entries in
/// the canonical order (`PodcastShowPresentation.episodeActions`) without restating it.
public struct ListeningQueueActionAvailability: Sendable, Equatable {
  public let actions: [ListeningQueueMenuAction]

  public static let none = ListeningQueueActionAvailability(actions: [])
  public static let both = ListeningQueueActionAvailability(actions: [.playNext, .addToUpNext])

  public var offersPlayNext: Bool { actions.contains(.playNext) }
  public var offersAddToUpNext: Bool { actions.contains(.addToUpNext) }
  public var isEmpty: Bool { actions.isEmpty }
}

/// The single player-aware answer to "may this row enter Up Next?", consulted by Home, Library,
/// Search, the shared long-press menu, the podcast show screen, and the episode card.
///
/// Pure: the player's identity is a value, so tests need no `PlaybackModel`.
public enum ListeningQueueActionPolicy {
  /// The identity the queue would hold for this row, or `nil` when the row is not queueable.
  /// Mirrors `ListeningQueueStore.resolveForInsertion`'s rejections that a menu can check without
  /// touching the database: an ebook is never queueable, a podcast row naming no episode is a
  /// show (`episodeIdentityRequired`), and an audiobook row with an episode id is a category
  /// mismatch (`episodeIdentityNotAllowed`).
  public static func identity(
    itemID: String, episodeID: String?, category: ItemMediaCategory
  ) -> ListeningIdentity? {
    switch category {
    case .ebook:
      return nil
    case .audiobook:
      guard episodeID == nil else { return nil }
      return .audiobook(itemID: itemID)
    case .podcast:
      guard let episodeID else { return nil }
      if let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId {
        return .rssEpisode(feedID: feedID, episodeID: episodeID)
      }
      return .podcastEpisode(itemID: itemID, episodeID: episodeID)
    }
  }

  /// `nowPlaying` is the player's active or retained identity (`PlaybackModel.nowPlayingIdentity`,
  /// not `activeItemID` alone). The mini-player retains the last successful item, so keying to the
  /// active session would withdraw every queue action when playback stopped.
  ///
  /// `nil` is the cleared "nothing playing" state: a finished retained title is not `nowPlaying`
  /// either, so every menu falls back to Play rather than offering a queue nothing can reach.
  ///
  /// `isAlreadyQueued` comes from the caller, and only the queue's own rows pass `true`: a browse
  /// row cannot answer it without observing the whole queue from a recycled list row. The store's
  /// idempotent append and its "Already in Up Next" feedback cover the rest.
  public static func availability(
    for identity: ListeningIdentity?,
    nowPlaying: ListeningIdentity?,
    isAlreadyQueued: Bool = false
  ) -> ListeningQueueActionAvailability {
    // With nothing playing or retained, menus offer Play rather than a queue nobody can reach.
    guard nowPlaying != nil else { return .none }
    guard let identity else { return .none }
    // A queue action on the thing already playing is meaningless, and an identity is never both
    // Now Playing and Up Next.
    guard identity != nowPlaying else { return .none }
    guard isAlreadyQueued == false else { return .none }
    return .both
  }

  public static func availability(
    itemID: String,
    episodeID: String?,
    category: ItemMediaCategory,
    nowPlaying: ListeningIdentity?,
    isAlreadyQueued: Bool = false
  ) -> ListeningQueueActionAvailability {
    availability(
      for: identity(itemID: itemID, episodeID: episodeID, category: category),
      nowPlaying: nowPlaying,
      isAlreadyQueued: isAlreadyQueued)
  }

  /// Withdraws the queue entries an availability withholds from a canonical episode menu, leaving
  /// every other entry and the order untouched. Podcast surfaces build their menus from
  /// `PodcastShowPresentation.episodeActions`, so this makes that list player-aware in one place.
  public static func apply(
    _ availability: ListeningQueueActionAvailability, to actions: [MediaItemAction]
  ) -> [MediaItemAction] {
    actions.filter { action in
      switch action {
      case .playNext: availability.offersPlayNext
      case .addToUpNext: availability.offersAddToUpNext
      default: true
      }
    }
  }
}
