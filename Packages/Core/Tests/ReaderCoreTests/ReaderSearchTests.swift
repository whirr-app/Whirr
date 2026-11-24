import Foundation
import TestSupport
import Testing

@testable import ReaderCore

@Suite struct ReaderSearchTests {

  @Test("search hits cannot be encoded")
  func searchHitsAreNotEncodable() {
    #expect((ReaderSearchHit.self as Any.Type) is any Encodable.Type == false)
  }

  @Test("hit ids use the search generation and ordinal")
  func hitIDsAreStableWithinTheirInputs() {
    let first = ReaderSearchHit.hitID(generation: 4, ordinal: 9)

    #expect(first == ReaderSearchHit.hitID(generation: 4, ordinal: 9))
    #expect(first != ReaderSearchHit.hitID(generation: 5, ordinal: 9))
    #expect(first != ReaderSearchHit.hitID(generation: 4, ordinal: 10))
  }

  @Test("chapter lookup uses the last resolved entry at or before the hit")
  func chapterTitleUsesProgressionBoundaries() {
    let toc = [
      TOCEntry(title: "Unresolved", depth: 0),
      TOCEntry(title: "First", depth: 0, startProgression: 0.2),
      TOCEntry(title: "Nested", depth: 1, startProgression: 0.45),
      TOCEntry(title: "Second", depth: 0, startProgression: 0.7),
    ]

    #expect(ReaderSearchHit.chapterTitle(for: nil, in: toc) == nil)
    #expect(ReaderSearchHit.chapterTitle(for: 0.1, in: toc) == nil)
    #expect(ReaderSearchHit.chapterTitle(for: 0.2, in: toc) == "First")
    #expect(ReaderSearchHit.chapterTitle(for: 0.6, in: toc) == "Nested")
    #expect(ReaderSearchHit.chapterTitle(for: 0.7, in: toc) == "Second")
    #expect(ReaderSearchHit.chapterTitle(for: 1, in: []) == nil)
  }

  @Test("the Core fake can stream and navigate configured hits")
  @MainActor
  func fakeSearchCanBeDriven() async throws {
    let hit = ReaderSearchHit(
      id: ReaderSearchHit.hitID(generation: 1, ordinal: 0),
      chapterTitle: "Chapter one",
      before: "before",
      highlight: "query",
      after: "after",
      totalProgression: 0.25
    )
    let renderer = FakeEPUBRendering()
    renderer.isSearchable = true
    renderer.searchHits = [hit]
    try await renderer.start()
    _ = try await renderer.open(
      EPUBOpenRequest(
        localFileURL: URL(fileURLWithPath: "/tmp/book.epub"),
        preferences: ReaderPreferences(), initialLocation: nil))

    var results = renderer.search(query: "query").makeAsyncIterator()
    #expect(try await results.next() == [hit])
    #expect(try await results.next() == nil)

    try await renderer.go(toSearchHit: hit.id)
    #expect(renderer.goToSearchHitIDs == [hit.id])

    await renderer.cancelSearch()
    await #expect(throws: ReaderSearchFailure.reading) {
      try await renderer.go(toSearchHit: hit.id)
    }
  }
}
