import AppModel
import Persistence

nonisolated enum NativePodcastShowsViewPresentation {
  enum EditModeEntranceCue: Equatable {
    case none
    case scale
  }

  static let navigationTitle = "Followed"
  static let sortMenuLabel = "Sort"
  static let resetMenuActionLabel = AllShowsResetCopy.menuActionLabel
  static let resetConfirmationTitle = AllShowsResetCopy.title
  static let resetConfirmationMessage = AllShowsResetCopy.message
  static let resetConfirmationConfirmLabel = AllShowsResetCopy.confirmLabel
  static let resetConfirmationCancelLabel = AllShowsResetCopy.cancelLabel
  /// Not the server's "Loading your shows…": neither source claims "your".
  static let loadingMessage = "Loading shows…"
  static let emptyTitle = "No Shows Yet"
  static let emptyMessage = "Follow a podcast to see it here."
  static let emptySystemImage = "antenna.radiowaves.left.and.right"
  static let unfollowConfirmationMessage =
    "Its downloads and listening history will be deleted from this device. If it’s playing, playback will stop."
  static let unfollowConfirmLabel = "Unfollow"
  static let unfollowSystemImage = "minus"

  static func showsUnfollowControl(isEditing: Bool) -> Bool { isEditing }

  static func shouldEndEditing(showCount: Int) -> Bool { showCount == 0 }

  static func unfollowConfirmationTitle(showTitle: String) -> String {
    "Unfollow “\(showTitle)”?"
  }

  static func unfollowAccessibilityLabel(showTitle: String) -> String {
    "Unfollow \(showTitle)"
  }

  static func editModeEntranceCue(reduceMotion: Bool) -> EditModeEntranceCue {
    reduceMotion ? .none : .scale
  }

  static func sortModeLabel(_ mode: NativePodcastShowSortMode) -> String {
    switch mode {
    case .alphabetical: "Alphabetical"
    case .mostRecent: "Most Recent"
    case .custom: "Custom"
    }
  }

  static let sortModeMenuOrder: [NativePodcastShowSortMode] = [
    .alphabetical, .mostRecent, .custom,
  ]

  static func resetIsOffered(mode: NativePodcastShowSortMode) -> Bool { mode == .custom }

  static func placeholder(for state: NativePodcastShowsModel.State) -> AllShowsPlaceholder? {
    switch state {
    case .loading: .loading(message: loadingMessage)
    case .empty:
      .empty(title: emptyTitle, message: emptyMessage, systemImage: emptySystemImage)
    case .loaded: nil
    }
  }
}

struct NativePodcastUnfollowConfirmation: Equatable, Sendable {
  struct Target: Equatable, Sendable {
    let itemID: String
    let title: String
  }

  private(set) var target: Target?
  var isPresented: Bool { target != nil }

  mutating func request(itemID: String, title: String) {
    target = Target(itemID: itemID, title: title)
  }

  mutating func cancel() {
    target = nil
  }

  mutating func confirm() -> Target? {
    defer { target = nil }
    return target
  }
}
