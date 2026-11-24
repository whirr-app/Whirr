import SyncEngine

/// Breaks the construction-order cycle between `PlaybackSessionCoordinator` (needs a
/// `requestDrain` closure at construction) and the `OutboxDrainer` that closure builds (needs a
/// `notifySessionGoneRecovery` closure calling back into the coordinator). `AppEnvironment.init`
/// fills `coordinator` right after `PlaybackSessionCoordinator.make`, before either closure can
/// run; `weak` so session-lifetime closures capturing the box don't keep it alive.
final class PlaybackCoordinatorBox: @unchecked Sendable {
  weak var coordinator: PlaybackSessionCoordinator?
}
