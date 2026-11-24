import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// `HomeModel` populates from `HomeReading`'s three observed projections (construction never
/// calls the network) and forwards pull-to-refresh to `SyncCoordinating.refresh()`. Unlike
/// `LibraryBrowseModel`, changing `filter` must swap all three observations for ones scoped to
/// the new category, leaking none of the previous filter's contents.
@Suite struct HomeModelTests {

  @MainActor
  @Test("starts loading, and no refresh is called, until the fake actually pushes a value")
  func startsLoading() {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()

    let model = HomeModel(home: home, sync: sync)

    #expect(model.state == .loading)
    #expect(sync.refreshCount == 0)
  }

  @MainActor
  @Test("omitting a saved source does not add a readiness barrier")
  func missingSavedSourceDoesNotStallReadiness() async {
    let home = FakeHomeReading()
    let model = HomeModel(home: home, sync: FakeSyncCoordinating())

    home.pushContinueListening([])
    home.pushContinueReading([])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([])
    home.pushDownloaded([])
    await waitUntil { model.state != .loading }

    #expect(model.state == .empty)
    #expect(model.savedForLater.isEmpty)
  }

  @MainActor
  @Test("saved content publishes after the saved source joins readiness")
  func savedContentPublishesAfterReadinessResolves() async {
    let home = FakeHomeReading()
    let saved = FakeSavedShelfReading()
    let model = HomeModel(home: home, sync: FakeSyncCoordinating(), savedShelf: saved)
    await waitUntil { saved.savedCalls.isEmpty == false }
    let entry = Self.makeSavedItem(id: "saved")

    home.pushContinueListening([])
    home.pushContinueReading([])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([])
    home.pushDownloaded([])
    saved.pushSaved([entry])
    await waitUntil { model.savedForLater == [entry] }

    #expect(model.state == .loaded)
  }

  @MainActor
  @Test("saved observation follows the selected filter category")
  func savedObservationFollowsFilterCategory() async {
    let home = FakeHomeReading()
    let saved = FakeSavedShelfReading()
    let model = HomeModel(home: home, sync: FakeSyncCoordinating(), savedShelf: saved)
    await waitUntil { saved.savedCalls.count == 1 }

    #expect(saved.savedCalls[0].filter == nil)
    #expect(saved.savedCalls[0].limit == 20)

    model.filter = .podcasts
    await waitUntil { saved.savedCalls.count == 2 }

    #expect(saved.savedCalls[1].filter == .podcast)
    #expect(saved.savedCalls[1].limit == 20)
  }

  @MainActor
  @Test("the All filter observes recently added with the seven-day cutoff")
  func allFilterUsesSevenDayRecentlyAddedCutoff() async {
    let home = FakeHomeReading()
    _ = HomeModel(
      home: home, sync: FakeSyncCoordinating(), filter: .all, now: { Self.fixedNow })

    await waitUntil { home.recentlyAddedSinceCalls.isEmpty == false }

    #expect(home.recentlyAddedSinceCalls.last?.since == HomeRecency.cutoff(now: Self.fixedNow))
  }

  @MainActor
  @Test("Home Recently Added switches live between native-preferred and all without another gate")
  func recentlyAddedUsesTheExistingNativeGate() async {
    let home = FakeHomeReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
    let model = HomeModel(
      home: home, sync: FakeSyncCoordinating(), filter: .all,
      nativeSubscriptions: subscriptions, now: { Self.fixedNow })
    let twin = Self.makeItem(id: "server-twin")
    let unmatched = Self.makeItem(id: "server-only")

    home.pushContinueListening([])
    home.pushContinueReading([])
    home.pushContinueSeries([])
    home.pushRecentlyAdded(
      HomeRecentlyAddedSnapshot(all: [twin, unmatched], nativePreferred: [unmatched]))
    home.pushDownloaded([])
    await waitUntil { model.state != .loading }

    #expect(model.recentlyAdded == [unmatched])
    #expect(subscriptions.observeEnabledCallCount == 1)

    await subscriptions.setEnabled(false)
    await waitUntil { model.recentlyAdded == [twin, unmatched] }
    await subscriptions.setEnabled(true)
    await waitUntil { model.recentlyAdded == [unmatched] }
    #expect(subscriptions.observeEnabledCallCount == 1)
  }

