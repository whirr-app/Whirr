import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The foreground/explicit-refresh trigger surface (API-CONVENTIONS.md rule 20: no timer-based
/// polling, ever).
///
/// The wait in `foregroundTransitionTriggersRefresh` is event-driven via
/// `FakeHTTPClient.waitForRequests`. The no-timer test checks the construction boundary: creating
/// the engine without an explicit trigger must not enqueue work.
@Suite("Foreground/explicit pull triggers", .timeLimit(.minutes(1)))
struct ForegroundPullTests {

  @Test("a foreground transition triggers refresh through the injected AppLifecycle stream")
  func foregroundTransitionTriggersRefresh() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title", author: nil)], total: 1, limit: 100, page: 0)

    #expect(h.http.requests.isEmpty)
    h.appLifecycle.simulateForeground()
    await h.http.waitForRequests { $0.isEmpty == false }

    #expect(h.http.requests.contains { $0.url.path == "/api/libraries" })
  }

  @Test("shutdown stops later lifecycle-triggered refreshes")
  func shutdownStopsLaterLifecycleTriggeredRefreshes() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title", author: nil)], total: 1, limit: 100, page: 0)

    // Positive control: the subscriber is live and a foreground transition does reach the engine.
    h.appLifecycle.simulateForeground()
    await h.http.waitForRequests { $0.isEmpty == false }
    let requestsBeforeShutdown = h.http.requests.count

    await h.engine.shutdown()
    await h.engine.shutdown()

    // Waiting for the subscriber to drop off the fake's stream makes the negative assertion
    // below sound: once the count reaches zero the transition has no consumer, so "no new
    // requests" is settled rather than a race.
    #expect(await waitUntil { h.appLifecycle.lifecycleSubscriberCount == 0 })

    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.appLifecycle.simulateForeground()

    #expect(h.http.requests.count == requestsBeforeShutdown)
  }

  @Test("explicit refresh() (pull-to-refresh) triggers a pull")
  func explicitRefreshTriggersAPull() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title", author: nil)], total: 1, limit: 100, page: 0)

    await h.engine.refresh()

    #expect(h.http.requests.contains { $0.url.path == "/api/libraries" })
  }

  @Test("no timer-based polling exists: nothing runs without an explicit trigger")
  func noTimerBasedPollingExists() async throws {
    let h = try await Harness()
    // Zero canned responses: any construction-time request would surface as a failed
    // FakeHTTPClient call once the queue underflows, not just as a missed assertion.
    #expect(h.http.requests.isEmpty)
  }

  @Test("a concurrent trigger while a refresh is active does not start a second traversal")
  func concurrentTriggerDoesNotStartASecondTraversal() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title", author: nil)], total: 1, limit: 100, page: 0)

    async let first: Void = h.engine.refresh()
    async let second: Void = h.engine.refresh()
    _ = await (first, second)

    let runs = try h.fetchSyncRuns()
    #expect(runs.count == 1)
  }

  /// A traversal can outlive its account and re-read the current account for a follow-up run. The
  /// next account's `running` row is its own live traversal, so reaping it as abandoned would
  /// mark that traversal incomplete.
  @Test("an engine built for one account does not reap another's runs")
  func anEngineBuiltForOneAccountDoesNotReapAnothersRuns() async throws {
    let h = try await Harness(bindsClientToAccount: true)
    let nextRecord = try await h.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM account")
      var record = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://sync.example.test",
        serverUserId: "next-user", serverVersion: "2.35.1")
      try record.insert(db)
      return record
    }
    let nextAccountId = try #require(nextRecord.id)
    let syncRunDAO = SyncRunDAO(database: h.database)
    let run = try await syncRunDAO.startRunAsync(
      accountId: nextAccountId, libraryId: nil, reason: "next-account", generation: 1,
      sortRequested: nil, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let runId = try #require(run.id)

    await h.engine.refresh()

    #expect(try syncRunDAO.fetch(runId: runId)?.state == .running)
    #expect(h.http.requests.isEmpty)
  }

  // MARK: - Shutdown drains the in-flight traversal

  /// Removal awaits `shutdown()` before it purges and wipes credentials, so its return must mean the
  /// traversal has ended, not merely that no new one will start.
  @Test("shutdown awaits the in-flight traversal and runs no follow-up")
  func shutdownAwaitsTheInFlightTraversalAndRunsNoFollowUp() async throws {
    let handOffs = DrainCallCounter()
    let h = try await Harness(authorSeriesFilterDataRefresh: { handOffs.increment() })
    let gate = HeldRequestGate()
    h.http.setRequestHook { request in
      if request.url.path == "/api/libraries/lib1/items" { await gate.blockFirstRequest() }
    }
    // Two full refreshes' responses, so a follow-up that wrongly starts is recorded rather than
    // failing on an empty queue.
    for _ in 0..<2 {
      h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
      h.enqueueEmptyProgress()
      h.enqueuePage(items: [(id: "item1", title: "Title", author: nil)], total: 1, limit: 100, page: 0)
    }

    let refresh = Task { await h.engine.refresh() }
    await gate.waitUntilBlocked()
    // Joins the blocked run as its follow-up.
    await h.engine.refresh()
    let requestsBeforeShutdown = h.http.requests.count

    let releaser = Task {
      await waitUntil { await h.engine.isShutdown }
      await gate.release()
    }
    await h.engine.shutdown()
    let pageWasReleasedBeforeShutdownReturned = await gate.isReleased
    await releaser.value
    await refresh.value

    #expect(pageWasReleasedBeforeShutdownReturned, "shutdown returned while its traversal was blocked on a page")
    #expect(h.http.requests.count == requestsBeforeShutdown, "no page or follow-up request after shutdown")
    #expect(handOffs.value == 0, "no ancillary hand-off starts after shutdown")
  }

  @Test("shutdown stops a traversal at the next page boundary")
  func shutdownStopsATraversalAtTheNextPageBoundary() async throws {
    let h = try await Harness(pageLimit: 1)
    let gate = HeldRequestGate()
    h.http.setRequestHook { request in
      if request.url.path == "/api/libraries/lib1/items" { await gate.blockFirstRequest() }
    }
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "first", title: "First", author: nil)], total: 2, limit: 1, page: 0)
    h.enqueuePage(items: [(id: "second", title: "Second", author: nil)], total: 2, limit: 1, page: 1)

    let refresh = Task { await h.engine.refresh() }
    await gate.waitUntilBlocked()
    let releaser = Task {
      await waitUntil { await h.engine.isShutdown }
      await gate.release()
    }
    await h.engine.shutdown()
    await releaser.value
    await refresh.value

    let itemPaths = h.http.requests
      .filter { $0.routeTemplate == "/api/libraries/:id/items" }
      .map(\.url.path)
    #expect(itemPaths == ["/api/libraries/lib1/items"])
  }

  /// A `.foreground` whose traversal outlives shutdown must not go on to its drain triggers: both
  /// would reach the outbox through this engine's playback boundary and upload drain after removal
  /// has quiesced them.
  @Test("shutdown suppresses the foreground outbox triggers")
  func shutdownSuppressesTheForegroundOutboxTrigger() async throws {
    let playback = FakePlaybackSyncing()
    let localDrains = DrainCallCounter()
    let h = try await Harness(localSessionUploadDrain: { localDrains.increment() }, playback: playback)
    // The launch drain fires each trigger once; settle it before counting.
    await playback.waitForCalls { Self.ordinaryTriggerCount($0) == 1 }
    await waitUntil { localDrains.value == 1 }
    let gate = HeldRequestGate()
    h.http.setRequestHook { request in
      if request.url.path == "/api/libraries" { await gate.blockFirstRequest() }
    }
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)

    let foreground = Task { await h.engine.handleLifecycleTransition(.foreground) }
    await gate.waitUntilBlocked()
    let releaser = Task {
      await waitUntil { await h.engine.isShutdown }
      await gate.release()
    }
    await h.engine.shutdown()
    await releaser.value
    await foreground.value

    #expect(Self.ordinaryTriggerCount(playback.calls) == 1)
    #expect(localDrains.value == 1)
  }

  /// The traversal runs in an engine-owned task so shutdown can reach it. Cancelling the caller
  /// that started it must still cancel it: SwiftUI cancels a `.refreshable` action when its view
  /// goes away.
  @Test("cancelling the caller that started a traversal still stops it")
  func cancellingTheStartingCallerStillStopsItsTraversal() async throws {
    let handOffs = DrainCallCounter()
    let h = try await Harness(pageLimit: 1, authorSeriesFilterDataRefresh: { handOffs.increment() })
    let gate = HeldRequestGate()
    h.http.setRequestHook { request in
      if request.url.path == "/api/libraries/lib1/items" { await gate.blockFirstRequest() }
    }
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "first", title: "First", author: nil)], total: 2, limit: 1, page: 0)
    h.enqueuePage(items: [(id: "second", title: "Second", author: nil)], total: 2, limit: 1, page: 1)

    let refresh = Task { await h.engine.refresh() }
    await gate.waitUntilBlocked()
    refresh.cancel()
    await gate.release()
    await refresh.value

    let itemPaths = h.http.requests
      .filter { $0.routeTemplate == "/api/libraries/:id/items" }
      .map(\.url.path)
    #expect(itemPaths == ["/api/libraries/lib1/items"])
    #expect(handOffs.value == 0)
  }

  private static func ordinaryTriggerCount(_ calls: [FakePlaybackSyncing.RecordedCall]) -> Int {
    calls.reduce(into: 0) { count, call in
      if case .notifyImmediateSyncTrigger = call { count += 1 }
    }
  }
}
