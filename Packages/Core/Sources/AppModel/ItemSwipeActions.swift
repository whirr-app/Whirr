import Persistence

/// One capsule on an item row's swipe edge.
///
/// Separate from `MediaItemAction`: these rows list books and eBooks as well as episodes,
/// and need verbs that vocabulary lacks (Read) or keeps off its edges (Remove from Saved).
public enum ItemSwipeAction: String, Sendable, Equatable, Hashable {
  case play
  /// The row is the one playing; see `MediaSwipePromotion.pause`.
  case pause
  case playNext
  /// An eBook's only "start" verb.
  case read
  case removeFromSaved
  case download
  case removeDownload
  case markAsFinished
  case resetProgress
}

/// Which actions an item row answers, on which edge.
///
/// One policy for every list of items, so a book swipes the same wherever it is listed. Podcast
/// episodes listed as episodes keep `PodcastEpisodeSwipeActions`; the `.list` shelf orders its
/// trailing edge the same way (device, then progress).
///
/// ## Saved for Later
///
/// A someday list, not a queue, storage or progress. Leading brings an item closer (one
/// media-appropriate promote verb); trailing lets it go (Remove from Saved, plus device
/// management).
///
/// - Remove from Saved is outermost on trailing and owns the full swipe, on every row shape
///   including the tombstone; it is the only action every shape supports.
/// - Red is therefore not outermost: Delete Download sits inside it, so a full swipe never deletes
///   gigabytes of audio on a bookmark shelf.
///
/// Progress actions are absent: a book saved because it is unread would be offered only Mark as
/// Finished, leaving a finished item on the shelf. Long press still carries both.
///
/// ## Any other list
///
/// Home's drill-downs, Search and Library. Leading is the same promote verb; trailing is the
/// coarse device action, then the first progress action `MediaProgressActionPolicy` offers. No
/// Remove from Saved: that belongs to the shelf.
public enum ItemSwipeActions {
  public enum Shelf: Sendable, Equatable {
    case savedForLater
    /// `prefersReading` is for a list about reading (Continue Reading): an item with both an
    /// eBook and audio leads with Read there rather than Play.
    case list(playbackStatus: ItemPlaybackStatus?, prefersReading: Bool = false)
  }

  public struct Actions: Sendable, Equatable {
    public let leading: [ItemSwipeAction]
    public let trailing: [ItemSwipeAction]

    public init(leading: [ItemSwipeAction], trailing: [ItemSwipeAction]) {
      self.leading = leading
      self.trailing = trailing
    }
  }

  /// - Parameters:
  ///   - capability: `nil` is the unavailable placeholder (an identity the server no longer lists).
  ///     On the saved shelf it answers Remove from Saved only; on a list, nothing.
  ///   - deviceAction: the same coarse device state every other swipe surface reads.
  ///   - identity: the playable identity, when the row has one. Absent for an eBook.
  ///   - isPlaybackIntended: read only when `identity` is `nowPlaying`; see `MediaSwipePromotion`.
  public static func actions(
    shelf: Shelf,
    capability: ItemMediaCapability?,
    deviceAction: ItemContextMenuDownloadAction,
    identity: ListeningIdentity?,
    nowPlaying: ListeningIdentity?,
    isPlaybackIntended: Bool
  ) -> Actions {
    let shelfActions: [ItemSwipeAction]
    let progress: [ItemSwipeAction]
    let prefersReading: Bool
    switch shelf {
    case .savedForLater:
      shelfActions = [.removeFromSaved]
      progress = []
      prefersReading = false
    case .list(let playbackStatus, let reading):
      shelfActions = []
      // Swipe shows only the first eligible action, as an episode row does; the menu has the rest.
      progress = MediaProgressActionPolicy.actions(for: playbackStatus).prefix(1).compactMap {
        action in
        switch action {
        case .markAsFinished: .markAsFinished
        case .resetProgress: .resetProgress
        case .removeFromContinueListening: nil
        }
      }
      prefersReading = reading
    }

    guard let capability else {
      return Actions(leading: [], trailing: shelfActions)
    }

    let leading: [ItemSwipeAction]
    switch capability {
    case .audioAndEbook where prefersReading:
      leading = [.read]
    case .audio, .audioAndEbook, .podcast:
      leading =
        switch MediaSwipePromotion.leading(
          identity: identity, nowPlaying: nowPlaying, isPlaybackIntended: isPlaybackIntended)
        {
        case .play: [.play]
        case .pause: [.pause]
        case .playNext: [.playNext]
        case nil: []
        }
    case .ebook:
      leading = [.read]
    case .unsupportedDocument:
      leading = []
    }

    let isActionable = capability != .unsupportedDocument
    guard capability.supportsDownload else {
      return Actions(leading: leading, trailing: shelfActions + (isActionable ? progress : []))
    }

    // Coarse, as in `PodcastEpisodeSwipeActions`: a swipe removes whatever download is present
    // rather than reproducing the fine-grained pause/resume controls.
    let device: [ItemSwipeAction] =
      switch deviceAction {
      case .download: [.download]
      case .remove: [.removeDownload]
      case .unavailable: []
      }

    return Actions(leading: leading, trailing: shelfActions + device + progress)
  }

  /// The format a single Download capsule requests. Coarse, since a capsule cannot offer the
  /// three-way choice the long-press menu does, and symmetric with Remove Download, which is
  /// already item-wide.
  public static func downloadFormat(for capability: ItemMediaCapability) -> ItemDownloadFormat {
    capability.downloadFormats.count > 1 ? .both : (capability.downloadFormats.first ?? .audio)
  }
}
