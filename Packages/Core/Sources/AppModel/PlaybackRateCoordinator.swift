import Foundation
import Observation
import Persistence
import PlayerCore

/// The single owner of every playback-speed mutation. The player menu, speed sheet, Show Settings,
/// lock screen and CarPlay all go through here, so a per-title override and the default it
/// inherits can be edited independently. PlayerCore persists nothing.
///
/// Every fast-path surface writes one title: the preset menu, lock screen and CarPlay pin whatever
/// they show; only the speed sheet's Default segment and Settings > Playback move the app-wide
/// default. `clearOverride` is the way back to inheriting.
///
/// - Writes are serialised and a burst collapses. The speed sheet's slider fires on every change;
///   each mutation awaits the one before it and each title's write carries a token, so a tick
///   queued when a newer one arrives is dropped. Intermediate speeds would each re-emit
///   `observeOverrides` into the six remaining-time surfaces that resolve a rate while scrolling.
/// - Nothing else may write: `ItemPlaybackSettingsWriting` is private to this type, as a direct
///   write would leave the coordinator's idea of the governing scope stale.
///
/// Lives in AppModel because that layer sees both Persistence and PlayerCore. Account-scoped and
/// rebuilt with each `AppEnvironment`; only the process-lifetime `PlaybackControlling` survives the
/// rebuild, so it needs no late-bound box.
@MainActor
@Observable
public final class PlaybackRateCoordinator {
  private let reading: any ItemPlaybackSettingsReading
  private let writing: any ItemPlaybackSettingsWriting
  private let preferences: any PlaybackPreferences
  private let player: any PlaybackControlling

  /// Every overridden title, as twentieth steps keyed by ABS item id. Bounded by the titles the
  /// listener has pinned, not the library, so the six remaining-time surfaces can resolve a rate
  /// synchronously instead of awaiting a read per row.
  public private(set) var overrides: [String: Int] = [:]
  /// The app-wide default. One value, not one per media kind.
  public private(set) var globalDefaultRate: Double
  /// Set when a durable write fails, so a screen can say so rather than showing a speed the
  /// database does not hold. Cleared by the next successful write of any kind.
  public private(set) var writeFailureMessage: String?
  /// The speed a Focus filter delivered, as delivered. Never persisted: the App holder owns it
  /// across rebuilds and hands it to each new coordinator.
  public private(set) var focusSpeed: FocusSpeed?
  /// A quick-control adjustment made while a Focus governs the loaded title. It replaces the Focus
  /// rate until that Focus changes or ends, and is never written anywhere.
  private var focusSessionRate: Double?

  /// What PlayerCore has loaded, told to this type by `PlaybackModel` as it loads and stops.
  /// Decides whether a mutation is also heard: editing the playing title's speed changes the audio
  /// now, editing an inactive title's does not.
  private var loadedItemID: String?
  /// The rate `preferences` actually holds, so a drag persists once per speed it passes through
  /// rather than once per gesture tick. Seeded with the restored rate, or `nil` when none was
  /// usable, so an explicit choice of the default value on a fresh install is still written.
  private var persistedGlobalRate: Double?
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  /// The tail of the serial mutation chain. Each new mutation awaits it, then becomes it.
  @ObservationIgnored private var mutations: Task<Void, Never>?
  /// The newest write requested for each title, keyed by item id. A queued write whose token is no
  /// longer the newest for its title has been superseded before reaching the database and is
  /// skipped. Per title, not global: one title's newer speed must not swallow another's.
  private var latestWriteTokens: [String: UInt64] = [:]
  private var nextWriteToken: UInt64 = 0

