import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

/// `AuthorSeriesModel` over a single navigable entity (`.author(id)`/`.series(id)`), consuming
/// `any AuthorSeriesReading`. Follows `HomeMoreModel`'s bounded-page approach over a one-shot
/// `async throws` boundary (like `ItemDetailExtrasModel`), not a `ValueObservation` stream.
@Suite struct AuthorSeriesModelTests {

  @MainActor
  @Test("a semantic author name resolves to its durable entity destination")
  func semanticAuthorNameResolvesBeforeLoadingBooks() async {
    let entity = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Matt Dinniman", libraryID: "lib-1")
    let row = SearchResultRow(
      kind: .book, entityID: "book-1", title: "Dungeon Crawler Carl", libraryID: "lib-1")
    let reading = FakeAuthorSeriesReading(
      entity: entity, itemsResults: [SearchPage(rows: [row], hasMore: false)])

    let model = AuthorSeriesModel(
      target: .authorName(name: "matt dinniman"), reading: reading)
    await waitUntil { model.state != .loading }

    #expect(model.entity == entity)
    #expect(model.rows == [row])
    #expect(reading.itemsCalls.map(\.entityID) == ["author-1"])
  }

  @MainActor
  @Test("a narrator destination loads audiobook rows across book libraries")
  func narratorLoadsByNameAcrossLibraries() async {
    let first = SearchResultRow(
      kind: .book, entityID: "book-1", title: "One", mediaCategory: .audiobook,
      narratorName: "Jeff Hays", libraryID: "lib-a")
    let second = SearchResultRow(
      kind: .book, entityID: "book-2", title: "Two", mediaCategory: .audiobook,
      narratorName: "Jeff Hays", libraryID: "lib-b")
    let reading = FakeAuthorSeriesReading(
      entity: nil,
      itemsResultsByRequest: [
        .init(entityID: "Jeff Hays", libraryID: "lib-a", offset: 0):
          SearchPage(rows: [first], hasMore: false),
        .init(entityID: "Jeff Hays", libraryID: "lib-b", offset: 0):
          SearchPage(rows: [second], hasMore: false),
      ],
      narratorLibraryIDs: ["lib-a", "lib-b"])

    let model = AuthorSeriesModel(target: .narrator(name: "Jeff Hays"), reading: reading)
    await waitUntil { model.state != .loading }

    #expect(model.rows.map(\.entityID) == ["book-1", "book-2"])
    #expect(Set(reading.itemsCalls.compactMap(\.libraryID)) == Set(["lib-a", "lib-b"]))
  }

  @MainActor
  @Test("a destination seed exposes its name before asynchronous loading completes")
  func destinationSeedIsImmediatelyVisible() async {
    let seed = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Fixture Author", libraryID: "lib-1")
    let reading = SuspendedAuthorSeriesReading(entity: seed)
    let model = AuthorSeriesModel(
      target: .author(id: "author-1", libraryID: "lib-1"), reading: reading, seed: seed)

    #expect(model.state == .loading)
    #expect(model.entity == seed)

    await reading.waitUntilItemsRequested(count: 1)
    await reading.resolveNext(SearchPage(rows: [], hasMore: false))
  }

  @MainActor
  @Test("a destination seed paints cached books before server reconciliation")
  func destinationSeedItemsAreImmediatelyVisible() {
    let entity = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Fixture Author", libraryID: "lib-1")
    let item = ItemSummary(
      serverItemId: "book-1", mediaKind: "book", title: "Cached Book",
      author: "Fixture Author", durationSeconds: nil)
    let model = AuthorSeriesModel(
      target: .author(id: "author-1", libraryID: "lib-1"),
      reading: SuspendedAuthorSeriesReading(entity: entity),
      seed: AuthorSeriesDestinationSeed(entity: entity, items: [item]))

    #expect(model.state == .loaded)
    #expect(model.rows.map(\.entityID) == ["book-1"])
  }

  @MainActor
  @Test("visible author rows share one scoped playback-progress observation")
  func visibleRowsShareOnePlaybackProgressObservation() async {
    let rows = [
      SearchResultRow(
        kind: .book, entityID: "book-1", title: "Book One", mediaCategory: .audiobook,
        durationSeconds: 3_600, libraryID: "lib"),
      SearchResultRow(
        kind: .book, entityID: "book-2", title: "Book Two", mediaCategory: .ebook,
        libraryID: "lib"),
    ]
    let reading = FakeAuthorSeriesReading(
      entity: nil, itemsResults: [SearchPage(rows: rows, hasMore: false)])
    let library = FakeLibraryReading()
    let model = AuthorSeriesModel(
      target: .author(id: "author-1"), reading: reading, library: library)

    await waitUntil {
      model.state == .loaded && library.observedItemPlaybackProgressIDs.count == 1
    }

    #expect(library.observedItemPlaybackProgressIDs == [Set(["book-1", "book-2"])])

    library.pushItemPlaybackProgress([
      "book-1": ItemPlaybackProgress(currentTime: 900, isFinished: false),
      "book-2": ItemPlaybackProgress(currentTime: 0, ebookProgress: 0.4, isFinished: false),
    ])
    await waitUntil { model.playbackProgress(for: "book-2")?.ebookProgress == 0.4 }

    #expect(model.playbackProgress(for: "book-1")?.currentTime == 900)
    #expect(model.playbackProgress(for: "outside") == nil)
  }

