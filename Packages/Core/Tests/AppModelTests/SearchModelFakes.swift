import Foundation
import Observation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

// MARK: - Test-only fakes local to this file (not shared via TestSupport, per repo convention:
// a fake only gets promoted to TestSupport once more than one test target needs it).

/// `SearchReading`'s fake: one stubbed page per method, resolved immediately. The local-emit
/// phase needs one resolved snapshot per settled query, not a live subscription.
actor FakeSearchReading: SearchReading {
  private var itemsResult: Result<SearchPage, Error> = .success(SearchPage(rows: [], hasMore: false))
  private var episodesResult: Result<SearchPage, Error> = .success(
    SearchPage(rows: [], hasMore: false))
  /// `nil` keeps the fake's default of admitting every id; a set lets model tests simulate SQL
  /// narrowing without duplicating persistence fixtures.
  private var admittedItemIDsValue: Set<String>?
  // Recorded for the filter-composition and paging tests.
  private var lastItemsFiltersValue: BrowseFilters?
  private var itemsQueriesValue: [String] = []
  private var itemsCallCountValue = 0

  func stubItems(_ result: Result<SearchPage, Error>) {
    itemsResult = result
  }

  func stubEpisodes(_ result: Result<SearchPage, Error>) {
    episodesResult = result
  }

  func setAdmittedItemIDs(_ ids: Set<String>?) {
    admittedItemIDsValue = ids
  }

  private var itemsLibraryIDsValue: [[String]?] = []
  private var episodesLibraryIDsValue: [[String]?] = []

  func lastItemsFilters() -> BrowseFilters? { lastItemsFiltersValue }
  func itemsQueries() -> [String] { itemsQueriesValue }
  func itemsCallCount() -> Int { itemsCallCountValue }
  /// Each call's full `libraryIDs` argument, in order. `nil` means "every library on the account".
  func itemsLibraryIDs() -> [[String]?] { itemsLibraryIDsValue }
  func episodesLibraryIDs() -> [[String]?] { episodesLibraryIDsValue }

  func searchItems(
    query: String, libraryIDs: [String]?, filters: BrowseFilters, limit: Int, offset: Int
  ) async throws -> SearchPage {
    itemsQueriesValue.append(query)
    lastItemsFiltersValue = filters
    itemsLibraryIDsValue.append(libraryIDs)
    itemsCallCountValue += 1
    return try itemsResult.get()
  }

  func searchEpisodes(
    query: String, libraryIDs: [String]?, filters: BrowseFilters, limit: Int, offset: Int
  ) async throws -> SearchPage {
    episodesLibraryIDsValue.append(libraryIDs)
    return try episodesResult.get()
  }

  func admittedItemIDs(_ ids: [String], filters: BrowseFilters) async throws -> Set<String> {
    Set(ids).intersection(admittedItemIDsValue ?? Set(ids))
  }

  // Close-match fallback. Both default to empty pages, like the protocol's own defaults, so every
  // test written before the fallback still settles `.empty`/`.emptyUnreachable`. The call counter
  // is what lets a fallback test prove it exercised the fallback rather than a silent default.
  private var closeMatchItemsResult: Result<SearchPage, Error> = .success(
    SearchPage(rows: [], hasMore: false))
  private var closeMatchEpisodesResult: Result<SearchPage, Error> = .success(
    SearchPage(rows: [], hasMore: false))
  private var closeMatchQueriesValue: [String] = []
  private var closeMatchItemsReturnedCountValue = 0
  // Stays parked on task cancellation, as the fallback it stands in for runs to completion.
  private nonisolated let closeMatchItemsGate = TestGate<Void>(
    label: "FakeSearchReading closeMatchItems", ignoresCancellation: true)

  func stubCloseMatchItems(_ result: Result<SearchPage, Error>) {
    closeMatchItemsResult = result
  }

  func stubCloseMatchEpisodes(_ result: Result<SearchPage, Error>) {
    closeMatchEpisodesResult = result
  }

  /// One entry per `closeMatchItems` call. The model always asks for items and episodes together.
  func closeMatchQueries() -> [String] { closeMatchQueriesValue }
  func closeMatchItemsReturnedCount() -> Int { closeMatchItemsReturnedCountValue }

  /// Holds every later `closeMatchItems` call until `resumeCloseMatchItems()`, so a test can change
  /// the query or filters while the fallback is in flight.
  func parkCloseMatchItems() { closeMatchItemsGate.hold() }
  func parkedCloseMatchItemsCount() -> Int { closeMatchItemsGate.parkedCount }

  func resumeCloseMatchItems() {
    closeMatchItemsGate.release()
  }

  func closeMatchItems(
    query: String, libraryIDs: [String]?, filters: BrowseFilters, limit: Int
  ) async throws -> SearchPage {
    closeMatchQueriesValue.append(query)
    await closeMatchItemsGate.pass()
    closeMatchItemsReturnedCountValue += 1
    return try closeMatchItemsResult.get()
  }

  func closeMatchEpisodes(
    query: String, libraryIDs: [String]?, filters: BrowseFilters, limit: Int
  ) async throws -> SearchPage {
    try closeMatchEpisodesResult.get()
  }
}

