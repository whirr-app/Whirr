import Foundation
import Observation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// `LibraryBrowseModel` populates entirely from `LibraryReading`'s observed projections
/// (construction never calls the network) and forwards pull-to-refresh to
/// `SyncCoordinating.refresh()`. Every state has copy assertions.
@Suite struct LibraryBrowseModelTests {

  @MainActor
  @Test("no state is emitted, and no refresh is called, until the fake actually pushes a value")
  func constructionNeverCallsRefreshOrRequiresAnEmission() throws {
    let library = FakeLibraryReading()
    let sync = FakeSyncCoordinating()

    let model = try Self.model(library: library, sync: sync)

    #expect(model.state == .loading)
    #expect(sync.refreshCount == 0)
  }

  @MainActor
  @Test("an empty browse list with no sync activity is the empty state, with copy")
  func emptyListWithNoSyncActivityIsEmptyState() async throws {
    let library = FakeLibraryReading()
    let sync = FakeSyncCoordinating()
    let model = try Self.model(library: library, sync: sync)

    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil))
    library.pushBrowseList([])
    await waitUntil { model.state != .loading }

    #expect(model.state == .empty)
    #expect(model.state.copyKey == "browse.empty")
    #expect(model.state.copyText(for: model.filters).isEmpty == false)
  }

  @MainActor
  @Test("a non-empty browse list with no sync activity is the loaded state")
  func nonEmptyListWithNoSyncActivityIsLoadedState() async throws {
    let library = FakeLibraryReading()
    let sync = FakeSyncCoordinating()
    let model = try Self.model(library: library, sync: sync)
    let item = Self.makeItem(id: "item1")

    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date()))
    library.pushBrowseList([item])
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded([item]))
    #expect(model.state.copyKey == "browse.loaded")
  }

  @MainActor
  @Test("a running sync is the partially-synced state, regardless of item count, with copy")
  func aRunningSyncIsThePartiallySyncedState() async throws {
    let library = FakeLibraryReading()
    let sync = FakeSyncCoordinating()
    let model = try Self.model(library: library, sync: sync)
    let item = Self.makeItem(id: "item1")

    library.pushBrowseList([item])
    library.pushSyncStatus(LibrarySyncStatus(isRunning: true, lastRunIncomplete: false, lastCompletedAt: nil))
    await waitUntil { model.state != .loading }

    #expect(model.state == .partiallySynced([item]))
    #expect(model.state.copyKey == "browse.partiallySynced")
    #expect(model.state.copyText(for: model.filters).isEmpty == false)
  }

  @MainActor
  @Test("a run with nothing cached at all is the loading state, not a blank partially-synced list")
  func aRunWithNothingCachedIsTheLoadingState() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)
    let item = Self.makeItem(id: "item1")

    // Settle on rows first, so the return to `.loading` below is an observed transition rather than
    // the state the model happened to start in.
    library.pushBrowseList([item])
    library.pushSyncStatus(
      LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date()))
    _ = await waitUntil { model.state == .loaded([item]) }

    library.pushBrowseList([])
    library.pushSyncStatus(
      LibrarySyncStatus(isRunning: true, lastRunIncomplete: false, lastCompletedAt: nil))
    _ = await waitUntil { model.state == .loading }

    #expect(model.state == .loading)
    #expect(model.state.copyKey == "browse.loading")
    #expect(model.state.copyText(for: model.filters).isEmpty == false)
  }

  @MainActor
  @Test("a status emission alone commits no state on cold start - the first snapshot does")
  func statusEmissionAloneCommitsNoStateOnColdStart() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)
    let item = Self.makeItem(id: "item-1")

    library.pushSyncStatus(
      LibrarySyncStatus(isRunning: true, lastRunIncomplete: false, lastCompletedAt: nil))

    #expect(model.state == .loading)

    // Both streams have to have emitted before a state is published, so waiting on the snapshot's
    // state is also what proves the status above was consumed rather than dropped.
    library.pushBrowseList([item])

    #expect(await waitUntil { model.state == .partiallySynced([item]) })
  }

  @MainActor
  @Test("ten snapshots during one deferral publish only the newest snapshot on release")
  func deferredSnapshotsPublishOnlyNewestSnapshotOnRelease() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)
    let initial = Self.makeItem(id: "initial")
    let settled = LibrarySyncStatus(
      isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date())

    library.pushSyncStatus(settled)
    library.pushBrowseList([initial])
    await waitUntil { model.state == .loaded([initial]) }

    let changes = LibraryStateRecorder(model)
    model.setPresentationDeferred(true)

    for index in 1...10 {
      library.pushBrowseList([Self.makeItem(id: "snapshot-\(index)")])
    }
    await awaitQuiescence("deferred browse snapshots to settle", of: { "\(changes.states)" })

    #expect(changes.states == [.loaded([initial])])

    model.setPresentationDeferred(false)
    #expect(await waitUntil { changes.states.count == 2 })
    #expect(
      changes.states
        == [.loaded([initial]), .loaded([Self.makeItem(id: "snapshot-10")])])
  }

  @MainActor
  @Test("a sync-status change publishes no new state while row publication is deferred")
  func statusChangeIsHeldWhileRowsAreDeferred() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)
    let item = Self.makeItem(id: "item")
    let settled = LibrarySyncStatus(
      isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date())

    library.pushSyncStatus(settled)
    library.pushBrowseList([item])
    await waitUntil { model.state == .loaded([item]) }

    let stateChanges = LibraryStateRecorder(model)

    model.setPresentationDeferred(true)
    library.pushSyncStatus(
      LibrarySyncStatus(isRunning: true, lastRunIncomplete: false, lastCompletedAt: nil))
    await awaitQuiescence("the deferred status change to settle", of: { "\(stateChanges.states)" })

    #expect(model.state == .loaded([item]))
    #expect(stateChanges.states == [.loaded([item])])
  }

  @MainActor
  @Test("initial loading publishes its first usable state while deferred")
  func initialLoadingPublishesFirstUsableStateWhileDeferred() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)
    let item = Self.makeItem(id: "first")
    let changes = LibraryStateRecorder(model)

    model.setPresentationDeferred(true)
    library.pushBrowseList([item])
    library.pushSyncStatus(
      LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date()))

    #expect(await waitUntil { model.state == .loaded([item]) })
    #expect(await waitUntil { changes.states.count == 2 })
    #expect(changes.states == [.loading, .loaded([item])])
  }

  @MainActor
  @Test("a filter change while deferred discards the old pending snapshot")
  func filterChangeWhileDeferredDiscardsOldPendingSnapshot() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)
    let initial = Self.makeItem(id: "initial")
    let pendingOld = Self.makeItem(id: "pending-old")
    let new = Self.makeItem(id: "podcast")
    let settled = LibrarySyncStatus(
      isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date())

    library.pushSyncStatus(settled)
    library.pushBrowseList([initial])
    await waitUntil { model.state == .loaded([initial]) }

    let changes = LibraryStateRecorder(model)
    model.setPresentationDeferred(true)
    library.pushBrowseSnapshot(filters: .unfiltered, Self.snapshot([pendingOld]))
    await awaitQuiescence("the deferred browse state to settle", of: { "\(changes.states)" })

    model.updateMediaFilter(.podcasts)
    let podcastFilters = BrowseFilters(categories: [.podcast])
    library.pushBrowseSnapshot(filters: podcastFilters, Self.snapshot([new]))
    library.pushSyncStatus(settled)

    #expect(await waitUntil { model.state == .loaded([new]) })
    #expect(await waitUntil { changes.states.count == 2 })
    #expect(changes.states == [.loaded([initial]), .loaded([new])])

    model.setPresentationDeferred(false)
    await awaitQuiescence("the released browse state to settle", of: { "\(changes.states)" })
    #expect(changes.states.count == 2)
    #expect(changes.states.contains(.loaded([pendingOld])) == false)
  }

  @MainActor
  @Test("releasing an idle gate with no pending value does not publish")
  func releasingIdleGateWithNoPendingValueDoesNotPublish() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)
    let item = Self.makeItem(id: "item")
    let settled = LibrarySyncStatus(
      isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date())

    library.pushSyncStatus(settled)
    library.pushBrowseList([item])
    await waitUntil { model.state == .loaded([item]) }

    let changes = LibraryStateRecorder(model)
    model.setPresentationDeferred(false)
    model.setPresentationDeferred(true)
    model.setPresentationDeferred(false)
    await awaitQuiescence("the idle presentation gate to settle", of: { "\(changes.states)" })

    #expect(changes.states == [.loaded([item])])
  }

  @MainActor
  @Test("an incomplete last run with no cached items and nothing running is the error state, with copy")
  func incompleteRunWithNoCachedItemsIsErrorState() async throws {
    let library = FakeLibraryReading()
    let sync = FakeSyncCoordinating()
    let model = try Self.model(library: library, sync: sync)

    library.pushBrowseList([])
    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: true, lastCompletedAt: nil))
    await waitUntil { model.state != .loading }

    #expect(model.state == .error)
    #expect(model.state.copyKey == "browse.error")
    #expect(model.state.copyText(for: model.filters).isEmpty == false)
  }

  @MainActor
  @Test("an incomplete run with stale cached items and nothing running is the stale-offline state, with copy")
  func incompleteRunWithStaleCachedItemsIsStaleOfflineState() async throws {
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_000_000))
    let library = FakeLibraryReading()
    let sync = FakeSyncCoordinating()
    let model = try Self.model(library: library, sync: sync, clock: clock, staleAfter: 60)
    let item = Self.makeItem(id: "item1")

    library.pushBrowseList([item])
    library.pushSyncStatus(
      LibrarySyncStatus(
        isRunning: false, lastRunIncomplete: true,
        lastCompletedAt: Date(timeIntervalSince1970: 1_000_000 - 120)))
    await waitUntil { model.state != .loading }

    #expect(model.state == .staleOffline([item]))
    #expect(model.state.copyKey == "browse.staleOffline")
    #expect(model.state.copyText(for: model.filters).isEmpty == false)

    library.pushSyncStatus(
      LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: clock.now()))
    await waitUntil { model.state == .loaded([item]) }
  }

  @MainActor
  @Test("an incomplete run with fresh cached items and nothing running keeps the loaded state")
  func incompleteRunWithFreshCachedItemsStaysLoaded() async throws {
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_000_000))
    let library = FakeLibraryReading()
    let sync = FakeSyncCoordinating()
    let model = try Self.model(library: library, sync: sync, clock: clock, staleAfter: 3600)
    let item = Self.makeItem(id: "item1")

    library.pushBrowseList([item])
    library.pushSyncStatus(
      LibrarySyncStatus(
        isRunning: false, lastRunIncomplete: true,
        lastCompletedAt: Date(timeIntervalSince1970: 1_000_000 - 30)))
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded([item]))
  }

  @MainActor
  @Test("refresh forwards to SyncCoordinating.refresh()")
  func refreshForwardsToSyncCoordinating() async throws {
    let library = FakeLibraryReading()
    let sync = FakeSyncCoordinating()
    let model = try Self.model(library: library, sync: sync)

    await model.refresh()

    #expect(sync.refreshCount == 1)
  }

  @MainActor
  @Test("every visible state has distinct, non-empty banner copy except loaded")
  func everyVisibleStateHasDistinctCopyKeys() throws {
    let states: [LibraryBrowseModel.State] = [
      .loading, .empty, .loaded([]), .partiallySynced([]), .error, .staleOffline([]),
    ]
    let keys = states.map(\.copyKey)
    #expect(Set(keys).count == keys.count)
    for state in states where state != .loaded([]) {
      #expect(state.copyText(for: .unfiltered).isEmpty == false)
    }
  }

  // MARK: - Media filter

  @MainActor
  @Test("the browse list subscribes across every library, unfiltered, at construction")
  func subscribesAcrossEveryLibraryUnfiltered() throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)

    #expect(model.mediaFilter == .all)
    #expect(model.filters == .unfiltered)
    #expect(library.observedBrowseFilters == [.unfiltered])
  }

  @MainActor
  @Test("changing the filter resubscribes under the new category without flashing loading")
  func changingFilterResubscribesUnderNewCategoryWithoutFlashingLoading() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)
    let oldItem = Self.makeItem(id: "item1")

    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date()))
    library.pushBrowseList([oldItem])
    await waitUntil { model.state != .loading }

    model.updateMediaFilter(.podcasts)

    #expect(model.state == .loaded([oldItem]), "the previous rendered state stays visible while the new filter arms")
    #expect(library.observedBrowseFilters == [.unfiltered, BrowseFilters(categories: [.podcast])])
  }

  @MainActor
  @Test("a library filter commits its list and sync status as one ready generation")
  func filterCommitsListAndStatusTogetherAfterBothReport() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)
    let oldItem = Self.makeItem(id: "old")
    let newItem = Self.makeItem(id: "podcast-1")
    let settled = LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date())

    library.pushSyncStatus(settled)
    library.pushBrowseList([oldItem])
    await waitUntil { model.state == .loaded([oldItem]) }

    model.updateMediaFilter(.podcasts)
    library.pushBrowseSnapshot(
      filters: BrowseFilters(categories: [.podcast]), Self.snapshot([newItem]))

    #expect(model.state == .loaded([oldItem]), "a list emission alone must not publish a half-new screen")

    library.pushSyncStatus(settled)
    await waitUntil { model.state == .loaded([newItem]) }

    #expect(model.state == .loaded([newItem]))
  }

  @MainActor
  @Test("selecting the already-active filter does not resubscribe")
  func reselectingActiveFilterDoesNotResubscribe() throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)

    model.updateMediaFilter(.all)
    model.updateDownloadedOnly(false)
    model.updatePlayback(.any)
    model.clearFilters()

    #expect(
      library.observedBrowseFilters == [.unfiltered],
      "every intent that names the value already held is a no-op, over every dimension")
  }

  /// The generation guard: cancelling a stream task stops new suspension but cannot un-deliver a
  /// value already in flight, so a superseded filter's late emission must be dropped on arrival.
  @MainActor
  @Test("a superseded filter's late value never lands in the new filter's list")
  func supersededFilterValueNeverLands() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)

    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date()))
    model.updateMediaFilter(.podcasts)

    // Emitted by the superseded `.all` subscription only, after the model moved to `.podcasts`.
    library.pushBrowseSnapshot(filters: .unfiltered, Self.snapshot([Self.makeItem(id: "stale-audiobook")]))
    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date()))

    let podcast = Self.makeItem(id: "podcast-1")
    library.pushBrowseSnapshot(filters: BrowseFilters(categories: [.podcast]), Self.snapshot([podcast]))
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded([podcast]), "the stale `.all` emission must not reach `.podcasts`")
    #expect(library.observedBrowseFilters == [.unfiltered, BrowseFilters(categories: [.podcast])])
  }

  /// With the media filter on the Library tab, an empty podcast list must not read
  /// "No books yet. Pull to sync your library."
  @MainActor
  @Test("the empty state's copy names the filtered media type, not books")
  func emptyCopyNamesTheFilteredMediaType() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library, startingFrom: BrowseFilters(categories: [.podcast]))

    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil))
    // A fully empty library, not one filtered to nothing: `.empty`, not `.filteredEmpty`.
    library.pushBrowseSnapshot(
      filters: BrowseFilters(categories: [.podcast]),
      LibraryBrowseSnapshot(items: [], unfilteredItemCount: 0))
    await waitUntil { model.state != .loading }

    let copy = model.state.copyText(for: model.filters)
    #expect(model.state == .empty)
    #expect(copy.localizedCaseInsensitiveContains("podcasts"))
    #expect(copy.localizedCaseInsensitiveContains("book") == false)
  }

  @MainActor
  @Test("the still-syncing banner names the filtered media type, not books")
  func partiallySyncedCopyNamesTheFilteredMediaType() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library, startingFrom: BrowseFilters(categories: [.podcast]))

    library.pushBrowseSnapshot(
      filters: BrowseFilters(categories: [.podcast]), Self.snapshot([Self.makeItem(id: "podcast-1")]))
    library.pushSyncStatus(LibrarySyncStatus(isRunning: true, lastRunIncomplete: false, lastCompletedAt: nil))
    await waitUntil { model.state != .loading }

    let copy = model.state.copyText(for: model.filters)
    #expect(copy.localizedCaseInsensitiveContains("podcasts"))
    #expect(copy.localizedCaseInsensitiveContains("book") == false)
  }

  /// Unfiltered, the merged list spans every library, so its copy cannot claim books either.
  @MainActor
  @Test("the unfiltered empty state's copy names no media type")
  func unfilteredEmptyCopyNamesNoMediaType() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)

    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil))
    library.pushBrowseList([])
    await waitUntil { model.state != .loading }

    #expect(model.state.copyText(for: model.filters).localizedCaseInsensitiveContains("book") == false)
  }

  // MARK: - Status dimensions and persistence

  @MainActor
  @Test("each status dimension resubscribes once, preserving the dimensions it does not name")
  func statusDimensionsResubscribePreservingTheOthers() throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)

    model.updateMediaFilter(.podcasts)
    model.updateDownloadedOnly(true)
    model.updatePlayback(.unfinished)

    #expect(
      library.observedBrowseFilters == [
        .unfiltered,
        BrowseFilters(categories: [.podcast]),
        BrowseFilters(categories: [.podcast], downloadedOnly: true),
        BrowseFilters(categories: [.podcast], downloadedOnly: true, playback: .unfinished),
      ])
    #expect(model.mediaFilter == .podcasts, "the media dimension survived the status changes")
  }

  @MainActor
  @Test("clearFilters returns to unfiltered in one resubscribe and removes the stored key")
  func clearFiltersReturnsToUnfilteredAndRemovesTheKey() throws {
    let defaults = Self.freshDefaults()
    let library = FakeLibraryReading()
    let model = LibraryBrowseModel(
      library: library, sync: FakeSyncCoordinating(), defaults: defaults)

    model.updateMediaFilter(.ebooks)
    model.updateDownloadedOnly(true)
    #expect(defaults.isEmpty == false)

    model.clearFilters()

    #expect(model.filters == .unfiltered)
    #expect(model.filters.isActive == false)
    #expect(defaults.isEmpty)
    #expect(library.observedBrowseFilters.last == .unfiltered)
  }

  @MainActor
  @Test("every intent persists before the replacement observation starts")
  func everyIntentPersistsBeforeResubscribing() throws {
    // Asserted through the storage rather than through ordering: by the time the fake has recorded
    // the new subscription, the value is already on disk, so a crash mid-change cannot leave the
    // stored filter describing the screen the reader just left.
    let defaults = Self.freshDefaults()
    let library = FakeLibraryReading()
    let model = LibraryBrowseModel(
      library: library, sync: FakeSyncCoordinating(), defaults: defaults)

    model.updateDownloadedOnly(true)
    #expect(BrowseFilterStorage.load(.library, from: defaults) == BrowseFilters(downloadedOnly: true))
    #expect(library.observedBrowseFilters.last == BrowseFilters(downloadedOnly: true))

    model.updatePlayback(.finished)
    #expect(
      BrowseFilterStorage.load(.library, from: defaults)
        == BrowseFilters(downloadedOnly: true, playback: .finished))
  }

  @MainActor
  @Test("filters set on one instance are the starting filters of the next against the same storage")
  func filtersSurviveIntoTheNextInstance() throws {
    let defaults = Self.freshDefaults()
    let first = LibraryBrowseModel(
      library: FakeLibraryReading(), sync: FakeSyncCoordinating(), defaults: defaults)

    first.updateMediaFilter(.podcasts)
    first.updateDownloadedOnly(true)

    let library = FakeLibraryReading()
    let second = LibraryBrowseModel(
      library: library, sync: FakeSyncCoordinating(), defaults: defaults)

    #expect(second.filters == BrowseFilters(categories: [.podcast], downloadedOnly: true))
    #expect(
      library.observedBrowseFilters == [BrowseFilters(categories: [.podcast], downloadedOnly: true)],
      "the persisted filter is what the first subscription asks for, not a default it corrects later")
  }

  /// Multiple media kinds are a valid Library selection and must survive the model boundary so the
  /// filter panel can combine them with each other and with Downloaded/playback.
  @MainActor
  @Test("a stored multi-category filter is preserved with the other dimensions")
  func storedMultiCategoryFilterIsPreservedAtTheBoundary() throws {
    let defaults = Self.freshDefaults()
    BrowseFilterStorage.save(
      BrowseFilters(categories: [.podcast, .ebook], downloadedOnly: true, playback: .unfinished),
      for: .library, to: defaults)

    let library = FakeLibraryReading()
    let model = LibraryBrowseModel(
      library: library, sync: FakeSyncCoordinating(), defaults: defaults)

    let expected = BrowseFilters(
      categories: [.podcast, .ebook], downloadedOnly: true, playback: .unfinished)
    #expect(model.filters == expected)
    #expect(model.mediaFilter == .all)
    #expect(library.observedBrowseFilters == [expected])
    #expect(
      BrowseFilterStorage.load(.library, from: defaults) == expected,
      "the complete selection is what survives relaunch")
  }

  // MARK: - Additive media selection (the menu's toggle seam)

  /// The funnel's media rows are `Toggle`s over one set, so the model owns membership rather than
  /// the view rebuilding a `BrowseFilters` per tap.
  @MainActor
  @Test("toggling a media kind on adds it to the selection, preserving the other dimensions")
  func togglingAMediaKindOnAddsItPreservingTheOtherDimensions() throws {
    let model = LibraryBrowseModel(
      library: FakeLibraryReading(), sync: FakeSyncCoordinating(), defaults: Self.freshDefaults())
    model.updateDownloadedOnly(true)
    model.updatePlayback(.finished)

    model.setMediaCategory(.podcast, isOn: true)
    #expect(
      model.filters
        == BrowseFilters(categories: [.podcast], downloadedOnly: true, playback: .finished))

    model.setMediaCategory(.ebook, isOn: true)
    #expect(
      model.filters
        == BrowseFilters(categories: [.podcast, .ebook], downloadedOnly: true, playback: .finished))
  }

  /// Unchecking the last kind means "no media constraint", not "match nothing", the same value a
  /// reader who never touched the rows has.
  @MainActor
  @Test("toggling the last selected media kind off returns to no media constraint")
  func togglingTheLastMediaKindOffReturnsToNoConstraint() throws {
    let model = LibraryBrowseModel(
      library: FakeLibraryReading(), sync: FakeSyncCoordinating(), defaults: Self.freshDefaults())
    model.setMediaCategory(.audiobook, isOn: true)

    model.setMediaCategory(.audiobook, isOn: false)

    #expect(model.filters.categories == nil)
    #expect(model.filters.isActive == false)
  }

  /// What each row's checkmark reads: membership in the set, with "no constraint" showing nothing
  /// checked, never a phantom all-checked state the reader cannot uncheck.
  @MainActor
  @Test("selection membership drives the rows, and no constraint means no kind is selected")
  func selectionMembershipDrivesTheRows() throws {
    let model = LibraryBrowseModel(
      library: FakeLibraryReading(), sync: FakeSyncCoordinating(), defaults: Self.freshDefaults())

    for category in ItemMediaCategory.allCases {
      #expect(model.isMediaCategorySelected(category) == false)
    }

    model.setMediaCategory(.ebook, isOn: true)

    #expect(model.isMediaCategorySelected(.ebook))
    #expect(model.isMediaCategorySelected(.audiobook) == false)
    #expect(model.isMediaCategorySelected(.podcast) == false)
  }

  /// Toggling a kind that is already in the wanted state must not churn the observation, the same
  /// no-op guard every other intent gets.
  @MainActor
  @Test("re-toggling a media kind to its current state does not resubscribe")
  func reTogglingAMediaKindToItsCurrentStateDoesNotResubscribe() throws {
    let library = FakeLibraryReading()
    let model = LibraryBrowseModel(
      library: library, sync: FakeSyncCoordinating(), defaults: Self.freshDefaults())

    model.setMediaCategory(.podcast, isOn: true)
    let subscriptionCount = library.observedBrowseFilters.count

    model.setMediaCategory(.podcast, isOn: true)

    #expect(library.observedBrowseFilters.count == subscriptionCount)
  }

  // MARK: - Filtered-empty

  @MainActor
  @Test("rows hidden behind an active filter are filteredEmpty, not empty")
  func hiddenRowsBehindAnActiveFilterAreFilteredEmpty() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library, startingFrom: BrowseFilters(downloadedOnly: true))

    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date()))
    library.pushBrowseSnapshot(
      filters: BrowseFilters(downloadedOnly: true),
      LibraryBrowseSnapshot(items: [], unfilteredItemCount: 12))
    await waitUntil { model.state != .loading }

    #expect(model.state == .filteredEmpty)
    #expect(model.state.copyKey == "browse.filteredEmpty")
    #expect(model.state.offersClearFilters)
    let copy = model.state.copyText(for: model.filters)
    #expect(copy.localizedCaseInsensitiveContains("filter"))
    #expect(model.state.emptyTitle(for: model.filters) != MediaFilterCopy.emptyTitle(for: .all))
  }

  @MainActor
  @Test("a genuinely empty library is still empty, and offers no Clear Filters")
  func genuinelyEmptyLibraryIsStillEmpty() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library, startingFrom: BrowseFilters(downloadedOnly: true))

    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date()))
    library.pushBrowseSnapshot(
      filters: BrowseFilters(downloadedOnly: true),
      LibraryBrowseSnapshot(items: [], unfilteredItemCount: 0))
    await waitUntil { model.state != .loading }

    #expect(model.state == .empty)
    #expect(model.state.offersClearFilters == false)
  }

  @MainActor
  @Test("an inactive filter over an empty list is empty however many rows the library holds")
  func inactiveFilterNeverProducesFilteredEmpty() async throws {
    // `unfilteredItemCount > 0` with `items == []` and no filter engaged is not a state the query
    // can produce; if it ever arrives, "your filter matched nothing" would be a lie.
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)

    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date()))
    library.pushBrowseSnapshot(
      filters: .unfiltered, LibraryBrowseSnapshot(items: [], unfilteredItemCount: 12))
    await waitUntil { model.state != .loading }

    #expect(model.state == .empty)
  }

  @MainActor
  @Test("filteredEmpty outranks error and stale-offline, because cached rows do exist")
  func filteredEmptyOutranksErrorAndStaleOffline() async throws {
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_000_000))
    let library = FakeLibraryReading()
    let defaults = Self.freshDefaults()
    BrowseFilterStorage.save(BrowseFilters(downloadedOnly: true), for: .library, to: defaults)
    let model = LibraryBrowseModel(
      library: library, sync: FakeSyncCoordinating(), defaults: defaults, clock: clock,
      staleAfter: 60)

    // An incomplete last run and an over-narrow filter: "couldn't load your library" would be
    // false: the rows are cached and present, just filtered out.
    library.pushBrowseSnapshot(
      filters: BrowseFilters(downloadedOnly: true),
      LibraryBrowseSnapshot(items: [], unfilteredItemCount: 40))
    library.pushSyncStatus(
      LibrarySyncStatus(
        isRunning: false, lastRunIncomplete: true,
        lastCompletedAt: Date(timeIntervalSince1970: 1_000_000 - 120)))
    await waitUntil { model.state != .loading }

    #expect(model.state == .filteredEmpty)
  }

  @MainActor
  @Test("an in-flight sync still outranks filteredEmpty - the list may yet fill")
  func inFlightSyncOutranksFilteredEmpty() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library, startingFrom: BrowseFilters(downloadedOnly: true))

    library.pushBrowseSnapshot(
      filters: BrowseFilters(downloadedOnly: true),
      LibraryBrowseSnapshot(items: [], unfilteredItemCount: 40))
    library.pushSyncStatus(LibrarySyncStatus(isRunning: true, lastRunIncomplete: false, lastCompletedAt: nil))
    await waitUntil { model.state != .loading }

    #expect(model.state == .partiallySynced([]))
  }

  @MainActor
  @Test("filteredEmpty has a distinct copy key and non-empty banner copy like every other state")
  func filteredEmptyJoinsTheCopyKeyContract() throws {
    let states: [LibraryBrowseModel.State] = [
      .loading, .empty, .loaded([]), .partiallySynced([]), .error, .staleOffline([]), .filteredEmpty,
    ]
    let keys = states.map(\.copyKey)

    #expect(Set(keys).count == keys.count)
    for state in states where state != .loaded([]) {
      #expect(state.copyText(for: BrowseFilters(downloadedOnly: true)).isEmpty == false)
    }
  }

  @MainActor
  @Test("the quick filter canonicalizes each title once across keystrokes and repeated reads")
  func quickFilterReusesTitleKeysAcrossKeystrokes() async throws {
    let library = FakeLibraryReading()
    let model = try Self.model(library: library)
    let dune = Self.makeItem(id: "dune", title: "Dune", author: "Frank Herbert")
    let lathe = Self.makeItem(id: "lathe", title: "The Lathe of Heaven", author: "Ursula K. Le Guin")
    let tehanu = Self.makeItem(id: "tehanu", title: "Tehanu", author: "Ursula K. Le Guin")

    #expect(model.quickFilteredItems(query: "dune").isEmpty)

    library.pushSyncStatus(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date()))
    library.pushBrowseList([dune, lathe, tehanu])
    await waitUntil { model.state != .loading }

    #expect(model.quickFilteredItems(query: "") == [dune, lathe, tehanu])
    #expect(model.titleSearchKeyComputations == 0)

    #expect(model.quickFilteredItems(query: "ursula").map(\.id) == ["lathe", "tehanu"])
    #expect(model.quickFilteredItems(query: "ursula").map(\.id) == ["lathe", "tehanu"])
    #expect(model.quickFilteredItems(query: "ursula le").map(\.id) == ["lathe", "tehanu"])
    #expect(model.quickFilteredItems(query: "Heaven").map(\.id) == ["lathe"])
    #expect(model.titleSearchKeyComputations == 3)

    let renamed = Self.makeItem(id: "tehanu", title: "Tehanu: The Last Book of Earthsea", author: nil)
    library.pushBrowseList([dune, lathe, renamed])
    await waitUntil { model.state == .loaded([dune, lathe, renamed]) }

    #expect(model.quickFilteredItems(query: "ursula").map(\.id) == ["lathe"])
    #expect(model.quickFilteredItems(query: "earthsea").map(\.id) == ["tehanu"])
    #expect(model.titleSearchKeyComputations == 4)
  }

  // MARK: - Helpers

  /// A model over a fresh, isolated defaults suite. Every test in this suite goes through here:
  /// the filter persists, so a model built against `UserDefaults.standard` would both read and
  /// write state shared with every other test in the process.
  @MainActor
  private static func model(
    library: FakeLibraryReading,
    sync: FakeSyncCoordinating = FakeSyncCoordinating(),
    startingFrom filters: BrowseFilters = .unfiltered,
    clock: any SyncClock = SystemSyncClock(),
    staleAfter: TimeInterval = AppModelStaleness.defaultStaleAfter
  ) throws -> LibraryBrowseModel {
    let defaults = freshDefaults()
    BrowseFilterStorage.save(filters, for: .library, to: defaults)
    return LibraryBrowseModel(
      library: library, sync: sync, defaults: defaults, clock: clock, staleAfter: staleAfter)
  }

  private static func freshDefaults() -> FakeBrowseFilterDefaults { FakeBrowseFilterDefaults() }

  /// The reading of "these rows and nothing hidden", for the cases that are about the list,
  /// not about the filtered/empty distinction.
  private static func snapshot(_ items: [ItemSummary]) -> LibraryBrowseSnapshot {
    LibraryBrowseSnapshot(items: items, unfilteredItemCount: items.count)
  }

  private static func makeItem(id: String) -> ItemSummary {
    ItemSummary(serverItemId: id, mediaKind: "book", title: "Title \(id)", author: nil, durationSeconds: nil)
  }

  private static func makeItem(id: String, title: String, author: String?) -> ItemSummary {
    ItemSummary(serverItemId: id, mediaKind: "book", title: title, author: author, durationSeconds: nil)
  }
}

@MainActor
private final class LibraryStateRecorder {
  private(set) var states: [LibraryBrowseModel.State]
  private let model: LibraryBrowseModel

  init(_ model: LibraryBrowseModel) {
    self.model = model
    self.states = [model.state]
    observe()
  }

  private func observe() {
    withObservationTracking {
      _ = model.state
    } onChange: { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.states.append(self.model.state)
        self.observe()
      }
    }
  }
}
