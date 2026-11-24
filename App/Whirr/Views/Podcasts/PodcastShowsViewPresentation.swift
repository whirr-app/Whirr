import AppModel
import Persistence
import SwiftUI

/// Pure presentation derivation for `PodcastShowsView`. Like `PodcastsViewPresentation`, it keeps
/// "which state wins" decisions testable without rendering.
nonisolated enum PodcastShowsViewPresentation {
  /// Named for the source rather than ownership: the root section that pushes this page is "On
  /// Your Server" and its sibling page is "Followed". Both collections are the user's, so neither
  /// surface claims the word "your" for itself.
  static let navigationTitle = "On Your Server"

  static func reorderAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy
  }

  /// Both all-shows screens wrap Edit and Done in this, so the switch into and out of edit mode
  /// carries the same motion on either source; Reduce Motion removes it.
  static func editModeAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy
  }

  static func placeholder(for state: PodcastShowsModel.State) -> AllShowsPlaceholder? {
    switch state {
    case .loading:
      return .loading(message: state.copyText)
    case .empty:
      return .empty(
        title: "No Shows Yet", message: state.copyText,
        systemImage: "antenna.radiowaves.left.and.right")
    case .error:
      return .error(
        title: "Couldn't Load Shows", message: state.copyText,
        systemImage: "exclamationmark.triangle", action: .retry)
    case .loaded, .partiallySynced, .staleOffline:
      return nil
    }
  }

  /// The snapshot's shows in the order `PodcastShowOrdering` produced, never re-sorted here. Every
  /// state that carries a cached snapshot renders it, settled or not.
  static func shows(in state: PodcastShowsModel.State) -> [ItemSummary] {
    switch state {
    case .loaded(let snapshot), .partiallySynced(let snapshot), .staleOffline(let snapshot):
      return snapshot.shows
    case .loading, .empty, .error:
      return []
    }
  }

  static let tileAccessibilityHint = "Opens the podcast show."

  /// Editing owns the tile's touch: a tap selects in read-only mode, and a drag reorders in edit
  /// mode, never both at once.
  static func tileIsSelectable(isEditing: Bool) -> Bool {
    !isEditing
  }

  /// The long-press context menu and the reorder drag would fight over the same gesture, so the
  /// menu is read-only mode only.
  static func contextMenuIsEnabled(isEditing: Bool) -> Bool {
    !isEditing
  }

  /// Editing availability: a sync run in progress could add a show mid-drag and invalidate the
  /// full visible sequence a completed drag commits, so editing follows
  /// `PodcastShowsModel.isEditingAllowed`.
  static func editingIsAllowed(in state: PodcastShowsModel.State) -> Bool {
    switch state {
    case .loaded, .staleOffline: true
    case .loading, .empty, .partiallySynced, .error: false
    }
  }

  static func editButtonTitle(isEditing: Bool) -> String {
    isEditing ? "Done" : "Edit"
  }

  /// Which accessibility move actions a tile at `index` of `count` items offers: none outside
  /// edit mode. The boundary action is omitted rather than disabled, so VoiceOver never announces
  /// a move that would be a no-op.
  static func accessibilityMoveActions(
    isEditing: Bool, index: Int, count: Int
  ) -> [PodcastShowAccessibilityMove] {
    guard isEditing else { return [] }
    var moves: [PodcastShowAccessibilityMove] = []
    if index > 0 { moves.append(.earlier) }
    if index < count - 1 { moves.append(.later) }
    return moves
  }

  /// The one-based "n of count" value VoiceOver reads alongside a tile while editing.
  static func accessibilityPositionValue(index: Int, count: Int) -> String {
    "\(index + 1) of \(count)"
  }

  /// The destination `PodcastShowsModel.move(itemID:to:)` needs for one accessibility move: one
  /// position away from `index`.
  static func destination(for move: PodcastShowAccessibilityMove, at index: Int) -> Int {
    switch move {
    case .earlier: index - 1
    case .later: index + 1
    }
  }

  /// Entering editing needs a stable snapshot; leaving it never does, so Done survives a gate
  /// that closes mid-edit rather than stranding the user inside a mode with no exit.
  static func editButtonIsAvailable(isEditing: Bool, isEditingAllowed: Bool) -> Bool {
    isEditing || isEditingAllowed
  }

  // MARK: - Mode display and confirmed reset

  /// The sort menu's current-mode row, one label per `PodcastShowSortMode` case.
  static func sortModeLabel(_ mode: PodcastShowSortMode) -> String {
    switch mode {
    case .alphabetical: "Alphabetical"
    case .custom: "Custom"
    }
  }

  /// Reset only has a custom order to discard once one exists. Under Alphabetical it would be a
  /// no-op with nothing to confirm.
  static func resetIsOffered(mode: PodcastShowSortMode) -> Bool {
    mode == .custom
  }

  /// The sort/reset menu is a read-only mode control: a reset mid-drag would race the working
  /// order a completed drop is about to commit.
  static func sortMenuIsAvailable(isEditing: Bool) -> Bool {
    !isEditing
  }

  static let resetMenuActionLabel = AllShowsResetCopy.menuActionLabel
  static let resetConfirmationTitle = AllShowsResetCopy.title
  static let resetConfirmationMessage = AllShowsResetCopy.message
  static let resetConfirmationConfirmLabel = AllShowsResetCopy.confirmLabel
  static let resetConfirmationCancelLabel = AllShowsResetCopy.cancelLabel

  /// What the grid draws: the view-local working order while editing (so an in-flight drag
  /// re-flows without a database write), and the model's observed order otherwise. Shows the
  /// working order has not seen (arrived mid-edit) keep their observed relative position at the
  /// tail, so a stale session never hides a tile.
  static func tiles(_ shows: [ItemSummary], in session: PodcastShowsEditingSession) -> [ItemSummary] {
    guard session.isEditing else { return shows }
    var remaining = Dictionary(
      shows.map { ($0.serverItemId, $0) }, uniquingKeysWith: { first, _ in first })
    var ordered: [ItemSummary] = []
    for id in session.order {
      if let show = remaining.removeValue(forKey: id) { ordered.append(show) }
    }
    ordered.append(contentsOf: shows.filter { remaining[$0.serverItemId] != nil })
    return ordered
  }
}

