import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

@Suite struct AuthorSeriesBrowseModelTests {

  @MainActor
  @Test("loads and alphabetizes authors while retaining entity metadata")
  func loadsInitialPage() async {
    let author = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Fixture Author", libraryID: "lib-1",
      bookCount: 3)
    let earlierAuthor = AuthorSeriesEntity(
      kind: .author, entityID: "author-2", name: "Aardvark Author", libraryID: "lib-1")
    let reading = FakeAuthorSeriesBrowseReading(
      pages: [AuthorSeriesBrowsePage(entities: [author, earlierAuthor], hasMore: true)])
    let model = AuthorSeriesBrowseModel(kind: .author, reading: reading)

    await settle(model)

    #expect(model.state == .loaded)
    #expect(model.entities == [earlierAuthor, author])
    #expect(model.hasMore)
    #expect(
      await reading.calls
        == [FakeAuthorSeriesBrowseReading.Call(kind: .author, limit: 50, offset: 0)])
  }

  @MainActor
  @Test("a failed fetch becomes a retryable error rather than claiming the library has no authors")
  func failedPageIsAnError() async {
    let reading = FakeAuthorSeriesBrowseReading(pages: [], failure: TestFailure())
    let model = AuthorSeriesBrowseModel(kind: .author, reading: reading)

    await settle(model)

    #expect(model.state == .error)
    #expect(model.entities.isEmpty)
  }

  @MainActor
  @Test("load more appends the next entity page")
  func appendsPage() async {
    let first = AuthorSeriesEntity(
      kind: .series, entityID: "series-1", name: "First Series", libraryID: "lib-1")
    let second = AuthorSeriesEntity(
      kind: .series, entityID: "series-2", name: "Second Series", libraryID: "lib-1")
    let reading = FakeAuthorSeriesBrowseReading(
      pages: [
        AuthorSeriesBrowsePage(entities: [first], hasMore: true),
        AuthorSeriesBrowsePage(entities: [second], hasMore: false),
      ])
    let model = AuthorSeriesBrowseModel(kind: .series, reading: reading)

    await settle(model)
    await model.loadMore()

    #expect(model.entities == [first, second])
    #expect(model.hasMore == false)
    #expect(
      await reading.calls
        == [
          FakeAuthorSeriesBrowseReading.Call(kind: .series, limit: 50, offset: 0),
          FakeAuthorSeriesBrowseReading.Call(kind: .series, limit: 50, offset: 1),
        ])
  }

  @MainActor
  @Test("an empty page becomes the explicit empty state")
  func emptyPage() async {
    let reading = FakeAuthorSeriesBrowseReading(
      pages: [AuthorSeriesBrowsePage(entities: [], hasMore: false)])
    let model = AuthorSeriesBrowseModel(kind: .author, reading: reading)

    await settle(model)

    #expect(model.state == .empty)
    #expect(model.entities.isEmpty)
  }

  @MainActor
  @Test("a refresh holds the loaded rows rather than dropping the list back to its loading state")
  func refreshHoldsLoadedRows() async {
    let first = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Fixture Author", libraryID: "lib-1")
    let second = AuthorSeriesEntity(
      kind: .author, entityID: "author-2", name: "Second Author", libraryID: "lib-1")
    let reading = FakeAuthorSeriesBrowseReading(
      pages: [
        AuthorSeriesBrowsePage(entities: [first], hasMore: false),
        AuthorSeriesBrowsePage(entities: [first, second], hasMore: false),
      ])
    let model = AuthorSeriesBrowseModel(kind: .author, reading: reading)
    await settle(model)

    // Pull-to-refresh: the rows and the loaded state both survive the reload, so the pull cannot
    // wipe the list and raise a second, full-screen spinner underneath the refresh control the
    // reader is already holding open.
    await reading.gateNextFetch()
    let refresh = Task { await model.refresh() }
    await waitUntil { await reading.isParkedAtGate }

    #expect(model.state == .loaded)
    #expect(model.entities == [first])

    await reading.releaseGate()
    await refresh.value

    #expect(model.state == .loaded)
    #expect(model.entities == [first, second])
  }

  @MainActor
  @Test("a refresh that fails leaves the rows it already had on screen")
  func refreshFailureKeepsRows() async {
    let first = AuthorSeriesEntity(
      kind: .series, entityID: "series-1", name: "First Series", libraryID: "lib-1")
    let reading = FakeAuthorSeriesBrowseReading(
      pages: [AuthorSeriesBrowsePage(entities: [first], hasMore: false)],
      failFromCall: 2)
    let model = AuthorSeriesBrowseModel(kind: .series, reading: reading)
    await settle(model)

    await model.refresh()

    // Distinct from a first load that fails, which has nothing to show and must say so: rows are
    // already on screen here, and replacing them with "couldn't load" loses more than it reports.
    #expect(model.state == .loaded)
    #expect(model.entities == [first])
  }

  // MARK: - The library join

  @MainActor
  @Test("rows carry the local library's count, media kinds, and series")
  func rowsAreEnrichedFromTheLibrary() async {
    let author = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Ursula K. Le Guin", libraryID: "lib-1")
    let reading = FakeAuthorSeriesBrowseReading(
      pages: [AuthorSeriesBrowsePage(entities: [author], hasMore: false)])
    let model = AuthorSeriesBrowseModel(kind: .author, reading: reading)
    await settle(model)

    model.updateItems([
      Self.item(id: "1", title: "The Dispossessed", author: "Ursula K. Le Guin"),
      Self.item(
        id: "2", title: "The Left Hand of Darkness", author: "Ursula K. Le Guin",
        category: .ebook, series: "Hainish Cycle #4"),
    ])

    #expect(model.groups.count == 1)
    #expect(model.groups[0].bookCount == 2)
    #expect(model.groups[0].categories == [.audiobook, .ebook])
    #expect(model.groups[0].seriesNames == ["Hainish Cycle"])
  }

  /// The defect: the funnel narrowed Titles and left these two modes listing every entity.
  @MainActor
  @Test("an active filter hides entities the filter matched nothing of")
  func activeFilterHidesUnmatchedEntities() async {
    let matched = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Audiobook Only", libraryID: "lib-1")
    let unmatched = AuthorSeriesEntity(
      kind: .author, entityID: "author-2", name: "Ebook Only", libraryID: "lib-1")
    let reading = FakeAuthorSeriesBrowseReading(
      pages: [AuthorSeriesBrowsePage(entities: [matched, unmatched], hasMore: false)])
    let filters = BrowseFilters(categories: [.audiobook])
    let model = AuthorSeriesBrowseModel(
      kind: .author, reading: reading, filters: filters)
    await settle(model)

    // The filtered projection carries only the audiobook, exactly as Titles would render it.
    model.updateItems([Self.item(id: "1", title: "A Book", author: "Audiobook Only")])

    #expect(model.groups.map(\.name) == ["Audiobook Only"])
  }

  @MainActor
  @Test("a filter that matches nothing becomes filtered-empty, not an empty library")
  func filterMatchingNothingIsFilteredEmpty() async {
    let author = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Someone", libraryID: "lib-1")
    let reading = FakeAuthorSeriesBrowseReading(
      pages: [AuthorSeriesBrowsePage(entities: [author], hasMore: false)])
    let filters = BrowseFilters(downloadedOnly: true)
    let model = AuthorSeriesBrowseModel(
      kind: .author, reading: reading, filters: filters)
    await settle(model)

    model.updateItems([])

    // Telling a reader who filtered to Downloaded that they have no authors is a lie about their
    // library. The state has to name the filter as the cause so the screen can offer the way out.
    #expect(model.state == .filteredEmpty)
    #expect(model.groups.isEmpty)
  }

  @MainActor
  @Test("adopting a new filter opens no browse observation")
  func updatingFiltersOpensNoBrowseObservation() async {
    let reading = FakeAuthorSeriesBrowseReading(
      pages: [AuthorSeriesBrowsePage(entities: [], hasMore: false)])
    let library = FakeLibraryReading()
    let model = AuthorSeriesBrowseModel(kind: .series, reading: reading)
    await settle(model)

    let downloaded = BrowseFilters(downloadedOnly: true)
    model.updateFilters(downloaded)
    // Re-picking the same value must not regroup, and neither filter adoption may open a stream.
    model.updateFilters(downloaded)

    #expect(library.observedBrowseFilters.isEmpty)
  }

  @MainActor
  private static func item(
    id: String,
    title: String,
    author: String? = nil,
    category: ItemMediaCategory = .audiobook,
    series: String? = nil
  ) -> ItemSummary {
    ItemSummary(
      serverItemId: id, mediaKind: "book", title: title, author: author, durationSeconds: nil,
      category: category, seriesName: series)
  }

  @MainActor
  private func settle(_ model: AuthorSeriesBrowseModel) async {
    _ = await awaitCondition("the browse model to leave loading", until: { model.state != .loading })
  }
}