  public init(
    reading: any ItemPlaybackSettingsReading,
    writing: any ItemPlaybackSettingsWriting,
    preferences: any PlaybackPreferences,
    player: any PlaybackControlling,
    focusSpeed: FocusSpeed? = nil
  ) {
    self.reading = reading
    self.writing = writing
    self.preferences = preferences
    self.player = player
    self.focusSpeed = focusSpeed
    // The value `PlayerController` restored into `state.rate`, read again because this type is
    // what changes it.
    let restoredRate = preferences.loadRate()
    persistedGlobalRate = restoredRate.flatMap(PlaybackRateResolution.normalizedRate)
    globalDefaultRate =
      PlaybackRateResolution(
        overrideStep: nil, globalRate: restoredRate
      ).effectiveRate

    let stream = reading.observeOverrides()
    observationTask = Task { [weak self] in
      for await overrides in stream {
        guard let self else { return }
        self.overrides = overrides
      }
    }
  }

  deinit {
    observationTask?.cancel()
    mutations?.cancel()
  }

  // MARK: - Reading

  /// The speed a title should play at: its own override, else the default, else 1×. Synchronous
  /// and allocation-light, since list rows call it while scrolling.
  public func effectiveRate(forItemID itemID: String?) -> Double {
    resolution(forItemID: itemID).effectiveRate
  }

  /// The rate a Focus is playing this title at, or nil when no Focus governs it (none is on, or it
  /// skips titles with their own speed and this title has one).
  public func focusRate(forItemID itemID: String?) -> Double? {
    let resolution = resolution(forItemID: itemID)
    return resolution.appliesFocusSpeed ? resolution.effectiveRate : nil
  }

  /// Whether this title carries its own speed. Distinct from "its speed differs from the default":
  /// an override equal to the current default is still a pin, and a later change to the default
  /// must leave it alone.
  public func hasOverride(forItemID itemID: String?) -> Bool {
    guard let itemID else { return false }
    return overrides[itemID] != nil
  }

  /// The speed stored for this title, or nil when it inherits the default. Unlike
  /// `effectiveRate` it never reports a Focus speed: a settings picker shows and edits what is
  /// stored, and the Focus only governs what is heard.
  public func overrideRate(forItemID itemID: String?) -> Double? {
    guard let itemID, let step = overrides[itemID] else { return nil }
    return PlaybackRateResolution.rate(forStep: step)
  }

  // MARK: - Playback lifecycle

  /// Told by `PlaybackModel` when PlayerCore's loaded title changes, including to `nil` on stop.
  public func itemDidLoad(_ itemID: String?) {
    loadedItemID = itemID
  }

  // MARK: - Mutations

  /// Takes a Focus filter's delivery. Heard at once by the loaded title, and with nothing loaded
  /// the idle engine follows too, so no surface shows a leftover Focus rate. Writes nothing.
  /// Repeating the current value, as each reconcile does, changes nothing, not even a session
  /// adjustment.
  public func setFocusSpeed(_ speed: FocusSpeed?) {
    guard speed != focusSpeed else { return }
    focusSpeed = speed
    focusSessionRate = nil
    applyEffectiveRateToEngine()
  }

  /// The quick controls' write: the player menu, the mini player, the Watch remote, the lock
  /// screen and CarPlay. While a Focus governs the loaded title it adjusts only this Focus
  /// session; otherwise it pins the loaded title. Reports false with nothing loaded, for the same
  /// reason `setRateForLoadedTitle` does.
  @discardableResult
  public func adjustLoadedTitleRate(_ rate: Double) -> Bool {
    guard let loadedItemID else { return false }
    guard resolution(forItemID: loadedItemID).appliesFocusSpeed else {
      setOverride(rate, itemID: loadedItemID)
      return true
    }
    guard let normalized = PlaybackRateResolution.normalizedRate(rate) else { return true }
    focusSessionRate = normalized
    applyEffectiveRateToLoadedTitle()
    return true
  }

  /// The player menus' write. They can be drawn for a title that is not the loaded one; a tap
  /// there pins that title, and a tap on the loaded title follows `adjustLoadedTitleRate`.
  public func adjustRate(_ rate: Double, itemID: String) {
    if itemID == loadedItemID {
      adjustLoadedTitleRate(rate)
    } else {
      setOverride(rate, itemID: itemID)
    }
  }

