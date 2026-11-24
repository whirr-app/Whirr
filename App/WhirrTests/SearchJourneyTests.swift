import AppModel
import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

/// `SearchModel` and `NavigationModel` (both AppModel), composed as `RootModel` and
/// `LibraryShellView` do via `SearchViewPresentation.route(for:)`, carry a user through the
/// local-first flow: local rows at once, a server author row merged in, a pushed author route, and
/// the query and filter intact on return. `SearchView` and `SearchResultsList` are not
/// instantiated; this proves the contract they wrap.
@MainActor
@Suite("Search journey")
struct SearchJourneyTests {

  @Test(
    "type -> local results appear -> server merges in an author row -> tap it -> route selected -> back -> query and filter survive"
  )
  func fullSearchJourney() async throws {
    let library = FakeLibraryReading()
    let searchReading = JourneySearchReading()
    // The fan-out is parked until the test answers it, so local rows must not wait on it.
    let sync = FakeSyncCoordinating()
    sync.searchGate.hold()
    let clock = FakeSearchClock()
    clock.resumeImmediately()
    let navigation = NavigationModel(presentation: .shell, section: .search)
    let model = SearchModel(
      library: library,
      searchReading: searchReading,
      sync: sync,
      clock: clock,
      defaults: JourneyBrowseFilterDefaults())

    // A filter narrower than the default, set before anything is typed. This non-default value has
    // to survive the round trip below, not whatever the default happens to be.
    // Use a non-category filter: category narrowing hides author and series entities, while
    // downloaded-only still proves a real, non-default filter survives navigation.
    model.updateDownloadedOnly(true)
    #expect(model.filters.downloadedOnly)

    // Type a settled query. The debounce clock is immediate, but the server fan-out is parked
    // (below), so local rows can only appear this soon if the local pipeline never waits on it.
    model.updateQuery("dune")
    await waitUntil { model.query == "dune" }
    await waitUntil {
      if case .results(let sections, let completeness) = model.state {
        return completeness == .awaitingServer && sections.contains { $0.kind == .book }
      }
      return false
    }
    guard case .results(let localSections, let localCompleteness) = model.state else {
      Issue.record("expected local-only results before the server answered")
      return
    }
    #expect(localCompleteness == .awaitingServer)
    #expect(localSections.contains { $0.rows.contains { $0.title == "Dune" } })
    // The author row cannot be here yet. Only `SearchModel.resolveServerRows` produces `.author`
    // rows, and it runs once the fan-out answers.
    #expect(localSections.contains { $0.kind == .author } == false)

    // The server answers with one author hit alongside the same book. A real fan-out both confirms
    // local rows and adds ones local search cannot find on its own.
    await sync.searchGate.waitUntilParked()
    sync.searchGate.release(
      .success(
        SearchFanOutResult(
          matches: [
            SearchMatch(kind: .author, libraryId: "lib1", itemId: "author-1", matchKey: nil, matchText: "Neil Gaiman")
          ])))

    await waitUntil {
      if case .results(let sections, let completeness) = model.state {
        return completeness == .complete && sections.contains { $0.kind == .author }
      }
      return false
    }
    guard case .results(let mergedSections, let mergedCompleteness) = model.state else {
      Issue.record("expected merged results once the server answered")
      return
    }
    #expect(mergedCompleteness == .complete)
    let authorRow = try #require(
      mergedSections.first { $0.kind == .author }?.rows.first { $0.title == "Neil Gaiman" })

    // Tap the author row. This is the `SearchViewPresentation.route(for:)` then
    // `NavigationModel.navigate(to:)` hop that `SearchResultsList.entityRow` and `LibraryShellView`
    // wire in production.
    let route = try #require(SearchViewPresentation.route(for: authorRow))
    #expect(route == .author(id: "author-1", libraryID: "lib1"))
    navigation.navigate(to: route)

    #expect(navigation[pathFor: .search] == [.author(id: "author-1", libraryID: "lib1")])

    // Back.
    navigation.pop()

    #expect(navigation[pathFor: .search].isEmpty)
    #expect(model.query == "dune")
    #expect(model.filters.downloadedOnly)
  }
}

/// In-memory, so a journey never writes the real app's filter preference.
private final class JourneyBrowseFilterDefaults: BrowseFilterDefaults {
  private var values: [String: String] = [:]
  func filterString(forKey key: String) -> String? { values[key] }
  func setFilterString(_ value: String?, forKey key: String) {
    if let value { values[key] = value } else { values.removeValue(forKey: key) }
  }
}

// MARK: - Journey-local fakes

private struct JourneySearchReading: SearchReading {
  func searchItems(
    query: String, libraryIDs: [String]?, filters: BrowseFilters, limit: Int, offset: Int
  ) async throws -> SearchPage {
    SearchPage(
      rows: [
        SearchResultRow(
          kind: .book, entityID: "book-1", title: "Dune", subtitle: "Frank Herbert",
          mediaCategory: .audiobook, libraryID: "lib1")
      ],
      hasMore: false)
  }

  func searchEpisodes(
    query: String, libraryIDs: [String]?, filters: BrowseFilters, limit: Int, offset: Int
  ) async throws -> SearchPage {
    SearchPage(rows: [], hasMore: false)
  }

  /// The journey asserts navigation and filter persistence, not filter membership, so every id is
  /// admitted. The server rows it merges must survive to be navigated to.
  func admittedItemIDs(_ ids: [String], filters: BrowseFilters) async throws -> Set<String> {
    Set(ids)
  }
}
