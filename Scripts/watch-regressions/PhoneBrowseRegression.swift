import Foundation
import WatchPlayback
import WatchProtocol

@MainActor
private final class PhoneBrowseHarness {
  struct Call {
    let scope: WatchBrowseScope
    let page: Int
    let sort: WatchBrowseEpisodeSort
    let played: WatchBrowsePlayedFilter
    let generation: UInt64?
    let source: WatchBrowseSource?
  }

  let originalStamp = try! WatchAccountStamp(accountIdentityHash: "account-a", serverIdentityHash: "server-a")
  var stamp: WatchAccountStamp?
  var calls: [Call] = []
  private var waiters: [Int: CheckedContinuation<WatchBrowseResult, Never>] = [:]

  init() { stamp = originalStamp }

  func model(scope: WatchBrowseScope = .shows, source: WatchBrowseSource? = nil) -> WatchPhoneBrowseModel {
    WatchPhoneBrowseModel(
      scope: scope, source: source, accountStamp: originalStamp, currentAccountStamp: { self.stamp },
      loader: { scope, source, page, sort, played, generation in
        let index = self.calls.count
        self.calls.append(
          Call(scope: scope, page: page, sort: sort, played: played, generation: generation, source: source))
        return await withCheckedContinuation { self.waiters[index] = $0 }
      })
  }

  func waitForCalls(_ count: Int) async {
    await hostAwait(
      "phone browse request \(count)", observing: { "\(calls.count) calls" }, until: { calls.count == count })
  }

  func finish(_ index: Int, _ result: WatchBrowseResult) {
    guard let waiter = waiters.removeValue(forKey: index) else { preconditionFailure("unknown request") }
    waiter.resume(returning: result)
  }
}

@main
struct PhoneBrowseRegression {
  @MainActor
  static func main() async throws {
    await catalogueLoadMoreDoubleTap()
    await duplicatePagesAndDoubleTap()
    await staleGenerationRestartsOnRetry()
    await ordinaryFailureRetriesSamePage()
    await initialFailureRetriesPageZero()
    await accountChangeDiscardsResponse()
    await accountRoundTripFencesOldRequests()
    await accountFencePrecedesChangeNotification()
    await scopePreferencesAndRefresh()
    await podcastDefaultAndFilterChange()
    await sourceReachesLoaderAndForeignRowsDrop()
    chapterProgressIsRelativeAndFallsBackSafely()
    displayFormattingClampsAndDropsEmptyParts()
    commandFeedbackHidesTransportDetails()
    playbackRateChoicesPreserveActualSpeed()
    print("watch phone browse regressions passed")
  }

  private static func chapterProgressIsRelativeAndFallsBackSafely() {
    let chapter = WatchDisplayFormatting.playbackProgress(
      position: 1800, duration: 7200, chapterStart: 1500, chapterEnd: 2400)
    precondition(chapter.elapsed == 300 && chapter.duration == 900 && chapter.isChapter)
    let end = WatchDisplayFormatting.playbackProgress(
      position: 2400, duration: 7200, chapterStart: 1500, chapterEnd: 2400)
    precondition(end.elapsed == 900 && end.isChapter)
    for bounds: (Double?, Double?) in [(nil, nil), (2000, 2400), (1500, 1700), (1500, .nan), (1500, 8000)] {
      let fallback = WatchDisplayFormatting.playbackProgress(
        position: 1800, duration: 7200, chapterStart: bounds.0, chapterEnd: bounds.1)
      precondition(fallback.elapsed == 1800 && fallback.duration == 7200 && !fallback.isChapter)
    }
    let unknown = WatchDisplayFormatting.playbackProgress(
      position: .nan, duration: nil, chapterStart: nil, chapterEnd: nil)
    precondition(unknown.elapsed == 0 && unknown.duration == nil && !unknown.isChapter)
  }

  private static func commandFeedbackHidesTransportDetails() {
    for outcome in [WatchCommandOutcome.sent, .busy, .unresolved] {
      let message: String? = outcome.statusDescription()
      precondition(message == nil, "transport bookkeeping must not produce listener-facing copy")
    }
    for outcome in [WatchCommandOutcome.phoneUnavailable, .rejected(.audioActivationFailed)] {
      let message: String? = outcome.statusDescription()
      precondition(message?.isEmpty == false, "a blocked action should retain a concrete recovery step")
    }
  }