  /// Pins one title to a speed. Heard immediately when that title is the one playing.
  public func setOverride(_ rate: Double, itemID: String) {
    guard let step = PlaybackRateResolution.step(forRate: rate) else { return }
    applyToPlayerIfLoaded(itemID: itemID, rate: PlaybackRateResolution.rate(forStep: step) ?? rate)
    let token = claimWriteToken(itemID: itemID)
    enqueue { [weak self] in
      guard let self, retireWriteTokenUnlessSuperseded(token, itemID: itemID) else { return }
      do {
        try await writing.upsertOverride(itemID: itemID, rateStep: step)
        overrides[itemID] = step
        writeFailureMessage = nil
      } catch {
        writeFailureMessage = PlaybackRateCopy.writeFailure
      }
    }
  }

  /// Drops a title's own speed so it inherits the default again. When that title is playing, the
  /// default is adopted immediately.
  public func clearOverride(itemID: String) {
    let isLoaded = loadedItemID == itemID
    let token = claimWriteToken(itemID: itemID)
    enqueue { [weak self] in
      guard let self, retireWriteTokenUnlessSuperseded(token, itemID: itemID) else { return }
      do {
        try await writing.deleteOverride(itemID: itemID)
        overrides[itemID] = nil
        writeFailureMessage = nil
      } catch {
        writeFailureMessage = PlaybackRateCopy.writeFailure
      }
    }
    if isLoaded { applyEffectiveRate(overrideStep: nil) }
  }

  /// Changes the app-wide default. Only titles that inherit it are affected, so this is heard only
  /// when the playing title has no override of its own.
  public func setGlobalDefault(_ rate: Double) {
    guard let normalized = PlaybackRateResolution.normalizedRate(rate) else { return }
    globalDefaultRate = normalized
    // Bounds persistence only. What is heard still follows every call, below.
    if normalized != persistedGlobalRate {
      persistedGlobalRate = normalized
      preferences.saveRate(normalized)
    }
    applyEffectiveRateToLoadedTitle()
  }

  /// The lock screen's and CarPlay's write: they know only "the thing that is playing", so it pins
  /// that title, as the on-screen menu does.
  ///
  /// Reports whether it could route the change. With nothing loaded there is no title to pin, and
  /// the app-wide default is no safe fallback: a stray lock-screen touch would move the speed of
  /// every inheriting title.
  @discardableResult
  public func setRateForLoadedTitle(_ rate: Double) -> Bool {
    adjustLoadedTitleRate(rate)
  }

  /// Removes every override for the account, leaving the default in place.
  public func clearAllOverrides() {
    if loadedItemID != nil { applyEffectiveRate(overrideStep: nil) }
    enqueue { [weak self] in
      guard let self else { return }
      do {
        try await writing.deleteAllOverrides()
        overrides = [:]
        writeFailureMessage = nil
      } catch {
        writeFailureMessage = PlaybackRateCopy.writeFailure
      }
    }
  }

  public func dismissWriteFailure() {
    writeFailureMessage = nil
  }

  /// Awaits everything already queued on the serial chain. A caller that needs to know whether a
  /// change reached the database (a test, or a screen about to report success) must wait for the
  /// write, not the intent that preceded it.
  public func waitForPendingWrites() async {
    await mutations?.value
  }

  // MARK: - Private

  /// A speed change is only audible when it belongs to the title PlayerCore has loaded. Sent ahead
  /// of the durable write so audio follows a drag immediately. Only the write needs ordering; the
  /// engine holds the newest value anyway.
  private func applyToPlayerIfLoaded(itemID: String, rate: Double) {
    guard loadedItemID == itemID else { return }
    player.send(.setRate(rate))
  }

  private func resolution(forItemID itemID: String?) -> PlaybackRateResolution {
    resolution(overrideStep: itemID.flatMap { overrides[$0] })
  }

  private func resolution(overrideStep: Int?) -> PlaybackRateResolution {
    PlaybackRateResolution(
      overrideStep: overrideStep, globalRate: globalDefaultRate,
      focusSpeed: focusSpeed.map {
        FocusSpeed(
          rate: focusSessionRate ?? $0.rate, skipsTitlesWithOwnSpeed: $0.skipsTitlesWithOwnSpeed)
      })
  }

