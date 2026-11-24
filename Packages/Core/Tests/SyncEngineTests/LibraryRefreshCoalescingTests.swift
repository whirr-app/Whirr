import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Which triggers start a traversal, which join one already in flight, and what scope a
/// libraries-only discovery pass leaves behind.
@Suite("Library pull: refresh coalescing, trigger reasons, and discovery scope", .timeLimit(.minutes(1)))
struct LibraryRefreshCoalescingTests {

  @Test("catalogue and server search omit excluded libraries while discovery still reconciles them")
  func excludedLibrariesAreDiscoveredButNeverTraversedOrSearched() async throws {
    let h = try await Harness()
    _ = try await h.seedLibrary(serverLibraryId: "excluded", isIncluded: false)
    h.enqueueLibraries([
      (id: "included", name: "Included", mediaType: "book"),
      (id: "excluded", name: "Excluded", mediaType: "book"),
    ])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)

    await h.engine.refresh()

    h.enqueueSearchResponse(book: [], podcast: [])
    _ = try await h.engine.search(libraryIDs: nil, query: "needle", limit: 25)

    let paths = h.http.requests.map(\.url.path)
    #expect(paths.contains("/api/libraries"))
    #expect(paths.contains("/api/libraries/included/items"))
    #expect(paths.contains("/api/libraries/excluded/items") == false)
    #expect(paths.contains("/api/libraries/included/search"))
    #expect(paths.contains("/api/libraries/excluded/search") == false)
    #expect(paths.contains("/api/libraries/excluded/filterdata") == false)
  }

  @Test("an empty included set stops immediately after library discovery")
  func emptyIncludedSetStopsBeforeProfileAndPages() async throws {
    let h = try await Harness()
    _ = try await h.seedLibrary(serverLibraryId: "excluded", isIncluded: false)
    h.enqueueLibraries([(id: "excluded", name: "Excluded", mediaType: "book")])

    await h.engine.refresh()

    #expect(h.http.requests.map(\.url.path) == ["/api/libraries"])
  }

  @Test("excluding a library while its page is in flight stops before the next page")
  func midRunExclusionStopsTheLibraryWalk() async throws {
    let ancillaryCalls = DrainCallCounter()
    let h = try await Harness(
      pageLimit: 1,
      authorSeriesFilterDataRefresh: { ancillaryCalls.increment() })
    let gate = RefreshRequestGate()
    h.http.setRequestHook { request in
      if request.url.path == "/api/libraries/lib1/items" {
        await gate.blockFirstRequest()
      }
    }
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "first", title: "First", author: nil)], total: 2, limit: 1, page: 0)
    h.enqueuePage(items: [(id: "second", title: "Second", author: nil)], total: 2, limit: 1, page: 1)

    let refresh = Task { await h.engine.refresh() }
    await gate.waitUntilBlocked()
    try await h.setLibraryIncluded(false, serverLibraryId: "lib1")
    await gate.release()
    await refresh.value

    let itemPaths = h.http.requests
      .filter { $0.routeTemplate == "/api/libraries/:id/items" }
      .map(\.url.path)
    #expect(itemPaths == ["/api/libraries/lib1/items"])
    #expect(ancillaryCalls.value == 0, "later ancillary passes must not start for an excluded library")
  }

  @Test("overlapping refresh and inclusion intents coalesce into one later refresh")
  func pendingRefreshCoalescesMultipleTriggers() async throws {
    let h = try await Harness()
    let gate = RefreshRequestGate()
    h.http.setRequestHook { request in
      if request.url.path == "/api/libraries/lib1/items" {
        await gate.blockFirstRequest()
      }
    }
    for _ in 0..<2 {
      h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
      h.enqueueEmptyProgress()
      h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    }

    let initialRefresh = Task { await h.engine.refresh() }
    await gate.waitUntilBlocked()
    await h.engine.refresh()
    await h.engine.librarySelectionDidIncludeLibrary()
    await h.engine.librarySelectionDidIncludeLibrary()
    await gate.release()
    await initialRefresh.value

    #expect(h.http.requests.filter { $0.routeTemplate == "/api/libraries" }.count == 2)
    #expect(h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }.count == 2)
  }

  @Test("library discovery reconciles the library list without walking the catalogue")
  func discoveryDoesNotTraverseItemPages() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])

    let result = await h.engine.refreshLibraryDiscovery()

    #expect(result == .reconciled)
    #expect(h.http.requests.filter { $0.routeTemplate == "/api/libraries" }.count == 1)
    #expect(h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }.isEmpty)
    #expect(h.http.requests.filter { $0.routeTemplate == "/api/me" }.isEmpty)
    // No traversal happened, so none is claimed: a libraries-only pass must not leave a completed
    // sync run behind for `syncStatus` to report as a catalogue refresh.
    #expect(try h.fetchSyncRuns().isEmpty)
  }

  @Test("a foreground trigger joining a discovery run still walks the catalogue")
  func foregroundJoiningDiscoveryStillTraverses() async throws {
    let h = try await Harness()
    let gate = RefreshRequestGate()
    h.http.setRequestHook { request in
      if request.url.path == "/api/libraries" {
        await gate.blockFirstRequest()
      }
    }
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)

    let discovery = Task { _ = await h.engine.refreshLibraryDiscovery() }
    await gate.waitUntilBlocked()
    await h.engine.handleLifecycleTransition(.foreground)
    await gate.release()
    await discovery.value

    // The discovery pass pulled no pages, so the foreground follow-up must not inherit its scope.
    #expect(h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }.count == 1)
    // Recorded as "foreground", not "coalesced": the discovery pass it joined pulled no pages, so
    // this is the cycle's first traversal, not a repeat.
    #expect(try h.fetchSyncRuns().map(\.reason) == ["foreground"])
  }

  /// The duplicate ordinary foreground traversal, identified and then removed.
  ///
  /// `.active → .inactive → .active` emits a second `.foreground` (`ScenePhaseLifecycleMapper`),
  /// and `SyncEngine` is an actor that suspends throughout a traversal. Left alone, the second
  /// delivery would land mid-run, become the pending reason and replay as a whole second walk;
  /// the traversal it joined satisfies it instead.
  @Test("an app-switcher bounce costs one traversal, not two")
  func foregroundDeliveredTwiceMidRunCostsOnlyOneTraversal() async throws {
    let h = try await Harness()
    let gate = RefreshRequestGate()
    h.http.setRequestHook { request in
      if request.url.path == "/api/libraries" {
        await gate.blockFirstRequest()
      }
    }
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)

    // `.active → .inactive` emits nothing; the return to `.active` is the second `.foreground`.
    #expect(ScenePhaseLifecycleMapper.transition(from: .active, to: .inactive) == nil)
    #expect(ScenePhaseLifecycleMapper.transition(from: .inactive, to: .active) == .foreground)

    let first = Task { await h.engine.handleLifecycleTransition(.foreground) }
    await gate.waitUntilBlocked()
    await h.engine.handleLifecycleTransition(.foreground)
    await gate.release()
    await first.value

    #expect(try h.fetchSyncRuns().map(\.reason) == ["foreground"])
    #expect(h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }.count == 1)
  }

  /// The launch case, between two different triggers: `RootModel`'s first-resolution pull races
  /// the scene's first `.active`. The foreground joins the explicit traversal and is satisfied by
  /// it.
  @Test("a foreground arriving during the launch pull costs one traversal, not two")
  func foregroundDuringTheLaunchPullCostsOnlyOneTraversal() async throws {
    let h = try await Harness()
    let gate = RefreshRequestGate()
    h.http.setRequestHook { request in
      if request.url.path == "/api/libraries" {
        await gate.blockFirstRequest()
      }
    }
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)

    let launchPull = Task { await h.engine.refresh() }
    await gate.waitUntilBlocked()
    await h.engine.handleLifecycleTransition(.foreground)
    await gate.release()
    await launchPull.value

    #expect(try h.fetchSyncRuns().map(\.reason) == ["explicit"])
    #expect(h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }.count == 1)
  }

  /// The same launch race in the other order, which nothing collapses.
  ///
  /// An `.explicit` request joining an in-flight traversal is not `.foreground`, so
  /// `joinedRunSatisfiesIt` does not apply and the pending reason replays as a second complete
  /// walk. The user asked for pull to refresh, so a joined run does not satisfy it
  /// (API-CONVENTIONS.md rule 20).
  ///
  /// `RootView`'s cold-launch path takes `RootModel.resolveLibraryAtColdLaunch()` and issues no
  /// pull, so no production caller produces this pairing on launch; the rule is still live for a
  /// genuine pull to refresh landing mid-traversal.
  @Test("the launch pull arriving during the foreground traversal costs two traversals")
  func launchPullDuringTheForegroundTraversalCostsTwoTraversals() async throws {
    let h = try await Harness()
    let gate = RefreshRequestGate()
    h.http.setRequestHook { request in
      if request.url.path == "/api/libraries" {
        await gate.blockFirstRequest()
      }
    }
    for _ in 0..<2 {
      h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
      h.enqueueEmptyProgress()
      h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    }

    let foreground = Task { await h.engine.handleLifecycleTransition(.foreground) }
    await gate.waitUntilBlocked()
    // `RootModel`'s first-resolution pull, which reaches the engine as
    // `.explicit` because `SyncCoordinating.refresh()` is the only broad entry point it has.
    await h.engine.refresh()
    await gate.release()
    await foreground.value

    #expect(try h.fetchSyncRuns().map(\.reason) == ["foreground", "explicit"])
    #expect(h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }.count == 2)
  }

  @Test("a stronger trigger joining an in-flight run keeps its own reason, not coalesced")
  func pendingRefreshCarriesStrongestReason() async throws {
    let h = try await Harness()
    let gate = RefreshRequestGate()
    h.http.setRequestHook { request in
      if request.url.path == "/api/libraries/lib1/items" {
        await gate.blockFirstRequest()
      }
    }
    for _ in 0..<2 {
      h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
      h.enqueueEmptyProgress()
      h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    }

    let initialRefresh = Task { await h.engine.refresh() }
    await gate.waitUntilBlocked()
    // A selection inclusion committed mid-run is the strongest trigger there is. The follow-up it
    // causes must reconcile as that inclusion, not be demoted to an anonymous coalesced pass.
    await h.engine.librarySelectionDidIncludeLibrary()
    await gate.release()
    await initialRefresh.value

    #expect(try h.fetchSyncRuns().map(\.reason) == ["explicit", "librarySelection"])
  }

  @Test("an idle inclusion intent starts exactly one refresh")
  func idleInclusionIntentStartsOneRefresh() async throws {
    let h = try await Harness()
    _ = try await h.seedLibrary(serverLibraryId: "lib1", isIncluded: false)
    try await h.setLibraryIncluded(true, serverLibraryId: "lib1")
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)

    await h.engine.librarySelectionDidIncludeLibrary()

    #expect(h.http.requests.filter { $0.routeTemplate == "/api/libraries" }.count == 1)
    #expect(h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }.count == 1)
  }

  @Test("an all-included account preserves the established request order")
  func allIncludedRequestOrderIsUnchanged() async throws {
    let h = try await Harness()
    h.enqueueLibraries([
      (id: "books", name: "Books", mediaType: "book"),
      (id: "more-books", name: "More Books", mediaType: "book"),
    ])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)

    await h.engine.refresh()

    #expect(
      h.http.requests.map(\.url.path) == [
        "/api/libraries", "/api/me", "/api/libraries/books/items", "/api/libraries/more-books/items",
      ])
  }
}

/// Holds exactly the first matching fake request after it has been recorded. That gives the
/// selection tests a deterministic point between page N and N+1 without guessing at task timing.
private actor RefreshRequestGate {
  private var hasBlocked = false
  // A held request runs to completion regardless of cancellation, as the real one would.
  private nonisolated let gate = TestGate<Void>(
    label: "RefreshRequestGate first request", ignoresCancellation: true)

  init() { gate.hold() }

  func blockFirstRequest() async {
    guard hasBlocked == false else { return }
    hasBlocked = true
    await gate.pass()
  }

  func waitUntilBlocked() async {
    await gate.waitUntilParked()
  }

  func release() {
    gate.release()
  }
}