  private static func playbackRateChoicesPreserveActualSpeed() {
    let rates = WatchDisplayFormatting.playbackRates(current: 1.35)
    precondition(rates.contains(1.35) && rates == rates.sorted())
    precondition(WatchDisplayFormatting.playbackRates(current: 1).filter { $0 == 1 }.count == 1)
    precondition(WatchDisplayFormatting.playbackRates(current: 4).last == 4)
    precondition(WatchDisplayFormatting.playbackRates(current: nil) == [0.75, 1, 1.25, 1.5, 1.75, 2])
    let presets = [0.9, 1.0, 1.1, 1.35]
    precondition(WatchDisplayFormatting.playbackRates(current: 1.35, presets: presets) == presets)
    precondition(WatchDisplayFormatting.playbackRates(current: 1.2, presets: presets) == [0.9, 1, 1.1, 1.2, 1.35])
    precondition(WatchDisplayFormatting.skipInterval(snapshot: nil, forward: false) == 15)
    precondition(WatchDisplayFormatting.skipInterval(snapshot: nil, forward: true) == 30)
    let snapshot = try! WatchCatalogueSnapshot(
      accountStamp: WatchAccountStamp(accountIdentityHash: "preferences", serverIdentityHash: "phone"),
      items: [], skipBackwardSeconds: 10, skipForwardSeconds: 45,
      playbackRatePresets: presets)
    precondition(WatchDisplayFormatting.skipInterval(snapshot: snapshot, forward: false) == 10)
    precondition(WatchDisplayFormatting.skipInterval(snapshot: snapshot, forward: true) == 45)
  }

  private static func row(_ id: String) -> WatchBrowseRow {
    .show(try! WatchBrowseShowRow(id: .nativeFeed(feedID: id), title: id))
  }

  private static func page(_ ids: [String], page: Int = 0, next: Int? = nil, generation: UInt64 = 1)
    -> WatchBrowseResult
  {
    .page(
      try! WatchBrowsePage(
        page: page, pageSize: 50, rows: ids.map(row), nextPage: next, isComplete: next == nil, generation: generation))
  }

  private static func failure(_ code: WatchBrowseErrorCode) -> WatchBrowseResult {
    .failure(try! WatchBrowseError(code: code, message: "Try this request again.", retryable: true))
  }

  @MainActor
  private static func catalogueLoadMoreDoubleTap() async {
    let harness = CataloguePageHarness()
    let model = WatchBrowseModel(clientProvider: { nil })
    let first = Task {
      await model.loadCatalogue(libraryID: "library") { _, page, _ in
        await harness.load(page)
      }
    }
    await harness.waitForCalls(1)
    await harness.finish(0)
    await first.value
    precondition(model.books.map(\.id) == ["page-0"] && model.hasMore)
    let second = Task { await model.loadMore() }
    await harness.waitForCalls(2)
    await model.loadMore()
    let pendingPages = await harness.pages
    precondition(pendingPages == [0, 1], "double tap duplicated or skipped catalogue page one")
    await harness.finish(1)
    await second.value
    let loadedPages = await harness.pages
    precondition(loadedPages == [0, 1])
    precondition(model.books.map(\.id) == ["page-0", "page-1"], "page one was not appended exactly once")
  }

  @MainActor
  private static func duplicatePagesAndDoubleTap() async {
    let harness = PhoneBrowseHarness()
    let model = harness.model()
    let first = Task { await model.refresh() }
    await harness.waitForCalls(1)
    precondition(model.isLoading && model.rows.isEmpty && !model.loaded)
    await model.loadMore()
    await model.retry()
    await model.refresh()
    precondition(harness.calls.count == 1, "concurrent actions issued duplicate requests")
    harness.finish(0, page(["one", "two"], next: 1))
    await first.value
    let second = Task { await model.loadMore() }
    await harness.waitForCalls(2)
    await model.loadMore()
    precondition(harness.calls.count == 2, "second load-more tap duplicated page one")
    precondition(harness.calls[1].page == 1 && harness.calls[1].generation == 1)
    harness.finish(1, page(["two", "three"], page: 1))
    await second.value
    precondition(model.rows == [row("one"), row("two"), row("three")], "duplicate page rows were appended")
    precondition(model.phase == .loaded && !model.hasMore && model.loaded)
  }

  @MainActor
  private static func staleGenerationRestartsOnRetry() async {
    let harness = PhoneBrowseHarness()
    let model = harness.model()
    let first = Task { await model.refresh() }
    await harness.waitForCalls(1)
    harness.finish(0, page(["old"], next: 1, generation: 4))
    await first.value
    let stale = Task { await model.loadMore() }
    await harness.waitForCalls(2)
    harness.finish(1, failure(.staleGeneration))
    await stale.value
    precondition(model.phase == .failed && model.loaded && model.rows == [row("old")])
    precondition(model.generation == nil && !model.hasMore)
    let retry = Task { await model.retry() }
    await harness.waitForCalls(3)
    precondition(harness.calls[2].page == 0 && harness.calls[2].generation == nil)
    precondition(model.rows.isEmpty && model.message == nil && !model.loaded)
    harness.finish(2, page(["fresh"], generation: 5))
    await retry.value
    precondition(model.rows == [row("fresh")] && model.generation == 5 && model.phase == .loaded)
  }

