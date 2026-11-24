import Foundation
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// `ItemHistoryModel` is cache-then-refresh over `ListeningHistoryProviding`; construction never
/// blocks. Cached entries surface immediately; a background refresh updates them or, on failure,
/// degrades silently to the cache and flips `isStale`.
@Suite(.timeLimit(.minutes(1))) struct ItemHistoryModelTests {

  @MainActor
  @Test("cached entries surface immediately, before any refresh completes")
  func cachedEntriesSurfaceImmediately() async {
    let history = FakeListeningHistoryProviding()
    let cached = [Self.makeEntry(sessionId: "s-1")]
    history.setCached(itemId: "item-1", entries: cached)
    history.holdRefresh()

    let model = ItemHistoryModel(itemId: "item-1", category: .audiobook, history: history)
    await waitUntil { model.entries == cached }

    #expect(model.entries == cached)
    #expect(model.isStale == false)
  }

  @MainActor
  @Test("a successful refresh replaces entries with the freshly-cached set and clears isStale")
  func successfulRefreshUpdatesEntriesAndClearsStale() async {
    let history = FakeListeningHistoryProviding()
    history.setCached(itemId: "item-1", entries: [Self.makeEntry(sessionId: "s-old")])
    history.refreshResult = true
    history.holdRefresh()

    let model = ItemHistoryModel(itemId: "item-1", category: .audiobook, history: history)
    await waitUntil { model.entries.first?.sessionId == "s-old" }

    // Simulate the refresh actually writing fresher rows before it reports success.
    history.setCached(itemId: "item-1", entries: [Self.makeEntry(sessionId: "s-new")])
    history.releaseRefresh()

    await waitUntil { model.entries.first?.sessionId == "s-new" }
    #expect(model.isStale == false)
    #expect(history.refreshCalls == ["item-1"])
  }

  @MainActor
  @Test("a failed refresh degrades silently to the cache and sets isStale")
  func failedRefreshDegradesToCacheAndSetsStale() async {
    let history = FakeListeningHistoryProviding()
    let cached = [Self.makeEntry(sessionId: "s-1")]
    history.setCached(itemId: "item-1", entries: cached)
    history.refreshResult = false

    let model = ItemHistoryModel(itemId: "item-1", category: .audiobook, history: history)
    await waitUntil { model.isStale }

    #expect(model.entries == cached, "a refresh failure must never clear or replace the cached entries")
    #expect(model.isStale)
  }

  @MainActor
  @Test("construction never calls refresh synchronously - only the fire-and-forget task does")
  func constructionDoesNotBlockOnRefresh() {
    let history = FakeListeningHistoryProviding()

    // No `holdRefresh()` here: the assertion only needs "nothing ran yet on this synchronous call
    // stack", which holds regardless. Holding would leave a fake refresh parked forever, as
    // nothing in this test calls `releaseRefresh()`.
    _ = ItemHistoryModel(itemId: "item-1", category: .audiobook, history: history)

    #expect(history.refreshCalls.isEmpty, "refresh is invoked from the background task, not synchronously in init")
  }

  // MARK: - Ebooks have no listening history to fetch

  /// Listening sessions are created by the audio player. Reading an EPUB writes
  /// `ebookLocation`/`ebookProgress` through `PATCH /me/progress` and opens no session, so no
  /// session can ever carry an ebook-only item's id. `refreshListeningHistory` pages up to ten
  /// pages of fifty sessions and filters client-side, so asking on an ebook's behalf is a
  /// guaranteed-empty crawl of the whole account's history, once per visit to the tab.
  @MainActor
  @Test("an ebook asks the history provider for nothing at all")
  func ebookAsksTheHistoryProviderForNothing() async {
    let history = FakeListeningHistoryProviding()
    history.setCached(itemId: "item-ebook", entries: [Self.makeEntry(sessionId: "s-1")])

    let model = ItemHistoryModel(itemId: "item-ebook", category: .ebook, history: history)
    await waitUntil { model.tracksListeningHistory == false }

    #expect(history.refreshCalls.isEmpty)
    #expect(history.cachedCalls.isEmpty)
    #expect(model.entries.isEmpty)
    #expect(model.isStale == false, "an ebook is not stale - it has nothing to be stale about")
  }

  @MainActor
  @Test("a cold ebook remains history-free when its category arrives after construction")
  func coldEbookRemainsHistoryFreeAfterCategoryResolves() async {
    let history = FakeListeningHistoryProviding()
    let model = ItemHistoryModel(itemId: "item-ebook", category: nil, history: history)

    #expect(model.tracksListeningHistory == false)
    model.updateCategory(.ebook)
    await Task.yield()

    #expect(history.refreshCalls.isEmpty)
    #expect(history.cachedCalls.isEmpty)
    #expect(model.tracksListeningHistory == false)
  }

  @MainActor
  @Test("an audiobook still reads the cache and refreshes")
  func audiobookStillReadsTheCacheAndRefreshes() async {
    let history = FakeListeningHistoryProviding()
    let cached = [Self.makeEntry(sessionId: "s-1")]
    history.setCached(itemId: "item-1", entries: cached)
    history.refreshResult = true

    let model = ItemHistoryModel(itemId: "item-1", category: .audiobook, history: history)
    await waitUntil { history.refreshCalls == ["item-1"] }

    #expect(model.tracksListeningHistory)
    #expect(model.entries == cached)
  }

  @MainActor
  @Test("explicit refresh drains uploads before walking and republishes each page")
  func explicitRefreshDrainsBeforeWalkAndPublishesPages() async {
    let history = FakeListeningHistoryProviding()
    history.holdRefresh()
    let model = ItemHistoryModel(itemId: "item-1", category: .audiobook, history: history)
    await waitUntil { history.refreshCalls.count == 1 }
    history.releaseRefresh()
    await model.refresh()
    history.clearRefreshCallsAndEvents()

    let first = Self.makeEntry(sessionId: "s-1")
    let second = Self.makeEntry(sessionId: "s-2")
    history.pageEntries = [[first], [first, second]]
    history.holdRefresh()
    let refreshedModel = ItemHistoryModel(
      itemId: "item-2", category: .audiobook, history: history,
      uploadDrain: {
        history.recordEvent("drain")
      })
    await waitUntil { history.refreshCalls.count == 1 }
    history.releaseRefresh()
    await refreshedModel.refresh()
    history.clearRefreshCallsAndEvents()

    await refreshedModel.refresh()
    #expect(history.events == ["drain", "walk"])
    #expect(history.pagePersistedCount == 2)
    #expect(refreshedModel.entries == [first, second])
    #expect(history.refreshCalls.count == 1)
  }

  @MainActor
  @Test("concurrent explicit refreshes coalesce to one walk")
  func concurrentRefreshesCoalesce() async {
    let history = FakeListeningHistoryProviding()
    let model = ItemHistoryModel(itemId: "item-1", category: .audiobook, history: history)
    await waitUntil { history.refreshCalls.count == 1 }
    await model.refresh()
    history.holdRefresh()
    history.clearRefreshCallsAndEvents()

    async let first = model.refresh()
    async let second = model.refresh()
    await waitUntil { history.refreshCalls.count == 1 }
    history.releaseRefresh()
    await first
    await second
    #expect(history.refreshCalls == ["item-1"])
  }

  @MainActor
  @Test("a refresh arriving during init's drain-less walk still drains once that walk finishes")
  func refreshDuringInitWalkStillDrains() async {
    let history = FakeListeningHistoryProviding()
    history.holdRefresh()
    let model = ItemHistoryModel(
      itemId: "item-1", category: .audiobook, history: history,
      uploadDrain: { history.recordEvent("drain") })
    // `init`'s walk is in flight and, by design, never drains.
    await waitUntil { history.refreshCalls.count == 1 }
    #expect(history.events.contains("drain") == false)

    async let tabSelection: Void = model.refresh()
    history.releaseRefresh()
    await tabSelection

    // Coalescing onto the in-flight walk would skip the drain entirely, which the History tab
    // depends on: a session that finished moments ago is still sitting in the upload outbox.
    #expect(history.events.contains("drain"))
    #expect(history.refreshCalls.count == 2)
  }

  @MainActor
  @Test("a category flip to ebook while awaiting a coalesced refresh does not restart the walk")
  func categoryFlipDuringCoalescedRefreshDoesNotRestart() async {
    let history = FakeListeningHistoryProviding()
    history.setCached(itemId: "item-1", entries: [Self.makeEntry(sessionId: "s-1")])
    history.holdRefresh()
    let model = ItemHistoryModel(itemId: "item-1", category: .audiobook, history: history)
    await waitUntil { history.refreshCalls.count == 1 }

    // The caller coalesces onto init's drain-less walk and would normally fall through to a
    // drained walk of its own once that finishes.
    async let waiting: Void = model.refresh()
    await Task.yield()
    model.updateCategory(.ebook)
    history.releaseRefresh()
    await waiting

    #expect(history.refreshCalls == ["item-1"], "an ebook must not get a fresh history walk")
    #expect(model.entries.isEmpty)
    #expect(model.isStale == false)
  }

  @MainActor
  @Test("a walk cancelled by the ebook flip publishes nothing when it completes anyway")
  func cancelledWalkPublishesNothingAfterEbookFlip() async {
    let history = FakeListeningHistoryProviding()
    history.setCached(itemId: "item-1", entries: [Self.makeEntry(sessionId: "s-1")])
    history.pageEntries = [[Self.makeEntry(sessionId: "s-2")]]
    history.holdRefresh()
    let model = ItemHistoryModel(itemId: "item-1", category: .audiobook, history: history)
    await waitUntil { model.entries.isEmpty == false }

    model.updateCategory(.ebook)
    #expect(model.entries.isEmpty)

    // The provider does not honour cancellation: the held walk resumes, persists its page, and
    // reports success. None of that may reach an item that no longer tracks history.
    history.releaseRefresh()
    await waitUntil { history.pagePersistedCount == 1 }
    await Task.yield()

    #expect(model.entries.isEmpty, "a cancelled walk must not republish listening history")
    #expect(model.isStale == false)
  }

  // MARK: - Helpers

  private static func makeEntry(sessionId: String) -> ListeningHistoryEntry {
    ListeningHistoryEntry(
      sessionId: sessionId, startedAt: Date(timeIntervalSince1970: 1_700_000_000), startPosition: 0,
      endPosition: 100, listenedSeconds: 100)
  }
}

