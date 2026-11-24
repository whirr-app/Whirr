/// Which surface is presenting a book's shared item menu, and therefore which of its entries are
/// worth a row there.
///
/// The podcast side states the same policy as `PodcastShowPresentation.suppressedActions(on:)`.
/// Here it is the flags below, one per concern, which `suppressedActions` turns into the entries
/// `BookMenuPresentation` drops: suppress what the surface already presents as its own control,
/// keep what it only mentions.
public enum BookMenuSurface: Sendable, Equatable, CaseIterable {
  /// A long press on a library row, a Home card or a search result. The menu is the only way to
  /// reach any of this.
  case browse
  /// The item detail screen's toolbar overflow. Play, Save for Later, the download control and the
  /// author and narrator links are already on screen; repeating them would bury the entries that
  /// are not.
  case itemDetail
  /// A row on the Downloads screen. Deletion is that screen's own control (a confirmed Delete
  /// swipe, and selection), so the menu drops its unconfirmed download entry and the screen
  /// appends its confirmed Delete instead.
  case downloads

  public var entries: BookMenuEntries {
    switch self {
    case .browse:
      BookMenuEntries(
        showsPlayPause: true, showsRead: true, showsQueue: true, showsSaved: true,
        showsNavigation: true, showsDownload: true, showsProgress: true,
        showsSendToEreader: true, showsWatch: true)
    case .itemDetail:
      BookMenuEntries(
        showsPlayPause: false, showsRead: false, showsQueue: true, showsSaved: false,
        showsNavigation: false, showsDownload: false, showsProgress: true,
        showsSendToEreader: true, showsWatch: true)
    case .downloads:
      BookMenuEntries(
        showsPlayPause: true, showsRead: true, showsQueue: true, showsSaved: true,
        showsNavigation: true, showsDownload: false, showsProgress: true,
        showsSendToEreader: true, showsWatch: true)
    }
  }
}

/// Which concerns a book menu draws on a given surface. One flag per thing a caller can withhold,
/// rather than per row: the rows inside a concern are still the shared policy's decision. A
/// surface chooses whether to ask the question, never what the answer is.
public struct BookMenuEntries: Sendable, Equatable {
  public let showsPlayPause: Bool
  public let showsRead: Bool
  /// Play Next and Add to Up Next, which no detail screen presents as a control of its own.
  public let showsQueue: Bool
  public let showsSaved: Bool
  /// The author and narrator links, behind "More from…" when both are present.
  public let showsNavigation: Bool
  public let showsDownload: Bool
  /// Mark as Finished, Reset Progress, Remove from Continue Listening.
  ///
  /// Never empty: `MediaProgressActionPolicy.actions` returns at least one entry for every playback
  /// status. An unstarted ebook keeps Mark as Finished, since a control that comes and goes with
  /// the item's state teaches that the action does not exist.
  public let showsProgress: Bool
  /// Send to E-reader. Whether a row is drawn is still `EbookDeliveryMenuEntry`'s decision: no
  /// ebook file or no devices means none.
  public let showsSendToEreader: Bool
  /// Send to Watch or Remove from Watch, drawn in the download section. No screen presents
  /// it as a control of its own, so every surface keeps it; whether a row is drawn is still the
  /// Watch's answer, and an item with no audio never gets one.
  public let showsWatch: Bool

  public init(
    showsPlayPause: Bool, showsRead: Bool, showsQueue: Bool, showsSaved: Bool,
    showsNavigation: Bool, showsDownload: Bool, showsProgress: Bool, showsSendToEreader: Bool,
    showsWatch: Bool
  ) {
    self.showsPlayPause = showsPlayPause
    self.showsRead = showsRead
    self.showsQueue = showsQueue
    self.showsSaved = showsSaved
    self.showsNavigation = showsNavigation
    self.showsDownload = showsDownload
    self.showsProgress = showsProgress
    self.showsSendToEreader = showsSendToEreader
    self.showsWatch = showsWatch
  }
}
