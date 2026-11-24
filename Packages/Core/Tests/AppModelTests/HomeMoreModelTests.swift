import Foundation
import Observation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite struct HomeMoreModelTests {
  @MainActor
  @Test("new content uses a seven-day cutoff")
  func newContentUsesSevenDayCutoff() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(HomeRecency.cutoff(now: now) == now.addingTimeInterval(-7 * 24 * 60 * 60))
  }

  @MainActor
  @Test("podcast detail observes recent episodes instead of show items")
  func podcastRecentEpisodesAreTheMoreContent() async {
    let reading = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let native = FakeNativeLatestReading()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let model = HomeMoreModel(
      section: .recentlyAdded, filter: .podcasts, home: reading, sync: sync,
      nativeLatestEpisodes: native,
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true), now: { now })

    await waitUntil { reading.newPodcastEpisodeCalls.isEmpty == false }

    #expect(reading.newPodcastEpisodeCalls.last?.since == HomeRecency.cutoff(now: now))
    #expect(reading.recentlyAddedSinceCalls.isEmpty)

    let serverTwin = HomePodcastEpisode(
      itemID: "show", showTitle: "Signal House", showAuthor: "Host",
      episodeID: "server-twin", title: "Server Twin", subtitle: nil,
      publishedAt: now.addingTimeInterval(10), durationSeconds: 1_200)
    let serverOnly = HomePodcastEpisode(
      itemID: "show", showTitle: "Signal House", showAuthor: "Host",
      episodeID: "server-only", title: "Server Only", subtitle: nil,
      publishedAt: now, durationSeconds: 1_200)
    let nativeTwin = HomePodcastEpisode(
      itemID: "rss:1", showTitle: "Signal House", showAuthor: "Host",
      episodeID: "native", title: "Native Twin", subtitle: nil,
      publishedAt: now.addingTimeInterval(5), durationSeconds: 1_200)
    reading.pushNewPodcastEpisodes(
      HomeLatestPodcastEpisodesSnapshot(
        all: [serverTwin, serverOnly], nativePreferred: [serverOnly]))
    native.push([nativeTwin])
    await waitUntil { model.state != .loading }

    #expect(model.section == .newEpisodes)
    #expect(model.state == .loaded)
    #expect(model.podcastEpisodes == [nativeTwin, serverOnly])
    #expect(model.items.isEmpty)
  }

  @MainActor
  @Test("Continue Listening waits for ABS, RSS, and the gate, then merges and suppresses duplicates")
  func mergedContinueListeningReadinessOrderingAndDuplicates() async {
    let abs = FakeHomeReading()
    let rss = FakeNativeContinueReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
    let model = HomeMoreModel(
      section: .continueListening, filter: .podcasts, home: abs,
      sync: FakeSyncCoordinating(), nativeContinueListening: rss,
      nativeSubscriptions: subscriptions)
    let changes = ContentChangeCounter(model: model)
    let older = Self.item(id: "abs", episodeID: "older", recency: 100)
    let newer = Self.item(id: "rss:1", episodeID: "newer", recency: 200)

    abs.pushContinueListening([older])
    await Task.yield()
    #expect(model.state == .loading)
    #expect(changes.count == 0)

    rss.push([newer])
    await waitUntil { model.state == .loaded }
    await waitUntil { changes.count == 1 }
    #expect(model.items == [newer, older])
    #expect(changes.count == 1)

    rss.push([newer])
    await awaitQuiescence(
      "the duplicate Continue Listening projection to remain suppressed",
      of: { "state=\(model.state), changes=\(changes.count)" })
    #expect(changes.count == 1)
  }

  @MainActor
  @Test("Continue Listening gate removes RSS rows and ignores later RSS-only changes")
  func continueListeningHonorsNativeSubscriptionsGate() async {
    let abs = FakeHomeReading()
    let rss = FakeNativeContinueReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
    let model = HomeMoreModel(
      section: .continueListening, filter: .all, home: abs,
      sync: FakeSyncCoordinating(), nativeContinueListening: rss,
      nativeSubscriptions: subscriptions)
    let server = Self.item(id: "abs", episodeID: "server", recency: 100)
    let native = Self.item(id: "rss:1", episodeID: "native", recency: 200)

    abs.pushContinueListening([server])
    rss.push([native])
    await waitUntil { model.items.count == 2 }

    await subscriptions.setEnabled(false)
    await waitUntil { model.items == [server] }

    rss.push([Self.item(id: "rss:2", episodeID: "later", recency: 300)])
    await awaitQuiescence(
      "the disabled Continue Listening RSS projection to remain ignored",
      of: { "items=\(model.items.map(\.serverItemId))" })
    #expect(model.items == [server])
  }

  @MainActor
  @Test("Continue Listening applies its limit after merging and deduplicating")
  func continueListeningAppliesLimitAfterMerge() async {
    let abs = FakeHomeReading()
    let rss = FakeNativeContinueReading()
    let model = HomeMoreModel(
      section: .continueListening, filter: .podcasts, home: abs,
      sync: FakeSyncCoordinating(), nativeContinueListening: rss,
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))
    let rssItems = (0..<100).map { offset in
      Self.item(
        id: "rss:\(offset)", episodeID: "episode-\(offset)",
        recency: TimeInterval(1_000 - offset))
    }
    let duplicate = Self.item(id: "rss:0", episodeID: "episode-0", recency: 1_000)

    abs.pushContinueListening([duplicate])
    rss.push(rssItems)
    await waitUntil { model.items.count == 100 }

    #expect(model.items.count == 100)
    #expect(model.items.last?.serverItemId == "rss:99")
  }

  @MainActor
  @Test("Continue Listening non-podcast filters retain the single ABS stream")
  func continueListeningNonPodcastFilterDoesNotOpenNativeStreams() async {
    let native = FakeNativeContinueReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
    let reading = FakeHomeReading()
    let model = HomeMoreModel(
      section: .continueListening, filter: .audiobooks, home: reading,
      sync: FakeSyncCoordinating(), nativeContinueListening: native,
      nativeSubscriptions: subscriptions)

    reading.pushContinueListening([])
    await waitUntil { model.state != .loading }
    #expect(reading.continueListeningCalls.count == 1)
    #expect(native.observeCallCount == 0)
    #expect(subscriptions.observeEnabledCallCount == 0)
  }

  @MainActor
  @Test("disabling native subscriptions removes RSS rows and re-enabling restores them")
  func latestEpisodesHonorNativeSubscriptionsGate() async {
    let abs = FakeHomeReading()
    let rss = FakeNativeLatestReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
    let model = HomeMoreModel(
      section: .newEpisodes, filter: .podcasts, home: abs, sync: FakeSyncCoordinating(),
      nativeLatestEpisodes: rss, nativeSubscriptions: subscriptions)
    let serverEpisode = Self.episode(itemID: "abs", episodeID: "server", publishedAt: 100)
    let nativeEpisode = Self.episode(itemID: "rss:1", episodeID: "native", publishedAt: 200)

    abs.pushNewPodcastEpisodes(
      HomeLatestPodcastEpisodesSnapshot(all: [serverEpisode], nativePreferred: []))
    rss.push([nativeEpisode])
    await waitUntil { model.podcastEpisodes == [nativeEpisode] }

    await subscriptions.setEnabled(false)
    await waitUntil { model.podcastEpisodes == [serverEpisode] }

    await subscriptions.setEnabled(true)
    await waitUntil { model.podcastEpisodes == [nativeEpisode] }
  }

  @MainActor
  @Test("Recently Added All waits for snapshot and gate, then switches policies live")
  func recentlyAddedAllUsesTwoSourceBarrier() async {
    let reading = FakeHomeReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: nil)
    let model = HomeMoreModel(
      section: .recentlyAdded, filter: .all, home: reading, sync: FakeSyncCoordinating(),
      nativeSubscriptions: subscriptions)
    let twin = Self.item(id: "twin")
    let unmatched = Self.item(id: "unmatched")

    reading.pushRecentlyAdded(
      HomeRecentlyAddedSnapshot(all: [twin, unmatched], nativePreferred: [unmatched]))
    await Task.yield()
    #expect(model.state == .loading)

    subscriptions.stubEnabled(true)
    await waitUntil { model.items == [unmatched] }
    subscriptions.stubEnabled(false)
    await waitUntil { model.items == [twin, unmatched] }
  }

  @MainActor
  @Test("a finite empty native gate settles as disabled")
  func finiteEmptyGateSettlesAsDisabled() async {
    let reading = FakeHomeReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: nil)
    subscriptions.finishObservations()
    let model = HomeMoreModel(
      section: .recentlyAdded, filter: .all, home: reading, sync: FakeSyncCoordinating(),
      nativeSubscriptions: subscriptions)
    let server = Self.item(id: "server")

    reading.pushRecentlyAdded(
      HomeRecentlyAddedSnapshot(all: [server], nativePreferred: []))
    await waitUntil { model.state != .loading }

    #expect(model.items == [server])
  }

  @MainActor
  @Test("Latest Episodes waits for all sources, merges by date, and suppresses duplicate merges")
  func mergedLatestEpisodesReadinessAndInvalidation() async {
    let abs = FakeHomeReading()
    let rss = FakeNativeLatestReading()
    let model = HomeMoreModel(
      section: .newEpisodes, filter: .podcasts, home: abs, sync: FakeSyncCoordinating(),
      nativeLatestEpisodes: rss)
    let changes = ContentChangeCounter(model: model)
    let older = Self.episode(itemID: "abs", episodeID: "older", publishedAt: 100)
    let newer = Self.episode(itemID: "rss:1", episodeID: "newer", publishedAt: 200)

    abs.pushNewPodcastEpisodes([older])
    await Task.yield()
    #expect(model.state == .loading)
    #expect(changes.count == 0)

    rss.push([newer])
    await waitUntil { model.state == .loaded }
    await waitUntil { changes.count == 1 }
    #expect(model.podcastEpisodes.map(\.id) == [newer.id, older.id])
    #expect(changes.count == 1)

    rss.push([newer])
    await awaitQuiescence(
      "the duplicate Latest Episodes projection to remain suppressed",
      of: { "state=\(model.state), changes=\(changes.count)" })
    #expect(changes.count == 1)
  }

  @MainActor
  @Test("book detail observes recently added items with the same cutoff")
  func bookRecentlyAddedUsesCutoff() async {
    let reading = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let model = HomeMoreModel(
      section: .recentlyAdded, filter: .audiobooks, home: reading, sync: sync, now: { now })

    await waitUntil { reading.recentlyAddedSinceCalls.isEmpty == false }

    #expect(reading.recentlyAddedSinceCalls.last?.category == .audiobook)
    #expect(reading.recentlyAddedSinceCalls.last?.since == HomeRecency.cutoff(now: now))

    reading.pushRecentlyAdded([Self.item(id: "new")])
    await waitUntil { model.state != .loading }
    #expect(model.items.map(\.serverItemId) == ["new"])
  }

  @MainActor
  @Test("Continue Reading detail loads ebook progress items")
  func continueReadingLoadsItems() async {
    let reading = FakeHomeReading()
    let native = FakeNativeContinueReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
    let model = HomeMoreModel(
      section: .continueReading, filter: .ebooks, home: reading, sync: FakeSyncCoordinating(),
      nativeContinueListening: native, nativeSubscriptions: subscriptions)

    await waitUntil { reading.continueReadingCalls.isEmpty == false }
    #expect(reading.continueReadingCalls.last?.category == .ebook)

    let item = Self.item(id: "reading")
    reading.pushContinueReading([item])
    await waitUntil { model.state != .loading }
    #expect(model.state == .loaded)
    #expect(model.items == [item])
    #expect(native.observeCallCount == 0)
    #expect(subscriptions.observeEnabledCallCount == 0)
  }

  @MainActor
  @Test("Downloaded waits for ABS, RSS, and the gate, then merges feeds by title")
  func downloadedMergesNativeFeedsByTitle() async {
    let abs = FakeHomeReading()
    let rss = FakeNativeContinueReading()
    rss.initialDownloaded = nil
    let model = HomeMoreModel(
      section: .downloaded, filter: .podcasts, home: abs,
      sync: FakeSyncCoordinating(), nativeContinueListening: rss,
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))
    let server = Self.downloadedItem(id: "abs", title: "Zeta")
    let feed = Self.downloadedItem(id: "rss:1", title: "Alpha")

    abs.pushDownloaded([server])
    await Task.yield()
    #expect(model.state == .loading)

    // Wait for the merge of the latest value from each source.
    rss.pushDownloaded([feed])
    await waitUntil { model.items == [feed, server] }
    #expect(model.state == .loaded)
    #expect(model.items == [feed, server])
  }

  @MainActor
  @Test("Downloaded gate removes RSS feeds and ignores later RSS-only changes")
  func downloadedHonorsNativeSubscriptionsGate() async {
    let abs = FakeHomeReading()
    let rss = FakeNativeContinueReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
    let model = HomeMoreModel(
      section: .downloaded, filter: .all, home: abs,
      sync: FakeSyncCoordinating(), nativeContinueListening: rss,
      nativeSubscriptions: subscriptions)
    let server = Self.downloadedItem(id: "abs", title: "Zeta")
    let feed = Self.downloadedItem(id: "rss:1", title: "Alpha")

    abs.pushDownloaded([server])
    rss.pushDownloaded([feed])
    await waitUntil { model.items == [feed, server] }

    await subscriptions.setEnabled(false)
    await waitUntil { model.items == [server] }

    rss.pushDownloaded([feed, Self.downloadedItem(id: "rss:2", title: "Beta")])
    await awaitQuiescence(
      "the disabled Downloaded RSS projection to remain ignored",
      of: { "items=\(model.items.map(\.serverItemId))" })
    #expect(model.items == [server])
  }

  @MainActor
  @Test("Downloaded non-podcast filters retain the single ABS stream")
  func downloadedNonPodcastFilterDoesNotOpenNativeStreams() async {
    let abs = FakeHomeReading()
    let rss = FakeNativeContinueReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
    abs.stubInitialDownloaded([])
    let model = HomeMoreModel(
      section: .downloaded, filter: .audiobooks, home: abs,
      sync: FakeSyncCoordinating(), nativeContinueListening: rss,
      nativeSubscriptions: subscriptions)

    await waitUntil { model.state != .loading }
    #expect(rss.observeDownloadedCallCount == 0)
    #expect(subscriptions.observeEnabledCallCount == 0)
  }

  @MainActor
  @Test("Downloaded detail observes the account storage amount")
  func downloadedObservesAccountStorage() async {
    let model = HomeMoreModel(
      section: .downloaded, filter: .all,
      home: FakeHomeReading(), sync: FakeSyncCoordinating(),
      storageReading: FakeStorageReading(accountTotals: StorageTotals(totalBytes: 1_500_000_000)))

    await waitUntil { model.accountStorageBytes != nil }

    #expect(model.accountStorageBytes == 1_500_000_000)
    #expect(
      HomeCopy.downloadedStorageAmount(bytes: 1_500_000_000)
        == "\(ByteCountFormatter.string(fromByteCount: 1_500_000_000, countStyle: .file)) on this device")
  }

  @MainActor
  @Test("Saved for Later's temporary destination is an empty more-list")
  func savedForLaterDestinationIsEmpty() async {
    let model = HomeMoreModel(
      section: .savedForLater, filter: .all,
      home: FakeHomeReading(), sync: FakeSyncCoordinating())

    await waitUntil { model.state != .loading }

    #expect(model.state == .empty)
    #expect(model.items.isEmpty)
    #expect(model.podcastEpisodes.isEmpty)
  }

  @MainActor
  @Test("Listening Stats has its own destination, so its more-list is empty")
  func listeningStatsDestinationIsEmpty() async {
    let model = HomeMoreModel(
      section: .listeningStats, filter: .all,
      home: FakeHomeReading(), sync: FakeSyncCoordinating())

    await waitUntil { model.state != .loading }

    #expect(model.state == .empty)
    #expect(model.items.isEmpty)
  }

  private static func item(id: String) -> HomeItem {
    HomeItem(
      serverItemId: id, title: id, author: "Author", category: .audiobook,
      durationSeconds: 3_600, progressSeconds: 0, isFinished: false, addedAt: nil,
      isDownloaded: false)
  }

  private static func downloadedItem(id: String, title: String) -> HomeItem {
    HomeItem(
      serverItemId: id, title: title, author: "Author", category: .podcast,
      durationSeconds: nil, progressSeconds: 0, isFinished: false, addedAt: nil,
      isDownloaded: true, audioDownloaded: true)
  }

  private static func item(
    id: String, episodeID: String, recency: TimeInterval
  ) -> HomeItem {
    HomeItem(
      serverItemId: id, title: id, author: "Author", category: .podcast,
      durationSeconds: 1_800, progressSeconds: 100, isFinished: false, addedAt: nil,
      isDownloaded: false, episodeID: episodeID, episodeTitle: episodeID,
      progressRecency: Date(timeIntervalSince1970: recency))
  }

  private static func episode(
    itemID: String, episodeID: String, publishedAt: TimeInterval
  ) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: itemID, showTitle: itemID, showAuthor: nil, episodeID: episodeID,
      title: episodeID, subtitle: nil, publishedAt: Date(timeIntervalSince1970: publishedAt),
      durationSeconds: 1_800)
  }
}

