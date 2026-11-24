import AppModel
import Foundation

/// A book's Send to Watch surfaces: its menu pair, the question before a large send,
/// and the detail page's status line. Its own copy and IDs: the episode pair's
/// (`PodcastEpisodeViewAction`) hints say "episode".
enum BookWatchPresentation {
  struct Entry: Equatable, Sendable {
    let id: String
    let label: String
    let hint: String
    let systemImage: String
  }

  static let send = Entry(
    id: "book-send-to-watch", label: MediaActionCopy.sendToWatch.title,
    hint: "Downloads this book on your Apple Watch.",
    systemImage: MediaActionCopy.sendToWatch.systemImage)
  static let remove = Entry(
    id: "book-remove-from-watch", label: MediaActionCopy.removeFromWatch.title,
    hint: "Removes this book from your Apple Watch.",
    systemImage: MediaActionCopy.removeFromWatch.systemImage)
  static let sendAnyway = "Send Anyway"

  static func entry(for copy: PodcastEpisodeWatchCopy) -> Entry {
    switch copy {
    case .notOnWatch: send
    case .onWatch: remove
    }
  }

  /// The question a too-large send asks first, as the submenu's title. The Watch's own admission
  /// still decides; a refusal shows as "Watch storage full".
  static func oversizedMessage(_ send: ABSWatchOversizedSend) -> String {
    let size = OnAppleWatchPresentation.bytes(send.declaredBytes)
    let free = OnAppleWatchPresentation.bytes(send.freeBytes)
    return "This book is \(size). Your Watch has about \(free) free."
  }

  // MARK: - The detail page's status line

  struct StatusLine: Equatable, Sendable {
    let text: String
    let systemImage: String
  }

  /// The one line under the detail page's action row for everything the Watch says about this book.
  /// Playing on Apple Watch wins while it applies; otherwise the copy's progress, or nothing for a
  /// state the row on On Apple Watch explains better (a failure, a decline, a removal).
  static func statusLine(
    watchPlaying: Bool, playingHere: Bool, copy: OnAppleWatchStatus?
  ) -> StatusLine? {
    if CompanionDeviceIndicatorPresentation.shows(watchPlaying: watchPlaying, playingHere: playingHere) {
      return StatusLine(
        text: CompanionDeviceIndicatorPresentation.text,
        systemImage: CompanionDeviceIndicatorPresentation.systemImage)
    }
    guard let copy, let text = copyText(copy) else { return nil }
    return StatusLine(text: text, systemImage: "applewatch")
  }

  private static func copyText(_ status: OnAppleWatchStatus) -> String? {
    switch status {
    case .onWatch: "On Apple Watch"
    case .downloadingOnWatch:
      status.downloadPercentText.map { "Downloading on Watch · \($0)" } ?? "Downloading on Watch"
    case .waitingForWiFiOnWatch, .waitingForWatch: status.text
    case .openWhirrOnWatch, .updateWhirrOnWatch, .setUpWatch, .watchStorageFull, .couldNotDownload,
      .notOnServer, .noAudioToDownload, .removedOnWatch, .watchAppNotInstalled:
      nil
    }
  }
}
