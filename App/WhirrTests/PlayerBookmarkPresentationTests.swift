import AppModel
import Persistence
import PlayerCore
import Testing

@testable import Whirr

struct PlayerBookmarkPresentationTests {
  private let chapters = [
    PlaybackChapter(id: "intro", title: "A Beginning", start: 0, end: 65),
    PlaybackChapter(id: "middle", title: nil, start: 65, end: 3_725),
    PlaybackChapter(id: "end", title: "The Last Word", start: 3_725, end: 3_845),
  ]

  private func bookmark(_ time: Double, _ title: String) -> AudioBookmark {
    AudioBookmark(serverItemID: "li_1", time: time, title: title, createdAt: nil)
  }

  // MARK: - Which items take a bookmark

  @Test("a server audiobook takes bookmarks; an episode or a device-owned item does not")
  func bookmarkableScope() {
    #expect(PlayerBookmarkPresentation.isBookmarkable(itemID: "li_1", episodeID: nil))
    #expect(PlayerBookmarkPresentation.isBookmarkable(itemID: "li_1", episodeID: "ep_1") == false)
    #expect(PlayerBookmarkPresentation.isBookmarkable(itemID: "rss:feed", episodeID: nil) == false)
    #expect(PlayerBookmarkPresentation.isBookmarkable(itemID: "", episodeID: nil) == false)
  }

  @Test("adding needs the shown audiobook to be the one actually loaded")
  func addNeedsLoadedItem() {
    func canAdd(active: String?, loaded: String?, loadedEpisode: String? = nil) -> Bool {
      PlayerBookmarkPresentation.canAddBookmark(
        itemID: "li_1", episodeID: nil, activeItemID: active, loadedItemID: loaded,
        loadedEpisodeID: loadedEpisode)
    }
    #expect(canAdd(active: "li_1", loaded: "li_1"))
    #expect(canAdd(active: "li_1", loaded: nil) == false)
    #expect(canAdd(active: "li_2", loaded: "li_2") == false)
    #expect(canAdd(active: "li_1", loaded: "li_1", loadedEpisode: "ep_1") == false)
    #expect(
      PlayerBookmarkPresentation.canAddBookmark(
        itemID: "li_1", episodeID: "ep_1", activeItemID: "li_1", loadedItemID: "li_1",
        loadedEpisodeID: "ep_1") == false)
  }

  // MARK: - Default title

  @Test("a new bookmark is titled with the chapter it falls in")
  func defaultTitleUsesChapter() {
    #expect(PlayerBookmarkPresentation.defaultTitle(position: 10, chapters: chapters) == "A Beginning")
    #expect(PlayerBookmarkPresentation.defaultTitle(position: 100, chapters: chapters) == "Chapter 2")
  }

  @Test("without chapters the default title names the time")
  func defaultTitleFallsBackToTime() {
    #expect(PlayerBookmarkPresentation.defaultTitle(position: 3_725, chapters: []) == "Bookmark at 1:02:05")
  }

  // MARK: - Rows

  @Test("rows run earliest first and carry their time and chapter")
  func rowsOrderAndDetail() {
    let rows = PlayerBookmarkPresentation.rows(
      bookmarks: [bookmark(3_800, "Ending"), bookmark(30, "Opening line")], chapters: chapters)

    #expect(rows.map(\.title) == ["Opening line", "Ending"])
    #expect(rows.map(\.positionLabel) == ["00:30", "1:03:20"])
    #expect(rows.map(\.chapterTitle) == ["A Beginning", "The Last Word"])
    #expect(rows.map(\.detailText) == ["00:30 · A Beginning", "1:03:20 · The Last Word"])
  }

  @Test("a row reads as title, at position, in chapter")
  func rowAccessibilityLabel() {
    let rows = PlayerBookmarkPresentation.rows(bookmarks: [bookmark(30, "Opening line")], chapters: chapters)
    #expect(rows.first?.accessibilityLabel == "Opening line, at 00:30, in A Beginning")

    let unchaptered = PlayerBookmarkPresentation.rows(bookmarks: [bookmark(30, "Opening line")], chapters: [])
    #expect(unchaptered.first?.accessibilityLabel == "Opening line, at 00:30")
    #expect(unchaptered.first?.detailText == "00:30")
  }

  @Test("a bookmark saved elsewhere with a blank title still has a name")
  func blankTitleFallsBack() {
    let rows = PlayerBookmarkPresentation.rows(bookmarks: [bookmark(30, "  ")], chapters: chapters)
    #expect(rows.first?.title == "Untitled Bookmark")
  }

  @Test("tapping a row seeks to the bookmark's exact stored time")
  func rowSeekTarget() {
    let rows = PlayerBookmarkPresentation.rows(bookmarks: [bookmark(1_234.567, "Odd")], chapters: chapters)
    #expect(rows.first?.seekOffset == 1_234.567)
  }

  // MARK: - Confirmation

  @Test("the confirmation names the outcome and the time")
  func confirmationCopy() {
    let added = PlayerBookmarkPresentation.confirmation(for: .added(bookmark(100, "Chapter 2")))
    #expect(added?.message == "Bookmark added at 01:40")
    #expect(added?.editableBookmark == bookmark(100, "Chapter 2"))

    let existing = PlayerBookmarkPresentation.confirmation(for: .alreadyBookmarked(bookmark(99, "Near")))
    #expect(existing?.message == "Already bookmarked at 01:39")
    #expect(existing?.editableBookmark == bookmark(99, "Near"))

    let failed = PlayerBookmarkPresentation.confirmation(for: .failed)
    #expect(failed?.message == AudioBookmarkCopy.saveFailed)
    #expect(failed?.editableBookmark == nil)
  }

  // MARK: - Overflow menu

  @Test("Add Bookmark leads the overflow menu, in its own group, only when offered")
  func overflowAddBookmark() {
    let without = PlayerOverflowMenuPresentation.actions(
      downloadAction: .download, includesHistory: true, playbackStatus: nil)
    #expect(without.contains(.addBookmark) == false)

    let with = PlayerOverflowMenuPresentation.actions(
      downloadAction: .download, includesHistory: true, includesAddBookmark: true,
      playbackStatus: nil)
    #expect(with.first == .addBookmark)
    #expect(Array(with.dropFirst()) == without)
    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.viewDetails, in: with))
  }
}

/// The Chapters | Bookmarks switch is a system segmented control in the sheet's body, the way the
/// item page's Chapters | Contents switch is. In the principal toolbar slot it was drawn as a
/// toolbar item on the bar's own glass, and it lost the control's glass selection thumb, which is
/// the switch's animation.
@Suite("Chapter sheet mode switch")
struct ChapterSelectorSheetModeSwitchTests {
  @Test("the mode switch is a segmented picker in the body, not a toolbar item")
  func modeSwitchLivesInTheBody() throws {
    let text = try ViewSourceScan.executableText(ofViewNamed: "ChapterSelectorSheet")
    let sheet = try #require(text.range(of: "struct ChapterSelectorSheet"))
    let list = try #require(text.range(of: "struct ChapterSelectorList"))
    let body = text[sheet.upperBound..<list.lowerBound]
    let toolbar = try #require(body.range(of: ".toolbar {"))

    #expect(ViewSourceScan.occurrences(of: [".pickerStyle(.segmented)"], in: String(body)) == 1)
    #expect(body[toolbar.lowerBound...].contains("Picker(") == false)
    #expect(body.contains("placement: .principal") == false)
  }
}
