import AppModel
import Foundation
import Persistence
import Testing

/// Which selection actions each entry of a collection or playlist accepts.
@Suite struct LibraryCollectionSelectionPolicyTests {
  @Test func anUnfinishedAudiobookAcceptsEveryActionButReset() {
    let entry = book("a")
    #expect(accepts(.download, entry))
    #expect(!accepts(.removeDownload, entry))
    #expect(accepts(.markAsFinished, entry))
    #expect(!accepts(.resetProgress, entry))
    #expect(accepts(.addToUpNext, entry))
    #expect(accepts(.saveForLater, entry))
  }

  @Test func aFinishedEntryOffersResetNotFinish() {
    for entry in [book("a", finished: true), episode("show", "ep", finished: true)] {
      #expect(!accepts(.markAsFinished, entry))
      #expect(accepts(.resetProgress, entry))
    }
  }

  @Test func anInProgressEntryOffersBothProgressActions() {
    for entry in [book("a", progress: 30), episode("show", "ep", progress: 30)] {
      #expect(accepts(.markAsFinished, entry))
      #expect(accepts(.resetProgress, entry))
    }
  }

  @Test func heldDownloadsOfferRemovalNotDownload() {
    for entry in [book("a"), episode("show", "ep")] {
      #expect(!accepts(.download, entry, device: .remove))
      #expect(accepts(.removeDownload, entry, device: .remove))
      #expect(!accepts(.download, entry, device: .unavailable))
      #expect(!accepts(.removeDownload, entry, device: .unavailable))
    }
  }

  @Test func anEpisodeDownloadsAudioAndQueuesByEpisode() {
    let entry = episode("show", "ep")
    #expect(LibraryCollectionSelectionPolicy.downloadFormat(for: entry, requested: nil) == .audio)
    #expect(accepts(.addToUpNext, entry))
    #expect(!accepts(.addToUpNext, entry, nowPlaying: .podcastEpisode(itemID: "show", episodeID: "ep")))
    #expect(accepts(.saveForLater, entry))
    #expect(!accepts(.saveForLater, entry, isSaved: true))
  }

  @Test func anEbookIsNeverQueuedAndNeverAsksForAudio() {
    let ebook = book("e", category: .ebook, readable: true)
    #expect(!accepts(.addToUpNext, ebook))
    #expect(accepts(.download, ebook))
    #expect(LibraryCollectionSelectionPolicy.downloadFormat(for: ebook, requested: nil) == .ebook)
    #expect(LibraryCollectionSelectionPolicy.downloadFormat(for: ebook, requested: .audio) == nil)
    #expect(LibraryCollectionSelectionPolicy.downloadFormat(for: ebook, requested: .both) == .ebook)
  }

  @Test func aMixedBookNeedsAFormatChoice() {
    let mixed = book("m", readable: true)
    #expect(LibraryCollectionSelectionPolicy.offersFormatChoice(for: mixed))
    #expect(!LibraryCollectionSelectionPolicy.offersFormatChoice(for: book("a")))
    #expect(LibraryCollectionSelectionPolicy.downloadFormat(for: mixed, requested: nil) == nil)
    #expect(LibraryCollectionSelectionPolicy.downloadFormat(for: mixed, requested: .both) == .both)
    #expect(LibraryCollectionSelectionPolicy.downloadFormat(for: book("a"), requested: .ebook) == nil)
  }

  @Test func anUnsupportedDocumentAcceptsNothing() {
    let document = book("d", category: .ebook, readable: false, progress: 30)
    for action in LibraryCollectionSelectionAction.allCases {
      #expect(!accepts(action, document))
    }
  }

  /// The list is read-only in Whirr: no selection action edits it (server lists are edited in
  /// Audiobookshelf itself).
  @Test func noActionEditsTheList() {
    #expect(
      Set(LibraryCollectionSelectionAction.allCases.map(\.title))
        == ["Download", "Mark as Finished", "Reset Progress", "Add to Up Next", "Save for Later", "Remove Downloads"])
  }

  @Test func saveForLaterWaitsForResolvedMembership() {
    #expect(!accepts(.saveForLater, book("a"), isSaved: nil))
    #expect(!accepts(.saveForLater, book("a"), isSaved: true))
  }

  @Test func targetsCarryTheEntrysIdentityInSelectionOrder() {
    let entries = [book("a"), episode("show", "ep"), book("b")]
    let selected = LibraryCollectionSelectionPolicy.selectedEntries(
      entries, ids: [entries[2].id, entries[1].id, "missing"])
    #expect(selected.map(\.id) == [entries[1].id, entries[2].id])

    let target = LibraryCollectionSelectionPolicy.batchTarget(for: entries[1], downloadFormat: .audio)
    #expect(target.itemID == "show")
    #expect(target.episodeID == "ep")
    #expect(target.category == .podcast)
    #expect(target.durationSeconds == 120)
    #expect(target.downloadFormat == .audio)
  }

  // MARK: - Fixtures

  private func accepts(
    _ action: LibraryCollectionSelectionAction, _ entry: LibraryCollectionEntry,
    device: ItemContextMenuDownloadAction = .download, isSaved: Bool? = false,
    nowPlaying: ListeningIdentity? = .audiobook(itemID: "elsewhere")
  ) -> Bool {
    LibraryCollectionSelectionPolicy.accepts(
      action, entry: entry, deviceAction: device, isSaved: isSaved, nowPlaying: nowPlaying)
  }

  private func book(
    _ id: String, category: ItemMediaCategory = .audiobook, readable: Bool = false,
    finished: Bool = false, progress: Double = 0
  ) -> LibraryCollectionEntry {
    .title(
      ItemSummary(
        serverItemId: id, mediaKind: "book", title: id, author: nil,
        durationSeconds: 60, progressSeconds: progress, category: category, hasReadableEbook: readable),
      isFinished: finished)
  }

  private func episode(_ show: String, _ id: String, finished: Bool = false, progress: Double = 0)
    -> LibraryCollectionEntry
  {
    .episode(
      HomePodcastEpisode(
        itemID: show, showTitle: show, showAuthor: nil, episodeID: id, title: id, subtitle: nil,
        publishedAt: Date(timeIntervalSince1970: 0), durationSeconds: 120, progressSeconds: progress,
        isFinished: finished))
  }
}