private actor FakeAuthorSeriesBrowseReading: AuthorSeriesReading {
  struct Call: Equatable {
    let kind: SearchResultKind
    let limit: Int
    let offset: Int
  }

  private var pages: [AuthorSeriesBrowsePage]
  private let failure: (any Error)?
  /// 1-based: the first call whose fetch throws, and every call after it.
  private let failFromCall: Int?
  private(set) var calls: [Call] = []

  private var isGateArmed = false
  // Stays parked on task cancellation, as the fetch it stands in for runs to completion.
  private nonisolated let gate = TestGate<Void>(
    label: "FakeAuthorSeriesBrowseReading entities", ignoresCancellation: true)

  init(
    pages: [AuthorSeriesBrowsePage], failure: (any Error)? = nil, failFromCall: Int? = nil
  ) {
    self.pages = pages
    self.failure = failure
    self.failFromCall = failFromCall
  }

  /// Parks the next fetch inside `entities` so a test can inspect the model mid-flight. Paired with
  /// `isParkedAtGate` rather than a call count: the count rises when the fetch starts, which is
  /// one suspension before the model has actually reached the state under test.
  func gateNextFetch() { isGateArmed = true }

  var isParkedAtGate: Bool { gate.parkedCount > 0 }

  func releaseGate() {
    gate.release()
  }

  func entities(
    kind: SearchResultKind, libraryID: String?, limit: Int, offset: Int
  ) async throws -> AuthorSeriesBrowsePage {
    calls.append(Call(kind: kind, limit: limit, offset: offset))
    if isGateArmed {
      isGateArmed = false
      gate.hold()
      await gate.pass()
    }
    if let failure { throw failure }
    if let failFromCall, calls.count >= failFromCall { throw TestFailure() }
    return pages.isEmpty ? AuthorSeriesBrowsePage(entities: [], hasMore: false) : pages.removeFirst()
  }

  func entity(
    kind: SearchResultKind, entityID: String, libraryID: String?
  ) async throws -> AuthorSeriesEntity? {
    nil
  }

  func items(
    kind: SearchResultKind, entityID: String, libraryID: String?, limit: Int, offset: Int
  ) async throws -> SearchPage {
    SearchPage(rows: [], hasMore: false)
  }
}

private struct TestFailure: Error {}
