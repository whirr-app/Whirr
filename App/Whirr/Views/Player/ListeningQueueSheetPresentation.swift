import AppModel
import DesignSystem
import Persistence

/// What the player-owned queue sheet renders and what its controls mean, as pure functions of
/// `ListeningQueueModel`'s state. Sibling to `ListeningQueuePresentation` (how it is presented).
/// Constructs no view, reads no SwiftUI environment, mutates nothing.
nonisolated enum ListeningQueueSheetPresentation {

  // MARK: - The Up Next quick action

  /// What the player's third quick action does. The queue emerges over the still-presented player
  /// rather than becoming a route, so `.navigateAndCollapse` exists only as the case this policy
  /// never selects, keeping the difference assertable.
  enum UpNextActivation: Sendable, Equatable {
    case presentSheet
    case navigateAndCollapse
  }

  static let upNextActivation: UpNextActivation = .presentSheet

  /// The same label empty or populated: no badge, count, or next-title text.
  static let upNextLabel = "Up Next"
  static let upNextHint = "Shows and manages what will play next."
  static let upNextSymbol = "text.line.first.and.arrowtriangle.forward"

  // MARK: - Opening the player from a row

  /// What a row seeds the player with: its title and byline, the show's cover and the episode's own
  /// image, so the page draws and tints from the episode before its item loads.
  @MainActor
  static func playerSeed(for row: ListeningQueueViewPresentation.Row) -> PlayerMetadataSeed {
    PlayerMetadataSeed(
      identity: row.identity, title: row.itemTitle,
      author: row.itemAuthor.isEmpty ? nil : row.itemAuthor,
      artworkSource: row.providerArtworkSource, artworkRevision: row.artworkRevision,
      episodeArtworkSource: row.episodeArtworkSource)
  }

  // MARK: - Content

  enum Content: Sendable, Equatable {
    case loading
    case empty
    /// Emptied by this Clear, with the transient Undo still live.
    case cleared
    case rows
  }

  /// `offersUndo` is `ListeningQueueModel.canUndoClear` narrowed to the current presentation. The
  /// transient action is invalidated when the sheet is dismissed, and the model owns no dismissal
  /// signal (its token has to outlive the sheet's view identity), so the sheet scopes the offer.
  static func content(state: ListeningQueueModel.State, offersUndo: Bool) -> Content {
    switch state {
    case .loading: .loading
    case .loaded: .rows
    case .empty: offersUndo ? .cleared : .empty
    }
  }

  /// The overflow carries Clear Up Next only while there is something to clear.
  static func showsClearAction(state: ListeningQueueModel.State) -> Bool {
    state == .loaded
  }

  // MARK: - Play Now

  enum PlayNowOutcome: Sendable, Equatable {
    case dismiss
    case stay
  }

  /// The row leaves Up Next only once preparation succeeded, and `PlaybackModel` performs that
  /// consumption itself (`acknowledgeStarted`), so the sheet's only decision is whether to get out
  /// of the way. A failed start leaves the sheet up, with the row in its prior position while the
  /// shared failure alert explains why playback was refused.
  static func playNowOutcome(
    requested: ListeningIdentity,
    nowPlaying: ListeningIdentity?,
    startFailureMessage: String?
  ) -> PlayNowOutcome {
    guard startFailureMessage == nil, nowPlaying == requested else { return .stay }
    return .dismiss
  }

  // MARK: - Reorder

  /// Translates SwiftUI's `onMove(perform:)` pair (whose `destination` is an index in the list as
  /// it stood before the row was lifted out) into the dense queue position `ListeningQueueModel
  /// .move(rowID:to:)` expects. `nil` for a move that resolves back onto the row's own position,
  /// which must not spend a queue revision (and would retire a live Clear undo offer for nothing).
  static func moveDestination(from source: Int, to destination: Int) -> Int? {
    let resolved = destination > source ? destination - 1 : destination
    return resolved == source ? nil : resolved
  }

  // MARK: - Open/close

  /// Opening and closing the queue: local presentation state, never a route. Opening Up Next must
  /// never change `NavigationModel.section` or any section path, so these two functions see no
  /// navigation at all.
  static func openQueue(_ isPresented: inout Bool) {
    isPresented = true
  }

  static func closeQueue(_ isPresented: inout Bool) {
    isPresented = false
  }

  /// Where a row's Open entry goes. An episode raises its card over the player, as the player's
  /// own View Details does; a book pushes its detail page behind the collapsing player.
  enum OpenDestination: Equatable {
    case episodeCard(NavigationModel.PodcastEpisodeRef)
    case route(NavigationModel.Route)
  }

  @MainActor static func openDestination(
    identity: ListeningIdentity, category: ItemMediaCategory
  ) -> OpenDestination {
    if category == .podcast,
      case .episodeCard(let ref) = PlayerDetailsNavigationPresentation.destination(
        itemID: identity.itemID, episodeID: identity.episodeID)
    {
      return .episodeCard(ref)
    }
    return .route(PodcastNavigationPresentation.route(itemID: identity.itemID, category: category))
  }

  // MARK: - Copy

  static let title = "Up Next"

  static let emptyTitle = "Nothing queued"
  static let emptyMessage = "Use Play Next or Add to Up Next from a book or episode."
  static let emptySymbol = "text.line.first.and.arrowtriangle.forward"

  static let clearedTitle = ListeningQueueCopy.cleared
  static let undoLabel = "Undo"
  static let undoHint = "Restores the items that were just cleared."

  static let clearLabel = "Clear Up Next"
  /// Clear Up Next announces that it does not stop the current item.
  static let clearHint = "Removes everything from Up Next. Does not stop what is playing now."
  static let overflowLabel = "Up Next options"
  static let overflowHint = "Shows actions for the whole queue."

  static let nextLabel = "Next"
  static let unavailableLabel = "No longer available"
  static let removeLabel = "Remove"
  /// Carried by the swipe action's own `Button`, which can take a hint.
  static let removeHint = "Removes this item from Up Next."
  /// The two move labels are hintless. They reach VoiceOver as `accessibilityAction(named:)`
  /// custom actions, which take a label and nothing else, so they must be self-describing.
  static let moveEarlierLabel = "Move Earlier"
  static let moveLaterLabel = "Move Later"
  static let rowActionsLabel = "Item options"
  static let rowActionsHint = "Shows actions for this queued item."

  // MARK: - The non-swipe route to removal (SC 2.5.7)

  /// Removal as a menu entry rather than a swipe. The swipe is the fast path, but it is a dragging
  /// movement, and SC 2.5.7 asks that anything a drag achieves also be achievable with a single
  /// pointer. This is the same removal in the row's own menu vocabulary, so the two routes cannot
  /// drift apart in label or behaviour.
  static let removeContextAction = MediaContextAction(
    id: "remove-from-up-next",
    label: removeLabel,
    hint: removeHint,
    systemImage: "trash",
    role: .destructive)

  /// What the row's ellipsis menu and its long press both list: the queue's own actions, then
  /// removal last, where a destructive entry belongs. With `displacedTitle`, the swap follows
  /// Play Now.
  static func rowContextActions(
    for category: ItemMediaCategory, displacedTitle: String? = nil
  ) -> [MediaContextAction] {
    var actions = ListeningQueueViewPresentation.contextActions(for: category)
    if let displacedTitle {
      actions.insert(swapContextAction(displacedTitle: displacedTitle), at: 1)
    }
    return actions + [removeContextAction]
  }

  // MARK: - Play Now, Then Resume

  static let swapActionID = "play-now-then-resume"

  /// Plays the row now and returns what was playing to the front of Up Next
  /// (`PlaybackModel.swap(toQueueItem:)`). The label stays short for the menu; the hint names the
  /// title that resumes.
  static func swapContextAction(displacedTitle: String) -> MediaContextAction {
    MediaContextAction(
      id: swapActionID,
      label: "Play Now, Then Resume",
      hint: "Plays this now, then resumes \(displacedTitle) where you left off.",
      systemImage: "arrow.left.arrow.right")
  }

  /// The title a swap from this row would return to Up Next, or nil when no swap is offered:
  /// nothing is playing, or the row is the title already playing.
  static func displacedTitle(
    row: ListeningIdentity, nowPlaying: ListeningIdentity?, displayed: PlaybackBookmark?
  ) -> String? {
    guard let nowPlaying, nowPlaying != row, let displayed else { return nil }
    return displayed.episodeTitle ?? displayed.title
  }

  static let errorAlertTitle = "Up Next"
}
