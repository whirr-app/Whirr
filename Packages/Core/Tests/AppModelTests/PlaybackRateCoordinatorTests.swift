import Foundation
import Persistence
import PlayerCore
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlaybackRateCoordinatorTests {
  /// The last value the listener saw is the one that commits. The intermediate speeds a drag
  /// passes through are not worth a write, and each would re-emit `observeOverrides` into every
  /// rate reader on screen.
  @Test("a drag's overrides collapse to the last value the listener saw")
  func rapidOverrideWritesCollapseToTheLastValue() async {
    let (coordinator, store, _, _) = Self.makeCoordinator()
    let rates = [1.1, 1.2, 1.3, 1.4, 1.5]

    for rate in rates {
      coordinator.setOverride(rate, itemID: "book")
    }
    await coordinator.waitForPendingWrites()

    #expect(store.calls == [.upsert(itemID: "book", rateStep: 30)])
    #expect(coordinator.overrides["book"] == PlaybackRateResolution.step(forRate: rates.last!))
  }

  /// The other half of the contract: superseding is about writes still queued behind a drag, not
  /// about dropping changes. A speed the listener actually settled on always reaches the database.
  @Test("overrides made one at a time each reach the database")
  func spacedOverrideWritesAllCommit() async {
    let (coordinator, store, _, _) = Self.makeCoordinator()
    let rates = [1.1, 1.2, 1.3]

    for rate in rates {
      coordinator.setOverride(rate, itemID: "book")
      await coordinator.waitForPendingWrites()
    }

    #expect(
      store.calls
        == rates.map {
          .upsert(itemID: "book", rateStep: PlaybackRateResolution.step(forRate: $0)!)
        })
  }

  /// Superseding is per title. One title's newer speed must not swallow another's, which a single
  /// global "newest write wins" token would do.
  @Test("a newer speed for one title does not supersede another title's")
  func supersedingIsPerTitle() async {
    let (coordinator, store, _, _) = Self.makeCoordinator()

    coordinator.setOverride(1.1, itemID: "a")
    coordinator.setOverride(1.2, itemID: "b")
    coordinator.setOverride(1.3, itemID: "a")
    await coordinator.waitForPendingWrites()

    #expect(
      store.calls
        == [
          .upsert(itemID: "b", rateStep: PlaybackRateResolution.step(forRate: 1.2)!),
          .upsert(itemID: "a", rateStep: PlaybackRateResolution.step(forRate: 1.3)!),
        ])
    #expect(coordinator.overrides["a"] == PlaybackRateResolution.step(forRate: 1.3))
    #expect(coordinator.overrides["b"] == PlaybackRateResolution.step(forRate: 1.2))
  }

  /// Clearing is a write on the same title, so it takes part in the same superseding, in both
  /// directions. Whichever the listener did last is what the database ends up holding.
  @Test("clearing and setting supersede each other on one title")
  func clearAndSetSupersedeEachOther() async {
    let (coordinator, store, _, _) = Self.makeCoordinator()

    coordinator.setOverride(1.4, itemID: "book")
    coordinator.clearOverride(itemID: "book")
    await coordinator.waitForPendingWrites()
    #expect(store.calls == [.delete(itemID: "book")])
    #expect(coordinator.overrides["book"] == nil)

    coordinator.clearOverride(itemID: "book")
    coordinator.setOverride(1.6, itemID: "book")
    await coordinator.waitForPendingWrites()
    #expect(
      store.calls
        == [
          .delete(itemID: "book"),
          .upsert(itemID: "book", rateStep: PlaybackRateResolution.step(forRate: 1.6)!),
        ])
    #expect(coordinator.overrides["book"] == PlaybackRateResolution.step(forRate: 1.6))
  }

  /// Clearing every override is not a per-title write and must not be reordered around one: a
  /// pinned speed requested before it still commits first, and is then wiped.
  @Test("clearing all overrides keeps its place behind a pending write")
  func clearAllKeepsItsPlaceBehindAPendingWrite() async {
    let (coordinator, store, _, _) = Self.makeCoordinator()

    coordinator.setOverride(1.4, itemID: "book")
    coordinator.clearAllOverrides()
    await coordinator.waitForPendingWrites()

    #expect(
      store.calls
        == [
          .upsert(itemID: "book", rateStep: PlaybackRateResolution.step(forRate: 1.4)!),
          .deleteAll,
        ])
    #expect(coordinator.overrides.isEmpty)
  }

  @Test("a failed override write is surfaced and does not update the cache")
  func failedOverrideWriteIsSurfaced() async {
    let (coordinator, store, _, _) = Self.makeCoordinator()
    store.setShouldThrow(true)

    coordinator.setOverride(1.8, itemID: "book")
    await coordinator.waitForPendingWrites()

    #expect(coordinator.writeFailureMessage == "Couldn't save that playback speed. Try again.")
    #expect(coordinator.overrides["book"] == nil)

    store.setShouldThrow(false)
    coordinator.setOverride(1.6, itemID: "book")
    await coordinator.waitForPendingWrites()

    #expect(coordinator.writeFailureMessage == nil)
    #expect(coordinator.overrides["book"] == PlaybackRateResolution.step(forRate: 1.6))
  }

  /// The app root's alert dismisses through this. Acknowledging the failure must not retry the
  /// write or pretend it landed: the cache still holds only what the database accepted.
  @Test("dismissing a write failure clears the message and writes nothing")
  func dismissingAWriteFailureWritesNothing() async {
    let (coordinator, store, _, _) = Self.makeCoordinator()
    store.setShouldThrow(true)
    coordinator.setOverride(1.8, itemID: "book")
    await coordinator.waitForPendingWrites()
    #expect(coordinator.writeFailureMessage != nil)
    let callsBeforeDismissal = store.calls

    coordinator.dismissWriteFailure()
    await coordinator.waitForPendingWrites()

    #expect(coordinator.writeFailureMessage == nil)
    #expect(store.calls == callsBeforeDismissal)
    #expect(coordinator.overrides["book"] == nil)
  }

  @Test("setting the loaded title's override changes the audio")
  func loadedTitleOverrideIsHeard() async {
    let (coordinator, _, player, _) = Self.makeCoordinator()
    coordinator.itemDidLoad("book")

    coordinator.setOverride(1.8, itemID: "book")
    await coordinator.waitForPendingWrites()

    #expect(Self.setRateCalls(player.intents) == [1.8])
  }

  @Test("setting another title's override does not change the audio")
  func inactiveTitleOverrideIsNotHeard() async {
    let (coordinator, _, player, _) = Self.makeCoordinator()
    coordinator.itemDidLoad("book")

    coordinator.setOverride(1.8, itemID: "another-book")
    await coordinator.waitForPendingWrites()

    #expect(Self.setRateCalls(player.intents).isEmpty)
  }

  @Test("clearing the loaded title's override makes it adopt the global default")
  func clearingLoadedTitleOverrideIsHeard() async {
    let (coordinator, _, player, _) = Self.makeCoordinator(initialRate: 1.5)
    coordinator.itemDidLoad("book")
    coordinator.setOverride(1.8, itemID: "book")
    await coordinator.waitForPendingWrites()

    coordinator.clearOverride(itemID: "book")
    await coordinator.waitForPendingWrites()

    #expect(Self.setRateCalls(player.intents) == [1.8, 1.5])
    #expect(coordinator.hasOverride(forItemID: "book") == false)
  }

  @Test("the global default is heard only by a loaded title that inherits it")
  func globalDefaultOnlyReachesLoadedInheritingTitle() async {
    let (overridden, _, overriddenPlayer, _) = Self.makeCoordinator()
    overridden.itemDidLoad("book")
    overridden.setOverride(1.8, itemID: "book")
    await overridden.waitForPendingWrites()

    overridden.setGlobalDefault(1.25)
    #expect(Self.setRateCalls(overriddenPlayer.intents) == [1.8])

    let (inheriting, _, inheritingPlayer, _) = Self.makeCoordinator()
    inheriting.itemDidLoad("book")
    inheriting.setGlobalDefault(1.25)

    #expect(Self.setRateCalls(inheritingPlayer.intents) == [1.25])
  }

  @Test("a preset write pins the title whether or not it already had its own speed")
  func presetWritesAlwaysPinTheTitle() async {
    let (coordinator, store, _, preferences) = Self.makeCoordinator()
    store.pushOverrides(["pinned-book": PlaybackRateResolution.step(forRate: 1.6)!])
    await waitUntil { coordinator.hasOverride(forItemID: "pinned-book") }

    coordinator.setOverride(1.8, itemID: "pinned-book")
    coordinator.setOverride(1.4, itemID: "inheriting-book")
    await coordinator.waitForPendingWrites()

    #expect(
      store.calls == [
        .upsert(itemID: "pinned-book", rateStep: 36),
        .upsert(itemID: "inheriting-book", rateStep: 28),
      ])
    // The point of the rule: an unpinned title is pinned by the tap rather than the tap reaching
    // past it to the default. Nothing the player menu can do moves what other titles play at.
    #expect(preferences.savedRates.isEmpty)
    #expect(coordinator.globalDefaultRate == 1)
  }

  @Test("the loaded-title write pins the loaded title rather than the default")
  func loadedTitleWritePinsTheLoadedTitle() async {
    let (coordinator, store, _, preferences) = Self.makeCoordinator()
    store.pushOverrides(["pinned-book": PlaybackRateResolution.step(forRate: 1.6)!])
    await waitUntil { coordinator.hasOverride(forItemID: "pinned-book") }

    coordinator.itemDidLoad("pinned-book")
    coordinator.setRateForLoadedTitle(1.8)
    await coordinator.waitForPendingWrites()

    coordinator.itemDidLoad("inheriting-book")
    coordinator.setRateForLoadedTitle(1.4)
    await coordinator.waitForPendingWrites()

    // The lock screen and the on-screen menu have to agree, so this is the same rule: the thing
    // that is playing is the thing that gets pinned.
    #expect(
      store.calls == [
        .upsert(itemID: "pinned-book", rateStep: 36),
        .upsert(itemID: "inheriting-book", rateStep: 28),
      ])
    #expect(preferences.savedRates.isEmpty)
  }

  @Test("the loaded-title scope does nothing when no title is loaded")
  func loadedTitleScopeDoesNothingWithoutLoadedTitle() async {
    let (coordinator, store, player, preferences) = Self.makeCoordinator()
    let initialRate = coordinator.globalDefaultRate

    coordinator.setRateForLoadedTitle(1.8)
    await coordinator.waitForPendingWrites()

    #expect(store.calls.isEmpty)
    #expect(preferences.savedRates.isEmpty)
    #expect(coordinator.globalDefaultRate == initialRate)
    #expect(player.intents.isEmpty)
  }

  @Test("override observation hydrates the cache and later emissions replace it")
  func overrideObservationHydratesAndReplacesCache() async {
    let (coordinator, store, _, _) = Self.makeCoordinator(initialRate: 1.25)
    store.pushOverrides([
      "book-a": PlaybackRateResolution.step(forRate: 1.1)!,
      "book-b": PlaybackRateResolution.step(forRate: 1.7)!,
    ])
    await waitUntil {
      coordinator.overrides == [
        "book-a": PlaybackRateResolution.step(forRate: 1.1)!,
        "book-b": PlaybackRateResolution.step(forRate: 1.7)!,
      ]
    }

    store.pushOverrides(["book-c": PlaybackRateResolution.step(forRate: 2.0)!])
    await waitUntil { coordinator.overrides == ["book-c": 40] }

    #expect(coordinator.effectiveRate(forItemID: "book-a") == 1.25)
    #expect(coordinator.effectiveRate(forItemID: "book-c") == 2.0)
  }

  @Test("an override equal to the default remains pinned when the default changes")
  func equalValuedOverrideRemainsPinned() async {
    let (coordinator, store, _, _) = Self.makeCoordinator(initialRate: 1.5)
    store.pushOverrides(["book": PlaybackRateResolution.step(forRate: 1.5)!])
    await waitUntil { coordinator.hasOverride(forItemID: "book") }

    coordinator.setGlobalDefault(2.0)

    #expect(coordinator.hasOverride(forItemID: "book"))
    #expect(coordinator.effectiveRate(forItemID: "book") == 1.5)
  }

  /// A slider drag calls `setGlobalDefault` on every gesture tick and `PlaybackRateResolution`
  /// quantises to twentieths, so most ticks carry a rate already held. Persisting each would write
  /// `UserDefaults` at gesture frequency, and its notification names no key, so every
  /// `@AppStorage` reader in the process would rebuild behind the sheet. Only genuine changes are
  /// durable, and the engine hears each speed once.
  @Test("a drag persists once per speed it passes through, not once per gesture tick")
  func dragPersistsOncePerDistinctRate() {
    let (coordinator, _, player, preferences) = Self.makeCoordinator(initialRate: 1.0)
    coordinator.itemDidLoad("book")

    // 1.0 → 1.15, sampled the way a slider samples: many ticks inside each twentieth.
    let drag = [
      1.0, 1.01, 1.02, 1.04, 1.05, 1.06, 1.07, 1.09, 1.1, 1.11, 1.12, 1.13, 1.14, 1.149, 1.15,
    ]
    for rate in drag {
      coordinator.setGlobalDefault(rate)
    }

    #expect(preferences.savedRates == [1.05, 1.1, 1.15])
    #expect(coordinator.globalDefaultRate == 1.15)
    #expect(Self.setRateCalls(player.intents) == [1.05, 1.1, 1.15])
  }

  /// Guarding on the in-memory value alone is a trap. A fresh install holds `1.0` without having
  /// persisted anything, so an explicit choice of `1.0` would look redundant and never be
  /// written, leaving `player.skipInterval`-style divergence for iCloud to resolve the wrong way
  /// at the next reconcile. The guard compares against what was actually stored.
  @Test("explicitly choosing the default rate on a fresh install is still persisted")
  func explicitDefaultRateOnAFreshInstallIsPersisted() {
    let (coordinator, _, _, preferences) = Self.makeCoordinator(initialRate: nil)

    coordinator.setGlobalDefault(1.0)

    #expect(preferences.savedRates == [1.0])
  }

  /// A stored value outside the supported range never became the coordinator's rate, so it must not
  /// suppress the first real write either.
  @Test("an unusable stored rate does not suppress the first write")
  func unusableStoredRateDoesNotSuppressTheFirstWrite() {
    let (coordinator, _, _, preferences) = Self.makeCoordinator(initialRate: 7.0)

    coordinator.setGlobalDefault(1.0)

    #expect(preferences.savedRates == [1.0])
  }

  @Test("RSS identities route their show speed to the device-owned feed settings")
  func rssOverrideRoutesToFeedSettings() async {
    let (coordinator, abs, rss, _, _) = Self.makeRoutedCoordinator()

    coordinator.setOverride(1.8, itemID: "rss:7")
    await coordinator.waitForPendingWrites()

    #expect(abs.calls.isEmpty)
    #expect(rss.calls == [.set(feedId: 7, rateStep: 36)])
    #expect(coordinator.overrides["rss:7"] == 36)
  }

  @Test("the composed read surface merges ABS item and RSS feed overrides")
  func routedReadMergesBothOrigins() async throws {
    let abs = FakeItemPlaybackSettingsAccess(initialOverrides: ["book": 22])
    let rss = FakeRSSPlaybackRateSettingsAccess(initialOverrides: [7: 44])
    let access = RoutingItemPlaybackSettingsAccess(abs: abs, rss: rss)

    #expect(try await access.fetchOverride(itemID: "book") == 22)
    #expect(try await access.fetchOverride(itemID: "rss:7") == 44)
    #expect(try await access.fetchOverrides() == ["book": 22, "rss:7": 44])
  }

  @Test("clear all clears ABS and RSS overrides while preserving the composed facade")
  func clearAllOverridesRoutesToBothStores() async {
    let (coordinator, abs, rss, _, _) = Self.makeRoutedCoordinator()
    coordinator.setOverride(1.2, itemID: "book")
    coordinator.setOverride(1.6, itemID: "rss:7")
    await coordinator.waitForPendingWrites()

    coordinator.clearAllOverrides()
    await coordinator.waitForPendingWrites()

    #expect(abs.calls.last == .deleteAll)
    #expect(rss.calls.last == .clearAll)
    #expect(coordinator.overrides.isEmpty)
  }

  // MARK: - Focus speed

  @Test("a Focus speed writes nothing durable")
  func focusSpeedWritesNothing() async {
    let (coordinator, store, _, preferences) = Self.makeCoordinator(initialRate: 1.2)
    coordinator.itemDidLoad("book")

    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9))
    coordinator.setFocusSpeed(nil)
    await coordinator.waitForPendingWrites()

    #expect(store.calls.isEmpty)
    #expect(preferences.savedRates.isEmpty)
    #expect(coordinator.globalDefaultRate == 1.2)
  }

  @Test("a Focus turning on and off is heard live by the loaded title")
  func focusSpeedIsHeardLiveBothWays() async {
    let (coordinator, store, player, _) = Self.makeCoordinator(initialRate: 1.2)
    store.pushOverrides(["book": PlaybackRateResolution.step(forRate: 1.5)!])
    await waitUntil { coordinator.hasOverride(forItemID: "book") }
    coordinator.itemDidLoad("book")
    player.state.rate = 1.5

    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9))
    #expect(coordinator.effectiveRate(forItemID: "book") == 0.9)
    #expect(coordinator.effectiveRate(forItemID: "other") == 0.9)
    player.state.rate = 0.9

    coordinator.setFocusSpeed(nil)
    #expect(coordinator.effectiveRate(forItemID: "book") == 1.5)
    #expect(coordinator.effectiveRate(forItemID: "other") == 1.2)
    #expect(Self.setRateCalls(player.intents) == [0.9, 1.5])
  }

  @Test("a Focus change is sent only when the loaded title's rate changes")
  func focusSpeedSentOnlyWhenTheLoadedRateChanges() async {
    let (coordinator, store, player, _) = Self.makeCoordinator(initialRate: 1.0)
    store.pushOverrides(["book": PlaybackRateResolution.step(forRate: 1.5)!])
    await waitUntil { coordinator.hasOverride(forItemID: "book") }
    coordinator.itemDidLoad("book")
    player.state.rate = 1.5

    // Skipping titles with their own speed leaves this pinned title where it is.
    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: true))
    #expect(coordinator.effectiveRate(forItemID: "book") == 1.5)
    #expect(coordinator.effectiveRate(forItemID: "other") == 0.9)
    // A repeat of the same value, as reconcile delivers it, is not a change.
    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: true))

    #expect(player.intents.isEmpty)
  }

  @Test("with nothing loaded, a Focus change resets the idle engine rate")
  func focusSpeedResetsTheIdleEngine() {
    let (coordinator, _, player, _) = Self.makeCoordinator(initialRate: 1.2)
    player.state.rate = 1.2

    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9))
    player.state.rate = 0.9
    coordinator.setFocusSpeed(nil)

    #expect(Self.setRateCalls(player.intents) == [0.9, 1.2])
  }

  @Test("Use Default, a default edit and clear-all keep the Focus speed while it governs")
  func durableEditsKeepTheGoverningFocusSpeed() async {
    let (coordinator, store, player, preferences) = Self.makeCoordinator(initialRate: 1.2)
    store.pushOverrides(["book": PlaybackRateResolution.step(forRate: 1.5)!])
    await waitUntil { coordinator.hasOverride(forItemID: "book") }
    coordinator.itemDidLoad("book")
    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9))
    player.state.rate = 0.9
    let sentBefore = player.intents.count

    coordinator.clearOverride(itemID: "book")
    coordinator.setGlobalDefault(1.4)
    coordinator.clearAllOverrides()
    await coordinator.waitForPendingWrites()

    #expect(player.intents.count == sentBefore)
    #expect(coordinator.effectiveRate(forItemID: "book") == 0.9)
    // The durable edits themselves still land.
    #expect(store.calls == [.delete(itemID: "book"), .deleteAll])
    #expect(preferences.savedRates == [1.4])
  }

  @Test("clearing a pinned title's speed under a skipping Focus hands it to the Focus")
  func clearingAPinUnderASkippingFocusAdoptsTheFocus() async {
    let (coordinator, store, player, _) = Self.makeCoordinator(initialRate: 1.2)
    store.pushOverrides(["book": PlaybackRateResolution.step(forRate: 1.5)!])
    await waitUntil { coordinator.hasOverride(forItemID: "book") }
    coordinator.itemDidLoad("book")
    player.state.rate = 1.5
    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: true))

    coordinator.clearOverride(itemID: "book")
    await coordinator.waitForPendingWrites()

    #expect(Self.setRateCalls(player.intents) == [0.9])
  }

  @Test("a quick adjustment under a Focus stays in the session and writes nothing")
  func quickAdjustmentUnderAFocusStaysInTheSession() async {
    let (coordinator, store, player, preferences) = Self.makeCoordinator(initialRate: 1.2)
    coordinator.itemDidLoad("book")
    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9))
    player.state.rate = 0.9

    #expect(coordinator.adjustLoadedTitleRate(0.8))
    await coordinator.waitForPendingWrites()

    #expect(store.calls.isEmpty)
    #expect(preferences.savedRates.isEmpty)
    #expect(coordinator.effectiveRate(forItemID: "book") == 0.8)
    #expect(coordinator.effectiveRate(forItemID: "next-book") == 0.8)
    #expect(Self.setRateCalls(player.intents) == [0.9, 0.8])
    player.state.rate = 0.8

    // A reconcile repeating the same Focus keeps the adjustment; the Focus ending drops it.
    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9))
    #expect(coordinator.effectiveRate(forItemID: "book") == 0.8)
    coordinator.setFocusSpeed(nil)
    #expect(coordinator.effectiveRate(forItemID: "book") == 1.2)
    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9))
    #expect(coordinator.effectiveRate(forItemID: "book") == 0.9)
  }

  @Test("a quick adjustment without a governing Focus pins the loaded title")
  func quickAdjustmentWithoutAFocusPins() async {
    let (coordinator, store, player, _) = Self.makeCoordinator(initialRate: 1.2)

    #expect(coordinator.adjustLoadedTitleRate(1.4) == false)

    coordinator.itemDidLoad("book")
    #expect(coordinator.adjustLoadedTitleRate(1.4))
    await coordinator.waitForPendingWrites()
    #expect(store.calls == [.upsert(itemID: "book", rateStep: 28)])
    #expect(Self.setRateCalls(player.intents) == [1.4])

    // A skipping Focus does not govern a pinned title, so the tap pins it again.
    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: true))
    #expect(coordinator.adjustLoadedTitleRate(1.6))
    await coordinator.waitForPendingWrites()
    #expect(store.calls.last == .upsert(itemID: "book", rateStep: 32))
  }

  /// The player menus can be drawn for a title that is not the one loaded. A tap there must still
  /// pin that title, not adjust the session of whatever happens to be playing.
  @Test("a quick adjustment for a title that is not loaded pins that title")
  func quickAdjustmentForAnotherTitlePinsIt() async {
    let (coordinator, store, player, _) = Self.makeCoordinator(initialRate: 1.2)
    coordinator.itemDidLoad("book")
    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9))

    coordinator.adjustRate(1.4, itemID: "other-book")
    coordinator.adjustRate(0.8, itemID: "book")
    await coordinator.waitForPendingWrites()

    #expect(store.calls == [.upsert(itemID: "other-book", rateStep: 28)])
    #expect(coordinator.effectiveRate(forItemID: "book") == 0.8)
    #expect(Self.setRateCalls(player.intents) == [0.9, 0.8])
  }

  @Test("a title's stored speed reads as stored while a Focus governs it")
  func storedOverrideIgnoresTheFocus() async {
    let (coordinator, store, _, _) = Self.makeCoordinator(initialRate: 1.2)
    store.pushOverrides(["show": PlaybackRateResolution.step(forRate: 1.5)!])
    await waitUntil { coordinator.hasOverride(forItemID: "show") }

    coordinator.setFocusSpeed(FocusSpeed(rate: 0.9))

    #expect(coordinator.effectiveRate(forItemID: "show") == 0.9)
    #expect(coordinator.overrideRate(forItemID: "show") == 1.5)
    #expect(coordinator.overrideRate(forItemID: "other") == nil)
    #expect(coordinator.overrideRate(forItemID: nil) == nil)
  }

  @Test("the Focus speed given at construction governs from the start")
  func initialFocusSpeedFromInit() {
    let store = FakeItemPlaybackSettingsAccess()
    let player = FakePlaybackControlling()
    let coordinator = PlaybackRateCoordinator(
      reading: store, writing: store, preferences: FakePlaybackPreferences(initialRate: 1.2),
      player: player, focusSpeed: FocusSpeed(rate: 0.9))

    #expect(coordinator.focusSpeed == FocusSpeed(rate: 0.9))
    #expect(coordinator.effectiveRate(forItemID: "book") == 0.9)
    #expect(coordinator.focusRate(forItemID: "book") == 0.9)
    #expect(player.intents.isEmpty)
  }

  private static func makeCoordinator(
    initialRate: Double? = 1.0
  ) -> (
    coordinator: PlaybackRateCoordinator,
    store: FakeItemPlaybackSettingsAccess,
    player: FakePlaybackControlling,
    preferences: FakePlaybackPreferences
  ) {
    let store = FakeItemPlaybackSettingsAccess()
    let player = FakePlaybackControlling()
    let preferences = FakePlaybackPreferences(initialRate: initialRate)
    let coordinator = PlaybackRateCoordinator(
      reading: store, writing: store, preferences: preferences, player: player)
    return (coordinator, store, player, preferences)
  }

  private static func makeRoutedCoordinator() -> (
    coordinator: PlaybackRateCoordinator,
    abs: FakeItemPlaybackSettingsAccess,
    rss: FakeRSSPlaybackRateSettingsAccess,
    player: FakePlaybackControlling,
    preferences: FakePlaybackPreferences
  ) {
    let abs = FakeItemPlaybackSettingsAccess()
    let rss = FakeRSSPlaybackRateSettingsAccess()
    let player = FakePlaybackControlling()
    let preferences = FakePlaybackPreferences(initialRate: 1.0)
    let access = RoutingItemPlaybackSettingsAccess(abs: abs, rss: rss)
    let coordinator = PlaybackRateCoordinator(
      reading: access, writing: access, preferences: preferences, player: player)
    return (coordinator, abs, rss, player, preferences)
  }

  private static func setRateCalls(_ intents: [PlayerIntent]) -> [Double] {
    intents.compactMap { intent in
      if case .setRate(let rate) = intent { return rate }
      return nil
    }
  }
}

