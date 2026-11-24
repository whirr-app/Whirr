import ABSApi
import Foundation
import Persistence
import Testing

@testable import Whirr

struct DirectionalArtworkPrefetcherTests {
  @Test("Home rails preserve the displayed item identity order for prefetching")
  func homeRailsProvideArtworkIDsInDisplayOrder() {
    let episodes = [
      HomePodcastEpisode(
        itemID: "show-1", showTitle: "Show 1", showAuthor: nil, episodeID: "episode-1",
        title: "Episode 1", subtitle: nil, publishedAt: Date(timeIntervalSince1970: 1),
        durationSeconds: 60),
      HomePodcastEpisode(
        itemID: "show-2", showTitle: "Show 2", showAuthor: nil, episodeID: "episode-2",
        title: "Episode 2", subtitle: nil, publishedAt: Date(timeIntervalSince1970: 2),
        durationSeconds: 60),
    ]

    #expect(
      HomeArtworkPrefetching.orderedIDs(for: .podcastEpisodes(episodes)) == ["show-1", "show-2"])
  }

  @Test("Saved for Later artwork uses the parent item ID for books and episodes")
  func savedEntriesUseParentItemArtworkIDs() {
    let episode = HomePodcastEpisode(
      itemID: "show", showTitle: "Show", showAuthor: nil, episodeID: "episode",
      title: "Episode", subtitle: nil, publishedAt: Date(timeIntervalSince1970: 1),
      durationSeconds: 60)
    let entries: [SavedShelfItem] = [
      SavedShelfItem(
        identity: .item(itemID: "book"), savedAt: Date(timeIntervalSince1970: 1),
        subjectTitle: "Book", contextTitle: nil, category: .ebook,
        itemSummary: ItemSummary(
          serverItemId: "book", mediaKind: "book", title: "Book", author: nil,
          durationSeconds: nil, category: .ebook),
        episode: nil, isUnavailable: false),
      SavedShelfItem(
        identity: .podcastEpisode(itemID: episode.itemID, episodeID: episode.episodeID),
        savedAt: Date(timeIntervalSince1970: 2), subjectTitle: episode.title,
        contextTitle: episode.showTitle, category: .podcast, itemSummary: nil,
        episode: episode, isUnavailable: false),
    ]

    #expect(HomeArtworkPrefetching.orderedIDs(for: .savedEntries(entries)) == ["book", "show"])
  }

  /// The grid's coalescing contract. `observe` only early-returns on an unchanged candidate
  /// window, so consecutive per-tile indices restarted the sequential batch once per column and
  /// cancelled the transfers it had already started. One row must resolve to one index.
  @Test("row alignment collapses a grid row onto its leading index")
  func rowAlignmentCollapsesAGridRow() {
    let columns = 5
    let firstRow = (0..<columns).map {
      DirectionalArtworkPrefetcher.rowAlignedIndex($0, columns: columns)
    }
    let secondRow = (columns..<(2 * columns)).map {
      DirectionalArtworkPrefetcher.rowAlignedIndex($0, columns: columns)
    }

    #expect(Set(firstRow) == [0])
    #expect(Set(secondRow) == [columns])
    // A single-column layout is already one tile per row, so alignment must not move it.
    #expect(DirectionalArtworkPrefetcher.rowAlignedIndex(7, columns: 1) == 7)
    #expect(DirectionalArtworkPrefetcher.rowAlignedIndex(0, columns: 4) == 0)
    // Defensive: a negative or zero column count must not trap or produce a negative index.
    #expect(DirectionalArtworkPrefetcher.rowAlignedIndex(9, columns: 0) == 9)
    #expect(DirectionalArtworkPrefetcher.rowAlignedIndex(-3, columns: 5) == 0)
  }

  @Test("a Home-card prefetcher builds exact Home-card artwork keys")
  func homeCardPrefetcherBuildsHomeCardKeys() {
    let key = DirectionalArtworkPrefetcher.artworkKey(
      source: .audiobookshelf(ArtworkAccountScope("scope")),
      itemID: "home-item",
      displaySize: 140,
      displayScale: 3,
      artworkRole: .homeCard, revision: .unversioned)

    #expect(key.variant == .homeCard(pixelWidth: 420))
    #expect(key.source == .audiobookshelf(ArtworkAccountScope("scope")))
  }

  @Test("the default prefetcher role remains the library thumbnail variant")
  func defaultPrefetcherBuildsLibraryThumbnailKeys() {
    let key = DirectionalArtworkPrefetcher.artworkKey(
      source: .audiobookshelf(ArtworkAccountScope("scope")),
      itemID: "library-item",
      displaySize: 44,
      displayScale: 3, revision: .unversioned)

    #expect(key.variant == .libraryThumbnail(pixelWidth: 132))
  }

  @Test("a downward visible range selects only the bounded forward and retained-behind window")
  func downwardVisibleRangePrefetchesOnlyTheBoundedForwardWindow() {
    let ids = (0..<30).map(String.init)

    let candidates = DirectionalPrefetchWindow.candidates(
      orderedIDs: ids,
      visibleIndices: 10...14,
      direction: .forward,
      aheadCount: 6,
      behindCount: 2)

    #expect(candidates == ["8", "9", "15", "16", "17", "18", "19", "20"])
  }

  @Test("an upward reversal selects the opposite bounded window")
  func upwardReversalCancelsQueuedDownwardCandidates() {
    let ids = (0..<30).map(String.init)

    let candidates = DirectionalPrefetchWindow.candidates(
      orderedIDs: ids,
      visibleIndices: 10...14,
      direction: .backward,
      aheadCount: 6,
      behindCount: 2)

    #expect(candidates == ["4", "5", "6", "7", "8", "9", "15", "16"])
  }

  @Test("windows clamp safely around a programmatic jump destination")
  func programmaticJumpSeedsAroundTheDestination() {
    let ids = (0..<5).map(String.init)

    let candidates = DirectionalPrefetchWindow.candidates(
      orderedIDs: ids,
      visibleIndices: 0...0,
      direction: .forward,
      aheadCount: 12,
      behindCount: 3)

    #expect(candidates == ["1", "2", "3", "4"])
  }
}