  /// Decides what is heard after a mutation. Resolves the loaded title through every input, the
  /// Focus included, and sends only a real change, so "Use Default", a default edit or clear-all
  /// during a Focus cannot knock playback off the Focus speed.
  private func applyEffectiveRateToLoadedTitle() {
    guard let loadedItemID else { return }
    applyEffectiveRate(overrideStep: overrides[loadedItemID])
  }

  /// `clearOverride` and `clearAllOverrides` resolve as though the override were already gone,
  /// because the cache only drops it once the queued write lands.
  private func applyEffectiveRate(overrideStep: Int?) {
    let rate = resolution(overrideStep: overrideStep).effectiveRate
    guard rate != player.state.rate else { return }
    player.send(.setRate(rate))
  }

  /// Like `applyEffectiveRateToLoadedTitle`, but with nothing loaded it resets the idle engine to
  /// the rate for no title, which `PlayerController` would otherwise keep from the Focus.
  private func applyEffectiveRateToEngine() {
    if loadedItemID == nil {
      applyEffectiveRate(overrideStep: nil)
    } else {
      applyEffectiveRateToLoadedTitle()
    }
  }

  /// Claims this title's newest-write token. Taken synchronously as the request arrives, so a tick
  /// landing while an earlier one is queued supersedes it rather than queueing behind it.
  private func claimWriteToken(itemID: String) -> UInt64 {
    nextWriteToken &+= 1
    latestWriteTokens[itemID] = nextWriteToken
    return nextWriteToken
  }

  /// Whether a queued write should still run. Retires the token when it should, so the table holds
  /// only titles with a write in flight rather than growing for the life of the account.
  private func retireWriteTokenUnlessSuperseded(_ token: UInt64, itemID: String) -> Bool {
    guard latestWriteTokens[itemID] == token else { return false }
    latestWriteTokens[itemID] = nil
    return true
  }

  /// The serial chain. A join would let a drag's writes race; this makes each mutation wait for
  /// the one before it, so the last value the listener saw is the last value committed.
  private func enqueue(_ work: @escaping @MainActor () async -> Void) {
    let previous = mutations
    mutations = Task { @MainActor in
      await previous?.value
      await work()
    }
  }
}

/// A playback speed written the way every surface writes it. The speed picker, the listening-time
/// copy and its spoken form all call this, so the visible label can never read "1×" while the copy
/// says another rate.
public nonisolated enum PlaybackRateCopy {
  static let writeFailure = "Couldn't save that playback speed. Try again."

  /// "0.9×" for a listening-time caption.
  public static func display(_ rate: Double) -> String {
    display(rate, includesMultiplier: true)
  }

  /// The rate as typed into the picker ("0.9"), or with its multiplier sign. A non-finite or
  /// non-positive rate is treated as the default speed, so a malformed preference cannot produce
  /// an undefined label.
  public static func display(_ rate: Double, includesMultiplier: Bool) -> String {
    let number = number(ItemDetailDurationPresentation.normalizedPlaybackRate(rate))
    return includesMultiplier ? "\(number)×" : number
  }

  /// The rate as VoiceOver reads it: "0.9 times speed", or "normal speed" at 1×.
  public static func spoken(_ rate: Double) -> String {
    let normalized = ItemDetailDurationPresentation.normalizedPlaybackRate(rate)
    guard normalized != 1 else { return "normal speed" }
    return "\(number(normalized)) times speed"
  }

  /// "0.9", matching the rounding `display(_:)` uses.
  private static func number(_ rate: Double) -> String {
    let hundredths = Int((rate * 100).rounded())
    let whole = hundredths / 100
    let remainder = hundredths % 100
    if remainder == 0 {
      return "\(whole)"
    }
    if remainder.isMultiple(of: 10) {
      return "\(whole).\(remainder / 10)"
    }
    return remainder < 10 ? "\(whole).0\(remainder)" : "\(whole).\(remainder)"
  }
}
