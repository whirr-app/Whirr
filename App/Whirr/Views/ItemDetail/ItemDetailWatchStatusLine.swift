import AppModel
import SwiftUI

/// The detail page's one line for what the Watch says about this book: "Playing on Apple
/// Watch" while that applies, else the book's copy. A bare line in the action row's stack, so it
/// reserves no height and wraps at accessibility sizes.
struct ItemDetailWatchStatusLine: View {
  let itemID: String
  let playback: PlaybackModel

  @Environment(\.watchCopies) private var watchCopies

  var body: some View {
    if let line = BookWatchPresentation.statusLine(
      watchPlaying: playback.isPlayingOnCompanion(itemID: itemID, episodeID: nil),
      playingHere: playback.activeItemID == itemID && playback.isPlaybackIntended,
      copy: watchCopies?.bookStatus(itemID: itemID))
    {
      Label(line.text, systemImage: line.systemImage)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
  }
}
