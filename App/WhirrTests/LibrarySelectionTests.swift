import AppModel
import Persistence
import Testing

@testable import Whirr

@Suite("Library selection")
struct LibrarySelectionTests {
  @Test func bulkConfirmationStartsAtTenAffectedTitles() {
    let actions: [LibraryBrowsePresentation.SelectionAction] = [
      .download, .downloadAudio, .downloadEbooks, .downloadAllFormats, .addToUpNext, .markAsFinished,
    ]
    for action in actions {
      for count in [0, 1, 9] {
        #expect(!action.requiresConfirmation(affectedCount: count))
      }
      for count in [10, 128] {
        #expect(action.requiresConfirmation(affectedCount: count))
      }
    }
  }

  @Test func destructiveActionsAlwaysConfirmAndSaveForLaterStaysImmediate() {
    for action in [LibraryBrowsePresentation.SelectionAction.removeDownloads, .resetProgress] {
      #expect(!action.requiresConfirmation(affectedCount: 0))
      for count in [1, 9, 10, 128] {
        #expect(action.requiresConfirmation(affectedCount: count))
      }
    }
    for count in [0, 1, 9, 10, 128] {
      #expect(!LibraryBrowsePresentation.SelectionAction.saveForLater.requiresConfirmation(affectedCount: count))
    }
  }

  @Test func excludesShowContainersAndUnsupportedDocuments() {
    #expect(!LibraryBrowsePresentation.isSelectable(item(.podcast)))
    #expect(!LibraryBrowsePresentation.isSelectable(item(.ebook)))
    #expect(LibraryBrowsePresentation.isSelectable(item(.ebook, readable: true)))
    #expect(LibraryBrowsePresentation.isSelectable(item(.audiobook)))
  }

  @Test func downloadFormatsRespectCapabilitiesAndRequireAnExplicitMixedChoice() {
    typealias Policy = LibraryBrowsePresentation
    let audio = item(.audiobook)
    let ebook = item(.ebook, readable: true)
    let mixed = item(.audiobook, readable: true)
    #expect(Policy.selectionDownloadFormat(.download, item: audio) == .audio)
    #expect(Policy.selectionDownloadFormat(.download, item: ebook) == .ebook)
    #expect(Policy.selectionDownloadFormat(.download, item: mixed) == nil)
    #expect(Policy.selectionDownloadFormat(.downloadAudio, item: ebook) == nil)
    #expect(Policy.selectionDownloadFormat(.downloadEbooks, item: audio) == nil)
    #expect(Policy.selectionDownloadFormat(.downloadAllFormats, item: mixed) == .both)
    #expect(Policy.selectionDownloadFormat(.downloadAllFormats, item: ebook) == .ebook)
  }

  @Test func eligibilityRespectsDownloadProgressSavedAndQueueState() throws {
    let book = item(.audiobook)
    let current = try #require(ListeningIdentity.audiobook(itemID: book.serverItemId))
    #expect(!eligible(.download, book, device: .remove))
    #expect(!eligible(.removeDownloads, book, device: .unavailable))
    #expect(eligible(.removeDownloads, book, device: .remove))
    #expect(!eligible(.markAsFinished, book, progress: .finished))
    #expect(!eligible(.resetProgress, book))
    #expect(eligible(.resetProgress, book, progress: .inProgress))
    #expect(!eligible(.saveForLater, book, saved: nil))
    #expect(!eligible(.saveForLater, book, saved: true))
    #expect(eligible(.saveForLater, book, saved: false))
    #expect(!eligible(.addToUpNext, book))
    #expect(!eligible(.addToUpNext, book, nowPlaying: current))
    #expect(eligible(.addToUpNext, book, nowPlaying: .audiobook(itemID: "other")))
    #expect(!eligible(.addToUpNext, item(.ebook, readable: true), nowPlaying: current))
  }

  @Test func selectAllUsesOnlyTheCurrentQueryAndSelectableMedia() {
    let items = [item(.audiobook, id: "visible"), item(.audiobook, id: "hidden"), item(.podcast, id: "visible-show")]
    let quickFiltered = LibraryQuickFilter.filter(items: items, query: "visible")
    #expect(LibraryBrowsePresentation.selectionItems(from: quickFiltered).map(\.serverItemId) == ["visible"])
    #expect(LibraryBrowsePresentation.selectionItems(from: []).isEmpty)
  }

  @Test func selectionTargetsPreserveVisibleOrderAndExcludeStaleIDs() {
    let items = [item(.audiobook, id: "first"), item(.audiobook, id: "second")]
    #expect(
      LibraryBrowsePresentation.selectedItems(items, ids: ["second", "stale", "first"]).map(\.serverItemId) == [
        "first", "second",
      ])
    #expect(LibraryBrowsePresentation.selectedItems(items, ids: []).isEmpty)
  }

  private func eligible(
    _ action: LibraryBrowsePresentation.SelectionAction, _ item: ItemSummary,
    device: ItemContextMenuDownloadAction = .download, progress: ItemPlaybackStatus? = nil,
    saved: Bool? = nil, nowPlaying: ListeningIdentity? = nil
  ) -> Bool {
    LibraryBrowsePresentation.selectionSupports(
      action, item: item, deviceAction: device, playbackStatus: progress,
      isSaved: saved, nowPlaying: nowPlaying)
  }

  private func item(_ category: ItemMediaCategory, readable: Bool = false, id: String = "book") -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id, mediaKind: category == .podcast ? "podcast" : "book",
      title: id, author: nil, durationSeconds: 120, category: category, hasReadableEbook: readable)
  }
}
