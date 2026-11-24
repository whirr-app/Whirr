import Foundation
import ReaderCore
import TestSupport
import Testing

@testable import AppModel

@Suite("Reader search model")
@MainActor
struct ReaderSearchModelTests {

  @Test("query edits coalesce behind the debounce")
  func queryEditsCoalesceBehindTheDebounce() async throws {
    let renderer = try await makeRenderer()
    let model = ReaderSearchModel(renderer: renderer, toc: [])

    model.query = "one"
    model.query = "ones"

    #expect(renderer.searchedQueries.isEmpty)
    #expect(await waitUntil { renderer.searchedQueries == ["ones"] })
  }

  @Test("a newer query cancels the previous stream consumer")
  func newerQueryCancelsPreviousStreamConsumer() async throws {
    let renderer = try await makeRenderer()
    let oldHit = hit(id: "old", progression: 0.1)
    let oldTail = hit(id: "old-tail", progression: 0.2)
    renderer.searchHitBatches = [[oldHit], [oldTail]]
    let model = ReaderSearchModel(renderer: renderer, toc: [])

    model.query = "old"
    #expect(await waitUntil { model.hits == [oldHit] })

    let newHit = hit(id: "new", progression: 0.8)
    renderer.searchHitBatches = [[newHit]]
    model.query = "new"
    // This releases the old renderer stream before the new debounce elapses. Its cancelled model
    // task must not append the old tail.
    renderer.releaseNextSearchHitBatch()

    #expect(await waitUntil { renderer.searchedQueries == ["old", "new"] })
    #expect(await waitUntil { model.hits == [newHit] })
    #expect(model.failure == nil)
    #expect(renderer.cancelSearchCallCount == 0)
  }

  @Test("hits accumulate as the renderer releases progressive pages")
  func hitsAccumulateAsRendererReleasesProgressivePages() async throws {
    let renderer = try await makeRenderer()
    let first = hit(id: "first", progression: 0.25)
    let second = ReaderSearchHit(
      id: "second", chapterTitle: "Existing chapter", before: "a", highlight: "term",
      after: "b", totalProgression: 0.75)
    renderer.searchHitBatches = [[first], [second]]
    let toc = [TOCEntry(title: "Chapter", depth: 0, startProgression: 0.2)]
    let model = ReaderSearchModel(renderer: renderer, toc: toc)

    model.query = "term"
    #expect(await waitUntil { model.hits.count == 1 })
    #expect(model.isSearching)
    #expect(model.hits[0].chapterTitle == "Chapter")

    renderer.releaseNextSearchHitBatch()
    #expect(await waitUntil { model.hits.count == 2 && model.isSearching == false })
    #expect(model.hits.map(\.id) == ["first", "second"])
    #expect(model.hits[1].chapterTitle == "Existing chapter")
  }

  @Test("the model caps results at 500 and reports truncation")
  func modelCapsResultsAt500AndReportsTruncation() async throws {
    let renderer = try await makeRenderer()
    renderer.searchHits = (0...500).map { index in
      hit(id: "hit-\(index)", progression: Double(index) / 500)
    }
    let model = ReaderSearchModel(renderer: renderer, toc: [])

    model.query = "term"

    #expect(await waitUntil { model.didReachHitLimit })
    #expect(model.hits.count == 500)
    #expect(model.isSearching == false)
    #expect(renderer.cancelSearchCallCount == 0)
  }

  @Test("a blank query resets the panel and cancels the renderer search")
  func blankQueryResetsPanelAndCancelsRendererSearch() async throws {
    let renderer = try await makeRenderer()
    renderer.searchHits = [hit(id: "hit", progression: 0.4)]
    let model = ReaderSearchModel(renderer: renderer, toc: [])

    model.query = "term"
    #expect(await waitUntil { model.hits.isEmpty == false })

    model.query = "  \n"
    #expect(
      await waitUntil {
        model.query == "  \n" && model.hits.isEmpty && model.isSearching == false
          && renderer.cancelSearchCallCount == 1
      })
    #expect(model.failure == nil)
    #expect(model.didReachHitLimit == false)
  }

  @Test("cancellation leaves failure nil")
  func cancellationLeavesFailureNil() async throws {
    let renderer = try await makeRenderer()
    renderer.searchHitBatches = [[hit(id: "first", progression: 0.1)], [hit(id: "second", progression: 0.2)]]
    let model = ReaderSearchModel(renderer: renderer, toc: [])

    model.query = "term"
    #expect(await waitUntil { model.hits.count == 1 })
    model.query = ""

    #expect(await waitUntil { model.isSearching == false && renderer.cancelSearchCallCount == 1 })
    #expect(model.failure == nil)
  }

  @Test("a renderer search failure is exposed after the stream stops")
  func rendererSearchFailureIsExposedAfterStreamStops() async throws {
    let renderer = try await makeRenderer()
    renderer.nextSearchFailure = .badQuery
    let model = ReaderSearchModel(renderer: renderer, toc: [])

    model.query = "term"

    #expect(await waitUntil { model.failure == .badQuery && model.isSearching == false })
  }

  private func makeRenderer() async throws -> FakeEPUBRendering {
    let renderer = FakeEPUBRendering()
    renderer.isSearchable = true
    try await renderer.start()
    _ = try await renderer.open(
      EPUBOpenRequest(
        localFileURL: URL(fileURLWithPath: "/tmp/search.epub"),
        preferences: ReaderPreferences(), initialLocation: nil))
    return renderer
  }

  private func hit(id: String, progression: Double) -> ReaderSearchHit {
    ReaderSearchHit(
      id: id, chapterTitle: nil, before: "before ", highlight: "term", after: " after",
      totalProgression: progression)
  }
}
