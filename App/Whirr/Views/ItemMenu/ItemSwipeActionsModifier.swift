import AppModel
import Persistence
import SwiftUI

/// The facts an item row's swipe reads, from whichever projection the list holds.
struct ItemSwipeSubject: Equatable {
  let itemID: String
  /// Set for a podcast episode, which then swipes as an episode does everywhere else.
  let episodeID: String?
  let category: ItemMediaCategory
  let hasReadableEbook: Bool
  /// The same status the row's long-press menu reads, so a swipe and the menu offer the same
  /// progress action.
  let playbackStatus: ItemPlaybackStatus?
  let durationSeconds: Double?

  init(
    itemID: String, episodeID: String?, category: ItemMediaCategory, hasReadableEbook: Bool,
    playbackStatus: ItemPlaybackStatus?, durationSeconds: Double?
  ) {
    self.itemID = itemID
    self.episodeID = episodeID
    self.category = category
    self.hasReadableEbook = hasReadableEbook
    self.playbackStatus = playbackStatus
    self.durationSeconds = durationSeconds
  }

  init(_ item: HomeItem) {
    self.init(
      itemID: item.serverItemId, episodeID: item.episodeID, category: item.category,
      hasReadableEbook: item.hasReadableEbook,
      playbackStatus: MediaProgressActionPolicy.playbackStatus(
        progressSeconds: item.progressSeconds, ebookProgress: item.ebookProgress,
        isFinished: item.isFinished),
      durationSeconds: item.durationSeconds)
  }

  /// A podcast show (not one of its episodes) has no swipe: a show-wide Download or Mark as
  /// Finished is too large an action for a glancing gesture. Long press still carries the menu.
  var offersSwipe: Bool { category != .podcast || episodeID != nil }
}

/// The swipe vocabulary for an item row in an ordinary list: Home's drill-downs, Search, Library.
///
/// Which actions a row offers is `ItemSwipeActions`' `.list` decision; this only renders and runs
/// them, as `PodcastEpisodeSwipeActionsModifier` does for episodes. A row that is a podcast episode
/// is handed to that modifier instead, so an episode swipes the same wherever it is listed.
///
/// Every capsule twins an entry in the row's `itemContextMenu`, never the only route. A selecting
/// row offers none: empty button arrays, not a dropped modifier, keep the view type stable.
struct ItemSwipeActionsModifier: ViewModifier {
  /// `nil` for a row with no long-press menu, which therefore offers no swipe either.
  let subject: ItemSwipeSubject?
  /// For a list about reading (Continue Reading): a mixed item leads with Read rather than Play.
  let prefersReading: Bool
  let isSelecting: Bool
  let nowPlaying: ListeningIdentity?
  let playback: PlaybackModel
  let actions: ItemActionsModel
  /// Opens the reader. `nil` on a surface that does not present it; Read is then not offered.
  let onRead: (() -> Void)?

  /// No branch around `content`: a `List` can only count a row without building it when every
  /// modifier on the row yields one view unconditionally. What varies is the buttons and who runs
  /// them.
  func body(content: Content) -> some View {
    let swipe = resolvedSwipe()
    return
      content
      .swipeActions(edge: .leading, allowsFullSwipe: true) {
        podcastEpisodeSwipeButtons(swipe.leading) { swipe.perform($0) }
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        podcastEpisodeSwipeButtons(swipe.trailing) { swipe.perform($0) }
      }
  }

  private typealias ResolvedSwipe = (
    leading: [PodcastEpisodeSwipeButton], trailing: [PodcastEpisodeSwipeButton],
    perform: (PodcastEpisodeSwipeButton) -> Void
  )

  private func resolvedSwipe() -> ResolvedSwipe {
    #if DEBUG
      if HarnessAblation.noSwipeActions { return ([], [], { _ in }) }
    #endif
    if let subject, let episodeID = subject.episodeID, subject.category == .podcast {
      let episode = PodcastEpisodeSwipeActionsModifier(
        episode: PodcastEpisodeSwipeSubject(
          itemID: subject.itemID, episodeID: episodeID, playbackStatus: subject.playbackStatus,
          durationSeconds: subject.durationSeconds),
        nowPlaying: nowPlaying, playback: playback, actions: actions, isSelecting: isSelecting)
      let buttons = episode.resolvedButtons()
      return (buttons.leading, buttons.trailing, episode.perform)
    }
    guard let subject, isSelecting == false, subject.offersSwipe else {
      return ([], [], { _ in })
    }
    let buttons = Self.buttons(for: resolvedActions(for: subject), offersRead: onRead != nil)
    return (buttons.leading, buttons.trailing, perform)
  }

