import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

@Suite("Saved selection")
struct SavedForLaterSelectionPolicyTests {
  @Test func unavailableAndUnsupportedItemsOnlyOfferShelfRemoval() {
    for entry in [book(unavailable: true), book(category: .ebook, readable: false)] {
      #expect(accepts(.removeFromSaved, entry))
      for action: SavedForLaterSelectionAction in [
        .download, .removeDownload, .markAsFinished, .resetProgress, .addToUpNext,
      ] {
        #expect(!accepts(action, entry, progress: .inProgress))
      }
    }
  }

  @Test func formatChoicesNeverRequestAudioForAnEbook() {
    let ebook = book(category: .ebook, readable: true)
    let mixed = book(readable: true)
    #expect(SavedForLaterSelectionPolicy.downloadFormat(for: ebook, requested: nil) == .ebook)
    #expect(SavedForLaterSelectionPolicy.downloadFormat(for: ebook, requested: .audio) == nil)
    #expect(SavedForLaterSelectionPolicy.downloadFormat(for: ebook, requested: .both) == .ebook)
    #expect(SavedForLaterSelectionPolicy.downloadFormat(for: mixed, requested: nil) == nil)
    #expect(SavedForLaterSelectionPolicy.downloadFormat(for: mixed, requested: .both) == .both)
    #expect(SavedForLaterSelectionPolicy.downloadFormat(for: book(), requested: .ebook) == nil)
  }

  @Test func wholeItemProgressUsesTheDurableStatusIncludingEbookProgress() {
    let ebook = book(category: .ebook, readable: true)
    #expect(!accepts(.markAsFinished, ebook, progress: .finished))
    #expect(accepts(.resetProgress, ebook, progress: .finished))
    #expect(accepts(.resetProgress, ebook, progress: .inProgress))
    #expect(!accepts(.resetProgress, ebook))
    #expect(!accepts(.download, ebook, device: .remove))
    #expect(!accepts(.removeDownload, ebook, device: .unavailable))
  }

  @Test func typedIdentitySeparatesSourcesAndSiblingShows() {
    let server = episode(itemID: "7", finished: true)
    let native = episode(itemID: "rss:7")
    let sibling = episode(itemID: "8")
    let entries = [server, native, sibling]
    #expect(Set(entries.map(\.identity)).count == 3)
    #expect(
      SavedForLaterSelectionPolicy.selectedEntries(entries, ids: [native.identity, .item(itemID: "missing")]).map(
        \.identity) == [native.identity])
    #expect(native.identity.itemID == "rss:7")
    #expect(!accepts(.markAsFinished, server))
    #expect(accepts(.resetProgress, server))
  }

  @Test func queueRejectsCurrentIdentityAndEbooks() throws {
    let row = episode(itemID: "rss:7")
    let current = try #require(
      ListeningQueueActionPolicy.identity(itemID: "rss:7", episodeID: "same", category: .podcast))
    #expect(!accepts(.addToUpNext, row))
    #expect(!accepts(.addToUpNext, row, nowPlaying: current))
    #expect(accepts(.addToUpNext, episode(itemID: "rss:8"), nowPlaying: current))
    #expect(!accepts(.addToUpNext, book(category: .ebook, readable: true), nowPlaying: current))
  }

  private func accepts(
    _ action: SavedForLaterSelectionAction, _ entry: SavedShelfItem,
    progress: ItemPlaybackStatus? = nil, device: ItemContextMenuDownloadAction = .download,
    nowPlaying: ListeningIdentity? = nil
  ) -> Bool {
    SavedForLaterSelectionPolicy.accepts(
      action, entry: entry, deviceAction: device,
      nowPlaying: nowPlaying, itemPlaybackStatus: progress)
  }

  private func book(category: ItemMediaCategory = .audiobook, readable: Bool = false, unavailable: Bool = false)
    -> SavedShelfItem
  {
    SavedShelfItem(
      identity: .item(itemID: "book"), savedAt: Date(), subjectTitle: "Book", contextTitle: nil,
      category: category,
      itemSummary: ItemSummary(
        serverItemId: "book", mediaKind: "book", title: "Book", author: nil,
        durationSeconds: 120, category: category, hasReadableEbook: readable), episode: nil, isUnavailable: unavailable)
  }

  private func episode(itemID: String, finished: Bool = false) -> SavedShelfItem {
    let identity: SavedShelfIdentity =
      itemID.hasPrefix("rss:")
      ? .rssEpisode(itemID: itemID, episodeID: "same") : .podcastEpisode(itemID: itemID, episodeID: "same")
    return SavedShelfItem(
      identity: identity, savedAt: Date(), subjectTitle: "Episode", contextTitle: "Show", category: .podcast,
      itemSummary: nil,
      episode: HomePodcastEpisode(
        itemID: itemID, showTitle: "Show", showAuthor: nil,
        episodeID: "same", title: "Episode", subtitle: nil, publishedAt: Date(), durationSeconds: 90,
        isFinished: finished), isUnavailable: false)
  }
}
