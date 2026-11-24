/// One item action's visible title and SF Symbol.
public struct MediaActionLabel: Sendable, Equatable, Hashable {
  public let title: String
  public let systemImage: String
  /// A shorter title for a control-group button, whose titles share one narrow line under their
  /// glyphs. VoiceOver still reads `title`. `nil` where `title` already fits.
  public let compactTitle: String?

  public init(title: String, systemImage: String, compactTitle: String? = nil) {
    self.title = title
    self.systemImage = systemImage
    self.compactTitle = compactTitle
  }
}

/// The single source of every item action's title and glyph: long-press menus, the player and
/// detail overflows, Up Next rows, swipe actions, selection toolbars and the episode rows drawn in
/// DesignSystem all read from here, so the same action cannot be worded two ways. The `item-action-titles-come-from-media-action-copy`
/// source rule fails on a title typed out anywhere else.
///
/// Titles stay on one menu line (`menuTitleBudget`); a longer one wraps and hyphenates in a system
/// menu. Hints and confirmations are not titles and stay with their screens.
public enum MediaActionCopy {
  /// The longest title a system menu row shows on one line at the default text size.
  public static let menuTitleBudget = 22

  // MARK: Playback and queue

  /// The same word for a book and an episode. A row built on the scroll path cannot read the
  /// player, so it always says Play; only a menu built when presented swaps in `pause`.
  public static let play = MediaActionLabel(title: "Play", systemImage: "play.fill")
  public static let pause = MediaActionLabel(title: "Pause", systemImage: "pause.fill")
  /// Up Next's "skip ahead to this row", which is not the same intent as Play.
  public static let playNow = MediaActionLabel(title: "Play Now", systemImage: "play.fill")
  public static let playNext = MediaActionLabel(
    title: "Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
  /// "Play Last" in the menu's top row, as Apple Music and Podcasts word it there; "Add to Up
  /// Next" wraps to two lines under its glyph.
  public static let addToUpNext = MediaActionLabel(
    title: "Add to Up Next", systemImage: "text.line.last.and.arrowtriangle.forward",
    compactTitle: "Play Last")

  /// Chapter Select mode's button, which names how many rows it will queue.
  public static func addToUpNext(count: Int) -> String {
    count == 0 ? addToUpNext.title : "Add \(count) to Up Next"
  }

  // MARK: Saved

  public static let saveForLater = MediaActionLabel(title: "Save for Later", systemImage: "bookmark")
  public static let removeFromSaved = MediaActionLabel(
    title: "Remove from Saved", systemImage: "bookmark.fill")
  /// A batch's removal, where the filled bookmark would read as a state rather than an action.
  public static let removeSelectionFromSaved = MediaActionLabel(
    title: "Remove from Saved", systemImage: "bookmark.slash")

  // MARK: Navigation

  /// The item's own page, from every surface: an episode or a book, from a menu, the player or Up
  /// Next.
  public static let viewDetails = MediaActionLabel(title: "View Details", systemImage: "info.circle")
  /// The show an episode belongs to, which is a different destination from the episode's page.
  public static let viewEpisodes = MediaActionLabel(title: "View Episodes", systemImage: "list.bullet")
  public static let moreFrom = MediaActionLabel(title: "More from…", systemImage: "person.2")
  public static let transcript = MediaActionLabel(title: "Transcript", systemImage: "quote.bubble")
  public static let listeningHistory = MediaActionLabel(
    title: "Listening History", systemImage: "clock.arrow.circlepath")
  /// Not `bookmark`: that glyph is Save for Later in every item menu.
  public static let addBookmark = MediaActionLabel(
    title: "Add Bookmark", systemImage: "bookmark.circle")

  // MARK: Device

  public static let download = MediaActionLabel(title: "Download", systemImage: "arrow.down.circle")
  /// One word for every surface and both media families. The item stays on the server, so
  /// "Delete" would overstate what happens.
  public static let removeDownload = MediaActionLabel(title: "Remove Download", systemImage: "trash")
  public static let removeDownloads = MediaActionLabel(title: "Remove Downloads", systemImage: "trash")
  /// The inert row shown while a removal is in flight.
  public static let removingDownload = MediaActionLabel(
    title: "Removing Download…", systemImage: "trash")
  /// A swipe capsule's short title. VoiceOver reads `removeDownload.title`.
  public static let removeSwipeTitle = "Remove"
  public static let sendToWatch = MediaActionLabel(title: "Send to Watch", systemImage: "applewatch")
  public static let removeFromWatch = MediaActionLabel(
    title: "Remove from Watch", systemImage: "applewatch.slash")

  // MARK: Progress

  /// `checkmark.circle`, Apple's mark-as-played glyph: a bare checkmark is a menu's selection mark
  /// and would read as already chosen.
  public static let markAsFinished = MediaActionLabel(
    title: "Mark as Finished", systemImage: "checkmark.circle")
  public static let resetProgress = MediaActionLabel(
    title: "Reset Progress", systemImage: "arrow.counterclockwise")
  public static let removeFromContinueListening = MediaActionLabel(
    title: ContinueListeningCopy.action, systemImage: "eye.slash")
  /// The submenu that holds the progress entries when two or more apply (`MediaItemMenuLayout`).
  public static let progress = MediaActionLabel(title: "Progress", systemImage: "gauge.with.needle")

  // MARK: Server

  /// "Server", not "Audiobookshelf": the full name wraps and hyphenates in a menu row, and the
  /// app already calls it the server ("Server address").
  public static let saveToServer = MediaActionLabel(
    title: "Save to Server", systemImage: "externaldrive.badge.plus")
  public static let removeFromServer = MediaActionLabel(
    title: "Remove from Server", systemImage: "trash")

  /// Every fixed label above, for the tests that pin the table's rules.
  public static let all: [MediaActionLabel] = [
    play, pause, playNow, playNext, addToUpNext,
    saveForLater, removeFromSaved, removeSelectionFromSaved,
    viewDetails, viewEpisodes, moreFrom, transcript, listeningHistory, addBookmark,
    download, removeDownload, removeDownloads, removingDownload, sendToWatch, removeFromWatch,
    markAsFinished, resetProgress, removeFromContinueListening, progress,
    saveToServer, removeFromServer,
  ]
}