  @MainActor
  @Test("loads a bounded first page for the target entity")
  func loadsBoundedFirstPage() async {
    let entity = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Fixture Author", libraryID: "lib-1")
    let row = SearchResultRow(kind: .book, entityID: "book-1", title: "Book One", libraryID: "lib-1")
    let reading = FakeAuthorSeriesReading(
      entity: entity, itemsResults: [SearchPage(rows: [row], hasMore: true)])
    let model = AuthorSeriesModel(target: .author(id: "author-1"), reading: reading)

    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded)
    #expect(model.entity == entity)
    #expect(model.rows == [row])
    #expect(model.hasMore)
    #expect(reading.itemsCalls.map(\.offset) == [0])
    #expect(reading.itemsCalls.map(\.limit) == [50])
    #expect(
      reading.itemsCalls.first?.libraryID == nil,
      "the cold route page starts in parallel before entity resolution supplies its library")
    #expect(reading.entityCalls == [.author])
  }

  @MainActor
  @Test("loadMore appends the next page rather than replacing the current rows")
  func appendsOnLoadMore() async {
    let rowA = SearchResultRow(kind: .book, entityID: "a", title: "A", libraryID: "lib")
    let rowB = SearchResultRow(kind: .book, entityID: "b", title: "B", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil,
      itemsResults: [
        SearchPage(rows: [rowA], hasMore: true),
        SearchPage(rows: [rowB], hasMore: false),
      ])
    let model = AuthorSeriesModel(target: .series(id: "series-1"), reading: reading)
    await waitUntil { model.state != .loading }

    await model.loadMore()

    #expect(model.rows == [rowA, rowB])
    #expect(model.sections.count == 1)
    #expect(model.hasMore == false)
    #expect(reading.itemsCalls.map(\.offset) == [0, 50])
  }

  @MainActor
  @Test("a series target exposes its ordered rows as one card")
  func seriesTargetUsesOneSection() async {
    let second = SearchResultRow(
      kind: .book, entityID: "second", title: "Second", seriesName: "Saga #2", libraryID: "lib")
    let first = SearchResultRow(
      kind: .book, entityID: "first", title: "First", seriesName: "Saga #1", libraryID: "lib")
    let entity = AuthorSeriesEntity(
      kind: .series, entityID: "series-1", name: "Saga", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: entity, itemsResults: [SearchPage(rows: [second, first], hasMore: false)])
    let model = AuthorSeriesModel(target: .series(id: "series-1"), reading: reading)

    await waitUntil { model.state != .loading }

    #expect(model.sections.count == 1)
    #expect(model.sections[0].displayName == "Saga")
    #expect(model.sections[0].rows.map(\.entityID) == ["first", "second"])
    #expect(model.rows == model.sections[0].rows)
  }

  @MainActor
  @Test("loadMore re-merges an author's next page into series order")
  func reordersAuthorsAcrossPages() async {
    let childrenTwo = SearchResultRow(
      kind: .book, entityID: "children-2", title: "Children of Ruin",
      seriesName: "Children of Time #2", libraryID: "lib")
    let expertOne = SearchResultRow(
      kind: .book, entityID: "expert-1", title: "The Expert System's Brother",
      seriesName: "Expert System #1", libraryID: "lib")
    let childrenOne = SearchResultRow(
      kind: .book, entityID: "children-1", title: "Children of Time",
      seriesName: "Children of Time #1", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil,
      itemsResults: [
        SearchPage(rows: [childrenTwo, expertOne], hasMore: true),
        SearchPage(rows: [childrenOne], hasMore: false),
      ])
    let model = AuthorSeriesModel(target: .author(id: "author-1"), reading: reading)
    await waitUntil { model.state != .loading }

    await model.loadMore()

    #expect(model.rows.map(\.entityID) == ["children-1", "children-2", "expert-1"])
  }

  @MainActor
  @Test("author sections are grouped and rows flatten from the same ordered source")
  func exposesAuthorSectionsAndDerivedRows() async {
    let saga = SearchResultRow(
      kind: .book, entityID: "saga-1", title: "Saga One", mediaCategory: .audiobook,
      seriesName: "Saga #1", libraryID: "lib")
    let standalone = SearchResultRow(
      kind: .book, entityID: "standalone", title: "A Standalone", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil, itemsResults: [SearchPage(rows: [standalone, saga], hasMore: false)])
    let model = AuthorSeriesModel(target: .author(id: "author-1"), reading: reading)

    await waitUntil { model.state != .loading }

    #expect(model.sections.map(\.displayName) == ["Saga", "A Standalone"])
    #expect(model.sections.map(\.itemCount) == [1, 1])
    #expect(model.sections.map(\.candidateWashSourceItemID) == ["saga-1", "standalone"])
    #expect(model.rows == model.sections.flatMap(\.rows))
  }

  @MainActor
  @Test("a section keeps its normalized ID when a later page appends to it")
  func keepsSectionIDsStableAcrossLoadMore() async {
    let later = SearchResultRow(
      kind: .book, entityID: "later", title: "Later", seriesName: "Saga #2", libraryID: "lib")
    let earlier = SearchResultRow(
      kind: .book, entityID: "earlier", title: "Earlier", seriesName: "Saga #1", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil,
      itemsResults: [
        SearchPage(rows: [later], hasMore: true),
        SearchPage(rows: [earlier], hasMore: false),
      ])
    let model = AuthorSeriesModel(target: .author(id: "author-1"), reading: reading)

    await waitUntil { model.state != .loading }
    let initialIDs = model.sections.map(\.id)

    await model.loadMore()

    #expect(model.sections.map(\.id) == initialIDs)
    #expect(model.sections[0].rows.map(\.entityID) == ["earlier", "later"])
  }

  @MainActor
  @Test("series rows are ordered numerically with unsequenced rows last")
  func ordersSeriesRowsBySequence() async {
    let two = SearchResultRow(
      kind: .book, entityID: "two", title: "Two", seriesName: "Saga #2", libraryID: "lib")
    let unsequenced = SearchResultRow(
      kind: .book, entityID: "bonus", title: "Bonus", seriesName: "Saga", libraryID: "lib")
    let fractional = SearchResultRow(
      kind: .book, entityID: "two-point-five", title: "Novella", seriesName: "Saga #2.5",
      libraryID: "lib")
    let one = SearchResultRow(
      kind: .book, entityID: "one", title: "One", seriesName: "Saga #1", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil,
      itemsResults: [SearchPage(rows: [two, unsequenced, fractional, one], hasMore: false)])
    let model = AuthorSeriesModel(target: .series(id: "series-1"), reading: reading)

    await waitUntil { model.state != .loading }

    #expect(model.rows.map(\.entityID) == ["one", "two", "two-point-five", "bonus"])
  }

  @MainActor
  @Test("loadMore is a no-op once hasMore is false")
  func loadMoreNoOpsWhenNoMorePages() async {
    let row = SearchResultRow(kind: .book, entityID: "a", title: "A", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil, itemsResults: [SearchPage(rows: [row], hasMore: false)])
    let model = AuthorSeriesModel(target: .series(id: "series-1"), reading: reading)
    await waitUntil { model.state != .loading }

    await model.loadMore()

    #expect(model.rows == [row])
    #expect(reading.itemsCalls.count == 1, "no second request should be made once hasMore is false")
  }

  @MainActor
  @Test("surfaces an empty state when the entity has no items")
  func surfacesEmptyState() async {
    let entity = AuthorSeriesEntity(
      kind: .series, entityID: "series-empty", name: "Empty Series", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: entity, itemsResults: [SearchPage(rows: [], hasMore: false)])
    let model = AuthorSeriesModel(target: .series(id: "series-empty"), reading: reading)

    await waitUntil { model.state != .loading }

    #expect(model.state == .empty)
    #expect(model.rows.isEmpty)
  }

  @MainActor
  @Test("loadMore does not issue a second request while one is already in flight")
  func loadMoreDoesNotReRequestWhileInFlight() async {
    let entity = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Fixture Author", libraryID: "lib")
    let firstRow = SearchResultRow(kind: .book, entityID: "1", title: "One", libraryID: "lib")
    let secondRow = SearchResultRow(kind: .book, entityID: "2", title: "Two", libraryID: "lib")
    let reading = SuspendedAuthorSeriesReading(entity: entity)
    let model = AuthorSeriesModel(target: .author(id: "author-1"), reading: reading)

    // Let the initial page load complete so `hasMore` is true and `loadMore` is reachable.
    await reading.waitUntilItemsRequested(count: 1)
    await reading.resolveNext(SearchPage(rows: [firstRow], hasMore: true))
    await waitUntil { model.state != .loading }

    let first = Task { await model.loadMore() }
    await reading.waitUntilItemsRequested(count: 2)
    let second = Task { await model.loadMore() }
    await second.value

    #expect(await reading.itemsCallCount == 2, "a concurrent loadMore call must not issue its own request")

    await reading.resolveNext(SearchPage(rows: [secondRow], hasMore: false))
    await first.value

    #expect(model.rows == [firstRow, secondRow])
    #expect(await reading.itemsCallCount == 2)
  }

  @MainActor
  @Test("lists the entity from every library it is known by, not just the tapped one")
  func listsEveryResolvedIdentity() async {
    let entity = AuthorSeriesEntity(
      kind: .author, name: "Alexandre Dumas",
      identities: [
        AuthorSeriesEntity.Identity(entityID: "author-audio", libraryID: "audiobooks"),
        AuthorSeriesEntity.Identity(entityID: "author-ebook", libraryID: "ebooks"),
      ])
    let audio = SearchResultRow(kind: .book, entityID: "audio-1", title: "Audio", libraryID: "audiobooks")
    let ebook = SearchResultRow(kind: .book, entityID: "ebook-1", title: "Ebook", libraryID: "ebooks")
    let reading = FakeAuthorSeriesReading(
      entity: entity,
      itemsResultsByRequest: [
        .init(entityID: "author-audio", libraryID: "audiobooks", offset: 0):
          SearchPage(rows: [audio], hasMore: false),
        .init(entityID: "author-ebook", libraryID: "ebooks", offset: 0):
          SearchPage(rows: [ebook], hasMore: false),
      ])
    let model = AuthorSeriesModel(
      target: .author(id: "author-audio", libraryID: "audiobooks"), reading: reading)

    await waitUntil { model.state != .loading }

    #expect(model.rows == [audio, ebook])
    #expect(
      Set(reading.itemsCalls.map(\.libraryID)) == Set(["audiobooks", "ebooks"]),
      "half the shelf lives in the library the route did not carry")
  }

  @MainActor
  @Test("each identity advances its own cursor without skipping its second page")
  func pagesEachIdentityIndependently() async {
    let entity = AuthorSeriesEntity(
      kind: .series, name: "Shared Series",
      identities: [
        AuthorSeriesEntity.Identity(entityID: "series-audio", libraryID: "audiobooks"),
        AuthorSeriesEntity.Identity(entityID: "series-ebook", libraryID: "ebooks"),
      ])
    let audioFirst = (0..<50).map { index in
      SearchResultRow(
        kind: .book, entityID: "audio-\(index)", title: "Audio \(index)", libraryID: "audiobooks")
    }
    let ebookFirst = (0..<50).map { index in
      SearchResultRow(
        kind: .book, entityID: "ebook-\(index)", title: "Ebook \(index)", libraryID: "ebooks")
    }
    let audioSecond = (50..<100).map { index in
      SearchResultRow(
        kind: .book, entityID: "audio-\(index)", title: "Audio \(index)", libraryID: "audiobooks")
    }
    let ebookSecond = (50..<100).map { index in
      SearchResultRow(
        kind: .book, entityID: "ebook-\(index)", title: "Ebook \(index)", libraryID: "ebooks")
    }
    let reading = FakeAuthorSeriesReading(
      entity: entity,
      itemsResultsByRequest: [
        .init(entityID: "series-audio", libraryID: "audiobooks", offset: 0):
          SearchPage(rows: audioFirst, hasMore: true),
        .init(entityID: "series-ebook", libraryID: "ebooks", offset: 0):
          SearchPage(rows: ebookFirst, hasMore: true),
        .init(entityID: "series-audio", libraryID: "audiobooks", offset: 50):
          SearchPage(rows: audioSecond, hasMore: false),
        .init(entityID: "series-ebook", libraryID: "ebooks", offset: 50):
          SearchPage(rows: ebookSecond, hasMore: false),
      ])
    let model = AuthorSeriesModel(
      target: .series(id: "series-audio", libraryID: "audiobooks"), reading: reading)

    await waitUntil { model.state != .loading }
    await model.loadMore()

    #expect(
      reading.itemsCalls.filter { $0.entityID == "series-audio" }.map(\.offset).sorted()
        == [0, 50])
    #expect(
      reading.itemsCalls.filter { $0.entityID == "series-ebook" }.map(\.offset).sorted()
        == [0, 50])
    #expect(
      model.rows.map(\.entityID)
        == (0..<100).map { "audio-\($0)" } + (0..<100).map { "ebook-\($0)" })
  }

  @MainActor
  @Test("an exhausted identity is not requested while another identity continues")
  func doesNotRequestAnExhaustedIdentityAgain() async {
    let entity = AuthorSeriesEntity(
      kind: .series, name: "Shared Series",
      identities: [
        AuthorSeriesEntity.Identity(entityID: "series-a", libraryID: "a"),
        AuthorSeriesEntity.Identity(entityID: "series-b", libraryID: "b"),
      ])
    let reading = FakeAuthorSeriesReading(
      entity: entity,
      itemsResultsByRequest: [
        .init(entityID: "series-a", libraryID: "a", offset: 0):
          SearchPage(rows: [Self.row(id: "a-0", libraryID: "a")], hasMore: false),
        .init(entityID: "series-b", libraryID: "b", offset: 0):
          SearchPage(rows: [Self.row(id: "b-0", libraryID: "b")], hasMore: true),
        .init(entityID: "series-b", libraryID: "b", offset: 50):
          SearchPage(rows: [Self.row(id: "b-50", libraryID: "b")], hasMore: false),
      ])
    let model = AuthorSeriesModel(
      target: .series(id: "series-a", libraryID: "a"), reading: reading)

    await waitUntil { model.state != .loading }
    await model.loadMore()
    await model.loadMore()

    #expect(
      reading.itemsCalls.filter { $0.entityID == "series-a" }.map(\.offset) == [0])
    #expect(
      reading.itemsCalls.filter { $0.entityID == "series-b" }.map(\.offset) == [0, 50])
    #expect(model.rows.map(\.entityID) == ["a-0", "b-0", "b-50"])
  }

  @MainActor
  @Test("identity completion order does not change merged row order")
  func mergesInIdentityOrderWhenResponsesCompleteOutOfOrder() async {
    let entity = AuthorSeriesEntity(
      kind: .series, name: "Shared Series",
      identities: [
        AuthorSeriesEntity.Identity(entityID: "series-a", libraryID: "a"),
        AuthorSeriesEntity.Identity(entityID: "series-b", libraryID: "b"),
        AuthorSeriesEntity.Identity(entityID: "series-c", libraryID: "c"),
      ])
    // The route's own page is fetched first, alone; the other identities are fetched together.
    // Holding b until c is answered makes that group complete in reverse identity order.
    let reading = FakeAuthorSeriesReading(
      entity: entity,
      itemsResultsByRequest: [
        .init(entityID: "series-a", libraryID: "a", offset: 0):
          SearchPage(rows: [Self.row(id: "a-0", libraryID: "a")], hasMore: false),
        .init(entityID: "series-b", libraryID: "b", offset: 0):
          SearchPage(rows: [Self.row(id: "b-0", libraryID: "b")], hasMore: false),
        .init(entityID: "series-c", libraryID: "c", offset: 0):
          SearchPage(rows: [Self.row(id: "c-0", libraryID: "c")], hasMore: false),
      ],
      heldUntilAnswered: [
        .init(entityID: "series-b", libraryID: "b", offset: 0):
          .init(entityID: "series-c", libraryID: "c", offset: 0)
      ])
    let model = AuthorSeriesModel(
      target: .series(id: "series-a", libraryID: "a"), reading: reading)

    await waitUntil { model.state != .loading }

    #expect(model.rows.map(\.entityID) == ["a-0", "b-0", "c-0"])
  }

  @MainActor
  @Test("duplicate server ids collapse while distinct ids remain visible")
  func deduplicatesServerIdsAfterIdentityMerge() async {
    let entity = AuthorSeriesEntity(
      kind: .author, name: "Shared Author",
      identities: [
        AuthorSeriesEntity.Identity(entityID: "author-a", libraryID: "a"),
        AuthorSeriesEntity.Identity(entityID: "author-b", libraryID: "b"),
      ])
    let reading = FakeAuthorSeriesReading(
      entity: entity,
      itemsResultsByRequest: [
        .init(entityID: "author-a", libraryID: "a", offset: 0): SearchPage(
          rows: [
            Self.row(id: "duplicate", title: "First copy", libraryID: "a"),
            Self.row(id: "distinct-a", libraryID: "a"),
          ], hasMore: false),
        .init(entityID: "author-b", libraryID: "b", offset: 0): SearchPage(
          rows: [
            Self.row(id: "duplicate", title: "Second copy", libraryID: "b"),
            Self.row(id: "distinct-b", libraryID: "b"),
          ], hasMore: false),
      ])
    let model = AuthorSeriesModel(
      target: .author(id: "author-a", libraryID: "a"), reading: reading)

    await waitUntil { model.state != .loading }

    #expect(model.rows.map(\.entityID) == ["distinct-a", "distinct-b", "duplicate"])
    #expect(model.rows.last?.title == "First copy")
  }

  @MainActor
  @Test("one failing identity does not blank another identity's rows")
  func preservesRowsWhenAnIdentityFails() async {
    let entity = AuthorSeriesEntity(
      kind: .author, name: "Shared Author",
      identities: [
        AuthorSeriesEntity.Identity(entityID: "author-a", libraryID: "a"),
        AuthorSeriesEntity.Identity(entityID: "author-b", libraryID: "b"),
      ])
    let failingKey = FakeAuthorSeriesReading.ItemsKey(
      entityID: "author-a", libraryID: "a", offset: 0)
    let reading = FakeAuthorSeriesReading(
      entity: entity,
      itemsResultsByRequest: [
        .init(entityID: "author-b", libraryID: "b", offset: 0):
          SearchPage(rows: [Self.row(id: "b-0", libraryID: "b")], hasMore: false)
      ],
      failingRequests: [failingKey])
    let model = AuthorSeriesModel(
      target: .author(id: "author-a", libraryID: "a"), reading: reading)

    await waitUntil { model.state != .loading }

    #expect(model.rows.map(\.entityID) == ["b-0"])
    #expect(model.state == .loaded)
  }

  @MainActor
  @Test("one empty identity does not blank another identity's rows")
  func preservesRowsWhenAnIdentityIsEmpty() async {
    let entity = AuthorSeriesEntity(
      kind: .author, name: "Shared Author",
      identities: [
        AuthorSeriesEntity.Identity(entityID: "author-a", libraryID: "a"),
        AuthorSeriesEntity.Identity(entityID: "author-b", libraryID: "b"),
      ])
    let reading = FakeAuthorSeriesReading(
      entity: entity,
      itemsResultsByRequest: [
        .init(entityID: "author-a", libraryID: "a", offset: 0):
          SearchPage(rows: [], hasMore: false),
        .init(entityID: "author-b", libraryID: "b", offset: 0):
          SearchPage(rows: [Self.row(id: "b-0", libraryID: "b")], hasMore: false),
      ])
    let model = AuthorSeriesModel(
      target: .author(id: "author-a", libraryID: "a"), reading: reading)

    await waitUntil { model.state != .loading }

    #expect(model.rows.map(\.entityID) == ["b-0"])
    #expect(model.state == .loaded)
  }

  @MainActor
  @Test("a failed continuation leaves the identity retryable at the same offset")
  func retriesTheSamePageAfterAFailedContinuation() async {
    let reading = FakeAuthorSeriesReading(
      entity: nil,
      itemsResultsByRequest: [
        .init(entityID: "author-1", libraryID: nil, offset: 0):
          SearchPage(rows: [Self.row(id: "a-0", libraryID: "lib")], hasMore: true)
      ],
      failingRequests: [.init(entityID: "author-1", libraryID: nil, offset: 50)])
    let model = AuthorSeriesModel(target: .author(id: "author-1"), reading: reading)

    await waitUntil { model.state != .loading }
    await model.loadMore()

    #expect(
      model.hasMore,
      "a dropped request is not an exhausted shelf; clearing hasMore removes the only trigger")
    #expect(model.rows.map(\.entityID) == ["a-0"])

    await model.loadMore()

    #expect(reading.itemsCalls.map(\.offset) == [0, 50, 50])
  }

  // MARK: - The Library filter the page was reached under

  @MainActor
  @Test("narrows the entity's items to what the active filter matches")
  func narrowsToTheActiveFilter() async {
    let ebook = SearchResultRow(
      kind: .book, entityID: "ebook-1", title: "Ebook", mediaCategory: .ebook, libraryID: "lib")
    let audiobook = SearchResultRow(
      kind: .book, entityID: "audio-1", title: "Audiobook", mediaCategory: .audiobook,
      libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil, itemsResults: [SearchPage(rows: [ebook, audiobook], hasMore: false)])
    let library = FakeLibraryReading()
    let filters = BrowseFilters(categories: [.ebook])
    let model = AuthorSeriesModel(
      target: .author(id: "author-1"), reading: reading, library: library, filters: filters)

    library.pushBrowseSnapshot(
      filters: filters,
      LibraryBrowseSnapshot(items: [Self.item(id: "ebook-1", category: .ebook)], unfilteredItemCount: 2))
    await waitUntil { model.state != .loading }

    #expect(model.rows == [ebook], "the audiobook is not part of the count the row stated")
    #expect(library.observedBrowseFilters == [filters])
  }

  @MainActor
  @Test("an entity emptied by the inherited filter reports filteredEmpty, not empty")
  func filterEmptiedEntityIsFilteredEmpty() async {
    let audiobook = SearchResultRow(
      kind: .book, entityID: "audio-1", title: "Audiobook", mediaCategory: .audiobook,
      libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil, itemsResults: [SearchPage(rows: [audiobook], hasMore: false)])
    let library = FakeLibraryReading()
    let filters = BrowseFilters(categories: [.ebook])
    let model = AuthorSeriesModel(
      target: .author(id: "author-1"), reading: reading, library: library, filters: filters)

    library.pushBrowseSnapshot(
      filters: filters, LibraryBrowseSnapshot(items: [], unfilteredItemCount: 1))
    await waitUntil { model.state != .loading }

    #expect(model.rows.isEmpty)
    #expect(
      model.state == .filteredEmpty,
      "the author has an item, so the filter is what emptied this screen")
  }

  @MainActor
  @Test("an inherited category filter regroups visible rows and removes empty sections")
  func filtersRegroupSections() async {
    let audiobook = SearchResultRow(
      kind: .book, entityID: "audio", title: "Audio", mediaCategory: .audiobook,
      seriesName: "Audio Saga #1", libraryID: "lib")
    let ebook = SearchResultRow(
      kind: .book, entityID: "ebook", title: "Ebook", mediaCategory: .ebook,
      seriesName: "Ebook Saga #1", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil, itemsResults: [SearchPage(rows: [audiobook, ebook], hasMore: false)])
    let library = FakeLibraryReading()
    let filters = BrowseFilters(categories: [.ebook])
    let model = AuthorSeriesModel(
      target: .author(id: "author-1"), reading: reading, library: library, filters: filters)

    library.pushBrowseSnapshot(
      filters: filters,
      LibraryBrowseSnapshot(
        items: [Self.item(id: "ebook", category: .ebook)], unfilteredItemCount: 2))
    await waitUntil { model.state != .loading }

    #expect(model.sections.map(\.displayName) == ["Ebook Saga"])
    #expect(model.rows.map(\.entityID) == ["ebook"])
  }

  @MainActor
  @Test("holds the loading state until the filter's first snapshot arrives")
  func waitsForTheFirstSnapshotBeforeShowingRows() async {
    let row = SearchResultRow(kind: .book, entityID: "a", title: "A", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil, itemsResults: [SearchPage(rows: [row], hasMore: false)])
    let library = FakeLibraryReading()
    let filters = BrowseFilters(downloadedOnly: true)
    let model = AuthorSeriesModel(
      target: .author(id: "author-1"), reading: reading, library: library, filters: filters)

    await waitUntil { reading.itemsCalls.isEmpty == false }
    await awaitQuiescence(
      "the author series loading projection to settle",
      of: { "state=\(model.state), rows=\(model.rows)" })

    #expect(
      model.state == .loading,
      "showing the unfiltered page first would visibly drop rows out of it a moment later")
    #expect(model.rows.isEmpty)

    library.pushBrowseSnapshot(
      filters: filters,
      LibraryBrowseSnapshot(items: [Self.item(id: "a", category: .audiobook)], unfilteredItemCount: 1))
    await waitUntil { model.state != .loading }

    #expect(model.rows == [row])
  }

  @MainActor
  @Test("an unfiltered page observes the local library for cached first paint")
  func unfilteredPageObservesTheLibrary() async {
    let row = SearchResultRow(kind: .book, entityID: "a", title: "A", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil, itemsResults: [SearchPage(rows: [row], hasMore: false)])
    let library = FakeLibraryReading()
    let model = AuthorSeriesModel(
      target: .author(id: "author-1"), reading: reading, library: library, filters: .unfiltered)

    await waitUntil { model.state != .loading }

    #expect(model.rows == [row])
    #expect(reading.itemsCalls.first?.libraryID == nil)
    #expect(library.observedBrowseFilters == [.unfiltered])
  }

  @MainActor
  @Test("fresh server rows keep cached expanded narrator metadata")
  func serverRowsKeepCachedNarratorMetadata() async {
    let entity = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Fixture Author", libraryID: "lib")
    let cached = ItemSummary(
      serverItemId: "book-1", mediaKind: "book", title: "Cached title",
      author: "Fixture Author", durationSeconds: 3_600, category: .audiobook,
      narratorName: "Adjoa Andoh")
    let remote = SearchResultRow(
      kind: .book, entityID: "book-1", title: "Fresh title", subtitle: "Fixture Author",
      mediaCategory: .audiobook, durationSeconds: 7_200, libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: entity, itemsResults: [SearchPage(rows: [remote], hasMore: false)])
    let model = AuthorSeriesModel(
      target: .author(id: "author-1", libraryID: "lib"), reading: reading,
      seed: AuthorSeriesDestinationSeed(entity: entity, items: [cached]))

    await waitUntil { model.rows.first?.title == "Fresh title" }

    #expect(model.rows.first?.durationSeconds == 7_200)
    #expect(model.rows.first?.narratorName == "Adjoa Andoh")
  }

  @MainActor
  @Test("a filtered page does not shorten an identity's next request")
  func filteredPageKeepsIdentityCursorAtPageBoundary() async {
    let hidden = SearchResultRow(kind: .book, entityID: "hidden", title: "Hidden", libraryID: "lib")
    let shown = SearchResultRow(kind: .book, entityID: "shown", title: "Shown", libraryID: "lib")
    let next = SearchResultRow(kind: .book, entityID: "next", title: "Next", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil,
      itemsResults: [
        SearchPage(rows: [hidden, shown], hasMore: true),
        SearchPage(rows: [next], hasMore: false),
      ])
    let library = FakeLibraryReading()
    let filters = BrowseFilters(categories: [.ebook])
    let model = AuthorSeriesModel(
      target: .author(id: "author-1"), reading: reading, library: library, filters: filters)
    library.pushBrowseSnapshot(
      filters: filters,
      LibraryBrowseSnapshot(
        items: [Self.item(id: "shown", category: .ebook), Self.item(id: "next", category: .ebook)],
        unfilteredItemCount: 3))
    await waitUntil { model.state != .loading }

    await model.loadMore()

    #expect(
      reading.itemsCalls.map(\.offset) == [0, 50],
      "the identity cursor advances by the bounded page size, not by visible rows")
    #expect(model.rows == [next, shown])
  }

  @MainActor
  @Test("a page that filtered down to nothing is not an empty entity while more pages remain")
  func staysLoadedWhileAFilteredPageIsEmpty() async {
    let hidden = SearchResultRow(kind: .book, entityID: "hidden", title: "Hidden", libraryID: "lib")
    let reading = FakeAuthorSeriesReading(
      entity: nil, itemsResults: [SearchPage(rows: [hidden], hasMore: true)])
    let library = FakeLibraryReading()
    let filters = BrowseFilters(categories: [.ebook])
    let model = AuthorSeriesModel(
      target: .author(id: "author-1"), reading: reading, library: library, filters: filters)

    library.pushBrowseSnapshot(
      filters: filters, LibraryBrowseSnapshot(items: [], unfilteredItemCount: 1))
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded, "the load-more row still has a page to ask for")
    #expect(model.rows.isEmpty)
  }

  private static func item(id: String, category: ItemMediaCategory) -> ItemSummary {
    ItemSummary(
      serverItemId: id, mediaKind: "book", title: id, author: "Author", durationSeconds: nil,
      category: category)
  }

  private static func row(
    id: String, title: String? = nil, libraryID: String
  ) -> SearchResultRow {
    SearchResultRow(
      kind: .book, entityID: id, title: title ?? id, libraryID: libraryID)
  }
}

