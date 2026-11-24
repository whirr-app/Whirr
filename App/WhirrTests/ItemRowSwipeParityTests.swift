import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

/// Every full-width item row swipes: a wide row reads as swipeable, so one that does not reads as
/// broken (Home's drill-downs, Search and Library once answered only a long press). The source
/// rules in `Scripts/source-rules/item.toml` cover which lists may draw item cards and which
/// surfaces carry no swipe.
@Suite("Item row swipe parity")
struct ItemRowSwipeParityTests {
  /// Read is offered only where the surface can present the reader. A capsule that does nothing is
  /// the "Play does nothing" bug in a new place.
  @Test("Read is dropped where the surface has no reader")
  func readNeedsAReader() {
    let actions = ItemSwipeActions.Actions(leading: [.read], trailing: [.download])

    let withReader = ItemSwipeActionsModifier.buttons(for: actions, offersRead: true)
    #expect(withReader.leading.map(\.id) == [ItemSwipeAction.read.rawValue])

    let withoutReader = ItemSwipeActionsModifier.buttons(for: actions, offersRead: false)
    #expect(withoutReader.leading.isEmpty)
    #expect(withoutReader.trailing.map(\.id) == [ItemSwipeAction.download.rawValue])
  }

  /// A podcast show listed among items swipes nothing: a show-wide Download or Mark as Finished is
  /// too large for a glancing gesture. An episode swipes as an episode.
  @Test("a show offers no swipe; its episodes and every book do")
  func showsDoNotSwipe() {
    func subject(_ category: ItemMediaCategory, episodeID: String?) -> ItemSwipeSubject {
      ItemSwipeSubject(
        itemID: "item", episodeID: episodeID, category: category, hasReadableEbook: false,
        playbackStatus: nil, durationSeconds: nil)
    }
    #expect(subject(.podcast, episodeID: nil).offersSwipe == false)
    #expect(subject(.podcast, episodeID: "episode").offersSwipe)
    #expect(subject(.audiobook, episodeID: nil).offersSwipe)
    #expect(subject(.ebook, episodeID: nil).offersSwipe)
  }
}
