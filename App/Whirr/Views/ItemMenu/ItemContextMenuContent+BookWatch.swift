import AppModel
import SwiftUI

extension ItemContextMenuContent {
  /// Read in the presented menu's body, as the episode pair is (`+Podcast.swift`), never in a row's
  /// body. Nil hides the pair: the item has no audio, or the Watch cannot take a book from this
  /// phone. A surface that withholds it does so through `BookMenuSurface.suppressedActions`.
  var bookWatchCopy: PodcastEpisodeWatchCopy? {
    guard capability.supportsPlayback else { return nil }
    return watchCopies?.bookWatchCopy(itemID: itemID)
  }

  /// The question a send larger than the Watch's last reported free space asks first.
  var bookWatchOversizedMessage: String? {
    guard bookWatchCopy == .notOnWatch,
      let oversized = watchCopies?.oversizedBook(itemID: itemID)
    else { return nil }
    return BookWatchPresentation.oversizedMessage(oversized)
  }
}
