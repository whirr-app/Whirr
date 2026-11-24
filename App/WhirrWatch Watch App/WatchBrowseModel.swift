import Foundation
import Observation
import WatchPlayback

/// Small MainActor presentation owner for Watch catalogue destinations. The client remains an
/// account-fenced actor; this type only retains the latest result and makes loading/failure
/// visible to SwiftUI.
@MainActor
@Observable
final class WatchBrowseModel {
  enum Phase: Equatable {
    case idle
    case loading
    case loaded
    case failed
  }

  private(set) var phase: Phase = .idle
  private(set) var errorMessage: String?
  private(set) var books: [WatchLibraryItem] = []
  private(set) var authors: [WatchBrowseAuthor] = []
  private(set) var series: [WatchBrowseSeries] = []
  private(set) var seriesBooks: [WatchLibraryItem] = []
  private(set) var shows: [WatchPodcastShow] = []
  private(set) var episodes: [WatchPodcastBrowseEpisode] = []
  private(set) var hasMore = false

  /// The client's collection cache is only otherwise cleared by a manual refresh, sign-out or a
  /// server change. A fresh first page past this age drops it so a long-running session re-reads.
  static let browseCacheMaxAge: TimeInterval = 10 * 60
  private static var cacheStamp: (client: ObjectIdentifier, at: Date)?

  /// Records that `client`'s browse cache was just emptied by someone other than this model.
  static func noteCacheInvalidated(for client: WatchLibraryClient, at date: Date = Date()) {
    cacheStamp = (ObjectIdentifier(client), date)
  }

  private let clientProvider: () -> WatchLibraryClient?
  private var requestGeneration = 0
  private var requestInFlight = false
  private var retryAction: (@MainActor () async -> Void)?
  private var loadMoreAction: (@MainActor () async -> Void)?

  init(clientProvider: @escaping () -> WatchLibraryClient?) {
    self.clientProvider = clientProvider
  }

  convenience init(client: WatchLibraryClient?) {
    self.init { client }
  }

  func retry() async {
    await retryAction?()
  }

  /// Loads the next complete-result page for the current destination. Each client page is sliced
  /// only after its own all-pages traversal, so appending here never reintroduces first-page sort
  /// or search semantics.
  func loadMore() async {
    guard phase != .loading else { return }
    await loadMoreAction?()
  }

  func reset() {
    requestGeneration &+= 1
    requestInFlight = false
    retryAction = nil
    loadMoreAction = nil
    phase = .idle
    errorMessage = nil
    hasMore = false
    books = []
    authors = []
    series = []
    seriesBooks = []
    shows = []
    episodes = []
  }

  func loadAudiobooks(
    libraryID: String,
    query: String? = nil,
    sort: WatchAudiobookSort = .title,
    startsWith: String? = nil,
    page: Int = 0
  ) async {
    await performPageLoad(page: page, rows: \.books) { [clientProvider] page in
      guard let client = clientProvider() else { throw WatchLibraryError.notAuthenticated }
      return try await client.browseAudiobooks(
        libraryID: libraryID, query: query, sort: sort, startsWith: startsWith, page: page)
    }
  }

  func loadAuthors(libraryID: String, query: String? = nil, page: Int = 0) async {
    await performPageLoad(page: page, rows: \.authors) { [clientProvider] page in
      guard let client = clientProvider() else { throw WatchLibraryError.notAuthenticated }
      return try await client.browseAuthors(libraryID: libraryID, query: query, page: page)
    }
  }

  func loadSeries(libraryID: String, query: String? = nil, page: Int = 0) async {
    await performPageLoad(page: page, rows: \.series) { [clientProvider] page in
      guard let client = clientProvider() else { throw WatchLibraryError.notAuthenticated }
      return try await client.browseSeries(libraryID: libraryID, query: query, page: page)
    }
  }

  func loadSeriesBooks(libraryID: String, seriesID: String, page: Int = 0) async {
    await performPageLoad(page: page, rows: \.seriesBooks) { [clientProvider] page in
      guard let client = clientProvider() else { throw WatchLibraryError.notAuthenticated }
      return try await client.browseSeriesBooks(libraryID: libraryID, seriesID: seriesID, page: page)
    }
  }

  func loadAuthorBooks(libraryID: String, authorID: String, page: Int = 0) async {
    await performPageLoad(page: page, rows: \.books) { [clientProvider] page in
      guard let client = clientProvider() else { throw WatchLibraryError.notAuthenticated }
      return try await client.browseAuthorBooks(libraryID: libraryID, authorID: authorID, page: page)
    }
  }

  func loadPodcastShows(libraryID: String, query: String? = nil, page: Int = 0) async {
    await performPageLoad(page: page, rows: \.shows) { [clientProvider] page in
      guard let client = clientProvider() else { throw WatchLibraryError.notAuthenticated }
      return try await client.browsePodcastShows(libraryID: libraryID, query: query, page: page)
    }
  }

