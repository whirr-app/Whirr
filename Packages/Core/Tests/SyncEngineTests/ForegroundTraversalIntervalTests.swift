import ABSApi
import Foundation
import Testing

@testable import SyncEngine

/// A library traversed within `SyncEngine.minimumForegroundTraversalInterval` is skipped by a
/// foreground refresh. Only foreground-initiated refreshes are gated; pull-to-refresh and library
/// selection are direct user requests and always traverse.
///
/// The gate reuses `pullLibrary`'s failure-backoff skip, so a gated library still has its
/// `/api/me` progress applied to rows it already has.
@Suite struct ForegroundTraversalIntervalTests {

  @Test func aForegroundWithinTheIntervalSkipsTheTraversal() async throws {
    let h = try await Harness()
    _ = try await h.seedLibrary(serverLibraryId: "lib1")
    try await Self.traverseOnce(h)
    #expect(Self.itemRequests(h) == 1)

    h.clock.advance(by: SyncEngine.minimumForegroundTraversalInterval - 1)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()

    await h.engine.handleLifecycleTransition(.foreground)

    #expect(Self.itemRequests(h) == 1)
    #expect(try h.fetchSyncRuns().map(\.reason) == ["foreground"], "a skipped library records no run")
  }

  @Test func aForegroundAfterTheIntervalTraversesAgain() async throws {
    let h = try await Harness()
    _ = try await h.seedLibrary(serverLibraryId: "lib1")
    try await Self.traverseOnce(h)

    h.clock.advance(by: SyncEngine.minimumForegroundTraversalInterval)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)

    await h.engine.handleLifecycleTransition(.foreground)

    #expect(Self.itemRequests(h) == 2)
  }

  /// Rule 20 keeps explicit pull-to-refresh a correctness path without qualification: the user
  /// pulled, so the catalogue is walked however recently it was last walked.
  @Test func explicitRefreshIsNeverGatedByTheInterval() async throws {
    let h = try await Harness()
    _ = try await h.seedLibrary(serverLibraryId: "lib1")
    try await Self.traverseOnce(h)

    h.clock.advance(by: 1)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)

    await h.engine.refresh()

    #expect(Self.itemRequests(h) == 2)
  }

  /// The interval is recorded only on a completed run. An incomplete traversal leaves its deletion
  /// inference unfinished, so it must never be the reason a later pass is skipped.
  @Test func anIncompleteTraversalDoesNotStartTheInterval() async throws {
    let h = try await Harness(pageLimit: 2, randomUnit: 1.0)
    _ = try await h.seedLibrary(serverLibraryId: "lib1")
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(
      items: [(id: "a", title: "A", author: nil), (id: "b", title: "B", author: nil)], total: 6,
      limit: 2, page: 0)
    h.enqueuePage(items: [(id: "c", title: "C", author: nil)], total: 8, limit: 2, page: 1)
    await h.engine.handleLifecycleTransition(.foreground)
    let requestsAfterIncompleteRun = Self.itemRequests(h)

    // Past the failure backoff the incomplete run scheduled, but well inside the traversal
    // interval a completed run would have started.
    h.clock.advance(by: ABSApi.BackoffPolicy.baseDelay)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 2, page: 0)

    await h.engine.handleLifecycleTransition(.foreground)

    #expect(Self.itemRequests(h) > requestsAfterIncompleteRun)
  }

  /// A skipped library still receives the positions another device wrote.
  @Test func aGatedForegroundStillAppliesServerProgress() async throws {
    let h = try await Harness()
    let libraryRowId = try #require(try await h.seedLibrary(serverLibraryId: "lib1").id)
    let seeded = try await h.seedItem(
      libraryRowId: libraryRowId, serverItemId: "seeded-item", generation: 1)
    let itemRowId = try #require(seeded.id)
    // The item must survive the first traversal's deletion inference, so the page lists it.
    try await Self.traverseOnce(h, items: [(id: "seeded-item", title: "Seeded", author: nil)])

    h.clock.advance(by: SyncEngine.minimumForegroundTraversalInterval - 1)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueProgress([(libraryItemId: "seeded-item", currentTime: 456, isFinished: false)])

    await h.engine.handleLifecycleTransition(.foreground)

    #expect(Self.itemRequests(h) == 1, "the traversal stayed gated")
    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.currentTime == 456)
  }

  private static func traverseOnce(
    _ h: Harness, items: [(id: String, title: String, author: String?)] = []
  ) async throws {
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: items, total: items.count, limit: 100, page: 0)
    await h.engine.handleLifecycleTransition(.foreground)
  }

  private static func itemRequests(_ h: Harness) -> Int {
    h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }.count
  }
}
