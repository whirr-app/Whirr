import ABSApi
import Foundation
import Testing

@testable import WatchPlayback

@Suite("Watch library browse")
struct WatchLibraryBrowseTests {
  @Test("podcast progress filters partition episodes before paging", arguments: [false, true])
  func podcastProgressFilters(recent: Bool) async throws {
    let service = try FakeService()
    let ids = ["new", "partial", "finished", "marked", "fraction", "reset"]
    let episodes = ids.enumerated().map { index, id in
      PodcastEpisode(
        id: id, title: id, contentUrl: nil, mimeType: nil, duration: 100,
        publishedAt: Date(timeIntervalSince1970: Double(index)))
    }
    service.detailValue = ItemDetail(
      id: "show", libraryID: "podcasts", mediaType: "podcast",
      media: .podcast(PodcastMedia(title: "Show", author: nil, description: nil, episodes: episodes)))
    service.recentEpisodePages = [
      episodes.map {
        RecentEpisode(libraryItemID: "show", showTitle: "Show", showAuthor: nil, episode: $0)
      }
    ]
    func progress(
      _ id: String, seconds: Double?, fraction: Double? = nil, finished: Bool = false,
      show: String = "show"
    ) -> MediaProgress {
      MediaProgress(
        libraryItemID: show, episodeID: id, mediaItemID: nil, mediaItemType: "podcast",
        duration: 100, progress: fraction, currentTime: seconds, isFinished: finished,
        hideFromContinueListening: false, ebookLocation: nil, ebookProgress: nil,
        lastUpdate: nil, startedAt: nil, finishedAt: nil)
    }
    service.progressValue = UserProgressSnapshot(
      progress: [
        progress("partial", seconds: 10), progress("finished", seconds: 100, finished: true),
        progress("marked", seconds: 0, finished: true), progress("fraction", seconds: nil, fraction: 0.2),
        progress("reset", seconds: 0, fraction: 0.5), progress("new", seconds: 30, show: "other-show"),
      ], hiddenSeriesIDs: [])
    let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings())
    let client = WatchLibraryClient(accountStore: store, service: service)
    _ = try await client.login(apiToken: "token")
    func fetch(_ filter: WatchPodcastEpisodeFilter, page: Int = 0, limit: Int = 40) async throws
      -> WatchLibraryBrowsePage<WatchPodcastBrowseEpisode>
    {
      if recent {
        return try await client.browseRecentPodcastEpisodes(
          libraryID: "podcasts", filter: filter, page: page, limit: limit)
      }
      return try await client.browsePodcastEpisodes(
        libraryID: "podcasts", showID: "show", filter: filter, page: page, limit: limit)
    }
    let unplayed = try await fetch(.unplayed)
    #expect(unplayed.items.map(\.title) == ["reset", "new"])
    let inProgress = try #require(WatchPodcastEpisodeFilter(rawValue: "inProgress"))
    let first = try await fetch(inProgress, limit: 1)
    let second = try await fetch(inProgress, page: 1, limit: 1)
    #expect(first.items.map(\.title) == ["fraction"])
    #expect(first.total == 2 && first.hasMore)
    #expect(second.items.map(\.title) == ["partial"])
    #expect(second.total == 2 && !second.hasMore)
    #expect(try await fetch(.all).total == ids.count)
  }

  @Test("Watch browse cache is scoped to the selected server library")
  func browseCacheScopesLibrary() async throws {
    let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings())
    let service = try FakeService()
    func page(_ id: String, _ title: String) -> LibraryItemsPage {
      LibraryItemsPage(
        items: [
          LibraryItemSummary(
            id: id, libraryID: id, mediaType: "book", title: title, authorName: nil, seriesName: nil, numAudioFiles: 1)
        ],
        total: 1, limit: 100, page: 0)
    }
    service.browsePagesByLibrary = ["one": [page("one-book", "One")], "two": [page("two-book", "Two")]]
    let client = WatchLibraryClient(accountStore: store, service: service)
    _ = try await client.login(apiToken: "token")
    let one = try await client.browseAudiobooks(libraryID: "one")
    let two = try await client.browseAudiobooks(libraryID: "two")
    #expect(one.items.map(\.id) == ["one-book"])
    #expect(two.items.map(\.id) == ["two-book"])
  }

  @Test("Watch browse fences a delayed response after account invalidation")
  func browseDropsObsoleteResponseAfterLogout() async throws {
    let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings())
    let service = try FakeService()
    service.browsePages = [
      LibraryItemsPage(
        items: [
          LibraryItemSummary(
            id: "stale", libraryID: "books", mediaType: "book", title: "Stale", authorName: nil,
            seriesName: nil, numAudioFiles: 1)
        ], total: 1, limit: 100, page: 0)
    ]
    let gate = BrowseResponseGate()
    service.browseGate = gate
    let client = WatchLibraryClient(accountStore: store, service: service)
    _ = try await client.login(apiToken: "token")

    let request = Task { try await client.browseAudiobooks(libraryID: "books") }
    await gate.waitUntilEntered()
    try await client.logout()
    await gate.release()

    do {
      _ = try await request.value
      Issue.record("an obsolete browse response should be fenced after logout")
    } catch let error as WatchLibraryError {
      #expect(error == .staleRequest)
    } catch {
      Issue.record("unexpected browse error: \(error)")
    }
    #expect(await client.currentAccount() == nil)
  }

  @Test("Watch entity browse fences delayed filterdata after account invalidation")
  func entityBrowseDropsObsoleteFilterDataAfterLogout() async throws {
    let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings())
    let service = try FakeService()
    service.browsePages = [
      LibraryItemsPage(
        items: [
          LibraryItemSummary(
            id: "book", libraryID: "books", mediaType: "book", title: "Book", authorName: "Author",
            seriesName: nil, numAudioFiles: 1)
        ], total: 1, limit: 100, page: 0)
    ]
    service.filterDataValue = LibraryFilterData(
      authors: [LibraryAuthorSummary(id: "author", name: "Author", numBooks: 1)], series: [])
    let gate = BrowseResponseGate()
    service.filterDataGate = gate
    let client = WatchLibraryClient(accountStore: store, service: service)
    _ = try await client.login(apiToken: "token")

    let request = Task { try await client.browseAuthors(libraryID: "books") }
    await gate.waitUntilEntered()
    try await client.logout()
    await gate.release()

    do {
      _ = try await request.value
      Issue.record("an obsolete filterdata response should be fenced after logout")
    } catch let error as WatchLibraryError {
      #expect(error == .staleRequest)
    } catch {
      Issue.record("unexpected entity browse error: \(error)")
    }
  }

  @Test("Watch browse de-duplicates repeated rows across pages")
  func browseDeduplicatesPaginationResults() async throws {
    let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings())
    let service = try FakeService()
    let first = LibraryItemSummary(
      id: "first", libraryID: "books", mediaType: "book", title: "First", authorName: nil,
      seriesName: nil, numAudioFiles: 1)
    let second = LibraryItemSummary(
      id: "second", libraryID: "books", mediaType: "book", title: "Second", authorName: nil,
      seriesName: nil, numAudioFiles: 1)
    var firstPage = [first]
    firstPage.append(
      contentsOf: (0..<99).map { index in
        LibraryItemSummary(
          id: "filler-\(index)", libraryID: "books", mediaType: "book", title: "Filler \(index)",
          authorName: nil, seriesName: nil, numAudioFiles: 1)
      })
    service.browsePages = [
      LibraryItemsPage(items: firstPage, total: 101, limit: 100, page: 0),
      LibraryItemsPage(items: [first, second], total: 101, limit: 100, page: 1),
    ]
    let client = WatchLibraryClient(accountStore: store, service: service)
    _ = try await client.login(apiToken: "token")

    let firstPageResult = try await client.browseAudiobooks(libraryID: "books", limit: 100)
    let secondPageResult = try await client.browseAudiobooks(libraryID: "books", page: 1, limit: 100)
    #expect(firstPageResult.total == 101)
    #expect(firstPageResult.items.count == 100)
    #expect(secondPageResult.items.count == 1)
    #expect(secondPageResult.items.first?.id == "second")
    let combinedIDs = firstPageResult.items.map(\.id) + secondPageResult.items.map(\.id)
    #expect(Set(combinedIDs).count == 101)
    #expect(combinedIDs.contains("first"))
  }

  @Test("Watch browse rejects a short page before the advertised total")
  func browseRejectsIncompletePage() async throws {
    let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings())
    let service = try FakeService()
    service.browsePages = [
      LibraryItemsPage(
        items: [
          LibraryItemSummary(
            id: "only", libraryID: "books", mediaType: "book", title: "Only", authorName: nil,
            seriesName: nil, numAudioFiles: 1)
        ], total: 2, limit: 100, page: 0)
    ]
    let client = WatchLibraryClient(accountStore: store, service: service)
    _ = try await client.login(apiToken: "token")
    await #expect(throws: WatchLibraryError.catalogueIncomplete) {
      _ = try await client.browseAudiobooks(libraryID: "books")
    }
  }

  @Test("Watch browse confirms unknown audio metadata from expanded evidence")
  func browseUnknownAudioUsesDetailEvidence() async throws {
    let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings())
    let service = try FakeService()
    service.browsePages = [
      LibraryItemsPage(
        items: [
          LibraryItemSummary(
            id: "confirmed", libraryID: "books", mediaType: "book", title: "Confirmed", authorName: nil,
            seriesName: nil,
            numAudioFiles: nil),
          LibraryItemSummary(
            id: "unknown", libraryID: "books", mediaType: "book", title: "Unknown", authorName: nil, seriesName: nil,
            numAudioFiles: nil),
        ], total: 2, limit: 100, page: 0)
    ]
    let audio = AudioFileCatalog(
      files: [AudioFileInfo(index: 0, ino: "audio", expectedSize: 1, mimeType: "audio/mpeg", duration: 1)],
      invalidEntryCount: 0)
    service.detailValues["confirmed"] = ItemDetail(
      id: "confirmed", libraryID: "books", mediaType: "book",
      media: .book(
        BookMedia(
          title: "Confirmed", subtitle: nil, authorName: nil, narratorName: nil, seriesName: nil,
          description: nil, duration: 1, audioFiles: audio, tracks: [], chapters: [], ebookFile: nil)))
    service.detailValues["unknown"] = ItemDetail(
      id: "unknown", libraryID: "books", mediaType: "book",
      media: .book(
        BookMedia(
          title: "Unknown", subtitle: nil, authorName: nil, narratorName: nil, seriesName: nil,
          description: nil, duration: nil,
          audioFiles: AudioFileCatalog(files: [], invalidEntryCount: 0), tracks: [], chapters: [], ebookFile: nil)))
    let client = WatchLibraryClient(accountStore: store, service: service)
    _ = try await client.login(apiToken: "token")
    let page = try await client.browseAudiobooks(libraryID: "books")
    #expect(page.items.map(\.id) == ["confirmed"])
  }

  @Test("Watch browse keeps audio evidence, searches every page, and sorts the complete result")
  func browseClassificationAndCompleteSort() async throws {
    let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings())
    let service = try FakeService()
    var first = (0..<100).map {
      LibraryItemSummary(
        id: "book-\($0)", libraryID: "books", mediaType: "book", title: "Zed \($0)",
        authorName: "Author", seriesName: nil, numAudioFiles: 1)
    }
    first.append(
      LibraryItemSummary(
        id: "ebook", libraryID: "books", mediaType: "book", title: "Ebook", authorName: "Author",
        seriesName: nil, numAudioFiles: 0))
    service.browsePages = [
      LibraryItemsPage(items: first, total: 101, limit: 100, page: 0),
      LibraryItemsPage(
        items: [
          LibraryItemSummary(
            id: "book-a", libraryID: "books", mediaType: "book", title: "A First", authorName: "Author",
            seriesName: nil, numAudioFiles: 1)
        ], total: 101, limit: 100, page: 1),
    ]
    let client = WatchLibraryClient(accountStore: store, service: service)
    _ = try await client.login(apiToken: "token")
    let page = try await client.browseAudiobooks(libraryID: "books", sort: .title, limit: 200)
    #expect(service.pageCalls.map(\.page) == [0, 1])
    #expect(
      service.pageCalls.allSatisfy {
        $0.libraryID == "books" && $0.limit == 100 && $0.sort == "title" && $0.filter == nil
      })
    #expect(page.total == 101)
    #expect(page.items.first?.id == "book-a")
    #expect(page.items.contains(where: { $0.id == "ebook" }) == false)
    let prefix = try await client.browseAudiobooks(libraryID: "books", startsWith: "f")
    #expect(prefix.items.map(\.id) == ["book-a"])
    let veryLargePage = try await client.browseAudiobooks(libraryID: "books", page: Int.max)
    #expect(veryLargePage.items.isEmpty)
    #expect(veryLargePage.page == Int.max)
  }

  @Test("Watch entity counts use visible audio membership for multi-author and sequenced series")
  func browseEntityCountsUseAudioMembership() async throws {
    let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings())
    let service = try FakeService()
    service.browsePages = [
      LibraryItemsPage(
        items: [
          LibraryItemSummary(
            id: "one", libraryID: "books", mediaType: "book", title: "One", authorName: "A, B", seriesName: "Saga #2.5",
            numAudioFiles: 1),
          LibraryItemSummary(
            id: "two", libraryID: "books", mediaType: "book", title: "Two", authorName: "B", seriesName: "Saga #3",
            numAudioFiles: 1),
          LibraryItemSummary(
            id: "ebook", libraryID: "books", mediaType: "book", title: "Ebook", authorName: "A", seriesName: "Saga #1",
            numAudioFiles: 0),
        ], total: 3, limit: 100, page: 0)
    ]
    service.filterDataValue = LibraryFilterData(
      authors: [
        LibraryAuthorSummary(id: "a", name: "A", numBooks: 2), LibraryAuthorSummary(id: "b", name: "B", numBooks: 2),
      ],
      series: [LibrarySeriesSummary(id: "saga", name: "Saga")])
    let client = WatchLibraryClient(accountStore: store, service: service)
    _ = try await client.login(apiToken: "token")
    let authors = try await client.browseAuthors(libraryID: "books")
    let series = try await client.browseSeries(libraryID: "books")
    #expect(authors.items.first(where: { $0.id == "a" })?.bookCount == 1)
    #expect(authors.items.first(where: { $0.id == "b" })?.bookCount == 2)
    #expect(series.items.first?.bookCount == 2)
  }

  @Test("author and series book browse forward server sort, filter and page size")
  func browseForwardsEntityArguments() async throws {
    let service = try FakeService()
    let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings())
    let client = WatchLibraryClient(accountStore: store, service: service)
    let account = try await client.login(apiToken: "token")
    _ = try await client.browseSeriesBooks(libraryID: "books", seriesID: "saga", limit: 7)
    _ = try await client.browseAuthorBooks(libraryID: "books", authorID: "author", limit: 9)
    #expect(
      service.pageCalls == [
        FakeService.PageCall(
          account: try account.tokenAccount(), libraryID: "books", page: 0, limit: 100,
          sort: "sequence", filter: LibraryItemFilter(group: "series", value: "saga")),
        FakeService.PageCall(
          account: try account.tokenAccount(), libraryID: "books", page: 0, limit: 100,
          sort: "title", filter: LibraryItemFilter(group: "authors", value: "author")),
      ])
  }

  @Test(
    "recent episode traversal stops on short and repeated pages and enforces its row bound",
    arguments: ["short", "repeated", "bound"])
  func recentEpisodeTermination(mode: String) async throws {
    let service = try FakeService()
    func rows(_ range: Range<Int>) -> [RecentEpisode] {
      range.map { index in
        RecentEpisode(
          libraryItemID: "show", showTitle: "Show", showAuthor: nil,
          episode: PodcastEpisode(
            id: "episode-\(index)", title: "Episode \(index)",
            contentUrl: nil, mimeType: nil, duration: 10, publishedAt: nil))
      }
    }
    switch mode {
    case "short": service.recentEpisodePages = [rows(0..<100), rows(99..<102)]
    case "repeated": service.recentEpisodePages = [rows(0..<100), rows(0..<100)]
    default: service.recentEpisodePages = (0..<100).map { rows(($0 * 100)..<(($0 + 1) * 100)) }
    }
    let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: LockedMemorySettings())
    let client = WatchLibraryClient(accountStore: store, service: service)
    _ = try await client.login(apiToken: "token")
    if mode == "bound" {
      await #expect(throws: WatchLibraryError.catalogueTooLarge) {
        _ = try await client.browseRecentPodcastEpisodes(libraryID: "podcasts")
      }
      #expect(service.recentPages == Array(0..<100))
    } else {
      let result = try await client.browseRecentPodcastEpisodes(libraryID: "podcasts", limit: 200)
      #expect(result.total == (mode == "short" ? 102 : 100))
      #expect(Set(result.items.map(\.id)).count == result.items.count)
      #expect(service.recentPages == [0, 1])
    }
  }

}