/// Minimal mutex, local to this file (mirrors `TestSupport.Locked`, which is internal to that
/// target and so cannot be reused across a different test target).
private final class HistoryModelTestLock<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) { storage = value }

  @discardableResult
  func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&storage)
  }
}

/// Test-only `ListeningHistoryProviding`: `holdRefresh()`/`releaseRefresh()` let a test observe
/// the cache-first emission before the refresh resolves.
final class FakeListeningHistoryProviding: ListeningHistoryProviding, @unchecked Sendable {
  private struct State {
    var cachedByItemId: [String: [ListeningHistoryEntry]] = [:]
    var refreshResult = true
    var refreshCalls: [String] = []
    var cachedCalls: [String] = []
    var pageEntries: [[ListeningHistoryEntry]] = []
    var events: [String] = []
    var pagePersistedCount = 0
  }
  private let state = HistoryModelTestLock(State())
  // The refresh runs to completion regardless of cancellation, so a cancelled one stays parked.
  private let refreshGate = TestGate<Void>(
    label: "FakeListeningHistoryProviding refresh", ignoresCancellation: true)

  var refreshResult: Bool {
    get { state.withValue { $0.refreshResult } }
    set { state.withValue { $0.refreshResult = newValue } }
  }
  var refreshCalls: [String] { state.withValue { $0.refreshCalls } }
  var cachedCalls: [String] { state.withValue { $0.cachedCalls } }