final class FakeItemPlaybackSettingsAccess: ItemPlaybackSettingsReading,
  ItemPlaybackSettingsWriting, @unchecked Sendable
{
  enum Call: Sendable, Equatable {
    case upsert(itemID: String, rateStep: Int)
    case delete(itemID: String)
    case deleteAll
  }

  private let callsBox = PlaybackRateTestLocked<[Call]>([])
  private let overridesBox: PlaybackRateTestLocked<[String: Int]>
  private let shouldThrowBox = PlaybackRateTestLocked(false)
  private let observationContinuation: AsyncStream<[String: Int]>.Continuation
  private let observationStream: AsyncStream<[String: Int]>

  var calls: [Call] { callsBox.value }

  init(initialOverrides: [String: Int] = [:]) {
    overridesBox = PlaybackRateTestLocked(initialOverrides)
    var continuation: AsyncStream<[String: Int]>.Continuation!
    observationStream = AsyncStream { continuation = $0 }
    observationContinuation = continuation
  }

  func setShouldThrow(_ shouldThrow: Bool) {
    shouldThrowBox.value = shouldThrow
  }

  func pushOverrides(_ overrides: [String: Int]) {
    overridesBox.value = overrides
    observationContinuation.yield(overrides)
  }

  func fetchOverride(itemID: String) async throws -> Int? {
    overridesBox.value[itemID]
  }

  func fetchOverrides() async throws -> [String: Int] {
    overridesBox.value
  }

  func observeOverrides() -> AsyncStream<[String: Int]> {
    observationStream
  }

  func upsertOverride(itemID: String, rateStep: Int) async throws {
    callsBox.withValue { $0.append(.upsert(itemID: itemID, rateStep: rateStep)) }
    try throwIfRequested()
    overridesBox.withValue { $0[itemID] = rateStep }
  }

  func deleteOverride(itemID: String) async throws {
    callsBox.withValue { $0.append(.delete(itemID: itemID)) }
    try throwIfRequested()
    overridesBox.withValue { $0[itemID] = nil }
  }

  func deleteAllOverrides() async throws {
    callsBox.withValue { $0.append(.deleteAll) }
    try throwIfRequested()
    overridesBox.value = [:]
  }

  private func throwIfRequested() throws {
    if shouldThrowBox.value { throw FakePlaybackSettingsWriteError.failed }
  }
}

