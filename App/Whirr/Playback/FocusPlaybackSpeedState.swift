import AppIntents
import AppModel
import Foundation
import Observation
import PlayerCore

/// What one Focus filter delivery carries: its speed, its trim and its sleep timer.
/// Any may be absent; all absent is no Focus.
nonisolated struct FocusFilterValue: Sendable, Equatable {
  var speed: FocusSpeed?
  var trim: FocusTrim?
  /// The countdown to start at each play while the Focus is on.
  var sleepTimerSeconds: Double?

  init(speed: FocusSpeed? = nil, trim: FocusTrim? = nil, sleepTimerSeconds: Double? = nil) {
    self.speed = speed
    self.trim = trim
    self.sleepTimerSeconds = sleepTimerSeconds
  }

  static let noFocus = FocusFilterValue()
}

/// The process-lifetime home of the Focus filter's speed and trim. The rate coordinator is rebuilt
/// on every login, logout and account rebuild, so this holds the Focus across them and each new
/// coordinator receives it at construction (`RootComposition`). Outside `PlaybackHardware` because
/// the filter's `perform()` must not build the engine or open the database. Also written to a
/// device-local `UserDefaults` key (not iCloud-synced), so a relaunch during a Focus starts at the
/// Focus speed before the launch reconcile; `UserDefaultsTrimSilencesPreferences` reads it too.
@MainActor
final class FocusPlaybackSpeedState {
  static let shared = FocusPlaybackSpeedState(defaults: .standard)

  /// Device-local on purpose: a Focus belongs to this device's state, and it must stay out of
  /// `ICloudSettingsSync.syncedKeys`.
  nonisolated static let storageKey = "com.remoteconcern.whirr.focusPlaybackSpeed"
  private nonisolated static let rateField = "rate"
  private nonisolated static let skipsField = "skipsTitlesWithOwnSpeed"
  private nonisolated static let trimField = "trimStrength"
  private nonisolated static let keepsTrimField = "keepsCustomTrim"
  private nonisolated static let sleepTimerField = "sleepTimerSeconds"
  /// A Focus that turns trimming off; any other value is a `TrimStrength` raw value.
  private nonisolated static let trimOff = "off"

  private(set) var value: FocusFilterValue
  var focusSpeed: FocusSpeed? { value.speed }
  var focusTrim: FocusTrim? { value.trim }
  private let defaults: UserDefaults
  private weak var coordinator: PlaybackRateCoordinator?
  /// The process's one player, which a Focus sleep timer is started on. Not per account: it
  /// outlives every composition rebuild, as this holder does.
  private var player: (any PlaybackControlling)?

  init(defaults: UserDefaults) {
    self.defaults = defaults
    value = Self.load(from: defaults)
  }

  /// Points the holder at the current account's coordinator. The coordinator already received
  /// `focusSpeed` through its initialiser; this is only so later deliveries reach it. Weak, so a
  /// superseded graph's coordinator is not kept alive.
  func bind(_ coordinator: PlaybackRateCoordinator) {
    self.coordinator = coordinator
  }

  /// One delivery, from the filter or from a reconcile. Stores it and applies it live. A sleep
  /// timer that is new to this delivery starts at once if audio is playing, so a Focus turning on
  /// mid-listen is heard; an unchanged one waits for the next play, so a foreground reconcile
  /// never restarts a timer the listener turned off.
  func deliver(_ next: FocusFilterValue) {
    let sleepTimerChanged = next.sleepTimerSeconds != value.sleepTimerSeconds
    store(next)
    if sleepTimerChanged { startSleepTimerIfDue() }
  }

  private func store(_ next: FocusFilterValue) {
    if next != value {
      value = next
      Self.store(next, in: defaults)
    }
    coordinator?.setFocusSpeed(next.speed)
  }

  /// Points the holder at the player a Focus sleep timer starts on.
  func attach(player: any PlaybackControlling) {
    self.player = player
  }

  /// Playback intent turned on. Reads the current Focus, then starts its sleep timer. A failed
  /// read keeps the stored Focus, so the timer still starts.
  func playbackStarted(current: () async throws -> FocusFilterValue) async {
    if let next = try? await current() { store(next) }
    startSleepTimerIfDue()
  }