@MainActor
private final class ContentChangeCounter {
  private(set) var count = 0

  init(model: HomeMoreModel) {
    observe(model)
  }

  private func observe(_ model: HomeMoreModel) {
    withObservationTracking {
      _ = model.state
      _ = model.items
      _ = model.podcastEpisodes
    } onChange: { [weak self, weak model] in
      Task { @MainActor in
        guard let self, let model else { return }
        self.count += 1
        self.observe(model)
      }
    }
  }
}

private final class FakeNativeLatestReading: NativeLatestPodcastEpisodesReading, @unchecked Sendable {
  nonisolated(unsafe) private var continuation: AsyncStream<[HomePodcastEpisode]>.Continuation?

  func observeLatestPodcastEpisodes(
    cutoff: @escaping @Sendable () -> Date, limit: Int
  ) -> AsyncStream<[HomePodcastEpisode]> {
    AsyncStream { continuation = $0 }
  }

  func push(_ episodes: [HomePodcastEpisode]) { continuation?.yield(episodes) }
}

final class FakeNativeContinueReading: NativeContinueListeningReading, @unchecked Sendable {
  nonisolated(unsafe) private(set) var observeCallCount = 0
  nonisolated(unsafe) private(set) var observeDownloadedCallCount = 0
  nonisolated(unsafe) private var continuations: [AsyncStream<[HomeItem]>.Continuation] = []
  nonisolated(unsafe) private var downloadedContinuations: [AsyncStream<[HomeItem]>.Continuation] = []
  /// Yielded the moment a Downloads observation opens, so tests that only exercise Continue
  /// Listening clear the shelf's readiness barrier without pushing. `nil` holds the stream until
  /// `pushDownloaded`.
  nonisolated(unsafe) var initialDownloaded: [HomeItem]? = []

  func observeContinueListening(limit: Int) -> AsyncStream<[HomeItem]> {
    observeCallCount += 1
    return AsyncStream { continuation in
      continuations.append(continuation)
    }
  }

  func observeDownloaded(limit: Int) -> AsyncStream<[HomeItem]> {
    observeDownloadedCallCount += 1
    return AsyncStream { continuation in
      downloadedContinuations.append(continuation)
      if let initialDownloaded { continuation.yield(initialDownloaded) }
    }
  }

  func push(_ items: [HomeItem]) {
    for continuation in continuations { continuation.yield(items) }
  }

  func pushDownloaded(_ items: [HomeItem]) {
    for continuation in downloadedContinuations { continuation.yield(items) }
  }
}
