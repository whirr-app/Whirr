import AppModel
import Testing

@testable import Whirr

struct ItemDetailJumpListPresentationTests {
  @Test("an audiobook offers chapters and bookmarks, as the player's chapter sheet does")
  func audiobookOffersBookmarks() {
    #expect(
      ItemDetailJumpListPresentation.tabs(capability: .audio, itemID: "li_1")
        == [.chapters, .bookmarks])
  }

  @Test("an audiobook with an ebook adds its contents after the audio lists")
  func mixedItemOffersAllThree() {
    #expect(
      ItemDetailJumpListPresentation.tabs(capability: .audioAndEbook, itemID: "li_1")
        == [.chapters, .bookmarks, .contents])
  }

  @Test("a podcast and a device-owned item take no bookmarks")
  func unbookmarkableItemsOfferChaptersOnly() {
    #expect(ItemDetailJumpListPresentation.tabs(capability: .podcast, itemID: "li_1") == [.chapters])
    #expect(
      ItemDetailJumpListPresentation.tabs(capability: .audio, itemID: "rss:feed")
        == [.chapters])
  }

  @Test("an ebook offers its contents alone, and an unsupported document nothing")
  func readableOnlyItems() {
    #expect(ItemDetailJumpListPresentation.tabs(capability: .ebook, itemID: "li_1") == [.contents])
    #expect(
      ItemDetailJumpListPresentation.tabs(capability: .unsupportedDocument, itemID: "li_1")
        .isEmpty)
  }

  @Test("the title names the list on show")
  func titleFollowsTab() {
    #expect(ItemDetailJumpListPresentation.Tab.chapters.title == "Chapters")
    #expect(ItemDetailJumpListPresentation.Tab.bookmarks.title == "Bookmarks")
    #expect(ItemDetailJumpListPresentation.Tab.contents.title == "Contents")
  }
}
