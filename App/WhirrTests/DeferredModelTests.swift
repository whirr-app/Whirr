import ABSApi
import AppModel
import Foundation
import Observation
import Persistence
import SwiftUI
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

/// `State(initialValue: Model(deps))` evaluates on every `View.init`, and SwiftUI builds far more
/// view values than it keeps. Several models subscribe synchronously in `init` and two start
/// network fetches, so each surplus construction dispatched real work that `deinit` raced to
/// cancel. `DeferredModel` moves construction off `init`.
@Suite("Deferred model construction")
@MainActor
struct DeferredModelTests {

  @Test("a deferred value is built once, however many times it is resolved")
  func resolvesOnce() {
    let deferred = DeferredModel<NSObject>()
    var buildCount = 0

    let first = deferred.resolve {
      buildCount += 1
      return NSObject()
    }
    let second = deferred.resolve {
      buildCount += 1
      return NSObject()
    }

    #expect(buildCount == 1)
    #expect(first === second)
  }

  @Test("the builder is not run at all until the value is resolved")
  func doesNotBuildEagerly() {
    let deferred = DeferredModel<NSObject>()
    var buildCount = 0
    _ = deferred

    #expect(buildCount == 0)
    _ = deferred.resolve {
      buildCount += 1
      return NSObject()
    }
    #expect(buildCount == 1)
  }

  @Test("a keyed store builds one value per key and reuses each of them")
  func keyedStoreResolvesOncePerKey() {
    let deferred = KeyedDeferredModels<String, NSObject>()
    var buildCount = 0
    let build = {
      buildCount += 1
      return NSObject()
    }

    let firstA = deferred.resolve("a", build)
    let secondA = deferred.resolve("a", build)
    let firstB = deferred.resolve("b", build)

    #expect(buildCount == 2)
    #expect(firstA === secondA)
    #expect(firstA !== firstB)
  }

  @Test("a keyed store builds nothing until one of its keys is resolved")
  func keyedStoreDoesNotBuildEagerly() {
    let deferred = KeyedDeferredModels<String, NSObject>()
    var buildCount = 0
    _ = deferred

    #expect(buildCount == 0)
    deferred.resolve("a") {
      buildCount += 1
      return NSObject()
    }
    #expect(buildCount == 1)
  }

  // MARK: - The views themselves

  /// `SettingsView` sits in a `Tab { }` builder, so `LibraryShellView` rebuilds it on every body
  /// evaluation. That runs on every track change, because the body reads `playback.activeItemID`.
  @Test("constructing SettingsView never subscribes to preferences or storage")
  @MainActor
  func settingsViewConstructionIsFree() {
    let preferences = FakeDownloadPreferences()
    let storage = FakeStorageReading()

    for _ in 0..<10 {
      _ = SettingsView(
        account: FakeAccountLifecycle(),
        downloadPreferences: preferences,
        resolutionCenterAccess: NoOpResolutionCenterAccess(),
        subscriptionOPMLModel: PodcastSubscriptionOPMLModel(),
        storageReading: storage,
        playbackRate: PlaybackRateCoordinatorFixture.unbound(),
        manageDownloadsDestination: { EmptyView() },
        resolutionCenterDestination: { EmptyView() },
        onLoggedOut: {})
    }

    #expect(preferences.changesSubscriptionCount == 0)
    #expect(storage.observationCount == 0)
  }

  /// The confirmation alert lives on Server & Account, where the button is. UIKit drops an alert
  /// presented from the covered `NavigationStack` root, so the root owns only the removal and the
  /// post-logout handoff, which is what this pins.
  @Test("SettingsView's logout removes the account and then hands off")
  @MainActor
  func settingsViewPerformsLogoutAndHandsOff() async {
    let account = makeSignedInAccount()
    let handedOff = Locked(0)
    let view = SettingsView(
      account: account,
      downloadPreferences: FakeDownloadPreferences(),
      resolutionCenterAccess: NoOpResolutionCenterAccess(),
      subscriptionOPMLModel: PodcastSubscriptionOPMLModel(),
      playbackRate: PlaybackRateCoordinatorFixture.unbound(),
      manageDownloadsDestination: { EmptyView() },
      resolutionCenterDestination: { EmptyView() },
      onLoggedOut: { handedOff.withValue { $0 += 1 } })

    let removed = await view.performLogout()

    #expect(removed)
    #expect(account.logoutCallCount == 1)
    #expect(handedOff.value == 1)
  }

  /// The failure raises Server & Account's retry alert, so it must arrive as `false`, not as a
  /// silent no-op, and must not run the handoff.
  @Test("a failed logout reports failure and never hands off")
  @MainActor
  func settingsViewReportsLogoutFailure() async {
    let account = makeSignedInAccount(logoutError: AccountRemovalError.deletionFailed)
    let handedOff = Locked(0)
    let view = SettingsView(
      account: account,
      downloadPreferences: FakeDownloadPreferences(),
      resolutionCenterAccess: NoOpResolutionCenterAccess(),
      subscriptionOPMLModel: PodcastSubscriptionOPMLModel(),
      playbackRate: PlaybackRateCoordinatorFixture.unbound(),
      manageDownloadsDestination: { EmptyView() },
      resolutionCenterDestination: { EmptyView() },
      onLoggedOut: { handedOff.withValue { $0 += 1 } })

    let removed = await view.performLogout()

    #expect(removed == false)
    #expect(account.logoutCallCount == 1)
    #expect(handedOff.value == 0)

    // Retry is not pinned here. It depends on the model's `.failed` state surviving between
    // `performLogout()` calls, and each call resolves its own model. The settings model tests pin
    // it where that state lives.
  }

