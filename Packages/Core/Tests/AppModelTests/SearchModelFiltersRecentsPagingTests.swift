import Foundation
import Observation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

extension SearchModelTests {
  // MARK: - Why a result set is incomplete

  /// Three unrelated situations need distinct reasons: the server has not answered yet, the server
  /// answered but a library failed, and the fan-out never reached the server at all. A single
  /// "More results may appear once you're back online" fits only the last. The first is not a
  /// fault and needs no annotation.
  @MainActor
  @Test("a settled, fully successful fan-out is complete and carries nothing to annotate")
  func successfulFanOutIsComplete() async {
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "book-1", title: "Local", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: FakeLibraryReading(), searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil { await sync.parkedCount() == 1 }

    // Before the server answers: local rows, and an explicitly transient reason.
    guard case .results(_, let pending) = model.state else {
      Issue.record("expected local results while the fan-out is parked, got \(model.state)")
      return
    }
    #expect(pending == .awaitingServer)

    await sync.resume(at: 0, with: .success(SearchFanOutResult(matches: [], failures: [])))
    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .complete }
      return false
    }
  }

  @MainActor
  @Test("a library whose search failed settles partial, carrying how many failed")
  func failedLibrarySettlesPartial() async {
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "book-1", title: "Local", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: FakeLibraryReading(), searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil { await sync.parkedCount() == 1 }

    await sync.resume(
      at: 0,
      with: .success(
        SearchFanOutResult(
          matches: [],
          failures: [
            SearchLibraryFailure(libraryId: "lib-podcasts", message: "notFound"),
            SearchLibraryFailure(libraryId: "lib-ebooks", message: "notFound"),
          ])))

    await waitUntil {
      if case .results(_, let completeness) = model.state {
        return completeness == .partial(failedLibraries: 2)
      }
      return false
    }
  }

  /// The genuinely offline case.
  @MainActor
  @Test("a fan-out that never reached the server settles unreachable, not partial")
  func thrownFanOutSettlesUnreachable() async {
    struct Offline: Error {}
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "book-1", title: "Local", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.failure(Offline()))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: FakeLibraryReading(), searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .unreachable }
      return false
    }
  }

  // MARK: - Filters, recents, and paging

  @MainActor
  @Test(
    "changing a media category re-queries without clearing the field and cancels the prior task - old results never leak into the narrowed set"
  )
  func changingMediaCategoryReQueriesAndDiscardsStaleResults() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil { await sync.parkedCount() == 1 }

    model.setMediaCategory(.podcast, isOn: true)
    // The field itself must survive the scope change untouched.
    #expect(model.query == "dune")
    await waitUntil { await sync.parkedCount() == 2 }

    let staleItem = ItemSummary(
      serverItemId: "stale-1", mediaKind: "book", title: "Stale", author: nil,
      durationSeconds: nil)
    library.setKnownItems([staleItem])
    await sync.resume(
      at: 0,
      with: .success(
        SearchFanOutResult(matches: [SearchMatch(itemId: "stale-1", matchKey: nil, matchText: nil)])
      ))
    await waitUntil { await sync.completedCount() == 1 }

    if case .results(let sections, _) = model.state {
      #expect(sections.first { $0.kind == .book }?.rows.map(\.entityID) != ["stale-1"])
    }

    let freshItem = ItemSummary(
      serverItemId: "fresh-1", mediaKind: "podcast", title: "Fresh", author: nil,
      durationSeconds: nil)
    library.setKnownItems([staleItem, freshItem])
    await sync.resume(
      at: 0,
      with: .success(
        SearchFanOutResult(matches: [
          SearchMatch(kind: .podcast, itemId: "fresh-1", matchKey: nil, matchText: nil)
        ])))

    await waitUntil {
      if case .results(let sections, _) = model.state {
        return sections.first { $0.kind == .podcast }?.rows.map(\.entityID) == ["fresh-1"]
      }
      return false
    }
  }

  @MainActor
  @Test("selecting a media category removes author and series rows from the produced sections")
  func mediaCategoryHidesAuthorAndSeriesSections() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let podcastRow = SearchResultRow(
      kind: .podcast, entityID: "podcast-1", title: "The Podcast", mediaCategory: .podcast,
      libraryID: "lib1")
    let authorRow = SearchResultRow(
      kind: .author, entityID: "author-1", title: "Neil Gaiman", libraryID: "lib1")
    let seriesRow = SearchResultRow(
      kind: .series, entityID: "series-1", title: "Sandman", libraryID: "lib1")
    await searchReading.stubItems(
      .success(SearchPage(rows: [podcastRow, authorRow, seriesRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .complete }
      return false
    }

    model.setMediaCategory(.podcast, isOn: true)
    await waitUntil {
      if case .results = model.state { return true }
      return false
    }

    guard case .results(let sections, _) = model.state else {
      Issue.record("expected narrowed results, got \(model.state)")
      return
    }
    #expect(await searchReading.lastItemsFilters() == BrowseFilters(categories: [.podcast]))
    #expect(sections.map(\.kind) == [.podcast])
    #expect(sections.flatMap(\.rows).allSatisfy { $0.kind == .podcast })
  }

  /// The dimension the exclusive `SearchScope` cannot express: "audiobooks and ebooks". The
  /// Library's media toggles are additive.
  @MainActor
  @Test("media categories are additive, and dropping the last one is the unnarrowed state again")
  func mediaCategoriesAreAdditive() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.setMediaCategory(.audiobook, isOn: true)
    model.setMediaCategory(.ebook, isOn: true)
    #expect(model.filters.categories == [.audiobook, .ebook])
    #expect(model.isMediaCategorySelected(.audiobook))
    #expect(model.isMediaCategorySelected(.podcast) == false)

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil { await searchReading.lastItemsFilters() != nil }
    #expect(await searchReading.lastItemsFilters()?.categories == [.audiobook, .ebook])

    model.setMediaCategory(.audiobook, isOn: false)
    model.setMediaCategory(.ebook, isOn: false)
    // An emptied set canonicalizes to `nil`: "no kind selected" is unnarrowed, so there is one
    // representation of it and the re-query guard cannot miss a later no-op.
    #expect(model.filters.categories == nil)
    #expect(model.filters == .unfiltered)
  }

  /// Search's filter outlives the launch that set it, as the Library's does, under a key of its
  /// own so the two screens never read each other's narrowing.
  @MainActor
  @Test("the filter persists and is restored on the next launch, under Search's own key")
  func filterPersistsAcrossLaunches() async {
    let defaults = FakeBrowseFilterDefaults()
    let model = SearchModel(
      library: FakeLibraryReading(), searchReading: FakeSearchReading(),
      sync: FakeSyncCoordinating(), clock: FakeSearchClock(), defaults: defaults)

    model.setMediaCategory(.podcast, isOn: true)
    model.updatePlayback(.finished)

    let relaunched = SearchModel(
      library: FakeLibraryReading(), searchReading: FakeSearchReading(),
      sync: FakeSyncCoordinating(), clock: FakeSearchClock(), defaults: defaults)
    #expect(relaunched.filters == BrowseFilters(categories: [.podcast], playback: .finished))

    // And it is Search's key, not the Library's, that carries it.
    #expect(BrowseFilterStorage.load(.library, from: defaults) == .unfiltered)
  }

  @MainActor
  @Test("no category narrowing retains author and series sections")
  func noCategoryNarrowingRetainsAuthorAndSeriesSections() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let podcastRow = SearchResultRow(
      kind: .podcast, entityID: "podcast-1", title: "The Podcast", mediaCategory: .podcast,
      libraryID: "lib1")
    let authorRow = SearchResultRow(
      kind: .author, entityID: "author-1", title: "Neil Gaiman", libraryID: "lib1")
    let seriesRow = SearchResultRow(
      kind: .series, entityID: "series-1", title: "Sandman", libraryID: "lib1")
    await searchReading.stubItems(
      .success(SearchPage(rows: [podcastRow, authorRow, seriesRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .complete }
      return false
    }

    model.setMediaCategory(.podcast, isOn: true)
    await waitUntil {
      if case .results = model.state { return true }
      return false
    }
    guard case .results(let podcastSections, _) = model.state else {
      Issue.record("expected podcast-only results, got \(model.state)")
      return
    }
    #expect(podcastSections.map(\.kind) == [.podcast])

    model.clearFilters()
    await waitUntil {
      if case .results(let sections, let completeness) = model.state {
        return completeness == .complete && sections.map(\.kind) == [.podcast, .author, .series]
      }
      return false
    }

    guard case .results(let sections, _) = model.state else {
      Issue.record("expected unnarrowed results, got \(model.state)")
      return
    }
    #expect(sections.map(\.kind) == [.podcast, .author, .series])
  }

  @MainActor
  @Test("a media category filters author and series rows from the server fan-out merge")
  func mediaCategoryFiltersServerFanOutEntityRows() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let podcast = ItemSummary(
      serverItemId: "podcast-1", mediaKind: "podcast", title: "The Podcast", author: nil,
      durationSeconds: nil, category: .podcast)
    library.setKnownItems([podcast])
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())
    let serverMatches = [
      SearchMatch(
        kind: .podcast, libraryId: "lib1", itemId: "podcast-1", matchKey: nil, matchText: nil),
      SearchMatch(
        kind: .author, libraryId: "lib1", itemId: "author-1", matchKey: nil,
        matchText: "Neil Gaiman"),
      SearchMatch(
        kind: .series, libraryId: "lib1", itemId: "series-1", matchKey: nil, matchText: "Sandman"),
    ]

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil { await sync.parkedCount() == 1 }
    await sync.resume(
      at: 0, with: .success(SearchFanOutResult(matches: serverMatches)))
    await waitUntil {
      if case .results(let sections, let completeness) = model.state {
        return completeness == .complete && sections.map(\.kind) == [.podcast, .author, .series]
      }
      return false
    }

    model.setMediaCategory(.podcast, isOn: true)
    await waitUntil { await sync.parkedCount() == 1 }
    await sync.resume(
      at: 0, with: .success(SearchFanOutResult(matches: serverMatches)))
    await waitUntil {
      if case .results(let sections, let completeness) = model.state {
        return completeness == .complete && sections.map(\.kind) == [.podcast]
      }
      return false
    }

    guard case .results(let sections, _) = model.state else {
      Issue.record("expected narrowed server results, got \(model.state)")
      return
    }
    #expect(sections.flatMap(\.rows).allSatisfy { $0.kind == .podcast })
  }

  @MainActor
  @Test("a media filter removes the server author row before promotion")
  func mediaFilterPreventsAuthorPromotion() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "local-book", title: "Local Book", mediaCategory: .audiobook,
      libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.setMediaCategory(.audiobook, isOn: true)
    model.updateQuery("Murakami")
    await clock.advance()
    await waitUntil { await sync.parkedCount(for: "Murakami") == 1 }

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

    guard case .results(let sections, let completeness) = model.state else {
      Issue.record("expected filtered settled results, got \(model.state)")
      return
    }
    #expect(completeness == .complete)
    #expect(sections.map(\.kind) == [.book])
    #expect(sections.contains { $0.kind == .author } == false)
  }

  @MainActor
  @Test("the ebook filter rejects a PDF-sidecar audiobook after the server merge")
  func ebookFilterRejectsServerPDFSidecarAudiobook() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubItems(.success(SearchPage(rows: [], hasMore: false)))
    let pdfSidecar = ItemSummary(
      serverItemId: "audio-pdf", mediaKind: "book", title: "Audio with PDF", author: nil,
      durationSeconds: 3_600, category: .audiobook, hasReadableEbook: false)
    let mixedEPUB = ItemSummary(
      serverItemId: "audio-epub", mediaKind: "book", title: "Audio with EPUB", author: nil,
      durationSeconds: 3_600, category: .audiobook, hasReadableEbook: true)
    library.setKnownItems([pdfSidecar, mixedEPUB])
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock,
      defaults: FakeBrowseFilterDefaults())

    model.setMediaCategory(.ebook, isOn: true)
    model.updateQuery("audio")
    await clock.advance()
    await waitUntil { await sync.parkedCount() == 1 }
    await sync.resume(
      at: 0,
      with: .success(
        SearchFanOutResult(matches: [
          SearchMatch(
            kind: .book, libraryId: "lib1", itemId: "audio-pdf", matchKey: "title",
            matchText: "Audio with PDF"),
          SearchMatch(
            kind: .book, libraryId: "lib1", itemId: "audio-epub", matchKey: "title",
            matchText: "Audio with EPUB"),
        ])))

    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .complete }
      return false
    }
    guard case .results(let sections, _) = model.state else {
      Issue.record("expected filtered server results, got \(model.state)")
      return
    }
    #expect(sections.flatMap(\.rows).map(\.entityID) == ["audio-epub"])
  }

  @MainActor
  @Test("changing a filter does not expose a stale annotation while replacement results are pending")
  func changingFilterDoesNotExposeStaleCompleteness() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let initialRow = SearchResultRow(
      kind: .book, entityID: "book-1", title: "Initial", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [initialRow], hasMore: false)))
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil { await sync.parkedCount() == 1 }
    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .awaitingServer }
      return false
    }
    await sync.resume(at: 0, with: .success(SearchFanOutResult(matches: [])))
    await waitUntil {
      if case .results(_, let completeness) = model.state { return completeness == .complete }
      return false
    }

    let replacementRow = SearchResultRow(
      kind: .podcast, entityID: "podcast-1", title: "Replacement", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [replacementRow], hasMore: false)))

    model.setMediaCategory(.podcast, isOn: true)
    await waitUntil { await sync.parkedCount() == 1 }
    await waitUntil { await searchReading.itemsQueries().count == 2 }

    switch model.state {
    case .searching:
      break
    case .results(_, let completeness):
      #expect(completeness == .complete)
    default:
      Issue.record("expected the previous results or a neutral loading state, got \(model.state)")
    }
  }

  @MainActor
  @Test(
    "changing the downloaded-only filter re-queries without clearing the field and cancels the prior task"
  )
  func changingFilterReQueriesAndDiscardsStaleResults() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil { await sync.parkedCount() == 1 }

    model.updateDownloadedOnly(true)
    #expect(model.query == "dune")
    await waitUntil { await sync.parkedCount() == 2 }

    let freshItem = ItemSummary(
      serverItemId: "fresh-1", mediaKind: "book", title: "Fresh", author: nil, durationSeconds: nil)
    library.setKnownItems([freshItem])
    // Resume the stale (pre-filter-change) request first; it must never reach `state`.
    await sync.resume(
      at: 0,
      with: .success(
        SearchFanOutResult(matches: [SearchMatch(itemId: "other-1", matchKey: nil, matchText: nil)]))
    )
    await waitUntil { await sync.completedCount() == 1 }
    if case .results(let sections, _) = model.state {
      #expect(sections.first { $0.kind == .book }?.rows.map(\.entityID) != ["other-1"])
    }

    await sync.resume(
      at: 0,
      with: .success(
        SearchFanOutResult(matches: [SearchMatch(itemId: "fresh-1", matchKey: nil, matchText: nil)]))
    )
    await waitUntil {
      if case .results(let sections, _) = model.state {
        return sections.first { $0.kind == .book }?.rows.map(\.entityID) == ["fresh-1"]
      }
      return false
    }
  }

  @MainActor
  @Test(
    "the three dimensions compose and round-trip to the local search call - dropping the last category is not a special-cased empty query"
  )
  func filtersComposeAndRoundTripWithNoCategoryNarrowing() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.setMediaCategory(.audiobook, isOn: true)
    model.updateDownloadedOnly(true)
    model.updatePlayback(.unfinished)
    #expect(model.filters.categories == [.audiobook])
    #expect(model.filters.downloadedOnly == true)
    #expect(model.filters.playback == .unfinished)

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil { await searchReading.lastItemsFilters() != nil }

    let scopedFilters = await searchReading.lastItemsFilters()
    #expect(
      scopedFilters == BrowseFilters(categories: [.audiobook], downloadedOnly: true, playback: .unfinished)
    )

    // Deselecting the last category must still carry the other (still-active) dimensions through:
    // an empty category set is "no category narrowing", not "no filters at all", and it goes
    // through the exact same `BrowseFilters` construction path as every other selection.
    model.setMediaCategory(.audiobook, isOn: false)
    await waitUntil {
      if let filters = await searchReading.lastItemsFilters() { return filters.categories == nil }
      return false
    }
    let uncategorizedFilters = await searchReading.lastItemsFilters()
    #expect(
      uncategorizedFilters
        == BrowseFilters(categories: nil, downloadedOnly: true, playback: .unfinished))
  }

  @MainActor
  @Test(
    "a query that settles with results is not recorded until the user explicitly submits it"
  )
  func settledQueryIsNotRecordedWithoutExplicitSubmission() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "b1", title: "Dune", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let recents = FakeRecentSearchStoring()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync,
      recentSearchStore: recents, clock: clock, defaults: FakeBrowseFilterDefaults())

    // Three keystrokes, only the last of which ever settles.
    model.updateQuery("d")
    model.updateQuery("du")
    model.updateQuery("dun")
    await clock.advance()
    await waitUntil { await sync.parkedCount() == 1 }

    // Local-only phase: a non-empty result is already on screen, but the query hasn't settled
    // (the server hasn't answered yet), so nothing is recorded yet.
    guard case .results(_, let completeness) = model.state else {
      Issue.record("expected local-only results before the server answered, got \(String(describing: model.state))")
      return
    }
    #expect(completeness == .awaitingServer)
    #expect(await recents.recordedQueries().isEmpty)

    await sync.resume(at: 0, with: .success(SearchFanOutResult(matches: [])))
    await waitUntil {
      model.state
        == .results(
          sections: [SearchSection(kind: .book, rows: [localRow], hasMore: false)],
          completeness: .complete)
    }
    #expect(await recents.recordedQueries().isEmpty)
  }

  @MainActor
  @Test("submitting the current query records it once its non-empty results settle")
  func submittedQueryIsRecordedWhenResultsSettle() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let localRow = SearchResultRow(
      kind: .book, entityID: "b1", title: "Dune", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [localRow], hasMore: false)))
    let sync = ControlledSyncCoordinating()
    let clock = FakeSearchClock()
    let recents = FakeRecentSearchStoring()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync,
      recentSearchStore: recents, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dun")
    await clock.advance()
    await waitUntil { await sync.parkedCount() == 1 }

    model.submitSearch()
    #expect(await recents.recordedQueries().isEmpty)

    await sync.resume(at: 0, with: .success(SearchFanOutResult(matches: [])))
    await waitUntil { await recents.recordedQueries() == ["dun"] }
  }

  @MainActor
  @Test("submitting an already-settled non-empty query records it immediately and only once")
  func settledSubmittedQueryIsRecordedOnce() async {
    let searchReading = FakeSearchReading()
    await searchReading.stubItems(
      .success(
        SearchPage(
          rows: [SearchResultRow(kind: .book, entityID: "b1", title: "Dune", libraryID: "lib1")],
          hasMore: false)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let recents = FakeRecentSearchStoring()
    let model = SearchModel(
      library: FakeLibraryReading(), searchReading: searchReading, sync: sync,
      recentSearchStore: recents, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dune")
    await clock.advance()
    await waitUntil {
      if case .results(_, .complete) = model.state { return true }
      return false
    }

    model.submitSearch()
    model.submitSearch()

    await waitUntil { await recents.recordedQueries() == ["dune"] }
  }

  @MainActor
  @Test("a settled query with zero matches is never recorded as recent")
  func emptySettledQueryIsNeverRecordedAsRecent() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let recents = FakeRecentSearchStoring()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync,
      recentSearchStore: recents, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("nothing")
    await clock.advance()
    await waitUntil { model.state == SearchModel.State.empty }

    #expect(await recents.recordedQueries().isEmpty)
  }

  @MainActor
  @Test("selecting a recent query repopulates the field and re-runs the search")
  func selectingRecentRepopulatesFieldAndSearches() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    let recent = RecentSearchQuery(normalizedQuery: "dune", displayQuery: "Dune", lastUsedAt: Date())
    model.selectRecent(recent)

    #expect(model.query == "Dune")
    await waitUntil { sync.recordedSearches.isEmpty == false }
    #expect(sync.recordedSearches.map(\.query) == ["Dune"])
  }

  @MainActor
  @Test("loadMore appends the next page for a section without disturbing rows already on screen")
  func loadMoreAppendsNextPageWithoutDisturbingExistingRows() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let firstRow = SearchResultRow(kind: .book, entityID: "b1", title: "Book One", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [firstRow], hasMore: true)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("book")
    await clock.advance()
    await waitUntil {
      if case .results(let sections, _) = model.state {
        return sections.first { $0.kind == .book }?.hasMore == true
      }
      return false
    }

    let secondRow = SearchResultRow(kind: .book, entityID: "b2", title: "Book Two", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [secondRow], hasMore: false)))

    await model.loadMore(section: .book)

    guard case .results(let sections, _) = model.state else {
      Issue.record("expected results after loadMore, got \(model.state)")
      return
    }
    let bookSection = sections.first { $0.kind == .book }
    #expect(bookSection?.rows.map(\.entityID) == ["b1", "b2"])
    #expect(bookSection?.hasMore == false)
  }

  @MainActor
  @Test("loadMore is a no-op for a section whose hasMore is false")
  func loadMoreNoOpsWhenHasMoreFalse() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let firstRow = SearchResultRow(kind: .book, entityID: "b1", title: "Book One", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [firstRow], hasMore: false)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("book")
    await clock.advance()
    await waitUntil { model.state != .idle && model.state != .searching }

    let callsBefore = await searchReading.itemsCallCount()
    await model.loadMore(section: .book)
    let callsAfter = await searchReading.itemsCallCount()

    #expect(callsAfter == callsBefore)
    guard case .results(let sections, _) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    #expect(sections.first { $0.kind == .book }?.rows.map(\.entityID) == ["b1"])
  }

  @MainActor
  @Test("loadMore cannot be issued twice concurrently for the same section")
  func loadMoreCannotDoubleIssueForSameSection() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let firstRow = SearchResultRow(kind: .book, entityID: "b1", title: "Book One", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [firstRow], hasMore: true)))
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.success([]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("book")
    await clock.advance()
    await waitUntil {
      if case .results(let sections, _) = model.state {
        return sections.first { $0.kind == .book }?.hasMore == true
      }
      return false
    }

    let callsBefore = await searchReading.itemsCallCount()
    let secondRow = SearchResultRow(kind: .book, entityID: "b2", title: "Book Two", libraryID: "lib1")
    await searchReading.stubItems(.success(SearchPage(rows: [secondRow], hasMore: false)))

    async let first: Void = model.loadMore(section: .book)
    async let second: Void = model.loadMore(section: .book)
    _ = await (first, second)

    let callsAfter = await searchReading.itemsCallCount()
    #expect(callsAfter == callsBefore + 1)

    guard case .results(let sections, _) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    #expect(sections.first { $0.kind == .book }?.rows.map(\.entityID) == ["b1", "b2"])
  }

  // MARK: - Media category

  @MainActor
  @Test("server-resolved item rows carry the local summary's media category")
  func serverResolvedRowsCarryTheSummaryMediaCategory() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubItems(.success(SearchPage(rows: [], hasMore: false)))
    let ebookSummary = ItemSummary(
      serverItemId: "server-ebook", mediaKind: "book", title: "Server Ebook", author: nil,
      durationSeconds: nil, category: .ebook)
    library.setKnownItems([ebookSummary])
    let sync = FakeSyncCoordinating()
    sync.stubSearch(
      .success([
        SearchMatch(
          kind: .book, libraryId: "lib1", itemId: "server-ebook", matchKey: "title",
          matchText: "Server Ebook")
      ]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("ebook")
    await clock.advance()
    await waitUntil {
      if case .results(let sections, let completeness) = model.state {
        return completeness == .complete && sections.isEmpty == false
      }
      return false
    }

    guard case .results(let sections, _) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    #expect(sections.first { $0.kind == .book }?.rows.first?.mediaCategory == .ebook)
  }

  @MainActor
  @Test("server-resolved item rows carry the local summary's series name")
  func serverResolvedRowsCarryTheSummarySeriesName() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubItems(.success(SearchPage(rows: [], hasMore: false)))
    let summary = ItemSummary(
      serverItemId: "server-book", mediaKind: "book", title: "The Gate of the Feral Gods",
      author: "Matt Dinniman", durationSeconds: nil, seriesName: "Dungeon Crawler Carl #6")
    library.setKnownItems([summary])
    let sync = FakeSyncCoordinating()
    sync.stubSearch(
      .success([
        SearchMatch(
          kind: .book, libraryId: "lib1", itemId: "server-book", matchKey: "authors",
          matchText: "Matt Dinniman")
      ]))
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("dinniman")
    await clock.advance()
    await waitUntil {
      if case .results(let sections, let completeness) = model.state {
        return completeness == .complete && sections.isEmpty == false
      }
      return false
    }

    guard case .results(let sections, _) = model.state else {
      Issue.record("expected results, got \(model.state)")
      return
    }
    #expect(
      sections.first { $0.kind == .book }?.rows.first?.seriesName == "Dungeon Crawler Carl #6")
  }

  // MARK: - Library scope

  @MainActor
  @Test("every search covers the whole account, not one library")
  func searchCoversEveryLibraryOnTheAccount() async {
    // Search covers every library on the account. Podcasts live in their own ABS library, so a
    // search scoped to the default (book) library cannot find a podcast or its publisher at all:
    // no local row, and no fan-out request for the library the show is actually in.
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubItems(.success(SearchPage(rows: [], hasMore: false)))
    await searchReading.stubEpisodes(.success(SearchPage(rows: [], hasMore: false)))
    let sync = FakeSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("goalhanger")
    await clock.advance()
    await waitUntil { model.state == .empty }

    #expect(await searchReading.itemsLibraryIDs() == [nil])
    #expect(await searchReading.episodesLibraryIDs() == [nil])
    #expect(sync.recordedSearchLibraryIDs == [nil])
  }

  @MainActor
  @Test("paging a section stays account-wide too")
  func loadMoreCoversEveryLibraryOnTheAccount() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    await searchReading.stubItems(
      .success(
        SearchPage(
          rows: [SearchResultRow(kind: .book, entityID: "b1", title: "Alpha", libraryID: "lib1")],
          hasMore: true)))
    await searchReading.stubEpisodes(.success(SearchPage(rows: [], hasMore: false)))
    let sync = FakeSyncCoordinating()
    let clock = FakeSearchClock()
    let model = SearchModel(
      library: library, searchReading: searchReading, sync: sync, clock: clock, defaults: FakeBrowseFilterDefaults())

    model.updateQuery("alpha")
    await clock.advance()
    await waitUntil {
      if case .results = model.state { return true }
      return false
    }
    await model.loadMore(section: .book)

    // Both the first page and the paged one: a second page scoped to one library would silently
    // drop every later match from the other libraries.
    #expect(await searchReading.itemsLibraryIDs() == [nil, nil])
  }

  // MARK: - Clearing recents

  @MainActor
  @Test("clearRecent removes one recorded query; clearRecents empties the list")
  func clearRecentRemovesOneAndClearRecentsEmptiesTheList() async {
    let library = FakeLibraryReading()
    let searchReading = FakeSearchReading()
    let store = FakeRecentSearchStoring()
    try? await store.record(query: "gaiman")
    try? await store.record(query: "ocean")
    let model = SearchModel(
      library: library, searchReading: searchReading,
      sync: NeverRespondingSyncCoordinating(), recentSearchStore: store, clock: FakeSearchClock(),
      defaults: FakeBrowseFilterDefaults())
    await waitUntil { model.recents.count == 2 }

    guard let ocean = model.recents.first(where: { $0.displayQuery == "ocean" }) else {
      Issue.record("expected the recorded recents, got \(model.recents)")
      return
    }
    model.clearRecent(ocean)
    await waitUntil { model.recents.map(\.displayQuery) == ["gaiman"] }
    #expect(model.recents.map(\.displayQuery) == ["gaiman"])

    model.clearRecents()
    await waitUntil { model.recents.isEmpty }
    #expect(model.recents.isEmpty)
  }
}
