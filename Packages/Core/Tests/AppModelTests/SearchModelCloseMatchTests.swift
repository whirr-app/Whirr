import Foundation
import Observation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

extension SearchModelTests {
  // MARK: - Close-match fallback

  static let closeMatchRow = SearchResultRow(
    kind: .book, entityID: "ocean", title: "The Ocean at the End of the Lane",
    subtitle: "Neil Gaiman", libraryID: "lib1")

  @MainActor
  @Test("a query that settles with nothing becomes close matches, never passing through empty")
  func emptySettleBecomesCloseMatches() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubCloseMatchItems(
      .success(SearchPage(rows: [Self.closeMatchRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())
    let recorder = StateRecorder(model)

    model.updateQuery("gaimn")
    await clock.advance()
    await waitUntil {
      if case .closeMatches = model.state { return true }
      return false
    }

    #expect(
      model.state
        == .closeMatches(
          sections: [SearchSection(kind: .book, rows: [Self.closeMatchRow], hasMore: false)],
          completeness: .complete))
    #expect(await searchReading.closeMatchQueries() == ["gaimn"])
    #expect(
      recorder.states.contains { $0 == .empty || $0 == .emptyUnreachable } == false,
      "the settle writes close matches once, never empty first")
  }

  @MainActor
  @Test("close-match episodes section beside items, and nothing is pageable")
  func closeMatchEpisodesSectionAndNeverPage() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let episodeRow = SearchResultRow(
      kind: .episode, entityID: "episode-1", parentItemID: "show-1", title: "Gaiman Interview",
      libraryID: "lib1")
    // `hasMore: true` from the reader must not survive: a close-match set is never paged.
    await searchReading.stubCloseMatchItems(
      .success(SearchPage(rows: [Self.closeMatchRow], hasMore: true)))
    await searchReading.stubCloseMatchEpisodes(
      .success(SearchPage(rows: [episodeRow], hasMore: true)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateQuery("gaimn")
    await clock.advance()
    await waitUntil {
      if case .closeMatches = model.state { return true }
      return false
    }

    guard case .closeMatches(let sections, _) = model.state else {
      Issue.record("expected close matches, got \(model.state)")
      return
    }
    #expect(Set(sections.map(\.kind)) == [.book, .episode])
    #expect(sections.allSatisfy { $0.hasMore == false })

    let itemCallsBefore = await searchReading.itemsCallCount()
    await model.loadMore(section: .book)
    #expect(await searchReading.itemsCallCount() == itemCallsBefore)
    #expect(model.state == .closeMatches(sections: sections, completeness: .complete))
  }

  @MainActor
  @Test("a fan-out that throws with nothing local becomes close matches marked unreachable")
  func thrownFanOutBecomesUnreachableCloseMatches() async {
    struct SignedOut: Error {}
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubCloseMatchItems(
      .success(SearchPage(rows: [Self.closeMatchRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.failure(SignedOut()))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())
    let recorder = StateRecorder(model)

    model.updateQuery("gaimn")
    await clock.advance()
    await waitUntil {
      if case .closeMatches = model.state { return true }
      return false
    }

    #expect(
      model.state
        == .closeMatches(
          sections: [SearchSection(kind: .book, rows: [Self.closeMatchRow], hasMore: false)],
          completeness: .unreachable))
    #expect(await searchReading.closeMatchQueries() == ["gaimn"])
    #expect(recorder.states.contains(.emptyUnreachable) == false)
  }

  /// The real offline shape: every library's request fails, but none of them throws, so the settle
  /// is `.partial` rather than `.unreachable`. Nothing is computed or shown while the fan-out is
  /// still out.
  @MainActor
  @Test("close matches wait for the fan-out, then carry its partial completeness")
  func closeMatchesWaitForFanOutAndCarryPartial() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubCloseMatchItems(
      .success(SearchPage(rows: [Self.closeMatchRow], hasMore: false)))
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateQuery("gaimn")
    await clock.advance()
    await waitUntil { await sync.parkedCount() == 1 }

    #expect(model.state == .searching)
    #expect(await searchReading.closeMatchQueries().isEmpty)

    let offline = SearchFanOutResult(
      matches: [],
      failures: [
        SearchLibraryFailure(libraryId: "lib1", message: "offline"),
        SearchLibraryFailure(libraryId: "lib2", message: "offline"),
      ])
    await sync.resume(at: 0, with: .success(offline))
    await waitUntil {
      if case .closeMatches = model.state { return true }
      return false
    }

    guard case .closeMatches(_, let completeness) = model.state else {
      Issue.record("expected close matches, got \(model.state)")
      return
    }
    #expect(completeness == .partial(failedLibraries: 2))
  }

  @MainActor
  @Test("the fallback is never asked when strict search found something")
  func strictResultsNeverAskTheFallback() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "local", title: "Neil Gaiman Stories", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    await searchReading.stubCloseMatchItems(
      .success(SearchPage(rows: [Self.closeMatchRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateQuery("gaiman")
    await clock.advance()
    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .complete }
      return false
    }

    #expect(await searchReading.closeMatchQueries().isEmpty)
  }

  /// A persisted filter's empty state names the filter and offers Clear Filters, and an
  /// approximate row inside the filter must not hide an exact match outside it.
  @MainActor
  @Test("with a filter active the fallback is not asked; clearing it rescues the query")
  func activeFilterKeepsEmptyStateUntilCleared() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubCloseMatchItems(
      .success(SearchPage(rows: [Self.closeMatchRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateDownloadedOnly(true)
    model.updateQuery("gaimn")
    await clock.advance()
    await waitUntil { model.state == .empty }

    #expect(model.state == .empty)
    #expect(await searchReading.closeMatchQueries().isEmpty)

    model.clearFilters()
    await waitUntil {
      if case .closeMatches = model.state { return true }
      return false
    }

    #expect(await searchReading.closeMatchQueries() == ["gaimn"])
  }

  /// An injected reader may ignore cancellation, so the generation re-check after the fallback's
  /// await is what keeps a superseded query's close matches off screen.
  @MainActor
  @Test("a fallback still in flight when the filters change cannot overwrite the newer settle")
  func staleFallbackCannotOverwriteNewerSettle() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubCloseMatchItems(
      .success(SearchPage(rows: [Self.closeMatchRow], hasMore: false)))
    await searchReading.parkCloseMatchItems()
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())
    let recorder = StateRecorder(model)

    model.updateQuery("gaimn")
    await clock.advance()
    await waitUntil { await searchReading.parkedCloseMatchItemsCount() == 1 }
    #expect(model.state == .searching)

    // The filter change supersedes the parked generation and, with a filter active, settles empty
    // without asking the fallback again.
    model.updateDownloadedOnly(true)
    await waitUntil { model.state == .empty }

    await searchReading.resumeCloseMatchItems()
    await waitUntil { await searchReading.closeMatchItemsReturnedCount() == 1 }

    // A further search under the same filter is the downstream barrier: once it settles, the
    // stale generation has had every chance to write.
    model.updateQuery("gaimnx")
    await clock.advance()
    await waitUntil { sync.recordedSearches.count == 3 }
    await waitUntil { model.state == .empty }

    #expect(model.state == .empty)
    #expect(await searchReading.closeMatchQueries() == ["gaimn"])
    #expect(
      recorder.states.contains { state in
        if case .closeMatches = state { return true }
        return false
      } == false,
      "the superseded generation's close matches must never reach state")
  }

  /// `recordRecentIfSubmitted` records only `.results`, so a misspelling never
  /// enters history, where selecting it could only ever reproduce a fallback.
  @MainActor
  @Test("a submitted search that settles as close matches is not recorded as recent")
  func closeMatchSettleIsNotRecordedAsRecent() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubCloseMatchItems(
      .success(SearchPage(rows: [Self.closeMatchRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let recents = FakeRecentSearchStoring()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync,
      recentSearchStore: recents, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("gaimn")
    model.submitSearch()
    await clock.advance()
    await waitUntil {
      if case .closeMatches = model.state { return true }
      return false
    }
    model.submitSearch()

    #expect(await recents.recordedQueries().isEmpty)
  }
}