/// `RecentSearchStoring`'s fake: an in-memory recent list plus every recorded query in call
/// order, so a test can assert when (not just whether) `record` was called without a database.
actor FakeRecentSearchStoring: RecentSearchStoring {
  private var recordedQueriesValue: [String] = []
  private var current: [RecentSearchQuery] = []
  private var continuations: [AsyncStream<[RecentSearchQuery]>.Continuation] = []

  func recordedQueries() -> [String] { recordedQueriesValue }

  func record(query: String) async throws {
    recordedQueriesValue.append(query)
    let entry = RecentSearchQuery(
      normalizedQuery: query.lowercased(), displayQuery: query, lastUsedAt: Date())
    current.removeAll { $0.normalizedQuery == entry.normalizedQuery }
    current.insert(entry, at: 0)
    emit()
  }

  nonisolated func observeRecent() -> AsyncStream<[RecentSearchQuery]> {
    AsyncStream { continuation in
      Task { await self.addContinuation(continuation) }
    }
  }

  private func addContinuation(_ continuation: AsyncStream<[RecentSearchQuery]>.Continuation) {
    continuations.append(continuation)
    continuation.yield(current)
  }

  func clear(query: String) async throws {
    let normalized = query.lowercased()
    current.removeAll { $0.normalizedQuery == normalized }
    emit()
  }

  func clearAll() async throws {
    current = []
    emit()
  }

  private func emit() {
    for continuation in continuations { continuation.yield(current) }
  }
}

// Stays: used by SearchModelTests.swift and SearchModelFiltersRecentsPagingTests.swift (outside this
// change); needs a search gate on `FakeSyncCoordinating` plus those call-site edits.
/// A `SyncCoordinating` whose fan-out request parks on a continuation. Proves the local-emit
/// phase never waits on the server without an unbounded wall-clock sleep.
actor NeverRespondingSyncCoordinating: SyncCoordinating {
  private var nextWaiterID = 0
  private var pending: [Int: CheckedContinuation<SearchFanOutResult, Error>] = [:]

  func refresh() async {}

  func search(libraryIDs: [String]?, query: String, limit: Int) async throws -> SearchFanOutResult {
    let waiterID = nextWaiterID
    nextWaiterID += 1
    do {
      return try await withTaskCancellationHandler(
        operation: {
          try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SearchFanOutResult, Error>) in
            if Task.isCancelled {
              continuation.resume(throwing: CancellationError())
            } else {
              pending[waiterID] = continuation
            }
          }
        },
        onCancel: {
          Task { await self.cancel(waiterID: waiterID) }
        })
    } catch {
      pending.removeValue(forKey: waiterID)
      throw error
    }
  }

  private func cancel(waiterID: Int) {
    pending.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
  }
}

// Stays: used across the Search suites outside this change, and it parks searches keyed by query
// text for out-of-order resumes, which a shared gate does not express.
/// A `SyncCoordinating` whose fan-out request parks until the test explicitly resumes it,
/// keyed by query text so two generations' requests can be told apart and resumed out of order.
actor ControlledSyncCoordinating: SyncCoordinating {
  private struct Pending {
    let query: String
    let continuation: CheckedContinuation<Result<SearchFanOutResult, Error>, Never>
  }
  private var pending: [Pending] = []
  private var completedQueries: [String] = []

  func refresh() async {}

  func search(libraryIDs: [String]?, query: String, limit: Int) async throws -> SearchFanOutResult {
    let result = await withCheckedContinuation {
      (continuation: CheckedContinuation<Result<SearchFanOutResult, Error>, Never>) in
      pending.append(Pending(query: query, continuation: continuation))
    }
    completedQueries.append(query)
    return try result.get()
  }

  func parkedCount(for query: String) -> Int {
    pending.filter { $0.query == query }.count
  }

  func resume(query: String, with result: Result<SearchFanOutResult, Error>) {
    guard let index = pending.firstIndex(where: { $0.query == query }) else { return }
    let item = pending.remove(at: index)
    item.continuation.resume(returning: result)
  }

  /// The scope/filter re-query tests keep the query text identical across the before/after
  /// requests (only the scope or a filter flag changes), so they tell the two parked calls apart
  /// by arrival order. This pair is the order-based counterpart of the query-keyed helpers above.
  func parkedCount() -> Int { pending.count }

  func completedCount(for query: String? = nil) -> Int {
    if let query { return completedQueries.filter { $0 == query }.count }
    return completedQueries.count
  }

  func resume(at index: Int, with result: Result<SearchFanOutResult, Error>) {
    guard pending.indices.contains(index) else { return }
    let item = pending.remove(at: index)
    item.continuation.resume(returning: result)
  }
}

/// Records every value `model.state` takes, in order, by re-arming `withObservationTracking` on
/// every change. Turns an `@Observable` property into an assertable sequence without polling.
@MainActor
final class StateRecorder {
  private(set) var states: [SearchModel.State]
  private let model: SearchModel

  init(_ model: SearchModel) {
    self.model = model
    self.states = [model.state]
    observe()
  }

  private func observe() {
    withObservationTracking {
      _ = model.state
    } onChange: { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.states.append(self.model.state)
        self.observe()
      }
    }
  }
}
