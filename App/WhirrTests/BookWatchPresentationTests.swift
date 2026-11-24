import AppModel
import Foundation
import Testing

@testable import Whirr

/// A book's Send to Watch surfaces: the menu pair, the question before a large
/// send, and the detail page's one status line.
@Suite("Book Watch presentation")
struct BookWatchPresentationTests {
  @Test("a book's Watch pair has its own IDs and copy, never the episode pair's")
  func entries() {
    let send = BookWatchPresentation.send
    let remove = BookWatchPresentation.remove

    #expect(BookWatchPresentation.entry(for: .notOnWatch) == send)
    #expect(BookWatchPresentation.entry(for: .onWatch) == remove)
    #expect(send.id == "book-send-to-watch")
    #expect(send.label == "Send to Watch")
    #expect(send.hint == "Downloads this book on your Apple Watch.")
    #expect(send.systemImage == "applewatch")
    #expect(remove.id == "book-remove-from-watch")
    #expect(remove.label == "Remove from Watch")
    #expect(remove.hint == "Removes this book from your Apple Watch.")
    #expect(remove.systemImage == "applewatch.slash")
    #expect(send.id != PodcastEpisodeViewAction.sendToWatch.rawValue)
    #expect(remove.id != PodcastEpisodeViewAction.removeFromWatch.rawValue)
  }

  @Test("only a book known to exceed the Watch's last reported free space asks first")
  func oversizedSend() throws {
    #expect(ABSWatchCopiesModel.oversized(declared: nil, free: 500) == nil, "an unknown size")
    #expect(ABSWatchCopiesModel.oversized(declared: 500, free: nil) == nil, "no inventory yet")
    #expect(ABSWatchCopiesModel.oversized(declared: 500, free: 500) == nil)

    let send = try #require(
      ABSWatchCopiesModel.oversized(declared: 1_400_000_000, free: 600_000_000))
    let message = BookWatchPresentation.oversizedMessage(send)

    #expect(message.hasPrefix("This book is "))
    #expect(message.contains(OnAppleWatchPresentation.bytes(1_400_000_000)))
    #expect(message.contains(OnAppleWatchPresentation.bytes(600_000_000)))
  }

  @Test("Playing on Apple Watch wins the detail line; otherwise it is the copy's progress")
  func statusLine() {
    func line(
      _ copy: OnAppleWatchStatus?, watchPlaying: Bool = false, playingHere: Bool = false
    ) -> String? {
      BookWatchPresentation.statusLine(
        watchPlaying: watchPlaying, playingHere: playingHere, copy: copy)?.text
    }

    #expect(line(.onWatch, watchPlaying: true) == CompanionDeviceIndicatorPresentation.text)
    #expect(line(nil, watchPlaying: true) == CompanionDeviceIndicatorPresentation.text)
    #expect(line(.onWatch, watchPlaying: true, playingHere: true) == "On Apple Watch")
    #expect(line(.onWatch) == "On Apple Watch")
    #expect(line(.downloadingOnWatch(progress: 0.4)) == "Downloading on Watch · 40%")
    #expect(line(.downloadingOnWatch(progress: nil)) == "Downloading on Watch")
    #expect(line(.waitingForWiFiOnWatch) == "Waiting for Wi-Fi on Watch")
    #expect(line(.waitingForWatch) == "Waiting for your Watch")
    #expect(line(nil) == nil)
    for status: OnAppleWatchStatus in [
      .openWhirrOnWatch, .updateWhirrOnWatch, .setUpWatch, .watchStorageFull, .couldNotDownload,
      .notOnServer, .noAudioToDownload, .removedOnWatch, .watchAppNotInstalled,
    ] {
      #expect(line(status) == nil, "\(status)")
    }
    #expect(
      BookWatchPresentation.statusLine(watchPlaying: false, playingHere: false, copy: .onWatch)?
        .systemImage == "applewatch")
  }
}
