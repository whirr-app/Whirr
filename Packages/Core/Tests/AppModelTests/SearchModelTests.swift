import Foundation
import Observation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// `SearchModel` is local-first, never blank, sectioned. Local rows (`SearchReading`) render
/// immediately; the server fan-out (`SyncCoordinating.search(libraryIDs:query:limit:)`) merges in
/// place. Injected-clock debounce, minimum query length and stale-generation cancellation are
/// proved through the local-emit-then-merge path, not just the final state.
@Suite(.timeLimit(.minutes(1))) struct SearchModelTests {
  // MARK: - Debounce and minimum query length

  @MainActor
  @Test("below the minimum query length, no search is issued and the state is queryTooShort")
  func belowMinimumLengthIssuesNoSearch() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      minimumQueryLength: 3, defaults: FakeBrowseFilterDefaults())

    // Below the minimum length, `updateQuery` never schedules a debounce wait, so there is
    // nothing for the clock to advance.
    model.updateQuery("ab")

    #expect(model.state == .queryTooShort)
    #expect(sync.recordedSearches.isEmpty)
  }

  @MainActor
  @Test("clearing the query returns to idle without ever searching")
  func clearingQueryReturnsToIdle() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync,
      clock: FakeSearchClock(), defaults: FakeBrowseFilterDefaults())

    model.updateQuery("")

    #expect(model.state == .idle)
    #expect(sync.recordedSearches.isEmpty)
  }

  @MainActor
  @Test("a query only searches after the debounce clock advances")
  func searchOnlyHappensAfterDebounceElapses() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dune")
    // No real sleep, and the clock hasn't been advanced yet: nothing has been searched.
    await waitUntil { clock.pendingSleepCount == 1 }
    #expect(sync.recordedSearches.isEmpty)

    await clock.advance()
    await waitUntil { sync.recordedSearches.isEmpty == false }

    #expect(sync.recordedSearches.map(\.query) == ["dune"])
    // Account-wide, not one library (see `searchCoversEveryLibraryOnTheAccount`).
    #expect(sync.recordedSearchLibraryIDs == [nil])
  }

  // MARK: - Local-first results and server merge

  @MainActor
  @Test("local results appear without waiting for the server")
  func localResultsAppearWithoutWaitingForServer() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "book-1", title: "Local Only Book", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = NeverRespondingSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dune")
    await clock.advance()

    await waitUntil { model.state != .idle && model.state != .searching }

    guard case .results(let sections, let completeness) = model.state else {
      Issue.record("expected a populated results state, got \(model.state)")
      return
    }
    #expect(completeness == .awaitingServer)
    #expect(sections == [SearchSection(kind: .book, rows: [localRow], hasMore: false)])
  }

  @MainActor
  @Test("server results merge in place - no intermediate blank state is ever observed")
  func serverResultsMergeInPlaceWithoutBlanking() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "local-1", title: "Local Book", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())
    let recorder = StateRecorder(model)

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil { await sync.parkedCount(for: "dune") == 1 }

    // The local-only phase must already be a populated, non-blank state.
    guard case .results(let localSections, let localCompleteness) = model.state else {
      Issue.record("expected local results before the server answered, got \(model.state)")
      return
    }
    #expect(localCompleteness == .awaitingServer)
    #expect(localSections == [SearchSection(kind: .book, rows: [localRow], hasMore: false)])

    let serverItem = ItemSummary(
      serverItemId: "server-1", mediaKind: "book", title: "Server Book", author: nil,
      durationSeconds: nil)
    library.setKnownItems([serverItem])
    let match = SearchMatch(
      kind: .book, libraryId: "lib1", itemId: "server-1", matchKey: "title", matchText: "Server Book")
    await sync.resume(query: "dune", with: .success(SearchFanOutResult(matches: [match])))

    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .complete }
      return false
    }

    guard case .results(let finalSections, let finalCompleteness) = model.state else {
      Issue.record("expected merged results, got \(model.state)")
      return
    }
    #expect(finalCompleteness == .complete)
    let bookSection = finalSections.first { $0.kind == .book }
    #expect(bookSection?.rows.map(\.entityID) == ["server-1", "local-1"])

    // No state anywhere in the recorded sequence was ever idle/empty/searching once local
    // results had already appeared. The list only grew, never blanked.
    let firstResultsIndex = recorder.states.firstIndex { state in
      if case .results = state { return true }
      return false
    }
    if let firstResultsIndex {
      for state in recorder.states[firstResultsIndex...] {
        switch state {
        case .idle, .empty, .emptyUnreachable, .closeMatches, .searching:
          // `.closeMatches` replaces only an empty settle, so it cannot follow results within one
          // generation; seeing it here would be a blanking state like the others.
          Issue.record("observed a blanking state \(state) after results had already appeared")
        case .results(let sections, _):
          #expect(sections.isEmpty == false)
        case .queryTooShort:
          break
        }
      }
    } else {
      Issue.record("no results state was ever recorded")
    }
  }

  // MARK: - Stale generations and ordering

  @MainActor
  @Test("a stale server response from an older generation cannot overwrite a newer query's results")
  func staleServerResponseCannotOverwriteNewerResults() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())
    let recorder = StateRecorder(model)

    model.updateQuery("stale")
    await clock.advance()
    await waitUntil { await sync.parkedCount(for: "stale") == 1 }

    model.updateQuery("fresh")
    await clock.advance()
    await waitUntil { await sync.parkedCount(for: "fresh") == 1 }

    let freshItem = ItemSummary(
      serverItemId: "fresh-1", mediaKind: "book", title: "Fresh", author: nil, durationSeconds: nil)
    library.setKnownItems([freshItem])
    let freshMatch = SearchMatch(itemId: "fresh-1", matchKey: nil, matchText: nil)
    await sync.resume(query: "fresh", with: .success(SearchFanOutResult(matches: [freshMatch])))

    await waitUntil {
      if case .results(let sections, _) = model.state {
        return sections.first { $0.kind == .book }?.rows.map(\.entityID) == ["fresh-1"]
      }
      return false
    }

    // The stale generation's server response resolves late with different data. It must never
    // reach `state`.
    let staleItem = ItemSummary(
      serverItemId: "stale-1", mediaKind: "book", title: "Stale", author: nil, durationSeconds: nil)
    library.setKnownItems([freshItem, staleItem])
    let staleMatch = SearchMatch(itemId: "stale-1", matchKey: nil, matchText: nil)
    await sync.resume(query: "stale", with: .success(SearchFanOutResult(matches: [staleMatch])))
    await waitUntil { await sync.completedCount(for: "stale") == 1 }

    // Re-run the current query as a downstream barrier. Whichever order the stale task takes
    // after its server continuation is released, its state history must never contain stale rows.
    model.updateQuery("fresh")
    await clock.advance()
    await waitUntil { await sync.parkedCount(for: "fresh") == 1 }
    await sync.resume(query: "fresh", with: .success(SearchFanOutResult(matches: [freshMatch])))
    await waitUntil {
      if case .results(let sections, _) = model.state {
        return sections.first { $0.kind == .book }?.rows.map(\.entityID) == ["fresh-1"]
      }
      return false
    }

    guard case .results(let sections, _) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    #expect(sections.first { $0.kind == .book }?.rows.map(\.entityID) == ["fresh-1"])
    #expect(
      recorder.states.contains { state in
        guard case .results(let sections, _) = state else { return false }
        return sections.contains { $0.rows.contains { $0.entityID == "stale-1" } }
      } == false,
      "the stale generation must never appear in the observed state history")
  }

  @MainActor
  @Test("online results render in server-returned order and match reasons survive to the rows")
  func onlineResultsRenderInServerOrderWithMatchReasons() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    let itemA = ItemSummary(
      serverItemId: "a", mediaKind: "book", title: "A Title", author: nil, durationSeconds: nil)
    let itemB = ItemSummary(
      serverItemId: "b", mediaKind: "book", title: "B Title", author: nil, durationSeconds: nil)
    library.setKnownItems([itemA, itemB])
    sync.stubSearch(
      .success([
        SearchMatch(itemId: "b", matchKey: "title", matchText: "B Title"),
        SearchMatch(itemId: "a", matchKey: "title", matchText: "A Title"),
      ]))

    model.updateQuery("title")
    await clock.advance()
    await waitUntil { model.state != .idle && model.state != .searching }

    guard case .results(let sections, let completeness) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    #expect(completeness == .complete)
    let bookRows = sections.first { $0.kind == .book }?.rows ?? []
    #expect(bookRows.map(\.entityID) == ["b", "a"])
    #expect(bookRows.map { $0.matchReason?.field } == ["title", "title"])
  }

  @MainActor
  @Test("author and series hits render straight from matchText, never upserted item rows")
  func authorAndSeriesHitsRenderFromMatchText() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    sync.stubSearch(
      .success([
        SearchMatch(
          kind: .author, libraryId: "lib1", itemId: "author-1", matchKey: nil,
          matchText: "Neil Gaiman"),
        SearchMatch(
          kind: .series, libraryId: "lib1", itemId: "series-1", matchKey: nil,
          matchText: "Sandman"),
      ]))

    model.updateQuery("gaiman")
    await clock.advance()
    await waitUntil { model.state != .idle && model.state != .searching }

    guard case .results(let sections, _) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    #expect(sections.first { $0.kind == .author }?.rows.first?.title == "Neil Gaiman")
    #expect(sections.first { $0.kind == .series }?.rows.first?.title == "Sandman")
  }

  @MainActor
  @Test("a filter-rejected server-only item is absent from the settled state")
  func filterRejectedServerOnlyItemIsAbsentFromSettledState() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubItems(.success(SearchPage(rows: [], hasMore: false)))
    await searchReading.setAdmittedItemIDs([])
    library.setKnownItems([
      ItemSummary(
        serverItemId: "rejected", mediaKind: "book", title: "Rejected Book", author: nil,
        durationSeconds: nil)
    ])
    let sync = FakeSyncCoordinating()
    sync.stubSearch(
      .success([
        SearchMatch(
          kind: .book, libraryId: "lib1", itemId: "rejected", matchKey: "title",
          matchText: "Rejected Book")
      ]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updatePlayback(.inProgress)
    model.updateQuery("rejected")
    await clock.advance()
    await waitUntil { model.state == .empty }

    #expect(model.state == .empty)
  }

  @MainActor
  @Test("an unfiltered search preserves the existing merged rows")
  func unfilteredSearchPreservesExistingMergedRows() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "local", title: "Local Book", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let serverItem = ItemSummary(
      serverItemId: "server", mediaKind: "book", title: "Server Book", author: "Server Author",
      durationSeconds: nil)
    library.setKnownItems([serverItem])
    let sync = FakeSyncCoordinating()
    sync.stubSearch(
      .success([
        SearchMatch(
          kind: .book, libraryId: "lib1", itemId: "server", matchKey: "title",
          matchText: "Server Book")
      ]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateQuery("title")
    await clock.advance()
    await waitUntil {
      if case .results(_, let completeness) = model.state {
        return completeness == .complete
      }
      return false
    }

    let expectedServerRow = SearchResultRow(
      kind: .book, entityID: "server", title: "Server Book", subtitle: "Server Author",
      matchReason: SearchMatchReason(field: "title", text: "Server Book"),
      mediaCategory: .audiobook, libraryID: "lib1")
    guard case .results(let sections, _) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    #expect(
      sections == [
        SearchSection(kind: .book, rows: [expectedServerRow, localRow], hasMore: false)
      ])
  }

  @MainActor
  @Test("author and series server rows survive engaged item filters")
  func entityServerRowsSurviveEngagedItemFilters() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.setAdmittedItemIDs([])
    let sync = FakeSyncCoordinating()
    sync.stubSearch(
      .success([
        SearchMatch(
          kind: .author, libraryId: "lib1", itemId: "author-1", matchKey: nil,
          matchText: "Neil Gaiman"),
        SearchMatch(
          kind: .series, libraryId: "lib1", itemId: "series-1", matchKey: nil,
          matchText: "Sandman"),
      ]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateDownloadedOnly(true)
    model.updatePlayback(.inProgress)
    model.updateQuery("gaiman")
    await clock.advance()
    await waitUntil {
      if case .results(_, let completeness) = model.state {
        return completeness == .complete
      }
      return false
    }

    guard case .results(let sections, _) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    #expect(sections.map(\.kind) == [.author, .series])
    #expect(sections.flatMap(\.rows).map(\.title) == ["Neil Gaiman", "Sandman"])
  }

  @MainActor
  @Test("the same author reported by two libraries reaches the section as one row")
  func crossLibraryAuthorHitsCollapseIntoOneRow() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    // One fan-out, one request per library. Audiobookshelf files an author per library, so
    // a reader with separate audiobook and ebook libraries gets a distinct id back from each.
    sync.stubSearch(
      .success([
        SearchMatch(
          kind: .author, libraryId: "lib-audio", itemId: "author-audio", matchKey: nil,
          matchText: "Becky Chambers"),
        SearchMatch(
          kind: .author, libraryId: "lib-ebook", itemId: "author-ebook", matchKey: nil,
          matchText: "Becky Chambers"),
      ]))

    model.updateQuery("chambers")
    await clock.advance()
    await waitUntil { model.state != .idle && model.state != .searching }

    guard case .results(let sections, _) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    let authorRows = sections.first { $0.kind == .author }?.rows ?? []
    #expect(authorRows.map(\.title) == ["Becky Chambers"])
    #expect(authorRows.first?.entityID == "author-audio")
  }

  @MainActor
  @Test("a promoting query starts with local books, then promotes the server author section")
  func promotingQueryPromotesAuthorOnlyAfterServerAnswers() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "local-book", title: "Local Book", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateQuery("Murakami")
    await clock.advance()
    await waitUntil { await sync.parkedCount(for: "Murakami") == 1 }

    guard case .results(let localSections, let localCompleteness) = model.state else {
      Issue.record("expected local results before the server answered, got \(model.state)")
      return
    }
    #expect(localCompleteness == .awaitingServer)
    #expect(localSections.map(\.kind) == [.book])

    await sync.resume(
      query: "Murakami",
      with: .success(
        SearchFanOutResult(
          matches: [
            SearchMatch(
              kind: .author, libraryId: "lib1", itemId: "author-1", matchKey: nil,
              matchText: "Haruki Murakami")
          ])))

    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .complete }
      return false
    }

    guard case .results(let settledSections, let settledCompleteness) = model.state else {
      Issue.record("expected settled results after the server answered, got \(model.state)")
      return
    }
    #expect(settledCompleteness == .complete)
    #expect(settledSections.map(\.kind) == [.author, .book])
    #expect(settledSections.first?.rows.first?.title == "Haruki Murakami")
  }

  // MARK: - Empty and failed results

  @MainActor
  @Test("a completed query with zero local and zero server matches is the empty state")
  func zeroLocalAndZeroServerMatchesIsEmptyState() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())
    sync.stubSearch(.success([]))

    model.updateQuery("nothing")
    await clock.advance()
    await waitUntil { model.state != .idle && model.state != .searching }

    #expect(model.state == .empty)
  }

  @MainActor
  @Test("local matches supplement a successful server search that returned nothing")
  func localMatchesSupplementEmptyServerResults() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "morin-1", title: "First Book", subtitle: "Amy Morin",
      libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("Morin")
    await clock.advance()
    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .complete }
      return false
    }

    guard case .results(let sections, let completeness) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    #expect(completeness == .complete)
    #expect(sections == [SearchSection(kind: .book, rows: [localRow], hasMore: false)])
  }

  @MainActor
  @Test(
    "a server search failure leaves local results on screen annotated unreachable, not an error"
  )
  func serverFailureLeavesLocalResultsAnnotatedUnreachable() async {
    struct Offline: Error {}
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "local", title: "Local Only", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.failure(Offline()))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateQuery("local")
    await clock.advance()
    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .unreachable }
      return false
    }

    guard case .results(let sections, let completeness) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    #expect(completeness == .unreachable)
    #expect(sections == [SearchSection(kind: .book, rows: [localRow], hasMore: false)])
  }

  @MainActor
  @Test("a failed fan-out cannot promote an author absent from local rows")
  func failedFanOutLeavesPromotingQueryUnpromoted() async {
    struct Offline: Error {}
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "local-book", title: "Local Book", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.failure(Offline()))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateQuery("Murakami")
    await clock.advance()
    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .unreachable }
      return false
    }

    guard case .results(let sections, let completeness) = model.state else {
      Issue.record("expected unreachable local results, got \(model.state)")
      return
    }
    #expect(completeness == .unreachable)
    #expect(sections.map(\.kind) == [.book])
  }

  @MainActor
  @Test("a server failure with no local matches is distinguishable from a genuine empty result")
  func serverFailureWithNoLocalMatchesIsDistinctFromEmptyState() async {
    struct Offline: Error {}
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.failure(Offline()))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("nothing")
    await clock.advance()
    await waitUntil { model.state != .idle && model.state != .searching }

    let failedState = model.state

    let successfulSync = FakeSyncCoordinating()
    successfulSync.stubSearch(.success([]))
    let successfulClock = FakeSearchClock()
    let successfulModel = SearchModel(
      library: library, searchReading: FakeSearchReading(), sync: successfulSync,
      clock: successfulClock, defaults: FakeBrowseFilterDefaults())
    successfulModel.updateQuery("nothing")
    await successfulClock.advance()
    await waitUntil {
      successfulModel.state != .idle && successfulModel.state != .searching
    }

    #expect(successfulModel.state == .empty)
    #expect(failedState == .emptyUnreachable)
    #expect(failedState != successfulModel.state)
  }
}
