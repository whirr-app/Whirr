import AppModel
import Foundation
import Persistence
import TestSupport
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch phone podcast browse", .serialized)
struct WatchPhoneBrowseModelTests {
  private let stamp = try! WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")

  @Test("In Progress includes started ABS and RSS episodes, excludes completed, and filters before paging")
  func inProgressEpisodes() async throws {
    let absID = try #require(PodcastSourceIdentity.abs(itemId: "show"))
    let rssID = try #require(PodcastSourceIdentity.rss(feedId: 1))
    let model = WatchPhoneBrowseModel(
      library: makeLibrary(items: [item(absID.itemId, title: "ABS", category: .podcast)]),
      nativeShows: makeShows(items: [item(rssID.itemId, title: "RSS", category: .podcast)]),
      podcasts: makePodcasts(episodes: [
        absID.itemId: [
          episode("new", title: "New", date: Date(timeIntervalSince1970: 500)),
          episode("same", title: "ABS partial", date: Date(timeIntervalSince1970: 100), played: true),
          episode("finished", title: "Finished", date: Date(timeIntervalSince1970: 400), played: true, finished: true),
          episode("marked", title: "Marked finished", date: nil, finished: true),
        ],
        rssID.itemId: [episode("same", title: "RSS partial", date: nil, played: true)],
      ]), readTimeoutNanoseconds: 1_000_000_000)
    model.bind(accountStamp: stamp)
    model.setNativeEnabled(true)
    let filter = try #require(WatchBrowsePlayedFilter(rawValue: "inProgress"))
    let first = await model.reply(
      for: try WatchBrowseRequest(
        accountStamp: stamp, scope: .latestEpisodes, pageSize: 1, played: filter))
    let page = try #require(first.page)
    #expect(page.rows.count == 1 && page.nextPage == 1)
    if case .episode(let row) = page.rows.first { #expect(row.title == "ABS partial") }
    let second = await model.reply(
      for: try WatchBrowseRequest(
        accountStamp: stamp, scope: .latestEpisodes, page: 1, pageSize: 1, played: filter, generation: page.generation))
    #expect(second.page?.rows.count == 1 && second.page?.isComplete == true)
    if case .episode(let row) = second.page?.rows.first { #expect(row.title == "RSS partial") }
    for show in [WatchBrowseShowIdentity.audiobookshelf(itemID: "show"), .nativeFeed(feedID: "1")] {
      let reply = await model.reply(
        for: try WatchBrowseRequest(
          accountStamp: stamp, scope: .episodes(show: show), played: filter, generation: page.generation))
      #expect(reply.page?.rows.count == 1)
      if case .episode(let row) = reply.page?.rows.first { #expect(row.show == show) }
    }
    let unplayed = await model.reply(
      for: try WatchBrowseRequest(
        accountStamp: stamp, scope: .latestEpisodes, played: .unplayed, generation: page.generation))
    #expect(unplayed.page?.rows.count == 1)
    if case .episode(let row) = unplayed.page?.rows.first { #expect(row.title == "New") }
    let all = await model.reply(
      for: try WatchBrowseRequest(
        accountStamp: stamp, scope: .latestEpisodes, played: .all, generation: page.generation))
    #expect(all.page?.rows.count == 5)
  }

  @Test("merges sources without identity collision and retains undated episodes")
  func mergesSources() async throws {
    let absID = try #require(PodcastSourceIdentity.abs(itemId: "same"))
    let rssID = try #require(PodcastSourceIdentity.rss(feedId: 1))
    let abs = makeLibrary(items: [item(absID.itemId, title: "ABS", category: .podcast)])
    let shows = makeShows(items: [item(rssID.itemId, title: "RSS\n show", category: .podcast)])
    let podcast = makePodcasts(episodes: [
      absID.itemId: [episode("abs-episode", title: "ABS episode", date: nil)],
      rssID.itemId: [episode("rss-episode", title: "RSS episode", date: Date())],
    ])
    let model = WatchPhoneBrowseModel(
      library: abs, nativeShows: shows, podcasts: podcast, readTimeoutNanoseconds: 1_000_000_000)
    model.bind(accountStamp: stamp)
    model.setNativeEnabled(true)
    let request = try WatchBrowseRequest(accountStamp: stamp, scope: .latestEpisodes, pageSize: 10)
    let result = await model.reply(for: request)
    guard case .accepted = result.status, let rows = result.page?.rows else {
      Issue.record("browse failed")
      return
    }
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.id)).count == 2)
    for case .episode(let row) in rows {
      #expect(row.phonePlayable)
      switch row.show {
      case .nativeFeed:
        #expect(!row.watchPlayable)
        #expect(row.showTitle == "RSS show")
      case .audiobookshelf: #expect(row.watchPlayable)
      }
    }
  }

  @Test("a source narrows shows and latest episodes before paging; no source covers both")
  func sourceFiltersBeforePaging() async throws {
    // Three ABS shows sort ahead of the RSS show, so a merged list would bury it on a later page.
    let absIDs = try ["a1", "a2", "a3"].map { try #require(PodcastSourceIdentity.abs(itemId: $0)) }
    let rssID = try #require(PodcastSourceIdentity.rss(feedId: 1))
    var episodes: [String: [PodcastEpisodeSummary]] = [:]
    for (index, id) in absIDs.enumerated() {
      episodes[id.itemId] = [
        episode("abs-\(index)", title: "ABS \(index)", date: Date(timeIntervalSince1970: 1_000 + Double(index)))
      ]
    }
    episodes[rssID.itemId] = [episode("rss", title: "RSS", date: Date(timeIntervalSince1970: 1))]
    let model = WatchPhoneBrowseModel(
      library: makeLibrary(
        items: absIDs.enumerated().map { item($1.itemId, title: "A show \($0)", category: .podcast) }),
      nativeShows: makeShows(items: [item(rssID.itemId, title: "Z show", category: .podcast)]),
      podcasts: makePodcasts(episodes: episodes), readTimeoutNanoseconds: 1_000_000_000)
    model.bind(accountStamp: stamp)
    model.setNativeEnabled(true)

    for scope in [WatchBrowseScope.shows, .latestEpisodes] {
      let followed = await model.reply(
        for: try WatchBrowseRequest(accountStamp: stamp, scope: scope, pageSize: 1, source: .nativeFeed))
      let page = try #require(followed.page)
      #expect(page.rows.count == 1 && page.isComplete)
      #expect(page.rows.allSatisfy { Self.show(of: $0).map(WatchBrowseSource.nativeFeed.contains) == true })

      var absRows: [WatchBrowseRow] = []
      var next: Int? = 0
      var generation: UInt64?
      while let pageNumber = next {
        let reply = await model.reply(
          for: try WatchBrowseRequest(
            accountStamp: stamp, scope: scope, page: pageNumber, pageSize: 1, generation: generation,
            source: .audiobookshelf))
        let absPage = try #require(reply.page)
        absRows += absPage.rows
        generation = absPage.generation
        next = absPage.nextPage
      }
      #expect(absRows.count == 3)
      #expect(absRows.allSatisfy { Self.show(of: $0).map(WatchBrowseSource.audiobookshelf.contains) == true })

      let both = await model.reply(for: try WatchBrowseRequest(accountStamp: stamp, scope: scope, pageSize: 10))
      #expect(both.page?.rows.count == 4)
    }
  }

  private static func show(of row: WatchBrowseRow) -> WatchBrowseShowIdentity? {
    switch row {
    case .show(let show): show.id
    case .episode(let episode): episode.show
    }
  }

  @Test("ABS show rows carry the show's cover revision; native shows carry none")
  func showRowsCarryCoverRevision() async throws {
    let absID = try #require(PodcastSourceIdentity.abs(itemId: "show"))
    let rssID = try #require(PodcastSourceIdentity.rss(feedId: 1))
    let absShow = ItemSummary(
      serverItemId: absID.itemId, mediaKind: "podcast", title: "ABS", author: nil, durationSeconds: nil,
      category: .podcast, serverUpdatedAt: Date(timeIntervalSince1970: 1_790_000_000.123))
    let model = WatchPhoneBrowseModel(
      library: makeLibrary(items: [absShow]),
      nativeShows: makeShows(items: [item(rssID.itemId, title: "RSS", category: .podcast)]),
      podcasts: makePodcasts(episodes: [absID.itemId: [], rssID.itemId: []]),
      readTimeoutNanoseconds: 1_000_000_000)
    model.bind(accountStamp: stamp)
    model.setNativeEnabled(true)
    let result = await model.reply(
      for: try WatchBrowseRequest(accountStamp: stamp, scope: .shows, pageSize: 10))
    var revisions: [WatchBrowseShowIdentity: String?] = [:]
    for case .show(let row) in result.page?.rows ?? [] { revisions[row.id] = row.artworkRevision }

    #expect(revisions[.audiobookshelf(itemID: "show")] == .some("1790000000123"))
    #expect(revisions[.nativeFeed(feedID: "1")] == .some(nil))
  }

  @Test("long metadata is byte-bounded across complete frozen pages")
  func longMetadataPagesRemainComplete() async throws {
    let showID = try #require(PodcastSourceIdentity.abs(itemId: "large-show"))
    let showTitle = String(repeating: "S", count: 500)
    let episodes = (0..<75).map { index in
      episode(
        "episode-\(index)", title: String(repeating: "E", count: 500), date: Date(timeIntervalSince1970: Double(index)))
    }
    let model = WatchPhoneBrowseModel(
      library: makeLibrary(items: [item(showID.itemId, title: showTitle, category: .podcast)]),
      nativeShows: makeShows(items: []),
      podcasts: makePodcasts(episodes: [showID.itemId: episodes]),
      readTimeoutNanoseconds: 1_000_000_000)
    model.bind(accountStamp: stamp)

    var page = 0
    var generation: UInt64?
    var selections: [WatchSelection] = []
    var pageCount = 0
    while pageCount < episodes.count {
      let request = try WatchBrowseRequest(
        accountStamp: stamp, scope: .latestEpisodes, page: page, pageSize: 50, generation: generation)
      let reply = await model.reply(for: request)
      #expect(reply.status == .accepted)
      let data = try WatchWireCodec.encode(reply)
      #expect(data.count <= WatchBrowseLimits.maxWireBytes)
      guard let resultPage = reply.page else { break }
      generation = resultPage.generation
      selections.append(
        contentsOf: resultPage.rows.compactMap {
          guard case .episode(let row) = $0 else { return nil }
          return row.selection
        })
      pageCount += 1
      guard let next = resultPage.nextPage else { break }
      page = next
    }
    #expect(pageCount > 1)
    #expect(selections.count == episodes.count)
    #expect(Set(selections).count == episodes.count)
  }

  @Test("per-show unplayed oldest filtering is applied before paging")
  func filtersBeforePaging() async throws {
    let showID = try #require(PodcastSourceIdentity.abs(itemId: "show"))
    let model = WatchPhoneBrowseModel(
      library: makeLibrary(items: [item(showID.itemId, title: "Show", category: .podcast)]),
      nativeShows: makeShows(items: []),
      podcasts: makePodcasts(episodes: [
        showID.itemId: [
          episode("new", title: "New", date: Date(timeIntervalSince1970: 200), played: true),
          episode("old", title: "Old", date: Date(timeIntervalSince1970: 100), played: false),
        ]
      ]), readTimeoutNanoseconds: 1_000_000_000)
    model.bind(accountStamp: stamp)
    let request = try WatchBrowseRequest(
      accountStamp: stamp, scope: .episodes(show: .audiobookshelf(itemID: showID.itemId)), pageSize: 1,
      episodeSort: .oldest, played: .unplayed)
    let reply = await model.reply(for: request)
    #expect(reply.page?.rows.count == 1)
    if case .some(.episode(let row)) = reply.page?.rows.first { #expect(row.title == "Old") }
  }

  @Test("refresh starts a new generation while prior page sessions remain readable")
  func generations() async throws {
    let showID = try #require(PodcastSourceIdentity.abs(itemId: "show"))
    let model = WatchPhoneBrowseModel(
      library: makeLibrary(items: [item(showID.itemId, title: "Show", category: .podcast)]),
      nativeShows: makeShows(items: []),
      podcasts: makePodcasts(episodes: [
        showID.itemId: [
          episode("one", title: "One", date: Date()),
          episode("two", title: "Two", date: Date(timeIntervalSince1970: 1)),
        ]
      ]), readTimeoutNanoseconds: 1_000_000_000)
    model.bind(accountStamp: stamp)
    let first = await model.reply(for: try WatchBrowseRequest(accountStamp: stamp, scope: .latestEpisodes, pageSize: 1))
    let generation = try #require(first.page?.generation)
    let oldPage = await model.reply(
      for: try WatchBrowseRequest(
        accountStamp: stamp, scope: .latestEpisodes, page: 1, pageSize: 1, generation: generation))
    #expect(oldPage.page?.page == 1)
    model.refresh()
    let refreshed = await model.reply(
      for: try WatchBrowseRequest(accountStamp: stamp, scope: .latestEpisodes, pageSize: 1))
    #expect(refreshed.page?.generation != generation)
  }

  @Test("an unavailable reader is retryable and account changes cannot publish its result")
  func unavailableAndAccountFence() async throws {
    // A library that never answers: the read starts and stays in flight.
    let library = FakeLibraryReading()
    let model = WatchPhoneBrowseModel(
      library: library, nativeShows: makeShows(items: []), podcasts: makePodcasts(episodes: [:]),
      readTimeoutNanoseconds: 5_000_000_000)
    model.bind(accountStamp: stamp)
    let request = try WatchBrowseRequest(accountStamp: stamp, scope: .shows)
    let task = Task { await model.reply(for: request) }
    #expect(await waitUntil("podcast read is in flight") { library.observedBrowseCategories.isEmpty == false })
    model.unbind()
    let reply = await task.value
    #expect(reply.error?.code == .accountUnavailable)
  }

  @Test("one missing show episode reader does not produce a partial catalogue")
  func missingShowReaderIsRetryable() async throws {
    let showID = try #require(PodcastSourceIdentity.abs(itemId: "missing-show"))
    let model = WatchPhoneBrowseModel(
      library: makeLibrary(items: [item(showID.itemId, title: "Show", category: .podcast)]),
      nativeShows: makeShows(items: []),
      // A show with no pushed episodes never answers, so its read is unavailable.
      podcasts: FakePodcastReading(),
      readTimeoutNanoseconds: 1_000_000)
    model.bind(accountStamp: stamp)
    let reply = await model.reply(for: try WatchBrowseRequest(accountStamp: stamp, scope: .shows))
    #expect(reply.status == .retryableError)
    #expect(reply.error?.retryable == true)
  }

  @Test("disabled native source does not block the ABS catalogue")
  func disabledNativeSourceIsIgnored() async throws {
    let showID = try #require(PodcastSourceIdentity.abs(itemId: "abs-only"))
    let model = WatchPhoneBrowseModel(
      library: makeLibrary(items: [item(showID.itemId, title: "ABS", category: .podcast)]),
      // Never answers: the native source is unavailable.
      nativeShows: FakeNativePodcastShowsReading(),
      podcasts: makePodcasts(episodes: [showID.itemId: [episode("episode", title: "Episode", date: nil)]]),
      readTimeoutNanoseconds: 1_000_000)
    model.bind(accountStamp: stamp)
    let reply = await model.reply(for: try WatchBrowseRequest(accountStamp: stamp, scope: .shows))
    #expect(reply.status == .accepted)
    #expect(reply.page?.rows.count == 1)
  }

  @Test("concurrent first pages share one complete load")
  func singleFlight() async throws {
    let showID = try #require(PodcastSourceIdentity.abs(itemId: "show"))
    let library = makeLibrary(items: [item(showID.itemId, title: "Show", category: .podcast)])
    let model = WatchPhoneBrowseModel(
      library: library, nativeShows: makeShows(items: []),
      podcasts: makePodcasts(episodes: [showID.itemId: [episode("episode", title: "Episode", date: Date())]]),
      readTimeoutNanoseconds: 1_000_000_000)
    model.bind(accountStamp: stamp)
    let request = try WatchBrowseRequest(accountStamp: stamp, scope: .shows)
    async let first = model.reply(for: request)
    async let second = model.reply(for: request)
    let replies = await [first, second]
    #expect(replies.allSatisfy { $0.status == .accepted })
    #expect(library.observedBrowseCategories.count == 1)
  }

  private func makeLibrary(items: [ItemSummary]) -> FakeLibraryReading {
    let library = FakeLibraryReading()
    library.stubBrowseList(items)
    return library
  }

  private func makeShows(items: [ItemSummary]) -> FakeNativePodcastShowsReading {
    FakeNativePodcastShowsReading(snapshot: NativePodcastShowsSnapshot(mode: .alphabetical, shows: items))
  }

  private func makePodcasts(episodes: [String: [PodcastEpisodeSummary]]) -> FakePodcastReading {
    let podcasts = FakePodcastReading()
    for (itemID, list) in episodes { podcasts.pushEpisodes(list, itemID: itemID) }
    return podcasts
  }

  private func item(_ id: String, title: String, category: ItemMediaCategory) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id, mediaKind: "podcast", title: title, author: nil, durationSeconds: nil, category: category)
  }

  private func episode(_ id: String, title: String, date: Date?, played: Bool = false, finished: Bool = false)
    -> PodcastEpisodeSummary
  {
    PodcastEpisodeSummary(
      id: id, title: title, subtitle: nil, episodeDescription: nil, seasonNumber: nil, episodeNumber: nil,
      episodeType: nil, durationSeconds: 120, sizeBytes: nil, publishedAt: date, progressSeconds: played ? 10 : 0,
      isPlayed: played || finished, isFinished: finished, downloadStatus: .notDownloaded, isAvailableOnServer: true)
  }
}