private final class FakeAuthorSeriesReading: AuthorSeriesReading, @unchecked Sendable {
  struct ItemsKey: Hashable {
    let entityID: String
    let libraryID: String?
    let offset: Int
  }

  struct ItemsCall: Equatable {
    let limit: Int
    let offset: Int
    var entityID: String = ""
    var libraryID: String?
  }

  private let lock = NSLock()
  private let entityResult: AuthorSeriesEntity?
  private var queuedItemsResults: [SearchPage]
  private let itemsResultsByRequest: [ItemsKey: SearchPage]
  private let failingRequests: Set<ItemsKey>
  private let heldUntilAnswered: [ItemsKey: ItemsKey]
  private let answeredRequests = WaitableState<Set<ItemsKey>>(
    [], label: "FakeAuthorSeriesReading answered requests")
  private let narratorLibraryIDResults: [String]
  private var _itemsCalls: [ItemsCall] = []
  private var _entityCalls: [SearchResultKind] = []

  var itemsCalls: [ItemsCall] {
    lock.lock()
    defer { lock.unlock() }
    return _itemsCalls
  }

  var entityCalls: [SearchResultKind] {
    lock.lock()
    defer { lock.unlock() }
    return _entityCalls
  }

  init(
    entity: AuthorSeriesEntity?,
    itemsResults: [SearchPage] = [],
    itemsResultsByRequest: [ItemsKey: SearchPage] = [:],
    failingRequests: Set<ItemsKey> = [],
    heldUntilAnswered: [ItemsKey: ItemsKey] = [:],
    narratorLibraryIDs: [String] = []
  ) {
    self.entityResult = entity
    self.queuedItemsResults = itemsResults
    self.itemsResultsByRequest = itemsResultsByRequest
    self.failingRequests = failingRequests
    self.heldUntilAnswered = heldUntilAnswered
    self.narratorLibraryIDResults = narratorLibraryIDs
  }