  @Test("constructing DownloadsView never opens a storage observation")
  func downloadsViewConstructionIsFree() throws {
    let storage = FakeStorageReading()
    let server = try ABSServerConfig(url: #require(URL(string: "http://127.0.0.1")))
    let coverClient = CoverImageClient(server: server)
    let paletteRecordStore = CoverPaletteRecordStore(database: try AppDatabase.inMemory())
    let harness = UIHarnessSession()

    for _ in 0..<10 {
      _ = DownloadsView(
        makeHomeModel: {
          HomeMoreModel(
            section: .downloaded, filter: .all,
            home: NoOpHomeReading(), sync: FakeSyncCoordinating(),
            storageReading: storage)
        },
        makePodcastShowModel: { itemID, filter in
          PodcastShowModel(itemID: itemID, reading: NoOpPodcastReading(), initialFilter: filter)
        },
        storageReading: storage,
        nativeSubscriptionsEnabled: false,
        downloadIntents: NoOpDownloadIntents(),
        coverClient: coverClient,
        paletteService: CoverPaletteService(recordStore: paletteRecordStore, coverClient: coverClient),
        playback: harness.playback,
        actions: harness.actions,
        onSelectItem: { _ in },
        onPresentReader: { _, _, _ in },
        onSearch: { _ in })
    }

    #expect(storage.observationCount == 0)
  }

  @Test("constructing ResolutionCenterView never fetches open items")
  func resolutionCenterViewConstructionIsFree() {
    let access = FakeResolutionCenterAccess()

    for _ in 0..<10 {
      _ = ResolutionCenterView(access: access)
    }

    #expect(access.calls.count == 0)
  }

  /// The worst case: `ItemDetailExtrasModel` and `ItemHistoryModel` start network fetches in
  /// `init`, so a surplus construction sent a real request and relied on `deinit` cancelling it in
  /// time.
  @Test("constructing ItemDetailView starts no database or network work")
  func itemDetailViewConstructionIsFree() async {
    let library = FakeLibraryReading()
    let downloads = FakeDownloadReading()
    let extras = FakeItemDetailExtrasAccess()
    let history = CountingHistoryProviding()
    let dependencies = UIHarnessSession()

    for _ in 0..<10 {
      _ = ItemDetailView(
        itemId: "item-1",
        library: library,
        nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
        coverClient: dependencies.coverClient,
        paletteService: dependencies.paletteService,
        playback: dependencies.playback,
        downloadReading: downloads,
        downloadIntents: NoOpDownloadIntents(),
        extrasAccess: extras,
        historyAccess: history,
        finishedStatus: dependencies.finishedStatus)
    }

    // Observations open synchronously in `init`, so they are countable at once. The network
    // fetches run in a `Task`, so a synchronous assertion would pass even on the unfixed build.
    // Wait a bounded time so the surplus requests can start. The fixed build passes once the wait
    // expires, without recording a failure.
    let outcome = await awaitCondition(
      "surplus item-detail work starts",
      timeout: 0.05,
      recordingIssue: false,
      observing: { "extras=\(extras.callCount), history=\(history.readCount)" },
      until: { extras.callCount > 0 && history.readCount > 0 })
    switch outcome {
    case .timedOut:
      break
    case .observed, .cancelled:
      Issue.record("the surplus work was allowed to start: \(outcome)")
    }

    #expect(library.itemDetailObservationCount == 0)
    #expect(downloads.statusObservationCount == 0)
    #expect(extras.callCount == 0)
    #expect(history.readCount == 0)
  }

  @Test("resolving an item detail body does not recursively resolve its model bundle")
  func itemDetailBodyResolutionIsAcyclic() {
    let dependencies = UIHarnessSession()

    for category in [ItemMediaCategory.audiobook, .ebook] {
      let seed = ItemSummary(
        serverItemId: "item-\(category)", mediaKind: "book", title: "Title", author: nil,
        durationSeconds: nil, category: category)
      let view = ItemDetailView(
        itemId: seed.serverItemId,
        seed: seed,
        library: FakeLibraryReading(),
        nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
        coverClient: dependencies.coverClient,
        paletteService: dependencies.paletteService,
        playback: dependencies.playback,
        downloadReading: FakeDownloadReading(),
        downloadIntents: NoOpDownloadIntents(),
        extrasAccess: FakeItemDetailExtrasAccess(),
        historyAccess: CountingHistoryProviding(),
        finishedStatus: dependencies.finishedStatus)

      // Evaluating `body` resolves the deferred bundle. Reading `downloadCategory` from inside that
      // builder re-entered the unresolved bundle through `model` and overflowed the stack.
      _ = view.body
    }
  }
}

// MARK: - Counting fakes

private final class CountingHistoryProviding: ListeningHistoryProviding, @unchecked Sendable {
  private let box = Locked(0)
  var readCount: Int { box.value }

  func cachedListeningHistory(itemId: String) async -> [ListeningHistoryEntry] {
    box.withValue { $0 += 1 }
    return []
  }
  func refreshListeningHistory(
    itemId: String, onPagePersisted: @escaping @Sendable @concurrent () async -> Void
  ) async -> Bool {
    box.withValue { $0 += 1 }
    await onPagePersisted()
    return false
  }
}

private func makeSignedInAccount(logoutError: (any Error)? = nil) -> FakeAccountLifecycle {
  let account = FakeAccountLifecycle()
  account.isAuthenticated = true
  account.stubLogout(throwing: logoutError)
  return account
}

extension FakeStorageReading {
  /// Every `observe…` call that opens an observation, consumed or not.
  fileprivate var observationCount: Int {
    accountObservationCount + itemObservationCount + downloadedItemsObservationCount
  }
}