  @MainActor
  @Test("the All filter observes continue-series suggestions alongside recent items")
  func allFilterObservesContinueSeries() async {
    let home = FakeHomeReading()
    let model = HomeModel(
      home: home, sync: FakeSyncCoordinating(), filter: .all, limit: 9,
      now: { Self.fixedNow })

    await waitUntil { home.continueSeriesCalls.isEmpty == false }

    let nextBook = Self.makeItem(id: "book-7")
    home.pushContinueListening([])
    home.pushContinueReading([])
    home.pushContinueSeries([nextBook])
    home.pushRecentlyAdded([])
    home.pushDownloaded([])
    await waitUntil { model.state != .loading }

    #expect(model.continueSeries == [nextBook])
    #expect(home.newPodcastEpisodeCalls.isEmpty)
  }

  @MainActor
  @Test("all and podcast filters merge ABS and RSS Continue Listening by recency")
  func mergedContinueListeningOrdersAllAndPodcastFilters() async {
    for filter in [MediaFilter.all, .podcasts] {
      let home = FakeHomeReading()
      let native = FakeNativeContinueReading()
      let model = HomeModel(
        home: home, sync: FakeSyncCoordinating(), filter: filter,
        nativeContinueListening: native,
        nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))
      let older = Self.makeContinueItem(id: "abs", episodeID: "older", recency: 100)
      let newer = Self.makeContinueItem(id: "rss:1", episodeID: "newer", recency: 200)

      home.pushContinueListening([older])
      native.push([newer])
      home.pushDownloaded([])
      if filter == .all {
        home.pushContinueReading([])
        home.pushContinueSeries([])
        home.pushRecentlyAdded([])
      }
      await waitUntil { model.state != .loading }

      #expect(model.continueListening == [newer, older])
    }
  }

  @MainActor
  @Test("Home Continue Listening waits for all three sources and ignores RSS while gated off")
  func mergedContinueListeningReadinessAndGate() async {
    let home = FakeHomeReading()
    let native = FakeNativeContinueReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: false)
    let model = HomeModel(
      home: home, sync: FakeSyncCoordinating(), filter: .podcasts,
      nativeContinueListening: native, nativeSubscriptions: subscriptions)
    let server = Self.makeContinueItem(id: "abs", episodeID: "server", recency: 100)
    let rss = Self.makeContinueItem(id: "rss:1", episodeID: "native", recency: 200)

    home.pushContinueListening([server])
    home.pushDownloaded([])
    await Task.yield()
    #expect(model.state == .loading)

    native.push([rss])
    await waitUntil { model.state != .loading }
    #expect(model.continueListening == [server])

    native.push([Self.makeContinueItem(id: "rss:2", episodeID: "later", recency: 300)])
    await awaitQuiescence(
      "the disabled Home Continue Listening RSS projection to remain ignored",
      of: { "items=\(model.continueListening.map(\.serverItemId))" })
    #expect(model.continueListening == [server])
  }

  @MainActor
  @Test("audiobook Continue Listening stays on ABS and opens no native observations")
  func audiobookContinueListeningDoesNotOpenNativeObservations() {
    let native = FakeNativeContinueReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
    _ = HomeModel(
      home: FakeHomeReading(), sync: FakeSyncCoordinating(), filter: .audiobooks,
      nativeContinueListening: native, nativeSubscriptions: subscriptions)

    #expect(native.observeCallCount == 0)
    #expect(subscriptions.observeEnabledCallCount == 0)
  }

  @MainActor
  @Test("all and podcast filters merge ABS and RSS Downloads by title, waiting for both halves")
  func mergedDownloadedOrdersAllAndPodcastFilters() async {
    for filter in [MediaFilter.all, .podcasts] {
      let home = FakeHomeReading()
      let native = FakeNativeContinueReading()
      native.initialDownloaded = nil
      let model = HomeModel(
        home: home, sync: FakeSyncCoordinating(), filter: filter,
        nativeContinueListening: native,
        nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))
      let server = Self.makeDownloadedItem(id: "abs", title: "Zeta")
      let feed = Self.makeDownloadedItem(id: "rss:1", title: "Alpha")

      home.pushContinueListening([])
      native.push([])
      home.pushDownloaded([server])
      if filter == .all {
        home.pushContinueReading([])
        home.pushContinueSeries([])
        home.pushRecentlyAdded([])
      }
      await awaitQuiescence(
        "the Downloads shelf to hold loading until its RSS half reports",
        of: { "state=\(model.state)" })
      #expect(model.state == .loading, "the shelf waits for the RSS half before settling")

      native.pushDownloaded([feed])
      await waitUntil { model.state != .loading }

      #expect(model.state == .loaded)
      #expect(model.downloaded == [feed, server])
    }
  }

  @MainActor
  @Test("the Downloads shelf drops RSS feeds while native subscriptions are off")
  func mergedDownloadedHonorsTheGate() async {
    let home = FakeHomeReading()
    let native = FakeNativeContinueReading()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
    let model = HomeModel(
      home: home, sync: FakeSyncCoordinating(), filter: .podcasts,
      nativeContinueListening: native, nativeSubscriptions: subscriptions)
    let server = Self.makeDownloadedItem(id: "abs", title: "Zeta")
    let feed = Self.makeDownloadedItem(id: "rss:1", title: "Alpha")

    home.pushContinueListening([])
    native.push([])
    home.pushDownloaded([server])
    native.pushDownloaded([feed])
    await waitUntil { model.downloaded == [feed, server] }

    await subscriptions.setEnabled(false)
    await waitUntil { model.downloaded == [server] }

    native.pushDownloaded([feed, Self.makeDownloadedItem(id: "rss:2", title: "Beta")])
    await awaitQuiescence(
      "the gated Downloads RSS projection to remain ignored",
      of: { "items=\(model.downloaded.map(\.serverItemId))" })
    #expect(model.downloaded == [server])
  }

  @MainActor
  @Test("audiobook Downloads stay on ABS and open no native Downloads observation")
  func audiobookDownloadedDoesNotOpenNativeObservations() {
    let native = FakeNativeContinueReading()
    _ = HomeModel(
      home: FakeHomeReading(), sync: FakeSyncCoordinating(), filter: .audiobooks,
      nativeContinueListening: native,
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))

    #expect(native.observeDownloadedCallCount == 0)
  }

  @MainActor
  @Test("an identical merged Home Continue Listening snapshot publishes once")
  func mergedContinueListeningSuppressesIdenticalSnapshot() async {
    let home = FakeHomeReading()
    let native = FakeNativeContinueReading()
    let model = HomeModel(
      home: home, sync: FakeSyncCoordinating(), filter: .podcasts,
      nativeContinueListening: native,
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))
    let item = Self.makeContinueItem(id: "rss:1", episodeID: "episode", recency: 100)

    home.pushContinueListening([item])
    native.push([])
    home.pushDownloaded([])
    await waitUntil { model.state == .loaded }

    let changes = HomeChangeCounter()
    withObservationTracking {
      _ = model.continueListening
    } onChange: {
      changes.mark()
    }

    home.pushContinueListening([item])
    native.push([])
    await awaitQuiescence(
      "the identical Home Continue Listening merge to remain suppressed",
      of: { "changes=\(changes.count)" })
    #expect(changes.count == 0)
  }

  @MainActor
  @Test("the Ebooks filter observes Continue Series and waits for it before readiness")
  func ebooksFilterObservesContinueSeries() async {
    let home = FakeHomeReading()
    let model = HomeModel(
      home: home, sync: FakeSyncCoordinating(), filter: .ebooks, limit: 9,
      now: { Self.fixedNow })

    await waitUntil { home.continueSeriesCalls.isEmpty == false }
    #expect(home.continueSeriesCalls.last?.category == .ebook)

    home.pushContinueListening([])
    home.pushContinueReading([])
    home.pushRecentlyAdded([])
    home.pushDownloaded([])
    #expect(model.state == .loading)

    let nextBook = Self.makeItem(id: "ebook-next", category: .ebook)
    home.pushContinueSeries([nextBook])
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded)
    #expect(model.continueSeries == [nextBook])
  }

  @MainActor
  @Test("Continue Reading loads as its own section and keeps a non-empty Home loaded")
  func continueReadingLoadsAsItsOwnSection() async {
    let home = FakeHomeReading()
    let model = HomeModel(home: home, sync: FakeSyncCoordinating())
    let reading = Self.makeItem(id: "reading", category: .ebook)

    home.pushContinueListening([])
    home.pushContinueReading([reading])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([])
    home.pushNewPodcastEpisodes([])
    home.pushDownloaded([])
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded)
    #expect(model.continueReading == [reading])
  }

  @MainActor
  @Test("Continue Reading participates in empty readiness and follows the media filter")
  func continueReadingParticipatesInReadinessAndFilter() async {
    let home = FakeHomeReading()
    let model = HomeModel(home: home, sync: FakeSyncCoordinating(), filter: .ebooks)
    let reading = Self.makeItem(id: "reading", category: .ebook)

    home.pushContinueListening([])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([])
    home.pushDownloaded([])
    #expect(model.state == .loading)

    #expect(home.continueReadingCalls.last?.category == .ebook)
    home.pushContinueReading([reading])
    await waitUntil { model.state != .loading }
    #expect(model.continueReading == [reading])

    model.filter = .podcasts
    await waitUntil { home.continueListeningCalls.count > 1 }
    #expect(home.continueReadingCalls.count == 1)
    home.pushContinueListening([], at: 1)
    home.pushNewPodcastEpisodes([], at: 0)
    home.pushDownloaded([], at: 1)
    await waitUntil { model.state == .empty }
    #expect(model.continueReading.isEmpty)
  }

  @MainActor
  @Test("populates item sections from pushed values")
  func populatesItemSectionsFromPushedValues() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let model = HomeModel(home: home, sync: sync)
    let continuing = Self.makeItem(id: "continuing", progressSeconds: 100)
    let added = Self.makeItem(id: "added")
    let downloaded = Self.makeItem(id: "downloaded")

    home.pushContinueListening([continuing])
    home.pushContinueReading([])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([added])
    home.pushNewPodcastEpisodes([])
    home.pushDownloaded([downloaded])
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded)
    #expect(model.continueListening == [continuing])
    #expect(model.recentlyAdded == [added])
    #expect(model.downloaded == [downloaded])
  }

  @MainActor
  @Test("recomputing one Home section only invalidates the changed section")
  func recomputeOnlyInvalidatesChangedSection() async {
    let home = FakeHomeReading()
    let model = HomeModel(home: home, sync: FakeSyncCoordinating())
    let initial = Self.makeItem(id: "initial")
    let changed = Self.makeItem(id: "changed")

    home.pushContinueListening([initial])
    home.pushContinueReading([])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([])
    home.pushNewPodcastEpisodes([])
    home.pushDownloaded([])
    await waitUntil { model.state == .loaded }

    let listeningChanges = HomeChangeCounter()
    let readingChanges = HomeChangeCounter()
    let recentChanges = HomeChangeCounter()
    let seriesChanges = HomeChangeCounter()
    let downloadedChanges = HomeChangeCounter()
    let stateChanges = HomeChangeCounter()
    withObservationTracking {
      _ = model.continueListening
    } onChange: {
      listeningChanges.mark()
    }
    withObservationTracking {
      _ = model.continueReading
    } onChange: {
      readingChanges.mark()
    }
    withObservationTracking {
      _ = model.recentlyAdded
    } onChange: {
      recentChanges.mark()
    }
    withObservationTracking {
      _ = model.continueSeries
    } onChange: {
      seriesChanges.mark()
    }
    withObservationTracking {
      _ = model.downloaded
    } onChange: {
      downloadedChanges.mark()
    }
    withObservationTracking {
      _ = model.state
    } onChange: {
      stateChanges.mark()
    }

    home.pushContinueListening([changed])
    await waitUntil { model.continueListening == [changed] }

    #expect(listeningChanges.count == 1)
    #expect(readingChanges.count == 0)
    #expect(recentChanges.count == 0)
    #expect(seriesChanges.count == 0)
    #expect(downloadedChanges.count == 0)
    #expect(stateChanges.count == 0)
  }

  @MainActor
  @Test("empty only once every section has reported and all three are empty")
  func emptyOnlyWhenAllThreeSectionsAreEmpty() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let model = HomeModel(home: home, sync: sync)

    home.pushContinueListening([])
    home.pushContinueReading([])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([])
    home.pushNewPodcastEpisodes([])
    home.pushDownloaded([])
    await waitUntil { model.state != .loading }

    #expect(model.state == .empty)
  }

  @MainActor
  @Test("one non-empty section among three empty ones is still the loaded state, not empty")
  func oneNonEmptySectionIsLoadedNotEmpty() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let model = HomeModel(home: home, sync: sync)
    let item = Self.makeItem(id: "only-one")

    home.pushContinueListening([])
    home.pushContinueReading([])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([item])
    home.pushNewPodcastEpisodes([])
    home.pushDownloaded([])
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded)
  }

  @MainActor
  @Test("state stays loading until every one of the three sections has reported at least once")
  func staysLoadingUntilEveryStreamHasReportedOnce() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let model = HomeModel(home: home, sync: sync)

    home.pushContinueListening([])
    home.pushContinueReading([])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([])
    home.pushNewPodcastEpisodes([])
    // `downloaded` never pushed, so state must not settle.

    #expect(model.state == .loading)
  }

  // MARK: - Shared Latest Episodes boundary

  @MainActor
  @Test("the podcasts filter leaves Latest Episodes to the shared dedicated model")
  func podcastsFilterDoesNotOpenADuplicateEpisodeObservation() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let model = HomeModel(home: home, sync: sync, filter: .podcasts, limit: 9)

    #expect(home.recentlyAddedCalls.isEmpty)
    #expect(home.newPodcastEpisodeCalls.isEmpty)

    home.pushContinueListening([])
    home.pushDownloaded([])
    await waitUntil { model.state != .loading }

    #expect(model.state == .empty)
    #expect(model.recentlyAdded.isEmpty)
  }

  @MainActor
  @Test("audiobook and ebook filters keep item-level Recently Added")
  func nonPodcastFiltersKeepItemLevelRecentlyAdded() async {
    for filter in [MediaFilter.audiobooks, .ebooks] {
      let home = FakeHomeReading()
      let sync = FakeSyncCoordinating()
      let model = HomeModel(home: home, sync: sync, filter: filter)
      let item = Self.makeItem(id: "added")

      home.pushContinueListening([])
      if filter != .podcasts { home.pushContinueReading([]) }
      if filter != .podcasts { home.pushContinueSeries([]) }
      home.pushRecentlyAdded([item])
      home.pushDownloaded([])
      await waitUntil { model.state != .loading }

      #expect(home.newPodcastEpisodeCalls.isEmpty)
      #expect(model.recentlyAdded == [item])
    }
  }

  @MainActor
  @Test("changing filter re-subscribes with the new category and replaces contents")
  func changingFilterResubscribesAndReplacesContents() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let model = HomeModel(home: home, sync: sync, filter: .all)
    let oldItem = Self.makeItem(id: "old", category: .audiobook)

    home.pushContinueListening([oldItem])
    home.pushContinueReading([])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([oldItem])
    home.pushNewPodcastEpisodes([])
    home.pushDownloaded([oldItem])
    await waitUntil { model.state != .loading }
    #expect(model.recentlyAdded == [oldItem])

    model.filter = .ebooks

    let newItem = Self.makeItem(id: "new", category: .ebook)
    home.pushContinueListening([newItem])
    home.pushContinueReading([newItem])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([newItem])
    home.pushDownloaded([newItem])
    await waitUntil { model.recentlyAdded == [newItem] }

    #expect(model.state == .loaded)
    #expect(model.continueListening == [newItem])
    #expect(model.recentlyAdded == [newItem])
    #expect(model.downloaded == [newItem])
  }

  @MainActor
  @Test("changing filter holds the previous contents until every new section has reported")
  func changingFilterHoldsPreviousContentsUntilTheNewOnesReport() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let model = HomeModel(home: home, sync: sync, filter: .all)
    let oldItem = Self.makeItem(id: "old", category: .audiobook)

    home.pushContinueListening([oldItem])
    home.pushContinueReading([])
    home.pushContinueSeries([])
    home.pushRecentlyAdded([oldItem])
    home.pushNewPodcastEpisodes([])
    home.pushDownloaded([oldItem])
    await waitUntil { model.state != .loading }

    model.filter = .ebooks
    let newItem = Self.makeItem(id: "new", category: .ebook)
    // Four of the five new item sections report: the screen must still be showing the previous
    // filter's contents rather than flashing a loading state it will leave milliseconds later.
    home.pushContinueListening([newItem], at: 1)
    home.pushContinueReading([], at: 1)
    home.pushContinueSeries([], at: 1)
    home.pushRecentlyAdded([newItem], at: 1)

    #expect(model.state == .loaded)
    #expect(model.continueListening == [oldItem])
    #expect(model.recentlyAdded == [oldItem])
    #expect(model.downloaded == [oldItem])

    home.pushDownloaded([newItem], at: 1)
    await waitUntil { model.downloaded == [newItem] }

    // Swapped as one, only once the last section arrives, so never a half-old, half-new screen.
    #expect(model.continueListening == [newItem])
    #expect(model.recentlyAdded == [newItem])
  }

  @MainActor
  @Test("a stale value pushed to the pre-filter-change subscription never leaks into state")
  func staleValueOnThePreviousSubscriptionNeverLeaksThrough() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let model = HomeModel(home: home, sync: sync, filter: .all)
    let before = Self.makeItem(id: "before")

    home.pushRecentlyAdded([before])
    home.pushContinueListening([])
    home.pushContinueReading([])
    home.pushContinueSeries([])
    home.pushNewPodcastEpisodes([])
    home.pushDownloaded([])
    await waitUntil { model.state != .loading }

    model.filter = .ebooks
    // Simulates the old (cancelled) subscription still delivering a buffered value. The fake
    // targets subscription index 0, the pre-change one; the new subscription is index 1 and has
    // not been pushed to yet.
    home.pushRecentlyAdded([Self.makeItem(id: "stale")], at: 0)

    // Still the held pre-change contents, untouched by the stale push.
    #expect(model.recentlyAdded == [before])

    home.pushRecentlyAdded([Self.makeItem(id: "fresh", category: .ebook)], at: 1)
    home.pushContinueListening([], at: 1)
    home.pushContinueReading([], at: 1)
    home.pushContinueSeries([], at: 1)
    home.pushDownloaded([], at: 1)
    await waitUntil { model.recentlyAdded != [before] }

    #expect(model.recentlyAdded == [Self.makeItem(id: "fresh", category: .ebook)])
  }

  @MainActor
  @Test("setting filter to its already-current value does not re-subscribe")
  func settingFilterToItsCurrentValueIsANoOp() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let model = HomeModel(home: home, sync: sync, filter: .audiobooks)
    await waitUntil { home.recentlyAddedCalls.isEmpty == false }
    let callCountBefore = home.recentlyAddedCalls.count

    model.filter = .audiobooks

    #expect(home.recentlyAddedCalls.count == callCountBefore)
  }

  @MainActor
  @Test("each filter maps to the matching ItemMediaCategory on every observe call")
  func filterMapsToTheMatchingCategoryOnEveryObserveCall() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let model = HomeModel(home: home, sync: sync, filter: .all)
    await waitUntil { home.recentlyAddedCalls.isEmpty == false }

    #expect(home.continueListeningCalls.last?.category == nil)
    #expect(home.recentlyAddedCalls.last?.category == nil)
    #expect(home.downloadedCalls.last?.category == nil)

    model.filter = .podcasts
    await waitUntil { home.continueListeningCalls.count > 1 }
    #expect(home.continueListeningCalls.last?.category == .podcast)
    #expect(home.downloadedCalls.last?.category == .podcast)
    // The middle section is the episode projection under this filter, so no second item-level
    // Recently Added subscription is opened at all.
    #expect(home.recentlyAddedCalls.count == 1)

    model.filter = .ebooks
    await waitUntil { home.recentlyAddedCalls.count > 1 }
    #expect(home.recentlyAddedCalls.last?.category == .ebook)
  }

  @MainActor
  @Test("limit is forwarded to every section's observe call")
  func limitIsForwardedToEveryObserveCall() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    _ = HomeModel(home: home, sync: sync, limit: 7)
    await waitUntil { home.downloadedCalls.isEmpty == false }

    #expect(home.continueListeningCalls.last?.limit == 7)
    #expect(home.recentlyAddedCalls.last?.limit == 7)
    #expect(home.downloadedCalls.last?.limit == 7)
  }

  @MainActor
  @Test("refresh forwards to SyncCoordinating.refresh() exactly once")
  func refreshForwardsToSyncCoordinatingExactlyOnce() async {
    let home = FakeHomeReading()
    let sync = FakeSyncCoordinating()
    let model = HomeModel(home: home, sync: sync)

    await model.refresh()

    #expect(sync.refreshCount == 1)
  }

  // MARK: - Helpers

  private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

  private static func makeItem(
    id: String, category: ItemMediaCategory = .audiobook, progressSeconds: Double = 0
  ) -> HomeItem {
    HomeItem(
      serverItemId: id, title: "Title \(id)", author: "Author", category: category,
      durationSeconds: 3600, progressSeconds: progressSeconds, isFinished: false, addedAt: nil,
      isDownloaded: false)
  }

  private static func makeEpisode(id: String) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: "show-\(id)", showTitle: "Show", showAuthor: "Publisher", episodeID: id,
      title: "Episode \(id)", subtitle: nil, publishedAt: fixedNow, durationSeconds: 1800)
  }

  private static func makeDownloadedItem(id: String, title: String) -> HomeItem {
    HomeItem(
      serverItemId: id, title: title, author: "Author", category: .podcast,
      durationSeconds: nil, progressSeconds: 0, isFinished: false, addedAt: nil,
      isDownloaded: true, audioDownloaded: true)
  }

  private static func makeContinueItem(
    id: String, episodeID: String, recency: TimeInterval
  ) -> HomeItem {
    HomeItem(
      serverItemId: id, title: "Title \(id)", author: "Author", category: .podcast,
      durationSeconds: 1_800, progressSeconds: 100, isFinished: false, addedAt: nil,
      isDownloaded: false, episodeID: episodeID, episodeTitle: episodeID,
      progressRecency: Date(timeIntervalSince1970: recency))
  }

  private static func makeSavedItem(
    id: String, category: ItemMediaCategory = .audiobook
  ) -> SavedShelfItem {
    let summary = ItemSummary(
      serverItemId: id, mediaKind: "book", title: "Saved \(id)", author: "Author",
      durationSeconds: 3600, category: category)
    return SavedShelfItem(
      identity: .item(itemID: id), savedAt: fixedNow, subjectTitle: summary.title,
      contextTitle: nil, category: category, itemSummary: summary, episode: nil,
      isUnavailable: false)
  }
}

private final class HomeChangeCounter: @unchecked Sendable {
  private(set) var count = 0

  func mark() { count += 1 }
}