  func loadPodcastEpisodes(
    libraryID: String,
    showID: String,
    sort: WatchPodcastEpisodeSort = .newest,
    filter: WatchPodcastEpisodeFilter = .all,
    page: Int = 0
  ) async {
    await performPageLoad(page: page, rows: \.episodes) { [clientProvider] page in
      guard let client = clientProvider() else { throw WatchLibraryError.notAuthenticated }
      return try await client.browsePodcastEpisodes(
        libraryID: libraryID, showID: showID, sort: sort, filter: filter, page: page)
    }
  }

  func loadRecentEpisodes(
    libraryID: String, filter: WatchPodcastEpisodeFilter = .unplayed, page: Int = 0
  ) async {
    await performPageLoad(page: page, rows: \.episodes) { [clientProvider] page in
      guard let client = clientProvider() else { throw WatchLibraryError.notAuthenticated }
      return try await client.browseRecentPodcastEpisodes(libraryID: libraryID, filter: filter, page: page)
    }
  }

  /// Legacy catalogue entry point uses the same paging owner as all browse destinations.
  func loadCatalogue(
    libraryID: String,
    loader: (@Sendable (String, Int, Int) async throws -> WatchLibraryPage)? = nil
  ) async {
    guard loader != nil || clientProvider() != nil else { return }
    await performPageLoad(page: 0, rows: \.books, retryFailedPage: true) { [clientProvider] page in
      let result: WatchLibraryPage
      if let loader {
        result = try await loader(libraryID, page, 40)
      } else if let client = clientProvider() {
        result = try await client.catalogue(libraryID: libraryID, page: page, limit: 40)
      } else {
        throw WatchLibraryError.notAuthenticated
      }
      return WatchLibraryBrowsePage(
        items: result.items, total: result.total, limit: 40, page: page, hasMore: (page + 1) * 40 < result.total)
    }
  }

  private func performPageLoad<Row: Identifiable & Sendable & Equatable>(
    page: Int,
    rows: ReferenceWritableKeyPath<WatchBrowseModel, [Row]>,
    retryFailedPage: Bool = false,
    fetch: @escaping @MainActor (Int) async throws -> WatchLibraryBrowsePage<Row>
  ) async where Row.ID: Hashable {
    // Page zero replaces an older request, including a same-destination reload. A second
    // load-more tap must not replace the in-flight request or skip its page.
    guard page == 0 || !requestInFlight else { return }
    requestGeneration &+= 1
    let token = requestGeneration
    let providerID = clientProvider().map(ObjectIdentifier.init)
    requestInFlight = true
    retryAction = { [weak self] in
      await self?.performPageLoad(page: 0, rows: rows, retryFailedPage: retryFailedPage, fetch: fetch)
    }
    loadMoreAction = nil
    if !retryFailedPage { hasMore = false }
    phase = .loading
    errorMessage = nil
    defer {
      if token == requestGeneration { requestInFlight = false }
    }
    do {
      if page == 0, let client = clientProvider() { await expireStaleBrowseCache(of: client) }
      let result = try await fetch(page)
      guard token == requestGeneration, clientProvider().map(ObjectIdentifier.init) == providerID else { return }
      self[keyPath: rows] = Self.appendingUnique(page == 0 ? [] : self[keyPath: rows], result.items)
      hasMore = result.hasMore
      if result.hasMore {
        loadMoreAction = { [weak self] in
          await self?.performPageLoad(page: page + 1, rows: rows, retryFailedPage: retryFailedPage, fetch: fetch)
        }
      }
      phase = .loaded
    } catch is CancellationError {
      guard token == requestGeneration, clientProvider().map(ObjectIdentifier.init) == providerID else { return }
      phase = .idle
    } catch {
      guard token == requestGeneration, clientProvider().map(ObjectIdentifier.init) == providerID else { return }
      errorMessage = message(for: error)
      if retryFailedPage {
        loadMoreAction = { [weak self] in
          await self?.performPageLoad(page: page, rows: rows, retryFailedPage: true, fetch: fetch)
        }
      }
      phase = .failed
    }
  }

  private func expireStaleBrowseCache(of client: WatchLibraryClient, now: Date = Date()) async {
    let identity = ObjectIdentifier(client)
    if let stamp = Self.cacheStamp, stamp.client == identity,
      now.timeIntervalSince(stamp.at) < Self.browseCacheMaxAge
    {
      return
    }
    // A client seen for the first time has an empty cache, so only the stamp needs recording.
    let seenBefore = Self.cacheStamp?.client == identity
    Self.cacheStamp = (identity, now)
    if seenBefore { await client.invalidateBrowseCache() }
  }

  private func message(for error: Error) -> String {
    if let error = error as? WatchLibraryError {
      if error == .catalogueTooLarge {
        return "This catalogue is too large for the Watch. Choose a smaller library."
      }
      if error == .catalogueIncomplete {
        return "The server returned an incomplete catalogue. Try again."
      }
    }
    return "Couldn’t load this catalogue. Try again."
  }

  private static func appendingUnique<T: Identifiable>(_ existing: [T], _ next: [T]) -> [T]
  where T.ID: Hashable {
    var seen = Set(existing.map(\.id))
    return existing + next.filter { seen.insert($0.id).inserted }
  }
}