  func entity(
    kind: SearchResultKind, entityID: String, libraryID: String?
  ) async throws -> AuthorSeriesEntity? {
    recordEntityCall(kind)
    return entityResult
  }

  func entity(kind: SearchResultKind, named name: String) async throws -> AuthorSeriesEntity? {
    recordEntityCall(kind)
    guard let entityResult else { return nil }
    return AuthorSeriesEntity.normalizedName(entityResult.name)
      == AuthorSeriesEntity.normalizedName(name) ? entityResult : nil
  }

  func narratorLibraryIDs() async throws -> [String] {
    narratorLibraryIDResults
  }

  func items(
    narratorName: String, libraryID: String, limit: Int, offset: Int
  ) async throws -> SearchPage {
    let response = recordItemsCall(
      limit: limit, offset: offset, entityID: narratorName, libraryID: libraryID)
    if let prerequisite = response.heldUntilAnswered {
      await waitUntilAnswered(prerequisite)
    }
    markAnswered(response.key)
    if response.shouldThrow { throw AuthorSeriesTestFailure() }
    return response.page
  }

  func items(
    kind: SearchResultKind, entityID: String, libraryID: String?, limit: Int, offset: Int
  ) async throws -> SearchPage {
    let response = recordItemsCall(
      limit: limit, offset: offset, entityID: entityID, libraryID: libraryID)
    if let prerequisite = response.heldUntilAnswered {
      await waitUntilAnswered(prerequisite)
    }
    markAnswered(response.key)
    if response.shouldThrow { throw AuthorSeriesTestFailure() }
    return response.page
  }