/// The two accessibility moves a tile can offer while editing. VoiceOver reads `label` aloud.
nonisolated enum PodcastShowAccessibilityMove: Sendable, Equatable {
  case earlier
  case later

  var label: String {
    switch self {
    case .earlier: "Move Earlier"
    case .later: "Move Later"
    }
  }
}

/// The all-shows page's view-local editing state (Edit/Done flag and the working id order a drag
/// re-flows), kept out of the view so it is testable without UI automation.
///
/// Only the working order moves mid-drag; `dragEntered` never touches the database.
/// `completeDrag` hands the finished sequence over once, and only if it differs from the start.
struct PodcastShowsEditingSession: Equatable, Sendable {
  private(set) var isEditing = false
  private(set) var order: [String] = []
  private(set) var draggedID: String?
  private var orderAtDragStart: [String]?

  var isDragging: Bool { draggedID != nil }

  /// Reseeds from the model's durable order. Ignored mid-drag: a snapshot arriving under a moving
  /// finger must not yank tiles out from beneath it.
  mutating func observe(order modelOrder: [String]) {
    guard !isDragging else { return }
    order = modelOrder
  }

  mutating func beginEditing(order modelOrder: [String]) {
    isEditing = true
    order = modelOrder
    clearDrag()
  }

  mutating func endEditing() {
    isEditing = false
    clearDrag()
  }

  /// The sync gate closed while editing: leave the mode and discard whatever the drag had
  /// arranged, without committing a synthetic move.
  mutating func syncGate(isEditingAllowed: Bool, order modelOrder: [String]) {
    guard isEditingAllowed == false else { return }
    isEditing = false
    clearDrag()
    order = modelOrder
  }

  mutating func beginDrag(_ itemID: String) {
    guard isEditing, order.contains(itemID) else { return }
    draggedID = itemID
    orderAtDragStart = order
  }

  /// The drag entered `itemID`'s tile: the dragged show takes that slot, pushing the entered tile
  /// (and everything between) one position back along the single flat sequence. Row and column
  /// do not matter: the grid re-flows the same ids at any column count.
  mutating func dragEntered(_ itemID: String) {
    guard let draggedID, draggedID != itemID,
      let from = order.firstIndex(of: draggedID), let to = order.firstIndex(of: itemID)
    else { return }
    order.remove(at: from)
    order.insert(draggedID, at: to)
  }

  /// Ends the drag and yields the sequence to persist, or `nil` when there is nothing to persist:
  /// no drag in flight, or one that landed exactly where it started. Calling twice yields `nil`
  /// the second time, so one drop can only ever write once.
  mutating func completeDrag() -> [String]? {
    guard draggedID != nil, let start = orderAtDragStart else { return nil }
    clearDrag()
    return order == start ? nil : order
  }

  private mutating func clearDrag() {
    draggedID = nil
    orderAtDragStart = nil
  }
}

/// The all-shows page's confirm-before-reset gate. Opening the sort menu, or seeing the Reset to
/// Alphabetical row in it, never presents the dialog. Only `request()`, the menu row's action,
/// does; `cancel()` dismisses without touching the model, and `confirm()` dismisses so the view
/// can then call `PodcastShowsModel.resetToAlphabetical()` once.
struct PodcastShowsResetConfirmation: Equatable, Sendable {
  private(set) var isPresented = false

  mutating func request() { isPresented = true }
  mutating func cancel() { isPresented = false }
  mutating func confirm() { isPresented = false }
}