  @MainActor
  private static func ordinaryFailureRetriesSamePage() async {
    let harness = PhoneBrowseHarness()
    let model = harness.model()
    let first = Task { await model.refresh() }
    await harness.waitForCalls(1)
    harness.finish(0, page(["one"], next: 1, generation: 7))
    await first.value
    let next = Task { await model.loadMore() }
    await harness.waitForCalls(2)
    harness.finish(1, failure(.retryable))
    await next.value
    precondition(model.message == "Try loading these titles again." && model.phase == .failed)
    precondition(model.rows == [row("one")] && model.nextPage == 1 && model.generation == 7 && model.loaded)
    let retry = Task { await model.retry() }
    await harness.waitForCalls(3)
    precondition(harness.calls[2].page == 1 && harness.calls[2].generation == 7)
    precondition(model.rows == [row("one")] && model.message == nil)
    harness.finish(2, page(["two"], page: 1, generation: 7))
    await retry.value
    precondition(model.rows == [row("one"), row("two")] && model.phase == .loaded)
  }

  @MainActor
  private static func initialFailureRetriesPageZero() async {
    let harness = PhoneBrowseHarness()
    let model = harness.model()
    let first = Task { await model.refresh() }
    await harness.waitForCalls(1)
    harness.finish(0, failure(.phoneUnavailable))
    await first.value
    precondition(model.phase == .failed && !model.loaded && !model.isLoading)
    let retry = Task { await model.retry() }
    await harness.waitForCalls(2)
    precondition(harness.calls[1].page == 0 && harness.calls[1].generation == nil)
    harness.finish(1, page([]))
    await retry.value
    precondition(model.phase == .loaded && model.rows.isEmpty && model.loaded && model.message == nil)
  }

  @MainActor
  private static func accountChangeDiscardsResponse() async {
    let harness = PhoneBrowseHarness()
    let model = harness.model()
    let old = Task { await model.refresh() }
    await harness.waitForCalls(1)
    harness.stamp = try! WatchAccountStamp(accountIdentityHash: "account-b", serverIdentityHash: "server-a")
    model.accountChanged()
    precondition(model.rows.isEmpty && !model.loaded && !model.hasMore && !model.isLoading)
    precondition(model.generation == nil && model.phase == .failed)
    let message = model.message
    precondition(message == "The account changed. Return to Podcasts to continue.")
    await model.retry()
    await model.refresh()
    await model.loadMore()
    precondition(harness.calls.count == 1, "an old destination requested the new account")
    harness.finish(0, page(["old"]))
    await old.value
    precondition(model.rows.isEmpty && model.message == message && model.phase == .failed)
  }

  @MainActor
  private static func accountRoundTripFencesOldRequests() async {
    // Both a late success and a late failure must leave a newer request and its phase alone.
    for oldResult in [page(["old"]), failure(.staleGeneration)] {
      let harness = PhoneBrowseHarness()
      let model = harness.model()
      let old = Task { await model.refresh() }
      await harness.waitForCalls(1)
      harness.stamp = nil
      model.accountChanged()
      harness.stamp = harness.originalStamp
      model.accountChanged()
      let current = Task { await model.retry() }
      await harness.waitForCalls(2)
      harness.finish(0, oldResult)
      await old.value
      precondition(model.isLoading && model.rows.isEmpty && model.message == nil, "old response changed active request")
      harness.finish(1, page(["current"], generation: 2))
      await current.value
      precondition(model.rows == [row("current")] && model.generation == 2 && model.phase == .loaded)
    }
  }

  @MainActor
  private static func accountFencePrecedesChangeNotification() async {
    let harness = PhoneBrowseHarness()
    let model = harness.model()
    let old = Task { await model.refresh() }
    await harness.waitForCalls(1)
    harness.stamp = nil
    // Simulate the reply arriving before SwiftUI delivers the account change callback.
    harness.finish(0, page(["old"]))
    await old.value
    precondition(model.rows.isEmpty && !model.loaded && !model.isLoading && model.generation == nil)
    model.accountChanged()
    precondition(model.phase == .failed)
  }

  @MainActor
  private static func scopePreferencesAndRefresh() async {
    for scope in [WatchBrowseScope.latestEpisodes, .shows, .episodes(show: .nativeFeed(feedID: "feed"))] {
      let harness = PhoneBrowseHarness()
      let model = harness.model(scope: scope)
      let first = Task { await model.refresh(sort: .oldest, filter: .unplayed) }
      await harness.waitForCalls(1)
      let call = harness.calls[0]
      precondition(call.scope == scope && call.page == 0 && call.generation == nil)
      precondition(call.sort == (scope == .latestEpisodes ? .newest : .oldest))
      precondition(call.played == (scope == .shows ? .all : .unplayed))
      harness.finish(0, page(["old"], next: 1, generation: 3))
      await first.value
      let refresh = Task { await model.refresh() }
      await harness.waitForCalls(2)
      precondition(harness.calls[1].page == 0 && harness.calls[1].generation == nil)
      precondition(harness.calls[1].sort == call.sort && harness.calls[1].played == call.played)
      precondition(model.rows.isEmpty && !model.loaded && !model.hasMore)
      harness.finish(1, page(["fresh"], generation: 4))
      await refresh.value
      precondition(model.rows == [row("fresh")])
    }
  }

