import MediaPlayer
import PlayerCore
import SyncEngine
import Testing

@testable import Whirr

/// Covers `RemoteCommandAdapter`. Lock-screen and Control Center commands forward to the same
/// `PlaybackControlling`/`PlayerIntent` surface that on-screen controls use. Tests run over a
/// `RemoteCommandRegistering` fake, so none touches `MPRemoteCommandCenter.shared()`.
@MainActor
@Suite("RemoteCommandAdapter")
struct RemoteCommandAdapterTests {

  private static func loadedState(itemId: String = "item-1", position: Double = 10) -> PlayerState {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)])
    let item = PlayerItem(id: itemId, timeline: timeline)
    return PlayerState(phase: .playing, item: item, currentTrackIndex: 0, globalPosition: position, rate: 1.0)
  }

  // MARK: - Registration wires every command

  @Test("registering wires play/pause/toggle/stop/skip/track/seek/rate handlers exactly once")
  func registeringWiresEveryHandlerOnce() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())

    adapter.register()

    #expect(center.playHandler != nil)
    #expect(center.pauseHandler != nil)
    #expect(center.togglePlayPauseHandler != nil)
    #expect(center.stopHandler != nil)
    #expect(center.skipForwardHandler != nil)
    #expect(center.skipForwardIntervalSeconds == 30)
    #expect(center.skipBackwardHandler != nil)
    #expect(center.skipBackwardIntervalSeconds == 15)
    #expect(center.nextTrackHandler != nil)
    #expect(center.previousTrackHandler != nil)
    #expect(center.changePlaybackPositionHandler != nil)
    #expect(center.changePlaybackRateHandler != nil)
    #expect(center.setterCallCount == 10)
  }

  @Test("registering twice only wires each command once")
  func duplicateRegistrationIsIdempotent() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())

    adapter.register()
    adapter.register()

    #expect(center.setterCallCount == 10)
  }

  // MARK: - Commands forward to the same PlayerCore intents on-screen controls use

  @Test("play command sends .play and reports success")
  func playCommandForwardsPlay() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    let status = center.playHandler?()

    #expect(player.sentIntents == [.play])
    #expect(status == .success)
  }

  @Test("pause command sends .pause and reports success")
  func pauseCommandForwardsPause() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    let status = center.pauseHandler?()

    #expect(player.sentIntents == [.pause])
    #expect(status == .success)
  }

  @Test("toggle command sends .toggle and reports success")
  func toggleCommandForwardsToggle() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    let status = center.togglePlayPauseHandler?()

    #expect(player.sentIntents == [.toggle])
    #expect(status == .success)
  }

  @Test("play and toggle recover an unavailable remote stream instead of sending raw intents")
  func playAndToggleRecoverUnavailableRemotePlayback() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let availability = FakePlaybackAvailability()
    availability.unavailableReason = .serverUnreachable
    availability.isTerminalRemotePlaybackFailure = true
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox(),
      playbackAvailability: availability)
    adapter.register()

    let playStatus = center.playHandler?()
    let toggleStatus = center.togglePlayPauseHandler?()

    #expect(playStatus == .success)
    #expect(toggleStatus == .success)
    #expect(availability.recoveryCallCount == 2)
    #expect(player.sentIntents.isEmpty)
  }

  @Test("a terminal RSS stall retries without displaying an ABS outage reason")
  func terminalRSSStallUsesRecoveryWithoutABSReason() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let availability = FakePlaybackAvailability()
    availability.isTerminalRemotePlaybackFailure = true
    // Native playback has no ABS reachability reason.
    availability.unavailableReason = nil
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox(),
      playbackAvailability: availability)
    adapter.register()

    #expect(center.playHandler?() == .success)
    #expect(availability.recoveryCallCount == 1)
    #expect(player.sentIntents.isEmpty)
  }

  @Test("play and toggle route through the sleep-timer latch instead of sending raw intents")
  func playAndToggleRouteThroughTheSleepTimerLatch() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let availability = FakePlaybackAvailability()
    availability.freshLocalSessionResumeResult = true
    // The latch wins even when the server is unreachable, because local playback never needs it.
    availability.unavailableReason = .serverUnreachable
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox(),
      playbackAvailability: availability)
    adapter.register()

    let playStatus = center.playHandler?()
    let toggleStatus = center.togglePlayPauseHandler?()

    #expect(playStatus == .success)
    #expect(toggleStatus == .success)
    #expect(availability.freshLocalSessionResumeCallCount == 2)
    #expect(availability.recoveryCallCount == 0)
    #expect(player.sentIntents.isEmpty)
  }

  @Test("pause never consults the sleep-timer latch")
  func pauseNeverConsultsTheSleepTimerLatch() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let availability = FakePlaybackAvailability()
    availability.freshLocalSessionResumeResult = true
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox(),
      playbackAvailability: availability)
    adapter.register()

    #expect(center.pauseHandler?() == .success)
    #expect(availability.freshLocalSessionResumeCallCount == 0)
    #expect(player.sentIntents == [.pause])
  }

  @Test("a complete local download keeps ordinary remote Play and Toggle behavior")
  func localPlaybackDoesNotEnterRemoteRecovery() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let availability = FakePlaybackAvailability()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox(),
      playbackAvailability: availability)
    adapter.register()

    #expect(center.playHandler?() == .success)
    #expect(center.togglePlayPauseHandler?() == .success)
    #expect(availability.recoveryCallCount == 0)
    #expect(player.sentIntents == [.play, .toggle])
  }

  /// A stream buffering against an unreachable server still has a live session. Refusing to move
  /// its playhead would take working controls away from a listener whose stream may yet resume.
  @Test("pause and skip still act during an unavailable but non-terminal buffer")
  func transportStillActsDuringUnavailableBuffer() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let availability = FakePlaybackAvailability()
    availability.unavailableReason = .serverUnreachable
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox(),
      playbackAvailability: availability)
    adapter.register()

    #expect(center.pauseHandler?() == .success)
    #expect(center.skipForwardHandler?() == .success)
    #expect(player.sentIntents.first == .pause)
  }

  @Test("stop command sends .stop and reports success")
  func stopCommandForwardsStop() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    let status = center.stopHandler?()

    #expect(player.sentIntents == [.stop])
    #expect(status == .success)
  }

  /// Sent as the relative intent rather than a resolved absolute position: `PlayerCore` owns both
  /// the arithmetic and the rule that a skip off the end finishes the item.
  @Test("skip forward command skips 30 seconds ahead")
  func skipForwardSkipsThirtySecondsAhead() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState(position: 10)
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    let status = center.skipForwardHandler?()

    #expect(player.sentIntents == [.skip(by: 30)])
    #expect(status == .success)
  }

  @Test("skip backward command uses the independently configured default")
  func skipBackwardUsesIndependentDefault() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState(position: 50)
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    let status = center.skipBackwardHandler?()

    #expect(player.sentIntents == [.skip(by: -15)])
    #expect(status == .success)
  }

  @Test("next-track command uses the configured forward skip")
  func nextTrackSkipsForward() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState(position: 10)
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    let status = center.nextTrackHandler?()

    #expect(player.sentIntents == [.skip(by: 30)])
    #expect(status == .success)
  }

  @Test("previous-track command uses the configured backward skip")
  func previousTrackSkipsBackward() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState(position: 50)
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    let status = center.previousTrackHandler?()

    #expect(player.sentIntents == [.skip(by: -15)])
    #expect(status == .success)
  }

  @Test("change-playback-position command performs an absolute seek to the given position")
  func changePlaybackPositionSeeksToAbsolutePosition() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState(position: 10)
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    let status = center.changePlaybackPositionHandler?(77)

    #expect(player.sentIntents == [.seek(toGlobalOffset: 77)])
    #expect(status == .success)
  }

  /// The lock screen scrubs within the published timeline. For a chaptered audiobook that is the
  /// current chapter (`NowPlayingChapterWindow`), so the incoming position is an offset into the
  /// chapter, not the book.
  @Test("a scrub on a chaptered audiobook seeks relative to the current chapter")
  func changePlaybackPositionIsChapterRelativeForAChapteredBook() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 150)])
    let chapters = PlaybackChapterMap(chapters: [
      PlaybackChapter(id: "c0", title: "Chapter One", start: 0, end: 50),
      PlaybackChapter(id: "c1", title: "Chapter Two", start: 50, end: 100),
    ])
    player.state = PlayerState(
      phase: .playing,
      item: PlayerItem(id: "item-1", episodeID: nil, timeline: timeline, chapters: chapters),
      currentTrackIndex: 0, globalPosition: 60, rate: 1.0)
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    let status = center.changePlaybackPositionHandler?(20)

    #expect(player.sentIntents == [.seek(toGlobalOffset: 70)])
    #expect(status == .success)
  }

  /// A terminal stall has ended the session, so nothing here can move the playhead. Reporting
  /// success would repeat the silent failure this feature exists to remove, one layer down.
  @Test("skip and seek fail honestly once the stream has terminally stalled")
  func skipAndSeekFailAfterTerminalStall() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState(position: 50)
    let availability = FakePlaybackAvailability()
    availability.unavailableReason = .serverUnreachable
    availability.isTerminalRemotePlaybackFailure = true
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox(),
      playbackAvailability: availability)
    adapter.register()

    #expect(center.skipForwardHandler?() == .commandFailed)
    #expect(center.skipBackwardHandler?() == .commandFailed)
    #expect(center.nextTrackHandler?() == .commandFailed)
    #expect(center.previousTrackHandler?() == .commandFailed)
    #expect(center.changePlaybackPositionHandler?(20) == .commandFailed)
    // Pause is not refused: forwarding it latches the listener's own intent, so a later recovery
    // restores a paused player rather than starting audio they stopped.
    #expect(center.pauseHandler?() == .success)
    #expect(player.sentIntents == [.pause])
  }

  /// The lock screen writes through the rate coordinator and pins the loaded title, even when that
  /// title has no speed of its own. It must not fall back to the app-wide default: an unpinned
  /// title would let one lock-screen touch change every title that inherits the default. The audio
  /// changes either way. The pin decides where the change is recorded.
  @Test("change-playback-rate command pins the loaded title and reports success")
  func changePlaybackRatePinsTheLoadedTitle() async {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let box = PlaybackRateCoordinatorBox()
    let coordinator = PlaybackRateCoordinatorFixture.unbound(player: player)
    box.underlying = coordinator
    coordinator.itemDidLoad("item-1")
    let adapter = RemoteCommandAdapter(center: center, controller: player, rateCoordinator: box)
    adapter.register()

    let status = center.changePlaybackRateHandler?(1.5)
    // The override is written behind an enqueued task. Without the wait, the assertions below would
    // read a coordinator that has not recorded the pin yet, and pass for the wrong reason.
    await coordinator.waitForPendingWrites()

    #expect(player.sentIntents == [.setRate(1.5)])
    #expect(status == .success)
    #expect(coordinator.effectiveRate(forItemID: "item-1") == 1.5)
    #expect(coordinator.hasOverride(forItemID: "item-1"))
    #expect(coordinator.globalDefaultRate == 1.0)
  }

  /// The same command on a title with its own speed must edit that override, never the default
  /// every other title inherits.
  @Test("change-playback-rate edits the loaded title's own speed when it has one")
  func changePlaybackRateWritesTheOverridingScope() async {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let box = PlaybackRateCoordinatorBox()
    let coordinator = PlaybackRateCoordinatorFixture.unbound(player: player)
    box.underlying = coordinator
    coordinator.itemDidLoad("item-1")
    coordinator.setOverride(1.8, itemID: "item-1")
    await coordinator.waitForPendingWrites()
    let adapter = RemoteCommandAdapter(center: center, controller: player, rateCoordinator: box)
    adapter.register()

    _ = center.changePlaybackRateHandler?(1.25)
    await coordinator.waitForPendingWrites()

    #expect(coordinator.effectiveRate(forItemID: "item-1") == 1.25)
    #expect(coordinator.globalDefaultRate == 1.0)
  }

  @Test("rate changes remain available while remote playback is unavailable")
  func changePlaybackRateRemainsAvailableDuringRemoteFailure() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let box = PlaybackRateCoordinatorBox()
    let coordinator = PlaybackRateCoordinatorFixture.unbound(player: player)
    box.underlying = coordinator
    coordinator.itemDidLoad("item-1")
    let availability = FakePlaybackAvailability()
    availability.unavailableReason = .serverUnreachable
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: box,
      playbackAvailability: availability)
    adapter.register()

    let status = center.changePlaybackRateHandler?(1.25)

    #expect(status == .success)
    #expect(player.sentIntents == [.setRate(1.25)])
  }

  /// Before the first login and after a logout there is no account to write to. Refusing the
  /// command is the honest answer; silently moving the audio without recording it is not.
  @Test("change-playback-rate is refused while no account is bound")
  func changePlaybackRateFailsWhenUnbound() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.loadedState()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    let status = center.changePlaybackRateHandler?(1.5)

    #expect(player.sentIntents.isEmpty)
    #expect(status == .commandFailed)
  }

  // MARK: - Failure statuses

  @Test("every command reports commandFailed and sends nothing when there is no loaded item")
  func commandsFailWhenNothingIsLoaded() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    player.state = .idle
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    #expect(center.playHandler?() == .commandFailed)
    #expect(center.pauseHandler?() == .commandFailed)
    #expect(center.togglePlayPauseHandler?() == .commandFailed)
    #expect(center.stopHandler?() == .commandFailed)
    #expect(center.skipForwardHandler?() == .commandFailed)
    #expect(center.skipBackwardHandler?() == .commandFailed)
    #expect(center.nextTrackHandler?() == .commandFailed)
    #expect(center.previousTrackHandler?() == .commandFailed)
    #expect(center.changePlaybackPositionHandler?(5) == .commandFailed)
    #expect(center.changePlaybackRateHandler?(1.5) == .commandFailed)
    #expect(player.sentIntents.isEmpty)
  }

  // MARK: - Teardown

  @Test("teardown removes all registered targets")
  func teardownRemovesAllTargets() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    adapter.teardown()

    #expect(center.removeAllTargetsCallCount == 1)
  }

  @Test("tearing down twice is harmless - targets are only removed once")
  func duplicateTeardownIsIdempotent() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()

    adapter.teardown()
    adapter.teardown()

    #expect(center.removeAllTargetsCallCount == 1)
  }

  @Test("tearing down without ever registering does nothing")
  func teardownWithoutRegistrationDoesNothing() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())

    adapter.teardown()

    #expect(center.removeAllTargetsCallCount == 0)
  }

  @Test("registering again after teardown wires every command again")
  func reregisteringAfterTeardownWiresAgain() {
    let center = FakeRemoteCommandRegistering()
    let player = FakeAdapterPlaybackControlling()
    let adapter = RemoteCommandAdapter(
      center: center, controller: player, rateCoordinator: PlaybackRateCoordinatorBox())
    adapter.register()
    adapter.teardown()

    adapter.register()

    #expect(center.setterCallCount == 20)
  }

  // MARK: - Published preferences (rate button and skip glyph)

  private static func isolatedDefaults() -> UserDefaults {
    let name = "RemoteCommandAdapterTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private static func adapter(
    _ center: FakeRemoteCommandRegistering, defaults: UserDefaults
  ) -> RemoteCommandAdapter {
    RemoteCommandAdapter(
      center: center, controller: FakeAdapterPlaybackControlling(),
      rateCoordinator: PlaybackRateCoordinatorBox(), defaults: defaults)
  }

  @Test("registering publishes the listener's speed presets as the rate control's steps")
  func registeringPublishesRatePresets() {
    let center = FakeRemoteCommandRegistering()
    let defaults = Self.isolatedDefaults()
    defaults.set(
      PlaybackRatePresetConfiguration(rates: [1, 1.5, 2]).encoded,
      forKey: ICloudSettingsSync.playbackRatePresetsKey)

    Self.adapter(center, defaults: defaults).register()

    #expect(center.supportedPlaybackRates == [[1, 1.5, 2]])
    #expect(center.skipIntervalUpdates.isEmpty)
  }

  @Test("with no stored presets the default cycle is published")
  func registeringPublishesDefaultPresets() {
    let center = FakeRemoteCommandRegistering()
    Self.adapter(center, defaults: Self.isolatedDefaults()).register()
    #expect(center.supportedPlaybackRates == [PlaybackRatePresetConfiguration.defaults])
  }

  @Test("a changed skip interval re-publishes the glyph without re-registering handlers")
  func changedSkipIntervalIsRepublished() {
    let center = FakeRemoteCommandRegistering()
    let defaults = Self.isolatedDefaults()
    let adapter = Self.adapter(center, defaults: defaults)
    adapter.register()

    defaults.set(45, forKey: SkipIntervalConfiguration.forwardStorageKey)
    adapter.publishPreferences()

    #expect(center.skipIntervalUpdates == [[45, 15]])
    #expect(center.skipForwardIntervalSeconds == 45)
    #expect(center.setterCallCount == 10)
    #expect(center.supportedPlaybackRates.count == 1)
  }

  @Test("changed presets re-publish the rate steps, and an unrelated change publishes nothing")
  func changedPresetsAreRepublishedOnce() {
    let center = FakeRemoteCommandRegistering()
    let defaults = Self.isolatedDefaults()
    let adapter = Self.adapter(center, defaults: defaults)
    adapter.register()

    defaults.set(
      PlaybackRatePresetConfiguration(rates: [1, 2]).encoded,
      forKey: ICloudSettingsSync.playbackRatePresetsKey)
    adapter.publishPreferences()
    defaults.set(true, forKey: "unrelated")
    adapter.publishPreferences()

    #expect(center.supportedPlaybackRates.last == [1, 2])
    #expect(center.supportedPlaybackRates.count == 2)
    #expect(center.skipIntervalUpdates.isEmpty)
  }

  @Test("nothing is published before registering or after teardown")
  func publishingNeedsRegistration() {
    let center = FakeRemoteCommandRegistering()
    let defaults = Self.isolatedDefaults()
    let adapter = Self.adapter(center, defaults: defaults)
    adapter.publishPreferences()
    adapter.register()
    adapter.teardown()
    defaults.set(45, forKey: SkipIntervalConfiguration.forwardStorageKey)
    adapter.publishPreferences()

    #expect(center.supportedPlaybackRates.count == 1)
    #expect(center.skipIntervalUpdates.isEmpty)
  }
}