  /// Starts the Focus timer while audio is meant to be playing and no timer runs: one the
  /// listener chose, or one the resume grace restarted during this same play, is left alone.
  private func startSleepTimerIfDue() {
    guard let seconds = value.sleepTimerSeconds, let player, player.isPlaybackIntended,
      player.state.sleepTimer.mode == .off
    else { return }
    player.send(.setSleepTimer(.custom(seconds: seconds)))
  }

  /// A Focus that changes while Whirr is suspended or closed is not delivered, but
  /// `.current` reports it. Read at launch, on foreground and at each play or resume.
  func reconcile(current: () async throws -> FocusFilterValue) async {
    // Not `try?`: that flattens "no Focus is on" into "the read failed", and the deactivation a
    // suspended Whirr missed would never be corrected.
    let next: FocusFilterValue
    do {
      next = try await current()
    } catch {
      return
    }
    deliver(next)
  }

  func reconcileWithFilter() async {
    await reconcile { try await PlaybackSpeedFocusFilter.current.focusValue }
  }

  /// Reconciles, and starts any Focus sleep timer, each time playback intent turns on, whatever
  /// started it: the app, the lock screen, CarPlay, the Watch or Siri. Playback can start without
  /// the app reaching the foreground, so the scene-phase reconcile alone would miss those.
  func reconcileOnEachPlay(of player: any PlaybackControlling) {
    attach(player: player)
    let isPlaybackIntended: @MainActor () -> Bool = { player.isPlaybackIntended }
    var wasIntended = isPlaybackIntended()
    observePlayback(isPlaybackIntended) { [weak self] isIntended in
      defer { wasIntended = isIntended }
      guard isIntended, !wasIntended, let self else { return }
      Task { await self.playbackStarted { try await PlaybackSpeedFocusFilter.current.focusValue } }
    }
  }

  private func observePlayback(
    _ isPlaybackIntended: @escaping @MainActor () -> Bool,
    onChange: @escaping @MainActor (Bool) -> Void
  ) {
    withObservationTracking {
      _ = isPlaybackIntended()
    } onChange: { [weak self] in
      // `onChange` fires before the new value lands, so read it on a later turn.
      Task { @MainActor [weak self] in
        guard let self else { return }
        onChange(isPlaybackIntended())
        self.observePlayback(isPlaybackIntended, onChange: onChange)
      }
    }
  }

  /// The Focus trim as last stored. Nonisolated, so the trim preferences can read it
  /// synchronously from any thread.
  nonisolated static func focusTrim(in defaults: UserDefaults) -> FocusTrim? {
    load(from: defaults).trim
  }

  private nonisolated static func load(from defaults: UserDefaults) -> FocusFilterValue {
    guard let stored = defaults.dictionary(forKey: storageKey) else { return .noFocus }
    let speed = (stored[rateField] as? Double).map {
      FocusSpeed(rate: $0, skipsTitlesWithOwnSpeed: stored[skipsField] as? Bool)
    }
    // An unknown strength, from a newer build, reads as no Focus trim rather than a guess.
    let keepsTrim = stored[keepsTrimField] as? Bool ?? false
    let trim = (stored[trimField] as? String).flatMap { raw -> FocusTrim? in
      if raw == trimOff { return FocusTrim(strength: nil, keepsShowSettings: keepsTrim) }
      return TrimStrength(rawValue: raw).map { FocusTrim(strength: $0, keepsShowSettings: keepsTrim) }
    }
    let sleepTimerSeconds = (stored[sleepTimerField] as? Double).flatMap { $0 > 0 ? $0 : nil }
    return FocusFilterValue(speed: speed, trim: trim, sleepTimerSeconds: sleepTimerSeconds)
  }

  private static func store(_ value: FocusFilterValue, in defaults: UserDefaults) {
    guard value != .noFocus else {
      defaults.removeObject(forKey: storageKey)
      return
    }
    var stored: [String: Any] = [:]
    if let speed = value.speed {
      stored[rateField] = speed.rate
      stored[skipsField] = speed.skipsTitlesWithOwnSpeed
    }
    if let trim = value.trim {
      stored[trimField] = trim.strength?.rawValue ?? trimOff
      stored[keepsTrimField] = trim.keepsShowSettings
    }
    if let sleepTimerSeconds = value.sleepTimerSeconds {
      stored[sleepTimerField] = sleepTimerSeconds
    }
    defaults.set(stored, forKey: storageKey)
  }
}
