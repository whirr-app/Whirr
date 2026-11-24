import AppModel
import Foundation
import Persistence
import PlayerCore
import Testing

@testable import Whirr

/// The App holder that keeps a Focus filter's speed across account rebuilds, and the filter
/// that delivers to it.
@MainActor
@Suite("Focus playback speed", .serialized)
struct FocusPlaybackSpeedStateTests {
  @Test("the Focus speed key stays on this device")
  func focusKeyIsNotSyncedToICloud() {
    #expect(ICloudSettingsSync.syncedKeys.contains(FocusPlaybackSpeedState.storageKey) == false)
  }

  @Test("a delivery is stored, and a deactivation removes it")
  func deliveryIsStoredAndDeactivationRemovesIt() {
    let defaults = Self.isolatedDefaults()
    let state = FocusPlaybackSpeedState(defaults: defaults)

    state.deliver(FocusFilterValue(speed: FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: true)))
    #expect(
      FocusPlaybackSpeedState(defaults: defaults).focusSpeed == FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: true))

    state.deliver(.noFocus)
    #expect(state.focusSpeed == nil)
    #expect(defaults.object(forKey: FocusPlaybackSpeedState.storageKey) == nil)
  }

  @Test("a deactivation restores the speed the loaded title had before")
  func deactivationRestores() {
    let player = PlayerController(engine: HarnessAudioEngine(), clock: SystemPlaybackClock())
    let coordinator = PlaybackRateCoordinatorFixture.unbound(player: player)
    coordinator.itemDidLoad("book")
    let state = FocusPlaybackSpeedState(defaults: Self.isolatedDefaults())
    state.bind(coordinator)
    let before = coordinator.effectiveRate(forItemID: "book")

    state.deliver(FocusFilterValue(speed: FocusSpeed(rate: 0.9)))
    #expect(coordinator.effectiveRate(forItemID: "book") == 0.9)
    #expect(player.state.rate == 0.9)

    state.deliver(.noFocus)
    #expect(coordinator.effectiveRate(forItemID: "book") == before)
    #expect(player.state.rate == before)
  }

  @Test("the Focus speed survives a composition rebuild")
  func focusSurvivesARebuild() throws {
    let state = FocusPlaybackSpeedState(defaults: Self.isolatedDefaults())
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let first = try Self.composition(hardware: hardware, focus: state)
    state.deliver(FocusFilterValue(speed: FocusSpeed(rate: 0.85)))
    #expect(first.root.playbackRate.focusSpeed == FocusSpeed(rate: 0.85))

    // Login, logout and account rebuilds each build a new graph and coordinator.
    let second = try Self.composition(hardware: hardware, focus: state)
    #expect(second.root.playbackRate.focusSpeed == FocusSpeed(rate: 0.85))

    // Later deliveries reach the current graph's coordinator.
    state.deliver(.noFocus)
    #expect(second.root.playbackRate.focusSpeed == nil)
  }

  @Test("a reconcile corrects a missed delivery and ignores a failed read")
  func reconcileCorrectsAndIgnoresFailures() async {
    let state = FocusPlaybackSpeedState(defaults: Self.isolatedDefaults())
    state.deliver(FocusFilterValue(speed: FocusSpeed(rate: 0.9)))

    await state.reconcile { throw CancellationError() }
    #expect(state.focusSpeed == FocusSpeed(rate: 0.9))

    await state.reconcile { .noFocus }
    #expect(state.focusSpeed == nil)
  }

  @Test("the filter maps its parameters to a Focus speed, with an unset switch meaning off")
  func filterParametersMapToAFocusSpeed() {
    let filter = PlaybackSpeedFocusFilter()
    #expect(filter.focusSpeed == nil)

    filter.speed = .x090
    #expect(filter.focusSpeed == FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: false))
    filter.skipsTitlesWithOwnSpeed = true
    #expect(filter.focusSpeed == FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: true))
  }

  @Test("the filter maps its trim rows, with a blank trim leaving trimming alone")
  func filterParametersMapToAFocusTrim() {
    let filter = PlaybackSpeedFocusFilter()
    #expect(filter.focusValue == .noFocus)

    filter.trimSilences = .off
    #expect(filter.focusValue == FocusFilterValue(trim: FocusTrim(strength: nil, keepsShowSettings: false)))
    filter.trimSilences = .high
    filter.keepsCustomTrim = true
    #expect(filter.focusTrim == FocusTrim(strength: .maximum, keepsShowSettings: true))
    #expect(filter.focusSpeed == nil)
    filter.trimSilences = .low
    #expect(filter.focusTrim?.strength == .moderate)
  }

  @Test("a trim-only delivery is stored with the speed and read by the trim preferences")
  func trimDeliveryIsStoredAndReadByPreferences() {
    let defaults = Self.isolatedDefaults()
    let state = FocusPlaybackSpeedState(defaults: defaults)
    let trim = FocusTrim(strength: nil, keepsShowSettings: true)

    state.deliver(FocusFilterValue(trim: trim))
    #expect(FocusPlaybackSpeedState(defaults: defaults).value == FocusFilterValue(trim: trim))
    #expect(UserDefaultsTrimSilencesPreferences(defaults: defaults).current.focus == trim)

    let both = FocusFilterValue(
      speed: FocusSpeed(rate: 0.9), trim: FocusTrim(strength: .maximum, keepsShowSettings: false))
    state.deliver(both)
    #expect(FocusPlaybackSpeedState(defaults: defaults).value == both)

    state.deliver(.noFocus)
    #expect(defaults.object(forKey: FocusPlaybackSpeedState.storageKey) == nil)
    #expect(UserDefaultsTrimSilencesPreferences(defaults: defaults).current.focus == nil)
  }

  @Test("a Focus trim change emits on the trim default stream, and its end restores the stored one")
  func focusTrimEmitsOnTheDefaultStream() async {
    let defaults = Self.isolatedDefaults()
    let preferences = UserDefaultsTrimSilencesPreferences(defaults: defaults)
    preferences.setEnabled(true)
    preferences.setStrength(.maximum)
    let stored = TrimSilencesDefault(isEnabled: true, strength: .maximum)
    let state = FocusPlaybackSpeedState(defaults: defaults)
    var iterator = preferences.observeDefault().makeAsyncIterator()
    #expect(await iterator.next() == stored)

    let sleep = FocusTrim(strength: nil, keepsShowSettings: false)
    state.deliver(FocusFilterValue(speed: FocusSpeed(rate: 0.9), trim: sleep))
    #expect(await iterator.next() == TrimSilencesDefault(isEnabled: true, strength: .maximum, focus: sleep))

    state.deliver(.noFocus)
    #expect(await iterator.next() == stored)
  }

  @Test("the filter offers 0.5× to 2× in twentieths, each one the resolver accepts")
  func filterSpeedsMatchTheSheetRange() {
    let rates = PlaybackSpeedOption.allCases.map(\.rate)
    #expect(rates.count == 31)
    #expect(rates.first == 0.5)
    #expect(rates.last == 2.0)
    for rate in rates {
      #expect(PlaybackRateResolution.normalizedRate(rate) == rate)
    }
  }

  @Test("the filter offers timed sleep timers from 5 minutes to 2 hours, unset meaning none")
  func filterSleepTimerOptions() {
    #expect(FocusSleepTimerOption.allCases.map(\.minutes) == [5, 10, 15, 20, 25, 30, 45, 60, 90, 120])
    let filter = PlaybackSpeedFocusFilter()
    #expect(filter.focusValue.sleepTimerSeconds == nil)
    filter.sleepTimer = .m25
    #expect(filter.focusValue == FocusFilterValue(sleepTimerSeconds: 25 * 60))
  }

  @Test("a sleep timer delivery is stored, and is the only thing a Focus may carry")
  func sleepTimerDeliveryIsStored() {
    let defaults = Self.isolatedDefaults()
    let state = FocusPlaybackSpeedState(defaults: defaults)

    state.deliver(FocusFilterValue(sleepTimerSeconds: 1800))
    #expect(FocusPlaybackSpeedState(defaults: defaults).value == FocusFilterValue(sleepTimerSeconds: 1800))

    state.deliver(.noFocus)
    #expect(defaults.object(forKey: FocusPlaybackSpeedState.storageKey) == nil)
  }

  @Test("each play under a Focus with a sleep timer starts one")
  func playStartsTheFocusSleepTimer() async {
    let player = Self.playingPlayer()
    let state = FocusPlaybackSpeedState(defaults: Self.isolatedDefaults())
    state.attach(player: player)

    await state.playbackStarted { FocusFilterValue(sleepTimerSeconds: 1200) }

    #expect(player.sentIntents == [.setSleepTimer(.custom(seconds: 1200))])
  }

  @Test("a play leaves a running timer alone, and does nothing without a Focus timer")
  func playLeavesARunningTimerAlone() async {
    let player = Self.playingPlayer()
    player.state.sleepTimer = SleepTimerState(mode: .countdown(remainingSeconds: 300), configuredSeconds: 600)
    let state = FocusPlaybackSpeedState(defaults: Self.isolatedDefaults())
    state.attach(player: player)

    await state.playbackStarted { FocusFilterValue(sleepTimerSeconds: 1800) }
    #expect(player.sentIntents.isEmpty)

    player.state.sleepTimer = .off
    await state.playbackStarted { FocusFilterValue(speed: FocusSpeed(rate: 0.9)) }
    #expect(player.sentIntents.isEmpty)
  }

  @Test("a play whose Focus read fails still starts the stored Focus timer")
  func playWithFailedReadUsesStoredValue() async {
    let player = Self.playingPlayer()
    let state = FocusPlaybackSpeedState(defaults: Self.isolatedDefaults())
    state.deliver(FocusFilterValue(sleepTimerSeconds: 600))
    state.attach(player: player)

    await state.playbackStarted { throw CancellationError() }

    #expect(player.sentIntents == [.setSleepTimer(.custom(seconds: 600))])
  }

  @Test("a Focus turning on mid-listen starts its timer once; turning off leaves it running")
  func deliveryWhileListening() async {
    let player = Self.playingPlayer()
    let state = FocusPlaybackSpeedState(defaults: Self.isolatedDefaults())
    state.attach(player: player)
    let sleep = FocusFilterValue(sleepTimerSeconds: 2700)

    state.deliver(sleep)
    #expect(player.sentIntents == [.setSleepTimer(.custom(seconds: 2700))])

    // The listener turns the timer off; a foreground reconcile of the same Focus must not re-arm.
    await state.reconcile { sleep }
    #expect(player.sentIntents.count == 1)

    state.deliver(.noFocus)
    #expect(player.sentIntents.count == 1)
  }

  @Test("a Focus turning on while paused waits for the next play")
  func deliveryWhilePausedWaits() {
    let player = FakeAdapterPlaybackControlling()
    let state = FocusPlaybackSpeedState(defaults: Self.isolatedDefaults())
    state.attach(player: player)

    state.deliver(FocusFilterValue(sleepTimerSeconds: 900))
    #expect(player.sentIntents.isEmpty)
  }

  private static func playingPlayer() -> FakeAdapterPlaybackControlling {
    let player = FakeAdapterPlaybackControlling()
    player.state.phase = .playing
    player.state.isPlaybackIntended = true
    return player
  }

  private static func isolatedDefaults() -> UserDefaults {
    let name = "whirr-focus-speed-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private static func composition(
    hardware: PlaybackHardware, focus: FocusPlaybackSpeedState
  ) throws -> RootComposition {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "whirr-focus-speed-\(UUID().uuidString)", isDirectory: true)
    return RootComposition(
      hardware: hardware, mode: .runtime, database: try AppDatabase.inMemory(),
      applicationSupportDirectory: directory, watchCompanionRuntime: nil,
      focusPlaybackSpeed: focus)
  }
}