final class FakeRSSPlaybackRateSettingsAccess: RSSPlaybackRateSettingsReading,
  RSSPlaybackRateSettingsWriting, @unchecked Sendable
{
  enum Call: Sendable, Equatable {
    case set(feedId: Int64, rateStep: Int)
    case clear(feedId: Int64)
    case clearAll
  }

  private let callsBox = PlaybackRateTestLocked<[Call]>([])
  private let overridesBox = PlaybackRateTestLocked<[Int64: Int]>([:])
  private let observationContinuation: AsyncStream<[Int64: Int]>.Continuation
  private let observationStream: AsyncStream<[Int64: Int]>

  var calls: [Call] { callsBox.value }

  init(initialOverrides: [Int64: Int] = [:]) {
    overridesBox.value = initialOverrides
    var continuation: AsyncStream<[Int64: Int]>.Continuation!
    observationStream = AsyncStream { continuation = $0 }
    observationContinuation = continuation
  }

  func fetchRateOverride(feedId: Int64) async throws -> Int? { overridesBox.value[feedId] }

  func fetchRateOverrides() async throws -> [Int64: Int] { overridesBox.value }

  func observeRateOverrides() -> AsyncStream<[Int64: Int]> { observationStream }

  func setRateOverride(feedId: Int64, rateStep: Int) async throws {
    callsBox.withValue { $0.append(.set(feedId: feedId, rateStep: rateStep)) }
    overridesBox.withValue { $0[feedId] = rateStep }
    observationContinuation.yield(overridesBox.value)
  }

  func clearRateOverride(feedId: Int64) async throws {
    callsBox.withValue { $0.append(.clear(feedId: feedId)) }
    overridesBox.withValue { $0[feedId] = nil }
    observationContinuation.yield(overridesBox.value)
  }

  func clearAllRateOverrides() async throws {
    callsBox.withValue { $0.append(.clearAll) }
    overridesBox.value = [:]
    observationContinuation.yield([:])
  }
}

private enum FakePlaybackSettingsWriteError: Error, Sendable {
  case failed
}

private final class PlaybackRateTestLocked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) {
    storage = value
  }

  var value: Value {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storage = newValue
    }
  }

  @discardableResult
  func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&storage)
  }
}