  // `NSLock.lock()`/`unlock()` are unavailable directly inside an `async` function body (Swift
  // 6.2). Calling through these plain synchronous helpers keeps the lock/unlock pair in a
  // non-async context.
  private func recordEntityCall(_ kind: SearchResultKind) {
    lock.lock()
    defer { lock.unlock() }
    _entityCalls.append(kind)
  }

  private func recordItemsCall(
    limit: Int, offset: Int, entityID: String, libraryID: String?
  ) -> ItemResponse {
    lock.lock()
    defer { lock.unlock() }
    let key = ItemsKey(entityID: entityID, libraryID: libraryID, offset: offset)
    _itemsCalls.append(
      ItemsCall(limit: limit, offset: offset, entityID: entityID, libraryID: libraryID))
    let page: SearchPage
    if let keyedPage = itemsResultsByRequest[key] {
      page = keyedPage
    } else {
      page =
        queuedItemsResults.isEmpty
        ? SearchPage(rows: [], hasMore: false)
        : queuedItemsResults.removeFirst()
    }
    return ItemResponse(
      key: key,
      page: page,
      shouldThrow: failingRequests.contains(key),
      heldUntilAnswered: heldUntilAnswered[key])
  }

  /// Holds a response until another request has been answered, so an out-of-order completion is
  /// caused rather than hoped for from a head start that load can erase.
  private func waitUntilAnswered(_ prerequisite: ItemsKey) async {
    await answeredRequests.waitUntil("answering \(prerequisite)") { $0.contains(prerequisite) }
  }