  var events: [String] { state.withValue { $0.events } }
  var pagePersistedCount: Int { state.withValue { $0.pagePersistedCount } }

  func clearRefreshCallsAndEvents() {
    state.withValue {
      $0.refreshCalls.removeAll()
      $0.events.removeAll()
      $0.pagePersistedCount = 0
    }
  }

  func recordEvent(_ event: String) {
    state.withValue { $0.events.append(event) }
  }

  func setCached(itemId: String, entries: [ListeningHistoryEntry]) {
    state.withValue { $0.cachedByItemId[itemId] = entries }
  }

  func holdRefresh() {
    refreshGate.hold()
  }

  func releaseRefresh() {
    refreshGate.release()
  }

  func cachedListeningHistory(itemId: String) async -> [ListeningHistoryEntry] {
    state.withValue {
      $0.cachedCalls.append(itemId)
      return $0.cachedByItemId[itemId] ?? []
    }
  }

  var pageEntries: [[ListeningHistoryEntry]] {
    get { state.withValue { $0.pageEntries } }
    set { state.withValue { $0.pageEntries = newValue } }
  }

  func refreshListeningHistory(
    itemId: String, onPagePersisted: @escaping @Sendable () async -> Void
  ) async -> Bool {
    state.withValue {
      $0.refreshCalls.append(itemId)
      $0.events.append("walk")
    }
    await refreshGate.pass()
    let pages = state.withValue { $0.pageEntries }
    for page in pages {
      setCached(itemId: itemId, entries: page)
      state.withValue { $0.pagePersistedCount += 1 }
      await onPagePersisted()
    }
    return state.withValue { $0.refreshResult }
  }
}