  private static func capability(of subject: ItemSwipeSubject) -> ItemMediaCapability {
    ItemMediaCapability.derive(category: subject.category, hasReadableEbook: subject.hasReadableEbook)
  }

  private func resolvedActions(for subject: ItemSwipeSubject) -> ItemSwipeActions.Actions {
    let identity = ListeningQueueActionPolicy.identity(
      itemID: subject.itemID, episodeID: subject.episodeID, category: subject.category)
    return ItemSwipeActions.actions(
      shelf: .list(playbackStatus: subject.playbackStatus, prefersReading: prefersReading),
      capability: Self.capability(of: subject),
      deviceAction: actions.downloadAction(for: subject.itemID, episodeID: subject.episodeID),
      identity: identity,
      nowPlaying: nowPlaying,
      isPlaybackIntended: playback.swipeIsPlaybackIntended(
        identity: identity, nowPlaying: nowPlaying))
  }

  static func buttons(
    for actions: ItemSwipeActions.Actions, offersRead: Bool
  ) -> (leading: [PodcastEpisodeSwipeButton], trailing: [PodcastEpisodeSwipeButton]) {
    let keep: (ItemSwipeAction) -> Bool = { offersRead || $0 != .read }
    return (
      leading: ItemSwipePresentation.buttons(for: actions.leading.filter(keep)),
      trailing: ItemSwipePresentation.buttons(for: actions.trailing.filter(keep))
    )
  }

  private func perform(_ button: PodcastEpisodeSwipeButton) {
    guard let subject, let action = ItemSwipeAction(rawValue: button.id) else { return }
    let itemID = subject.itemID
    let episodeID = subject.episodeID
    let progress = PodcastEpisodeProgressActions(actions: actions, playback: playback)

    Task {
      switch action {
      case .play, .pause:
        await playback.performSwipePlayback(
          pause: action == .pause, itemID: itemID, episodeID: episodeID)
      case .playNext:
        await actions.playNext(itemID: itemID, episodeID: episodeID)
      case .read:
        onRead?()
      case .download:
        await actions.requestDownload(
          itemID: itemID, episodeID: episodeID,
          format: ItemSwipeActions.downloadFormat(for: Self.capability(of: subject)))
      case .removeDownload:
        await actions.removeDownload(itemID: itemID, episodeID: episodeID)
      case .markAsFinished:
        await progress.markAsFinished(
          itemID: itemID, episodeID: episodeID, duration: subject.durationSeconds)
      case .resetProgress:
        await progress.resetProgress(
          itemID: itemID, episodeID: episodeID, category: subject.category)
      case .removeFromSaved:
        // Saved for Later's verb; the `.list` shelf never emits it.
        return
      }
    }
  }
}

extension View {
  /// The canonical swipe actions for an item row in a `List`.
  func itemSwipeActions(
    _ subject: ItemSwipeSubject?,
    prefersReading: Bool = false,
    isSelecting: Bool,
    nowPlaying: ListeningIdentity?,
    playback: PlaybackModel,
    actions: ItemActionsModel,
    onRead: (() -> Void)?
  ) -> some View {
    modifier(
      ItemSwipeActionsModifier(
        subject: subject, prefersReading: prefersReading, isSelecting: isSelecting,
        nowPlaying: nowPlaying, playback: playback, actions: actions, onRead: onRead))
  }
}

extension View {
  /// Lets the swipe actions of rows inside this view present outside a `List`.
  ///
  /// iOS 27 only. On 26 a swipe action outside a `List` does nothing, so those rows are reached
  /// through their long-press menu, which carries every swipe action.
  @ViewBuilder
  func swipeActionsContainerWhereSupported() -> some View {
    if #available(iOS 27, *) {
      swipeActionsContainer()
    } else {
      self
    }
  }
}
