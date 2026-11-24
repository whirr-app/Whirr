import Foundation
import Observation
import WatchProtocol

enum WatchBrowseResult: Equatable {
  case page(WatchBrowsePage)
  case failure(WatchBrowseError)
}

/// Owns phone catalogue paging while preserving the destination's account fence.
@MainActor
@Observable
final class WatchPhoneBrowseModel {
  typealias Loader =
    @MainActor (
      WatchBrowseScope, WatchBrowseSource?, Int, WatchBrowseEpisodeSort, WatchBrowsePlayedFilter, UInt64?
    ) async -> WatchBrowseResult

  private(set) var rows: [WatchBrowseRow] = []
  private(set) var nextPage: Int?
  private(set) var generation: UInt64?
  private(set) var phase: WatchBrowseModel.Phase = .idle
  private(set) var message: String?
  // A successful earlier page keeps Refresh available even after a later page fails.
  private(set) var loaded = false
  var isLoading: Bool { phase == .loading }
  var hasMore: Bool { nextPage != nil }

  private let scope: WatchBrowseScope
  private let source: WatchBrowseSource?
  private let accountStamp: WatchAccountStamp
  private let currentAccountStamp: @MainActor () -> WatchAccountStamp?
  private let loader: Loader
  private var sort: WatchBrowseEpisodeSort = .newest
  private var filter: WatchBrowsePlayedFilter = .inProgress
  private var requestToken = UUID()

  init(
    scope: WatchBrowseScope, source: WatchBrowseSource? = nil, accountStamp: WatchAccountStamp,
    currentAccountStamp: @escaping @MainActor () -> WatchAccountStamp?,
    loader: @escaping Loader
  ) {
    self.scope = scope
    self.source = source
    self.accountStamp = accountStamp
    self.currentAccountStamp = currentAccountStamp
    self.loader = loader
  }

  func loadMore() async {
    await load()
  }

  func retry() async {
    await load(reset: generation == nil)
  }

  func refresh(sort: WatchBrowseEpisodeSort, filter: WatchBrowsePlayedFilter) async {
    self.sort = sort
    self.filter = filter
    await refresh()
  }

  func refresh() async {
    await load(reset: true)
  }

  func accountChanged() {
    requestToken = UUID()
    rows = []
    nextPage = nil
    generation = nil
    loaded = false
    message = "The account changed. Return to Podcasts to continue."
    phase = .failed
  }

  private func inSource(_ row: WatchBrowseRow) -> Bool {
    guard let source else { return true }
    switch row {
    case .show(let show): return source.contains(show.id)
    case .episode(let episode): return source.contains(episode.show)
    }
  }

  private func load(reset: Bool = false) async {
    guard !isLoading, accountStamp == currentAccountStamp() else { return }
    let token = UUID()
    requestToken = token
    phase = .loading
    message = nil
    // An account change may invalidate the response before SwiftUI delivers onChange.
    defer { if requestToken == token && phase == .loading { phase = loaded ? .loaded : .idle } }
    if reset {
      rows = []
      nextPage = nil
      generation = nil
      loaded = false
    }
    let latest = scope == .latestEpisodes
    let shows = scope == .shows
    let result = await loader(
      scope, source, reset ? 0 : (nextPage ?? 0), latest ? .newest : sort,
      shows ? .all : filter, generation)
    guard requestToken == token, accountStamp == currentAccountStamp() else { return }
    switch result {
    case .page(let page):
      generation = page.generation
      var existing = Set(rows.map(\.id))
      // An older phone ignores the request's source and returns both; keep this list to its own.
      rows += page.rows.filter { inSource($0) && existing.insert($0.id).inserted }
      nextPage = page.nextPage
      loaded = true
      phase = .loaded
    case .failure(let error):
      if error.code == .staleGeneration {
        generation = nil
        nextPage = nil
      }
      // Protocol diagnostics may mention requests or generations; keep recovery copy local.
      switch error.code {
      case .accountUnavailable:
        message = "Open Whirr on your iPhone to connect your library."
      case .phoneUnavailable:
        message = "Open Whirr on your nearby iPhone, then retry."
      case .unsupportedScope:
        message = "Open these titles in Whirr on your iPhone."
      case .noData:
        message = "Open Podcasts in Whirr on your iPhone, then retry."
      case .retryable, .staleGeneration, .invalidRequest:
        message = "Try loading these titles again."
      }
      phase = .failed
    }
  }
}
