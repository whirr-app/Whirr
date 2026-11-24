import AppModel
import Persistence
import PlayerCore
import SyncEngine
import Testing

@testable import Whirr

/// The Up Next entries on a chapter row, on item detail and in the player: which titles offer
/// them, and the chapter they queue.
@Suite("Chapter queue actions")
struct ChapterQueueActionTests {
  @Test func bothQueueEndsAreOfferedInMenuOrder() {
    #expect(ChapterQueueAction.allCases.map(\.label) == ["Play Next", "Add to Up Next"])
  }

  @Test(arguments: [
    (ItemMediaCapability.audio, true), (.audioAndEbook, true), (.podcast, false), (.ebook, false),
    (.unsupportedDocument, false),
  ])
  func onlyABooksChaptersCanBeQueued(capability: ItemMediaCapability, offered: Bool) {
    #expect(ChapterQueueAction.isOffered(for: capability) == offered)
  }

  @Test func theQueuedChapterTakesItsTimesFromTheItemAndItsNameFromTheList() {
    let chapters = [
      ItemChapterInfo(title: "One", start: 0, end: 100),
      ItemChapterInfo(title: nil, start: 100, end: 250),
    ]

    #expect(
      ChapterQueueAction.queueChapter(at: 1, displayTitle: "Chapter 2", in: chapters)
        == ListeningQueueChapter(start: 100, end: 250, title: "Chapter 2"))
    #expect(ChapterQueueAction.queueChapter(at: 2, displayTitle: "Chapter 3", in: chapters) == nil)
  }

  @Test func thePlayerOffersThemForABookAndNotAnEpisode() {
    #expect(ChapterQueueAction.isOffered(playingEpisodeID: nil))
    #expect(ChapterQueueAction.isOffered(playingEpisodeID: "episode-1") == false)
  }

  @Test func thePlayersChapterQueuesWithItsOwnTimesAndTheListsName() {
    let chapter = PlaybackChapter(id: "1", title: nil, start: 100, end: 250)

    #expect(
      ChapterQueueAction.queueChapter(chapter, displayTitle: "Chapter 2")
        == ListeningQueueChapter(start: 100, end: 250, title: "Chapter 2"))
  }
}
