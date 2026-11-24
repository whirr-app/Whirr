import Persistence

/// A book's item menu as data: the counterpart of `PodcastShowPresentation.episodeActionSections`,
/// in the same `MediaItemAction` vocabulary and the same `MediaItemMenuSection` order, so a test can
/// compare a book's menu with an episode's without rendering either.
///
/// Surfaces differ only by `BookMenuSurface.suppressedActions`, as episode surfaces differ only by
/// `PodcastShowPresentation.suppressedActions(on:)`. Every input that needs the player or a model is
/// resolved by the caller in the presented menu's body, never on the scroll path.
public enum BookMenuPresentation {
  /// What the caller already knows about one book when its menu is presented.
  public struct State: Sendable, Equatable {
    public var capability: ItemMediaCapability
    /// `nil` while Saved membership is unresolved: the entry is withheld rather than flashed.
    public var isSaved: Bool?
    public var queueAvailability: ListeningQueueActionAvailability
    public var playbackStatus: ItemPlaybackStatus?
    public var isCurrentlyPlaying: Bool
    public var isHidden: Bool
    public var downloadAction: ItemContextMenuDownloadAction
    /// Whether this surface can open the reader at all (the podcast screens cannot).
    public var canOpenReader: Bool
    /// Whether an author or narrator link has a name to search for.
    public var hasCreatorOrNarratorLink: Bool
    /// Whether `EbookDeliveryMenuEntry` resolved a device to send to.
    public var canSendToEreader: Bool
    /// The Watch's answer for this book, or `nil` when it cannot take one from this phone. Only a
    /// book with audio gets the pair.
    public var watchCopy: PodcastEpisodeWatchCopy?

    public init(
      capability: ItemMediaCapability,
      isSaved: Bool? = nil,
      queueAvailability: ListeningQueueActionAvailability = .none,
      playbackStatus: ItemPlaybackStatus? = nil,
      isCurrentlyPlaying: Bool = false,
      isHidden: Bool = false,
      downloadAction: ItemContextMenuDownloadAction = .download,
      canOpenReader: Bool = true,
      hasCreatorOrNarratorLink: Bool = true,
      canSendToEreader: Bool = false,
      watchCopy: PodcastEpisodeWatchCopy? = nil
    ) {
      self.capability = capability
      self.isSaved = isSaved
      self.queueAvailability = queueAvailability
      self.playbackStatus = playbackStatus
      self.isCurrentlyPlaying = isCurrentlyPlaying
      self.isHidden = isHidden
      self.downloadAction = downloadAction
      self.canOpenReader = canOpenReader
      self.hasCreatorOrNarratorLink = hasCreatorOrNarratorLink
      self.canSendToEreader = canSendToEreader
      self.watchCopy = watchCopy
    }
  }

  /// The sections this book's menu draws on `surface`, empty sections omitted.
  ///
  /// `.removeDownload` stands for `.unavailable` too, as it does for an episode: the renderer draws
  /// it inert, reading "Removing Download…", rather than letting it vanish mid-purge.
  public static func actionSections(
    _ state: State, surface: BookMenuSurface
  ) -> [MediaItemActionSection] {
    let suppressed = surface.suppressedActions
    return MediaItemMenuSection.allCases.compactMap { kind in
      let actions = candidates(kind, state).filter { suppressed.contains($0) == false }
      return actions.isEmpty ? nil : MediaItemActionSection(kind: kind, actions: actions)
    }
  }

  /// Every entry the browse surface would offer in one section, before suppression.
  private static func candidates(
    _ kind: MediaItemMenuSection, _ state: State
  ) -> [MediaItemAction] {
    // A document Whirr cannot open has nothing to play, read, download or mark: its page, its
    // creator, and the server's attachment of the file as stored.
    if state.capability == .unsupportedDocument {
      return switch kind {
      case .primary: [.viewDetails]
      case .navigation: state.hasCreatorOrNarratorLink ? [.moreFrom] : []
      case .server: state.canSendToEreader ? [.sendToEreader] : []
      case .saved, .download, .progress, .destructive: []
      }
    }
    switch kind {
    case .primary:
      let playback: [MediaItemAction] =
        state.capability.supportsPlayback
        ? ListeningQueueActionPolicy.apply(
          state.queueAvailability, to: [.playPause, .playNext, .addToUpNext])
        : []
      let read: [MediaItemAction] =
        state.capability.supportsReading && state.canOpenReader ? [.read] : []
      return playback + read
    case .saved:
      return switch state.isSaved {
      case nil: []
      case false: [.saveForLater]
      case true: [.removeFromSaved]
      }
    case .navigation:
      return state.hasCreatorOrNarratorLink ? [.moreFrom] : []
    // The Watch pair follows the device download, as it does for an episode.
    case .download:
      let device: [MediaItemAction] =
        state.downloadAction == .download && state.capability.downloadFormats.isEmpty == false
        ? [.download] : []
      let watch =
        state.capability.supportsPlayback
        ? PodcastShowPresentation.watchActions(state.watchCopy) : []
      return device + watch
    // Never empty: `MediaProgressActionPolicy.actions` returns at least one entry for every
    // playback status.
    case .progress:
      return MediaProgressActionPolicy.actions(
        for: state.playbackStatus, isHidden: state.isHidden,
        isCurrentlyPlaying: state.isCurrentlyPlaying
      ).map(MediaItemAction.init)
    // A book's server action is Send to E-reader. The server-save pair is a native RSS episode
    // concern and never reaches a book menu.
    case .server:
      return state.canSendToEreader ? [.sendToEreader] : []
    case .destructive:
      return state.downloadAction == .download ? [] : [.removeDownload]
    }
  }
}

extension BookMenuSurface {
  /// The book counterpart of `PodcastShowPresentation.suppressedActions(on:)`, derived from
  /// `entries` so the flags stay the one statement of each surface's policy.
  public var suppressedActions: Set<MediaItemAction> {
    let entries = entries
    var suppressed: Set<MediaItemAction> = []
    if entries.showsPlayPause == false { suppressed.insert(.playPause) }
    if entries.showsRead == false { suppressed.insert(.read) }
    if entries.showsQueue == false { suppressed.formUnion([.playNext, .addToUpNext]) }
    if entries.showsSaved == false { suppressed.formUnion([.saveForLater, .removeFromSaved]) }
    if entries.showsNavigation == false { suppressed.insert(.moreFrom) }
    if entries.showsDownload == false { suppressed.formUnion([.download, .removeDownload]) }
    if entries.showsProgress == false {
      suppressed.formUnion([.markAsFinished, .resetProgress, .removeFromContinueListening])
    }
    if entries.showsSendToEreader == false { suppressed.insert(.sendToEreader) }
    if entries.showsWatch == false { suppressed.formUnion([.sendToWatch, .removeFromWatch]) }
    return suppressed
  }
}
