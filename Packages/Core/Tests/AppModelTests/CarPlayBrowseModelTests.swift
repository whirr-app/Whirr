import Foundation
import TestSupport
import Testing

@testable import AppModel
@testable import Persistence

/// The car's Continue and Up Next lists, read through the boundaries Home uses.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CarPlayBrowseModelTests {

  @Test func continueIsLoadingUntilEverySourceHasDelivered() async {
    let harness = Harness()
    harness.model.start()
    await Self.settle(harness)
    #expect(harness.model.continueListening.content == .loading)

    harness.home.pushContinueListening([Self.book("book-1")])
    await Self.settle(harness)
    #expect(harness.model.continueListening.content == .loading)

    harness.native.push([])
    await Self.until("continue listening delivered") { harness.model.continueListening.content != .loading }

    #expect(Self.rows(harness.model.continueListening).map(\.title) == ["Book book-1"])
  }

  @Test func continueAsksForBooksAndEpisodesTogetherAndBoundsTheRead() async {
    let harness = Harness(limit: 5)
    harness.model.start()
    await Self.settle(harness)

    #expect(harness.home.continueListeningCalls.count == 1)
    #expect(harness.home.continueListeningCalls.first?.category == nil)
    #expect(harness.home.continueListeningCalls.first?.limit == 5)
  }

  @Test func continueMergesSourcesByRecencyAndCarriesExactIdentities() async throws {
    let harness = Harness()
    harness.model.start()
    await Self.settle(harness)
    let feedItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)?.itemId)
    harness.home.pushContinueListening([
      Self.book("book-1", recency: 100),
      Self.episode(itemID: "show-1", episodeID: "ep-9", recency: 300),
    ])
    harness.native.push([Self.episode(itemID: feedItemID, episodeID: "guid-1", recency: 200)])
    await Self.until("continue listening delivered") { harness.model.continueListening.content != .loading }

    let rows = Self.rows(harness.model.continueListening)
    #expect(
      rows.map(\.identity) == [
        .podcastEpisode(itemID: "show-1", episodeID: "ep-9"),
        .rssEpisode(feedID: 7, episodeID: "guid-1"),
        .audiobook(itemID: "book-1"),
      ])
    // An episode row leads with the episode and names its show underneath.
    #expect(rows.first?.title == "Episode ep-9")
    #expect(rows.first?.subtitle == "Show show-1")
    #expect(rows.last?.subtitle == "Author")
    #expect(harness.model.continueListening.generation == 4)
  }

  @Test func nativeRowsAreLeftOutWhileNativeSubscriptionsAreOff() async throws {
    let harness = Harness(nativeEnabled: false)
    harness.model.start()
    await Self.settle(harness)
    let feedItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)?.itemId)
    harness.home.pushContinueListening([Self.book("book-1")])
    harness.native.push([Self.episode(itemID: feedItemID, episodeID: "guid-1", recency: 200)])
    await Self.until("continue listening delivered") { harness.model.continueListening.content != .loading }

    #expect(Self.rows(harness.model.continueListening).map(\.identity) == [.audiobook(itemID: "book-1")])
  }

  @Test func rowWhoseIdentityDoesNotResolveIsShownDisabled() async throws {
    let harness = Harness()
    harness.model.start()
    await Self.settle(harness)
    // A whole native show with no episode names nothing playable.
    let feedItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)?.itemId)
    harness.home.pushContinueListening([])
    harness.native.push([Self.book(feedItemID)])
    await Self.until("continue listening delivered") { harness.model.continueListening.content != .loading }

    let row = try #require(Self.rows(harness.model.continueListening).first)
    #expect(row.identity == nil)
    #expect(row.isPlayable == false)
  }

  @Test func emptyContinueIsRowsNotLoading() async {
    let harness = Harness()
    harness.model.start()
    await Self.settle(harness)
    harness.home.pushContinueListening([])
    harness.native.push([])
    await Self.until("continue listening delivered") { harness.model.continueListening.content != .loading }

    #expect(harness.model.continueListening.content == .rows([]))
  }

  @Test func upNextAsksForABoundedLivePrefixAndKeepsItsOrder() async throws {
    let harness = Harness(limit: 2)
    harness.model.start()
    await Self.settle(harness)
    #expect(harness.model.upNext.content == .loading)
    #expect(harness.queue.limits == [2])

    harness.queue.push([try Self.queued(1, itemID: "book-1"), try Self.queued(3, itemID: "book-3")])
    await Self.until("up next delivered") { harness.model.upNext.content != .loading }

    let rows = Self.rows(harness.model.upNext)
    #expect(rows.map(\.identity) == [.audiobook(itemID: "book-1"), .audiobook(itemID: "book-3")])
    #expect(rows.map(\.id) == ["queue|1", "queue|3"])
    #expect(harness.model.snapshot(for: .upNext) == harness.model.upNext)
    #expect(harness.model.upNext.generation == 4)
  }

  @Test func aQueuedChapterIsNamedByItsChapterAndCarriesItToThePlayAction() async throws {
    let harness = Harness(limit: 2)
    harness.model.start()
    await Self.settle(harness)
    let chapter = ListeningQueueChapter(start: 100, end: 200, title: "The Storm")
    let book = try Self.queued(1, itemID: "book-1")
    let untitled = try Self.queued(2, itemID: "book-2")
    harness.queue.push([
      ListeningQueueItem(
        id: book.id, position: book.position, identity: book.identity, primaryTitle: book.primaryTitle,
        secondaryTitle: book.secondaryTitle, category: .audiobook, isTombstone: false, chapter: chapter),
      ListeningQueueItem(
        id: untitled.id, position: untitled.position, identity: untitled.identity,
        primaryTitle: untitled.primaryTitle, secondaryTitle: "", category: .audiobook, isTombstone: false,
        chapter: ListeningQueueChapter(start: 0, end: 50, title: " ")),
    ])
    await Self.until("up next delivered") { harness.model.upNext.content != .loading }

    let rows = Self.rows(harness.model.upNext)
    #expect(rows.map(\.title) == ["The Storm", "Chapter"])
    #expect(rows.map(\.subtitle) == ["Book book-1 · Author", "Book book-2"])
    #expect(rows.map(\.chapter?.chapter) == [chapter, ListeningQueueChapter(start: 0, end: 50, title: " ")])
    #expect(rows.map(\.chapter?.rowID) == [book.id, untitled.id], "each row starts and consumes its own Up Next row")
  }

  @Test func recentBooksAsksForAudiobooksOnlyAndBoundsTheRead() async {
    let harness = Harness(limit: 3)
    harness.model.start()
    await Self.settle(harness)
    #expect(harness.model.recentBooks.content == .loading)
    #expect(harness.home.recentlyAddedCalls.count == 1)
    #expect(harness.home.recentlyAddedCalls.first?.category == .audiobook)
    #expect(harness.home.recentlyAddedCalls.first?.limit == 3)

    harness.home.pushRecentlyAdded([Self.book("book-1"), Self.book("book-2")])
    await Self.until("recent books delivered") { harness.model.recentBooks.content != .loading }

    let rows = Self.rows(harness.model.recentBooks)
    #expect(rows.map(\.identity) == [.audiobook(itemID: "book-1"), .audiobook(itemID: "book-2")])
    #expect(rows.map(\.id) == ["recent|book-1|", "recent|book-2|"])
  }

  // MARK: Paged routes

  @Test func audiobooksPageThroughTheBoundedReadAndCarryTheGeneration() async throws {
    let harness = Harness(limit: 2)
    harness.books.rows = try (0..<3).map { try Self.pagedBook("book-\($0)") }

    let first = try Self.page(await harness.model.page(.audiobooks, generation: 4))
    let second = try Self.page(await harness.model.page(.audiobooks, after: first.next, generation: 4))

    #expect(first.rows.map(\.identity) == [.audiobook(itemID: "book-0"), .audiobook(itemID: "book-1")])
    #expect(first.generation == 4)
    #expect(first.rows.first?.artwork == .item(id: "book-0", updatedAt: nil))
    #expect(second.rows.map(\.identity) == [.audiobook(itemID: "book-2")])
    #expect(second.next == nil)
    #expect(harness.books.calls.map(\.limit) == [2, 2])
  }

  @Test func showsListTheServerFirstThenTopUpFromFollowedFeeds() async throws {
    let harness = Harness(limit: 3)
    let feedItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)?.itemId)
    harness.serverPodcasts.shows.rows = [Self.show("s-1"), Self.show("s-2")]
    harness.followedPodcasts.shows.rows = [Self.show(feedItemID), Self.show("f-2"), Self.show("f-3")]

    let first = try Self.page(await harness.model.page(.podcastShows, generation: 4))
    let second = try Self.page(await harness.model.page(.podcastShows, after: first.next, generation: 4))

    #expect(first.rows.map(\.id) == ["show|s-1", "show|s-2", "show|\(feedItemID)"])
    #expect(second.rows.map(\.id) == ["show|f-2", "show|f-3"])
    #expect(second.next == nil)
    // A show opens its episodes; a whole show is never a thing to play.
    #expect(first.rows.first?.identity == nil)
    #expect(first.rows.first?.isPlayable == false)
    #expect(first.rows.last?.child == .showEpisodes(itemID: feedItemID))
  }

  @Test func aFullServerPageOnlyPointsAtFollowedFeedsWhenTheyHaveRows() async throws {
    let withFollowed = Harness(limit: 2)
    withFollowed.serverPodcasts.shows.rows = [Self.show("s-1"), Self.show("s-2")]
    withFollowed.followedPodcasts.shows.rows = [Self.show("f-1")]
    let first = try Self.page(await withFollowed.model.page(.podcastShows, generation: 4))
    let second = try Self.page(await withFollowed.model.page(.podcastShows, after: first.next, generation: 4))
    #expect(first.rows.map(\.id) == ["show|s-1", "show|s-2"])
    #expect(second.rows.map(\.id) == ["show|f-1"])

    let serverOnly = Harness(limit: 2)
    serverOnly.serverPodcasts.shows.rows = [Self.show("s-1"), Self.show("s-2")]
    #expect(try Self.page(await serverOnly.model.page(.podcastShows, generation: 4)).next == nil)
  }

  @Test func followedFeedsAreLeftOutOfPagesWhileNativeSubscriptionsAreOff() async throws {
    let harness = Harness(nativeEnabled: false, limit: 3)
    let feedItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)?.itemId)
    harness.serverPodcasts.shows.rows = [Self.show("s-1")]
    harness.followedPodcasts.shows.rows = [Self.show(feedItemID)]
    harness.followedPodcasts.episodes.rows = [try Self.pagedEpisode(feedID: 7, "guid-1")]
    harness.followedDownloads.rows = [try Self.download(feedID: 7, "guid-1")]

    #expect(try Self.page(await harness.model.page(.podcastShows, generation: 4)).rows.map(\.id) == ["show|s-1"])
    #expect(
      try Self.page(await harness.model.page(.showEpisodes(itemID: feedItemID), generation: 4)).rows.isEmpty)
    #expect(try Self.page(await harness.model.page(.downloads, generation: 4)).rows.isEmpty)
    #expect(harness.followedPodcasts.shows.calls.isEmpty)
  }

  @Test func showEpisodesReadTheOwningSourceAndDisableWhatCannotPlay() async throws {
    let harness = Harness(limit: 5)
    let feedItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)?.itemId)
    harness.serverPodcasts.episodes.rows = [
      try Self.pagedEpisode(itemID: "show-1", "streamable"),
      try Self.pagedEpisode(itemID: "show-1", "downloaded", downloaded: true, onServer: false),
      try Self.pagedEpisode(itemID: "show-1", "gone", onServer: false),
    ]
    harness.followedPodcasts.episodes.rows = [try Self.pagedEpisode(feedID: 7, "guid-1")]

    let server = try Self.page(await harness.model.page(.showEpisodes(itemID: "show-1"), generation: 4))
    let followed = try Self.page(await harness.model.page(.showEpisodes(itemID: feedItemID), generation: 4))

    #expect(server.rows.map(\.isPlayable) == [true, true, false])
    #expect(server.rows.map(\.isDownloaded) == [false, true, false])
    #expect(server.rows.first?.identity == .podcastEpisode(itemID: "show-1", episodeID: "streamable"))
    #expect(followed.rows.map(\.identity) == [.rssEpisode(feedID: 7, episodeID: "guid-1")])
    #expect(harness.serverPodcasts.episodeItemIDs == ["show-1"])
    #expect(harness.followedPodcasts.episodeItemIDs == [feedItemID])
  }

  @Test func episodeRowsSayHowLongTheyAreAndHowMuchIsLeft() async throws {
    let harness = Harness(limit: 5)
    let identity = try #require(ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "e"))
    harness.serverPodcasts.episodes.rows = [
      PodcastEpisodePageRow(
        identity: identity, title: "New", publishedAt: nil, durationSeconds: 2_700, isFinished: false,
        audioDownloaded: false, isAvailableOnServer: true),
      PodcastEpisodePageRow(
        identity: identity, title: "Started", publishedAt: nil, durationSeconds: 2_700, isFinished: false,
        audioDownloaded: false, isAvailableOnServer: true, progressSeconds: 900),
      PodcastEpisodePageRow(
        identity: identity, title: "Done", publishedAt: nil, durationSeconds: 2_700, isFinished: true,
        audioDownloaded: false, isAvailableOnServer: true, progressSeconds: 2_700),
    ]

    let page = try Self.page(await harness.model.page(.showEpisodes(itemID: "show-1"), generation: 4))

    #expect(page.rows.map(\.subtitle) == ["45 min", "30 min left", "Played"])
    #expect(page.rows.map(\.progress) == [nil, 900.0 / 2_700.0, 1])
  }

  @Test func latestEpisodesWaitForEverySourceThenMergeNewestFirst() async throws {
    let harness = Harness()
    harness.model.start()
    await Self.until("followed latest episodes observed") { harness.nativeLatest.limits.isEmpty == false }
    #expect(harness.model.latestEpisodes.content == .loading)
    let feedItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)?.itemId)

    harness.home.pushNewPodcastEpisodes([Self.latest(itemID: "show-1", "old", hoursAgo: 30)])
    harness.nativeLatest.push([Self.latest(itemID: feedItemID, "guid", hoursAgo: 2, progress: 600)])
    await Self.until("latest episodes delivered") { harness.model.latestEpisodes.content != .loading }

    let rows = Self.rows(harness.model.latestEpisodes)
    #expect(
      rows.map(\.identity) == [
        .rssEpisode(feedID: 7, episodeID: "guid"), .podcastEpisode(itemID: "show-1", episodeID: "old"),
      ])
    #expect(rows.map(\.title) == ["Episode guid", "Episode old"])
    #expect(rows.map(\.subtitle) == ["Show \(feedItemID) · Today · 20 min left", "Show show-1 · Yesterday · 30 min"])
    #expect(rows.map(\.progress) == [600.0 / 1_800.0, nil])
    #expect(harness.nativeLatest.limits == [CarPlayBrowseModel.latestEpisodeLimit])
    #expect(harness.home.newPodcastEpisodeCalls.map(\.limit) == [CarPlayBrowseModel.latestEpisodeLimit])
    #expect(harness.model.snapshot(for: .latestEpisodes) == harness.model.latestEpisodes)
  }

  @Test func followedEpisodesAreLeftOutOfLatestWhileNativeSubscriptionsAreOff() async throws {
    let harness = Harness(nativeEnabled: false)
    harness.model.start()
    await Self.until("followed latest episodes observed") { harness.nativeLatest.limits.isEmpty == false }
    let feedItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)?.itemId)

    harness.home.pushNewPodcastEpisodes([Self.latest(itemID: "show-1", "server", hoursAgo: 5)])
    harness.nativeLatest.push([Self.latest(itemID: feedItemID, "guid", hoursAgo: 2)])
    await Self.until("latest episodes delivered") { harness.model.latestEpisodes.content != .loading }

    #expect(Self.rows(harness.model.latestEpisodes).map(\.title) == ["Episode server"])
  }

  @Test func authorsAndSeriesOpenTheirBooksAndNeverPlay() async throws {
    let harness = Harness(limit: 2)
    harness.entities.names.rows = [
      AudioEntityPageRow(kind: .author, name: "Ann Lee", bookCount: 1),
      AudioEntityPageRow(kind: .author, name: "Bo Chen", bookCount: 3),
      AudioEntityPageRow(kind: .author, name: "Cy Dunn", bookCount: 2),
    ]

    let first = try Self.page(await harness.model.page(.authors, generation: 4))
    let second = try Self.page(await harness.model.page(.authors, after: first.next, generation: 4))
    let series = try Self.page(await harness.model.page(.series, generation: 4))

    #expect(first.rows.map(\.title) == ["Ann Lee", "Bo Chen"])
    #expect(first.rows.map(\.subtitle) == ["1 book", "3 books"])
    #expect(first.rows.map(\.child) == [.authorBooks(name: "Ann Lee"), .authorBooks(name: "Bo Chen")])
    #expect(first.rows.allSatisfy { $0.identity == nil && $0.isPlayable == false })
    #expect(second.rows.map(\.title) == ["Cy Dunn"])
    #expect(second.next == nil)
    #expect(series.rows.first?.child == .seriesBooks(name: "Ann Lee"))
    #expect(harness.entities.requests == ["author", "author", "series"])
    #expect(await harness.model.page(.series, after: first.next, generation: 4) == .rejected(.staleCursor))
  }

  @Test func anAuthorsAndASeriesBooksPlayAndASeriesLeadsWithTheBookNumber() async throws {
    let harness = Harness(limit: 1)
    let identity = try #require(ListeningIdentity.audiobook(itemID: "b1"))
    harness.entities.books.rows = [
      AudiobookPageRow(
        identity: identity, title: "First", author: "Ann Lee", serverUpdatedAt: nil, seriesSequence: "1"),
      try Self.pagedBook("b2"),
    ]

    let series = try Self.page(await harness.model.page(.seriesBooks(name: "Saga"), generation: 4))
    let more = try Self.page(
      await harness.model.page(.seriesBooks(name: "Saga"), after: series.next, generation: 4))
    let author = try Self.page(await harness.model.page(.authorBooks(name: "Ann Lee"), generation: 4))

    #expect(series.rows.map(\.identity) == [identity])
    #expect(series.rows.map(\.subtitle) == ["Book 1 · Ann Lee"])
    #expect(more.rows.map(\.subtitle) == ["Author"])
    #expect(author.rows.first?.isPlayable == true)
    // The same book in two lists is two rows.
    #expect(series.rows.first?.id != author.rows.first?.id)
    #expect(harness.entities.requests == ["series:Saga", "series:Saga", "author:Ann Lee"])
    #expect(
      await harness.model.page(.authorBooks(name: "Ann Lee"), after: series.next, generation: 4)
        == .rejected(.staleCursor))
  }

  @Test func downloadsListServerAudioThenFollowedEpisodes() async throws {
    let harness = Harness(limit: 2)
    harness.serverDownloads.rows = [try Self.download(itemID: "book-1")]
    harness.followedDownloads.rows = [try Self.download(feedID: 7, "guid-1"), try Self.download(feedID: 7, "guid-2")]

    let first = try Self.page(await harness.model.page(.downloads, generation: 4))
    let second = try Self.page(await harness.model.page(.downloads, after: first.next, generation: 4))

    #expect(first.rows.map(\.identity) == [.audiobook(itemID: "book-1"), .rssEpisode(feedID: 7, episodeID: "guid-1")])
    #expect(second.rows.map(\.identity) == [.rssEpisode(feedID: 7, episodeID: "guid-2")])
    #expect((first.rows + second.rows).map(\.isDownloaded) == [true, true, true])
    #expect(second.next == nil)
  }

  @Test func aPageForAReplacedGraphIsRefusedWithoutReading() async throws {
    let harness = Harness()
    harness.books.rows = [try Self.pagedBook("book-1")]

    #expect(await harness.model.page(.audiobooks, generation: 3) == .rejected(.staleGeneration))
    harness.current.value = 5
    #expect(await harness.model.page(.audiobooks, generation: 4) == .rejected(.staleGeneration))
    #expect(harness.books.calls.isEmpty)
  }

  @Test func aPageThatReturnsAfterTheGraphWasReplacedIsDropped() async throws {
    let harness = Harness()
    harness.books.rows = [try Self.pagedBook("book-1")]
    let current = harness.current
    harness.books.beforeReturning = { await MainActor.run { current.value = 5 } }

    #expect(await harness.model.page(.audiobooks, generation: 4) == .rejected(.staleGeneration))
    #expect(harness.books.calls.count == 1)
  }

  @Test func staleCursorsAndObservedRoutesAreRejected() async throws {
    let harness = Harness(limit: 1)
    harness.books.rows = try (0..<2).map { try Self.pagedBook("book-\($0)") }
    harness.serverPodcasts.shows.rows = [Self.show("s-1")]
    let books = try Self.page(await harness.model.page(.audiobooks, generation: 4))

    // Another list's cursor, and one a reader no longer accepts.
    #expect(await harness.model.page(.podcastShows, after: books.next, generation: 4) == .rejected(.staleCursor))
    harness.serverPodcasts.shows.error = AudioBrowsePagingError.staleCursor
    #expect(await harness.model.page(.podcastShows, generation: 4) == .rejected(.staleCursor))
    harness.serverPodcasts.shows.error = CancellationError()
    #expect(await harness.model.page(.podcastShows, generation: 4) == .rejected(.unavailable))

    #expect(await harness.model.page(.continueListening, generation: 4) == .rejected(.notPaged))
    #expect(harness.model.snapshot(for: .audiobooks) == nil)
  }

  @Test func startingTwiceObservesOnce() async {
    let harness = Harness()
    harness.model.start()
    harness.model.start()
    await Self.settle(harness)

    #expect(harness.home.continueListeningCalls.count == 1)
    #expect(harness.native.observeCallCount == 1)
  }

  @MainActor
  private final class Generation {
    var value = 4
  }

  @MainActor
  private struct Harness {
    let home = FakeHomeReading()
    let native = FakeNativeContinueReading()
    let queue = QueueReading()
    let books = PageSource<AudiobookPageRow>()
    let entities = Entities()
    let nativeLatest = LatestReading()
    let serverPodcasts = Podcasts()
    let followedPodcasts = Podcasts()
    let serverDownloads = PageSource<DownloadedAudioPageRow>()
    let followedDownloads = PageSource<DownloadedAudioPageRow>()
    let current = Generation()
    let model: CarPlayBrowseModel

    init(nativeEnabled: Bool = true, limit: Int = CarPlayBrowseModel.defaultRowLimit) {
      let current = current
      model = CarPlayBrowseModel(
        generation: 4, currentGeneration: { current.value }, home: home, nativeContinueListening: native,
        nativeLatestEpisodes: nativeLatest,
        nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: nativeEnabled),
        sources: CarPlayBrowseSources(
          queue: queue, audiobooks: books, entities: entities, serverPodcasts: serverPodcasts,
          followedPodcasts: followedPodcasts, serverDownloads: serverDownloads,
          followedDownloads: followedDownloads),
        limit: limit, now: { CarPlayBrowseModelTests.now })
    }
  }

  private final class QueueReading: ListeningQueuePrefixReading, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[ListeningQueueItem]>.Continuation?
    private var requested: [Int] = []

    var limits: [Int] { lock.withLock { requested } }

    func observeLiveQueue(limit: Int) -> AsyncStream<[ListeningQueueItem]> {
      AsyncStream { continuation in
        lock.withLock {
          self.requested.append(limit)
          self.continuation = continuation
        }
      }
    }

    func push(_ items: [ListeningQueueItem]) {
      lock.withLock { continuation }?.yield(items)
    }
  }

  /// A list read a page at a time. Its cursor is the next row's index.
  private final class PageSource<Row: Sendable & Equatable>: AudioBrowsePaging, DownloadedAudioPaging,
    @unchecked Sendable
  {
    private let lock = NSLock()
    private var storedRows: [Row] = []
    private var storedCalls: [(after: Int?, limit: Int)] = []
    private var storedError: (any Error)?
    private var storedBeforeReturning: (@Sendable () async -> Void)?

    var rows: [Row] {
      get { lock.withLock { storedRows } }
      set { lock.withLock { storedRows = newValue } }
    }
    var error: (any Error)? {
      get { lock.withLock { storedError } }
      set { lock.withLock { storedError = newValue } }
    }
    var beforeReturning: (@Sendable () async -> Void)? {
      get { lock.withLock { storedBeforeReturning } }
      set { lock.withLock { storedBeforeReturning = newValue } }
    }
    var calls: [(after: Int?, limit: Int)] { lock.withLock { storedCalls } }

    func read(after start: Int?, limit: Int) async throws -> (rows: [Row], next: Int?) {
      lock.withLock { storedCalls.append((start, limit)) }
      await beforeReturning?()
      if let error { throw error }
      let all = rows
      let page = Array(all.dropFirst(start ?? 0).prefix(limit))
      let end = (start ?? 0) + page.count
      return (page, end < all.count ? end : nil)
    }

    func page(after cursor: AudioBrowseCursor?, limit: Int) async throws -> AudioBrowsePage<Row, AudioBrowseCursor> {
      let result = try await read(after: cursor.flatMap { Int($0.scope) }, limit: limit)
      return AudioBrowsePage(
        rows: result.rows, next: result.next.map { AudioBrowseCursor(scope: "\($0)", keys: []) })
    }

    func audiobookPage(
      after cursor: AudiobookPageCursor?, limit: Int
    ) async throws -> AudioBrowsePage<AudiobookPageRow, AudiobookPageCursor> {
      let result = try await read(after: cursor.map { Int($0.rowID) }, limit: limit)
      return AudioBrowsePage(
        rows: result.rows.compactMap { $0 as? AudiobookPageRow },
        next: result.next.map { AudiobookPageCursor(sortTitle: "", rowID: Int64($0)) })
    }

    func downloadedAudioPage(
      after cursor: AudioBrowseCursor?, limit: Int
    ) async throws -> AudioBrowsePage<DownloadedAudioPageRow, AudioBrowseCursor> {
      let page = try await page(after: cursor, limit: limit)
      return AudioBrowsePage(rows: page.rows.compactMap { $0 as? DownloadedAudioPageRow }, next: page.next)
    }
  }

  /// Authors, series and their books. Cursors are the next row's index, as in `PageSource`.
  private final class Entities: AudioEntityPaging, @unchecked Sendable {
    let names = PageSource<AudioEntityPageRow>()
    let books = PageSource<AudiobookPageRow>()
    private let lock = NSLock()
    private var storedRequests: [String] = []

    var requests: [String] { lock.withLock { storedRequests } }

    func entityPage(
      kind: AudioEntityKind, after cursor: AudioEntityCursor?, limit: Int
    ) async throws -> AudioBrowsePage<AudioEntityPageRow, AudioEntityCursor> {
      lock.withLock { storedRequests.append(kind.rawValue) }
      let result = try await names.read(after: cursor.flatMap { Int($0.name) }, limit: limit)
      return AudioBrowsePage(
        rows: result.rows.map { AudioEntityPageRow(kind: kind, name: $0.name, bookCount: $0.bookCount) },
        next: result.next.map { AudioEntityCursor(kind: kind, name: "\($0)") })
    }

    func entityBookPage(
      kind: AudioEntityKind, name: String, after cursor: AudioEntityBookCursor?, limit: Int
    ) async throws -> AudioBrowsePage<AudiobookPageRow, AudioEntityBookCursor> {
      lock.withLock { storedRequests.append("\(kind.rawValue):\(name)") }
      let result = try await books.read(after: cursor.map { Int($0.rowID) }, limit: limit)
      return AudioBrowsePage(
        rows: result.rows,
        next: result.next.map { AudioEntityBookCursor(kind: kind, name: name, rowID: Int64($0)) })
    }
  }

  private final class LatestReading: NativeLatestPodcastEpisodesReading, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[HomePodcastEpisode]>.Continuation?
    private var requested: [Int] = []

    var limits: [Int] { lock.withLock { requested } }

    func observeLatestPodcastEpisodes(
      cutoff: @escaping @Sendable () -> Date, limit: Int
    ) -> AsyncStream<[HomePodcastEpisode]> {
      AsyncStream { continuation in
        lock.withLock {
          requested.append(limit)
          self.continuation = continuation
        }
      }
    }

    func push(_ episodes: [HomePodcastEpisode]) {
      _ = lock.withLock { continuation }?.yield(episodes)
    }
  }

  /// 2026-11-13 12:00 UTC.
  nonisolated static let now = Date(timeIntervalSince1970: 1_794_571_200)

  private static func latest(
    itemID: String, _ episodeID: String, hoursAgo: Double, progress: Double = 0
  ) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: itemID, showTitle: "Show \(itemID)", showAuthor: nil, episodeID: episodeID,
      title: "Episode \(episodeID)", subtitle: nil, publishedAt: now.addingTimeInterval(-hoursAgo * 3_600),
      durationSeconds: 1_800, progressSeconds: progress)
  }

  private final class Podcasts: PodcastBrowsePaging, @unchecked Sendable {
    let shows = PageSource<ItemSummary>()
    let episodes = PageSource<PodcastEpisodePageRow>()
    private let lock = NSLock()
    private var requestedItemIDs: [String] = []

    var episodeItemIDs: [String] { lock.withLock { requestedItemIDs } }

    func showPage(
      after cursor: AudioBrowseCursor?, limit: Int
    ) async throws -> AudioBrowsePage<ItemSummary, AudioBrowseCursor> {
      try await shows.page(after: cursor, limit: limit)
    }

    func episodePage(
      itemID: String, after cursor: AudioBrowseCursor?, limit: Int
    ) async throws -> AudioBrowsePage<PodcastEpisodePageRow, AudioBrowseCursor> {
      lock.withLock { requestedItemIDs.append(itemID) }
      return try await episodes.page(after: cursor, limit: limit)
    }
  }

  private static func page(_ result: CarPlayBrowsePageResult) throws -> CarPlayBrowsePage {
    guard case .page(let page) = result else {
      Issue.record("expected a page, got \(result)")
      throw CancellationError()
    }
    return page
  }

  private static func pagedBook(_ itemID: String) throws -> AudiobookPageRow {
    AudiobookPageRow(
      identity: try #require(ListeningIdentity.audiobook(itemID: itemID)), title: "Book \(itemID)",
      author: "Author", serverUpdatedAt: nil)
  }

  private static func show(_ itemID: String) -> ItemSummary {
    ItemSummary(
      serverItemId: itemID, mediaKind: "podcast", title: "Show \(itemID)", author: "Host",
      durationSeconds: nil, progressSeconds: 0, category: .podcast, hasReadableEbook: false, addedAt: nil,
      seriesName: nil, narratorName: nil, expandedMetadataFetchedAt: nil, itemDescription: nil)
  }

  private static func pagedEpisode(
    itemID: String? = nil, feedID: Int64? = nil, _ episodeID: String, downloaded: Bool = false,
    onServer: Bool = true
  ) throws -> PodcastEpisodePageRow {
    let identity =
      feedID.map { ListeningIdentity.rssEpisode(feedID: $0, episodeID: episodeID) }
      ?? ListeningIdentity.podcastEpisode(itemID: itemID ?? "", episodeID: episodeID)
    return PodcastEpisodePageRow(
      identity: try #require(identity), title: "Episode \(episodeID)", publishedAt: nil,
      durationSeconds: nil, isFinished: false, audioDownloaded: downloaded, isAvailableOnServer: onServer)
  }

  private static func download(
    itemID: String? = nil, feedID: Int64? = nil, _ episodeID: String? = nil
  ) throws -> DownloadedAudioPageRow {
    let identity =
      feedID.flatMap { feedID in episodeID.flatMap { ListeningIdentity.rssEpisode(feedID: feedID, episodeID: $0) } }
      ?? ListeningIdentity.resolving(itemID: itemID ?? "", episodeID: episodeID)
    return DownloadedAudioPageRow(identity: try #require(identity), title: "Download", subtitle: nil)
  }

  private static func rows(_ snapshot: CarPlayBrowseSnapshot) -> [CarPlayBrowseRow] {
    guard case .rows(let rows) = snapshot.content else { return [] }
    return rows
  }

  private static func book(_ itemID: String, recency: TimeInterval? = nil) -> HomeItem {
    HomeItem(
      serverItemId: itemID, title: "Book \(itemID)", author: "Author", category: .audiobook,
      durationSeconds: 100, progressSeconds: 10, isFinished: false, addedAt: nil,
      isDownloaded: false, progressRecency: recency.map(Date.init(timeIntervalSince1970:)))
  }

  private static func episode(itemID: String, episodeID: String, recency: TimeInterval) -> HomeItem {
    HomeItem(
      serverItemId: itemID, title: "Show \(itemID)", author: "Host", category: .podcast,
      durationSeconds: 100, progressSeconds: 10, isFinished: false, addedAt: nil,
      isDownloaded: false, episodeID: episodeID, episodeTitle: "Episode \(episodeID)",
      progressRecency: Date(timeIntervalSince1970: recency))
  }

  private static func queued(_ id: Int64, itemID: String, isTombstone: Bool = false) throws
    -> ListeningQueueItem
  {
    ListeningQueueItem(
      id: id, position: Int(id), identity: try #require(ListeningIdentity.audiobook(itemID: itemID)),
      primaryTitle: "Book \(itemID)", secondaryTitle: "Author", category: .audiobook,
      isTombstone: isTombstone)
  }

  /// Lets the observations deliver before a negative assertion.
  private static func settle(_ harness: Harness) async {
    await awaitQuiescence("car lists settling") {
      let model = harness.model
      return "\(model.continueListening.content)|\(model.upNext.content)|\(model.recentBooks.content)"
        + "|\(harness.queue.limits)|\(harness.home.recentlyAddedCalls.count)"
    }
  }

  private static func until(_ label: String, _ condition: @MainActor () -> Bool) async {
    await waitUntil(label) { condition() }
  }
}
