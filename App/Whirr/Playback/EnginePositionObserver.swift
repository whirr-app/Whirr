import AVFoundation
import PlayerCore

/// Owns `AVQueuePlayerAudioEngine`'s periodic position observer and its skip-range boundary
/// observer: their tokens, the cadence the periodic one runs at, and the gates a tick passes before
/// it becomes a `positionUpdated` event. The engine reads nothing back but `cadence`.
@MainActor
final class EnginePositionObserver {
  /// What the observer reads from the engine, as closures so it holds no reference to it. The
  /// engine's closures capture it weakly: an engine that has gone reads as "not playing".
  struct Context {
    /// The transport intent most recently sent to AVPlayer (`handlePeriodicTime`'s first gate).
    let isPlaybackRequested: () -> Bool
    /// Whether an item is loaded.
    let hasCurrentItem: () -> Bool
    /// The generation whose load-time positioning seek has not yet been confirmed.
    let pendingPositioningGeneration: () -> Int?
    let currentGeneration: () -> Int
    /// The map the current item's composition was cut by. Item clocks run in played time, and
    /// everything the observer reports or arms is source time.
    let trim: () -> PlayerTrimMap?
    /// The engine's `emit`, so the DEBUG trace and the event stream stay in one place.
    let emit: (AudioEngineEvent) -> Void
  }

  private let queuePlayer: AudioQueuePlayerControlling
  private let foregroundPositionInterval: CMTime
  private let backgroundPositionInterval: CMTime
  private let context: Context

  private var timeObserverToken: Any?
  /// The skip-range boundary (`setBoundary`), armed for one generation's item.
  private var boundaryObserverToken: Any?
  /// The cadence the currently installed observer runs at. Owned here rather than read from a
  /// scene-phase source because `PlayerCore` has no notion of scene phase and this adapter has no
  /// SwiftUI: `PlaybackHardware.handleScenePhase` pushes changes in.
  private(set) var cadence: AVQueuePlayerAudioEngine.PositionCadence = .foreground

  init(
    queuePlayer: AudioQueuePlayerControlling,
    foregroundPositionInterval: CMTime,
    backgroundPositionInterval: CMTime,
    context: Context
  ) {
    self.queuePlayer = queuePlayer
    self.foregroundPositionInterval = foregroundPositionInterval
    self.backgroundPositionInterval = backgroundPositionInterval
    self.context = context
  }

  /// Switches the periodic observer between cadences. A change while nothing is observing is just
  /// recorded (the next `startPositionObservationIfNeeded` picks it up), so a scene-phase change
  /// with no playback loaded never installs an observer of its own.
  func setPositionCadence(_ newCadence: AVQueuePlayerAudioEngine.PositionCadence) {
    guard newCadence != cadence else { return }
    cadence = newCadence
    guard timeObserverToken != nil else { return }
    stopPositionObservation()
    startPositionObservationIfNeeded()
  }

  private var currentPositionInterval: CMTime {
    switch cadence {
    case .foreground: foregroundPositionInterval
    case .background: backgroundPositionInterval
    }
  }

  func startPositionObservationIfNeeded() {
    guard timeObserverToken == nil else { return }
    timeObserverToken = queuePlayer.addPeriodicTimeObserver(forInterval: currentPositionInterval) {
      [weak self] time in
      self?.handlePeriodicTime(time)
    }
  }

  func stopPositionObservation() {
    guard let token = timeObserverToken else { return }
    queuePlayer.removeTimeObserver(token)
    timeObserverToken = nil
  }

  /// A boundary is track-local and belongs to the generation it was armed under. `AVQueuePlayer`
  /// keeps a boundary observer across an auto-advance, so a crossing reported for a later
  /// generation's item is dropped; `PlayerReducer` arms again after every load and seek.
  func setBoundary(atLocalOffset offset: Double?) {
    removeBoundaryObserver()
    guard let offset, offset.isFinite, offset >= 0, context.hasCurrentItem() else { return }
    let generation = context.currentGeneration()
    let playedOffset = context.trim()?.playedTime(forSource: offset) ?? offset
    boundaryObserverToken = queuePlayer.addBoundaryTimeObserver(
      forTimes: [AVQueuePlayerAudioEngine.seekTime(seconds: playedOffset)]
    ) {
      [weak self] time in
      guard let self, generation == self.context.currentGeneration() else { return }
      // The same gates as a periodic tick: nothing while paused or before the load's seek lands.
      self.handlePeriodicTime(time)
    }
  }

  func removeBoundaryObserver() {
    guard let token = boundaryObserverToken else { return }
    queuePlayer.removeTimeObserver(token)
    boundaryObserverToken = nil
  }

  private func handlePeriodicTime(_ time: CMTime) {
    guard context.isPlaybackRequested(), context.hasCurrentItem(), time.isValid,
      !time.isIndefinite
    else { return }
    // Until this load's own seek lands, every tick carries the fresh item's clock rather than the
    // position the listener is resuming from. Reporting it would move the playhead to the start of
    // the book for as long as the seek takes (on a cold Resume the progress bar would withdraw,
    // the play capsule would jump, and a position of zero would go to sync as progress).
    guard context.pendingPositioningGeneration() != context.currentGeneration() else { return }
    let sourceOffset = context.trim()?.sourceTime(forPlayed: time.seconds) ?? time.seconds
    context.emit(
      .positionUpdated(generation: context.currentGeneration(), localOffset: sourceOffset))
  }
}