  private func markAnswered(_ key: ItemsKey) {
    answeredRequests.mutate { $0.insert(key) }
  }

  private struct ItemResponse {
    let key: ItemsKey
    let page: SearchPage
    let shouldThrow: Bool
    let heldUntilAnswered: ItemsKey?
  }
}

/// Gates every `items` call on a manually-resolved continuation, so a test can prove a boundary
/// call is coalesced rather than duplicated while one is already in flight.
private actor SuspendedAuthorSeriesReading: AuthorSeriesReading {
  private let entityResult: AuthorSeriesEntity?
  private(set) var itemsCallCount = 0
  private(set) var entityCallCount = 0
  // Stays parked on task cancellation, as the request it stands in for runs to completion.
  private nonisolated let gate = TestGate<SearchPage>(
    label: "SuspendedAuthorSeriesReading items", ignoresCancellation: true)

  init(entity: AuthorSeriesEntity?) {
    self.entityResult = entity
    gate.hold()
  }

  func entity(
    kind: SearchResultKind, entityID: String, libraryID: String?
  ) async throws -> AuthorSeriesEntity? {
    entityCallCount += 1
    return entityResult
  }

  func items(
    kind: SearchResultKind, entityID: String, libraryID: String?, limit: Int, offset: Int
  ) async throws -> SearchPage {
    itemsCallCount += 1
    return await gate.pass(otherwise: { SearchPage(rows: [], hasMore: false) })
  }

  /// Polls on the caller's isolation, not this actor's. The `@MainActor` model's request waits
  /// behind every other main-actor test in a full parallel run; a poll on this actor is never
  /// queued there and burns its serviced-poll budget while the model still waits, whereas a poll
  /// from the `@MainActor` test needs a main-actor turn each time, so the budget stretches.
  ///
  /// On timeout, reports how far the load got: no entity call means the initial task never ran;
  /// an entity call without an items call means the page fetch never started.
  func waitUntilItemsRequested(
    count: Int,
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    _ = await awaitCondition(
      "items request \(count)",
      isolation: isolation,
      sourceLocation: sourceLocation,
      observing: {
        let calls = await (self.entityCallCount, self.itemsCallCount)
        return "entity calls \(calls.0), items calls \(calls.1)"
      },
      until: { await self.itemsCallCount >= count })
  }

  func resolveNext(_ page: SearchPage) async {
    // The call count rises before the request parks, so wait for the park before releasing it.
    await gate.waitUntilParked()
    gate.releaseNext(page)
  }
}

private struct AuthorSeriesTestFailure: Error {}
