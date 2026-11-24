import MediaPlayer
import PlayerCore

/// Lock screen/Control Center command adapter (see ARCHITECTURE.md). Forwards every command as the
/// `PlayerIntent`s the on-screen player sends through `PlaybackControlling`, so there is no second
/// state machine. Skips use the listener's configured intervals (Settings ▸ Playback ▸ Skip
/// Buttons); Bluetooth double-/triple-clicks arrive as next/previous commands and get the same
/// skips. Owns no session or engine (injected `RemoteCommandRegistering`).
@MainActor
final class RemoteCommandAdapter {
  /// Read fresh on every command so a settings change takes effect without re-registering. The
  /// glyph the system draws comes from the published interval instead, which
  /// `publishPreferences()` keeps in step.
  private var forwardSkipIntervalSeconds: TimeInterval {
    TimeInterval(
      SkipIntervalConfiguration.resolvedSeconds(
        defaults.integer(forKey: SkipIntervalConfiguration.forwardStorageKey), forward: true))
  }

  private var backwardSkipIntervalSeconds: TimeInterval {
    TimeInterval(
      SkipIntervalConfiguration.resolvedSeconds(
        defaults.integer(forKey: SkipIntervalConfiguration.backwardStorageKey), forward: false))
  }

  /// The listener's speed presets: the rates the system's rate control steps through, so the
  /// lock screen and CarPlay cycle the same list as the player's own menu.
  private var ratePresets: [Double] {
    PlaybackRatePresetConfiguration.decode(
      defaults.string(forKey: ICloudSettingsSync.playbackRatePresetsKey) ?? ""
    ).rates
  }

  private let center: any RemoteCommandRegistering
  private let controller: any PlaybackControlling
  /// A lock-screen or CarPlay speed change pins the loaded title, as the player's preset menu does
  /// (`setRateForLoadedTitle`). Boxed because this adapter outlives every account
  /// (`PlaybackRateCoordinatorBox`).
  private let rateCoordinator: PlaybackRateCoordinatorBox
  private let playbackAvailability: (any PlaybackAvailabilityProviding)?
  private let defaults: UserDefaults
  private var isRegistered = false
  private var preferenceObserver: NSObjectProtocol?
  private var published: Published?

  private struct Published: Equatable {
    let forward: TimeInterval
    let backward: TimeInterval
    let rates: [Double]
  }

  /// No default for `rateCoordinator`: a default-argument expression evaluates at the call site's
  /// isolation rather than this `@MainActor` initialiser's, and `PlaybackRateCoordinatorBox` is
  /// MainActor-isolated (as with `remoteCommandCenter` in `PlaybackHardware.init`).
  init(
    center: any RemoteCommandRegistering, controller: any PlaybackControlling,
    rateCoordinator: PlaybackRateCoordinatorBox,
    playbackAvailability: (any PlaybackAvailabilityProviding)? = nil,
    defaults: UserDefaults = .standard
  ) {
    self.defaults = defaults
    self.center = center
    self.controller = controller
    self.rateCoordinator = rateCoordinator
    self.playbackAvailability = playbackAvailability
  }

