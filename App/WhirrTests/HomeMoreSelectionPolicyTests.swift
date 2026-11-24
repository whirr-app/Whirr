import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

@Suite("Home More selection")
struct HomeMoreSelectionPolicyTests {
  @Test func onlyContinueShelvesOfferSelection() {
    for section in HomeMoreSection.allCases {
      let expected = section == .continueListening || section == .continueReading
      #expect(HomeMoreSelectionPolicy.offersSelection(section: section) == expected)
    }
  }

  @Test func progressActionsFollowTheItemStatus() {
    let finished = item(progress: 120, finished: true)
    #expect(accepts(.resetProgress, item: finished))
    #expect(!accepts(.markAsFinished, item: finished))

    let untouched = item()
    #expect(accepts(.markAsFinished, item: untouched))
    #expect(!accepts(.resetProgress, item: untouched))

    let inProgress = item(progress: 20)
    #expect(accepts(.markAsFinished, item: inProgress))
    #expect(accepts(.resetProgress, item: inProgress))
  }

  @Test func hiddenAndPlayingItemsCannotBeRemovedFromContinueListening() {
    let inProgress = item(progress: 20)
    #expect(
      accepts(.removeFromContinueListening, item: inProgress))
    #expect(
      !accepts(.removeFromContinueListening, item: inProgress, isHidden: true))
    #expect(
      !accepts(.removeFromContinueListening, item: inProgress, isCurrentlyPlaying: true))
  }

  @Test func downloadsFollowTheDeviceActionAndMediaCapability() {
    let audio = item()
    #expect(accepts(.download, item: audio, deviceAction: .download))
    #expect(!accepts(.download, item: audio, deviceAction: .remove))
    #expect(accepts(.removeDownload, item: audio, deviceAction: .remove))
    #expect(!accepts(.removeDownload, item: audio, deviceAction: .download))

    let unsupported = item(category: .ebook, readable: false)
    #expect(!accepts(.download, item: unsupported, deviceAction: .download))
    #expect(!accepts(.removeDownload, item: unsupported, deviceAction: .remove))
  }

  @Test func formatSelectionOnlyAsksForMixedMedia() {
    #expect(HomeMoreSelectionPolicy.downloadFormat(for: item(), requested: nil) == .audio)
    #expect(
      HomeMoreSelectionPolicy.downloadFormat(
        for: item(readable: true), requested: nil) == nil)
  }

  @Test func shelfRemovalTitleMatchesTheRowContextMenu() {
    let listening = HomeMoreSelectionAction.removeFromShelfTitle(section: .continueListening)
    let reading = HomeMoreSelectionAction.removeFromShelfTitle(section: .continueReading)

    #expect(listening != reading)
    #expect(
      listening == ItemContextMenuPresentation.progressEntry(.removeFromContinueListening).title)
    #expect(
      reading
        == ItemContextMenuPresentation.progressEntry(
          .removeFromContinueListening, usesEbookProgress: true
        ).title)
  }

  @Test func ebookOnlyItemsUseReadingWordingOnEveryShelf() {
    let ebook = item(category: .ebook, readable: true)
    #expect(HomeMoreSelectionPolicy.usesEbookProgress(for: ebook, in: .downloaded))
    #expect(HomeMoreSelectionPolicy.usesEbookProgress(for: ebook, in: .continueListening))
    #expect(HomeMoreSelectionPolicy.usesEbookProgress(for: item(), in: .continueReading))
    #expect(!HomeMoreSelectionPolicy.usesEbookProgress(for: item(), in: .downloaded))
    #expect(
      !HomeMoreSelectionPolicy.usesEbookProgress(for: item(readable: true), in: .downloaded))
  }

  private func accepts(
    _ action: HomeMoreSelectionAction,
    item: HomeItem,
    deviceAction: ItemContextMenuDownloadAction = .download,
    isHidden: Bool = false,
    isCurrentlyPlaying: Bool = false
  ) -> Bool {
    HomeMoreSelectionPolicy.accepts(
      action,
      item: item,
      deviceAction: deviceAction,
      nowPlaying: nil,
      isHidden: isHidden,
      isCurrentlyPlaying: isCurrentlyPlaying)
  }

  private func item(
    category: ItemMediaCategory = .audiobook,
    readable: Bool = false,
    progress: Double = 0,
    finished: Bool = false
  ) -> HomeItem {
    HomeItem(
      serverItemId: "item",
      title: "Item",
      author: "Author",
      category: category,
      hasReadableEbook: readable,
      durationSeconds: 120,
      progressSeconds: progress,
      isFinished: finished,
      addedAt: Date(timeIntervalSince1970: 0),
      isDownloaded: false)
  }
}