  /// A list for one source asks the phone for that source, and drops any row of the other source
  /// that an older phone, which ignores the request's source, still returns.
  @MainActor
  private static func sourceReachesLoaderAndForeignRowsDrop() async {
    let abs = WatchBrowseRow.show(try! WatchBrowseShowRow(id: .audiobookshelf(itemID: "abs"), title: "abs"))
    let rss = WatchBrowseRow.show(try! WatchBrowseShowRow(id: .nativeFeed(feedID: "rss"), title: "rss"))
    let mixed = WatchBrowseResult.page(
      try! WatchBrowsePage(page: 0, pageSize: 50, rows: [abs, rss], nextPage: nil, isComplete: true, generation: 1))
    for (source, kept) in [
      (WatchBrowseSource.audiobookshelf, [abs]), (.nativeFeed, [rss]), (nil, [abs, rss]),
    ] as [(WatchBrowseSource?, [WatchBrowseRow])] {
      let harness = PhoneBrowseHarness()
      let model = harness.model(scope: .shows, source: source)
      let load = Task { await model.refresh() }
      await harness.waitForCalls(1)
      precondition(harness.calls[0].source == source)
      harness.finish(0, mixed)
      await load.value
      precondition(model.rows == kept && model.loaded)
    }
  }

  private static func displayFormattingClampsAndDropsEmptyParts() {
    print(
      "Formatter deliberately changes earlier behavior: clamp negative or non-finite durations and drop empty metadata parts"
    )
    precondition(WatchDisplayFormatting.clock(0) == "0:00:00")
    precondition(WatchDisplayFormatting.clock(60) == "0:01:00")
    precondition(WatchDisplayFormatting.duration(3661) == "1:01:01")
    precondition(WatchDisplayFormatting.remaining(61) == "0:01:01 remaining")
    for invalid in [Double.nan, .infinity, -.infinity, -1] {
      precondition(WatchDisplayFormatting.clock(invalid) == "0:00:00")
    }
    precondition(WatchDisplayFormatting.metadata([nil, "Show", "", "1:00:00"]) == "Show · 1:00:00")
    precondition(WatchDisplayFormatting.metadata([nil, ""]) == "")
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    // Pinned POSIX/GMT, as the app's own boundary-date test pins it: 2023-11-14T22:13:20Z.
    precondition(WatchDisplayFormatting.date(date) == "Nov 14, 2023")
  }

  @MainActor
  private static func podcastDefaultAndFilterChange() async {
    let harness = PhoneBrowseHarness()
    let model = harness.model(scope: .latestEpisodes)
    let initial = Task { await model.refresh() }
    await harness.waitForCalls(1)
    precondition(harness.calls[0].played.rawValue == "inProgress", "podcasts should open on In Progress")
    harness.finish(0, page(["started"], next: 1, generation: 7))
    await initial.value
    let change = Task { await model.refresh(sort: .newest, filter: .unplayed) }
    await harness.waitForCalls(2)
    precondition(harness.calls[1].played == .unplayed && harness.calls[1].generation == nil)
    precondition(model.rows.isEmpty && !model.hasMore, "filter changes must discard the previous cursor")
    harness.finish(1, page(["new"], generation: 8))
    await change.value
    precondition(model.rows == [row("new")] && model.generation == 8)
  }
}

private actor CataloguePageHarness {
  private(set) var pages: [Int] = []
  private var waiters: [Int: CheckedContinuation<WatchLibraryPage, Never>] = [:]

  func load(_ page: Int) async -> WatchLibraryPage {
    pages.append(page)
    return await withCheckedContinuation { waiters[page] = $0 }
  }

  func waitForCalls(_ count: Int) async {
    await hostAwait("catalogue page \(count)", observing: { "\(pages.count) pages" }, until: { pages.count == count })
  }

  func finish(_ page: Int) {
    let id = "page-\(page)"
    let item = WatchLibraryItem(
      id: id, libraryID: "library", kind: .audiobook, title: id, author: nil,
      selection: .audiobookshelf(itemID: id, episodeID: nil), durationSeconds: nil, episodeCount: nil)
    guard let waiter = waiters.removeValue(forKey: page) else { preconditionFailure("unknown page") }
    waiter.resume(returning: WatchLibraryPage(items: [item], total: 80, limit: 40, page: page))
  }
}