  /// Idempotent: a second call before `teardown()` wires nothing new.
  func register() {
    guard !isRegistered else { return }
    isRegistered = true

    center.setPlayHandler { [weak self] in self?.forward(.play) ?? .commandFailed }
    center.setPauseHandler { [weak self] in self?.forward(.pause) ?? .commandFailed }
    center.setTogglePlayPauseHandler { [weak self] in self?.forward(.toggle) ?? .commandFailed }
    center.setStopHandler { [weak self] in self?.forward(.stop) ?? .commandFailed }
    center.setSkipForwardHandler(intervalSeconds: forwardSkipIntervalSeconds) { [weak self] in
      self.map { $0.skip(by: $0.forwardSkipIntervalSeconds) } ?? .commandFailed
    }
    center.setSkipBackwardHandler(intervalSeconds: backwardSkipIntervalSeconds) { [weak self] in
      self.map { $0.skip(by: -$0.backwardSkipIntervalSeconds) } ?? .commandFailed
    }
    // AirPods and other Bluetooth controls report double-/triple-clicks as next-/previous-track
    // rather than the dedicated skip commands above. Treat them as directional skips so the gesture
    // matches the on-screen transport controls and user settings.
    center.setNextTrackHandler { [weak self] in
      self.map { $0.skip(by: $0.forwardSkipIntervalSeconds) } ?? .commandFailed
    }
    center.setPreviousTrackHandler { [weak self] in
      self.map { $0.skip(by: -$0.backwardSkipIntervalSeconds) } ?? .commandFailed
    }
    center.setChangePlaybackPositionHandler { [weak self] position in
      self?.seek(to: position) ?? .commandFailed
    }
    center.setChangePlaybackRateHandler { [weak self] rate in
      self?.setRate(rate) ?? .commandFailed
    }
    published = Published(
      forward: forwardSkipIntervalSeconds, backward: backwardSkipIntervalSeconds, rates: [])
    publishPreferences()
    preferenceObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.publishPreferences() }
    }
  }

  /// Re-publishes what the system draws from stored preferences (the skip glyphs' intervals and
  /// the rate control's steps) when either has changed. Commands read the preferences live; the
  /// system's controls only show what was last published.
  func publishPreferences() {
    guard isRegistered else { return }
    let next = Published(
      forward: forwardSkipIntervalSeconds, backward: backwardSkipIntervalSeconds, rates: ratePresets)
    guard next != published else { return }
    if next.forward != published?.forward || next.backward != published?.backward {
      center.setSkipIntervals(forwardSeconds: next.forward, backwardSeconds: next.backward)
    }
    if next.rates != published?.rates { center.setSupportedPlaybackRates(next.rates) }
    published = next
  }

  /// Idempotent: a second call, or a call before registering, does nothing.
  func teardown() {
    guard isRegistered else { return }
    isRegistered = false
    if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    preferenceObserver = nil
    published = nil
    center.removeAllTargets()
  }

  private var hasLoadedItem: Bool {
    controller.state.item != nil
  }

  private var remotePlaybackUnavailable: Bool {
    playbackAvailability?.remotePlaybackUnavailable ?? false
  }

  /// A stream still buffering against an unreachable server has a live session that a seek can
  /// still act on. A terminal stall does not, so the commands that move the playhead can only
  /// report honestly there.
  private var isTerminalRemotePlaybackFailure: Bool {
    playbackAvailability?.isTerminalRemotePlaybackFailure ?? false
  }

  private func forward(_ intent: PlayerIntent) -> MPRemoteCommandHandlerStatus {
    guard hasLoadedItem else { return .commandFailed }
    let startsPlayback = intent == .play || intent == .toggle
    if startsPlayback, playbackAvailability?.resumeThroughFreshLocalSessionIfLatched() == true {
      // The latch exists only for local playback, which reachability never gates, so it is
      // consulted ahead of the unavailability branch. A bare intent here would resume audio
      // with no session recording it (the sleep timer just closed the local one).
      return .success
    }
    if startsPlayback, remotePlaybackUnavailable {
      // A press here is the same explicit ask as Retry in the app, so it runs the same recovery
      // rather than sending an intent the dead session would silently drop. Reachability changing
      // on its own never starts anything.
      return playbackAvailability?.recoverPlayback() == true ? .success : .commandFailed
    }
    controller.send(intent)
    return .success
  }

  private func skip(by delta: TimeInterval) -> MPRemoteCommandHandlerStatus {
    guard hasLoadedItem else { return .commandFailed }
    guard isTerminalRemotePlaybackFailure == false else { return .commandFailed }
    controller.send(.skip(by: delta))
    return .success
  }

  /// `position` is expressed in whatever timeline `NowPlayingMetadataAdapter` last published, so a
  /// chaptered audiobook's scrub arrives relative to the current chapter and has to be lifted back
  /// onto the global timeline before it becomes a seek intent.
  private func seek(to position: TimeInterval) -> MPRemoteCommandHandlerStatus {
    guard hasLoadedItem else { return .commandFailed }
    guard isTerminalRemotePlaybackFailure == false else { return .commandFailed }
    let chapterStart = NowPlayingChapterWindow.chapter(for: controller.state)?.start ?? 0
    controller.send(.seek(toGlobalOffset: chapterStart + position))
    return .success
  }

  /// Never `controller.send(.setRate:)` directly: a raw intent changes the audio without recording
  /// which scope was edited, so the next change from any other surface would write the wrong one.
  /// The coordinator sends the intent itself once it has decided the scope.
  private func setRate(_ rate: Double) -> MPRemoteCommandHandlerStatus {
    guard hasLoadedItem else { return .commandFailed }
    return rateCoordinator.setRateForLoadedTitle(rate) ? .success : .commandFailed
  }
}
