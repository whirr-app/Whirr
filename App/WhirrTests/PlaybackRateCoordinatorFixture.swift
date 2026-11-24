import AppModel
import Persistence
import PlayerCore

@testable import Whirr

/// A `PlaybackRateCoordinator` bound to nothing, for App tests that only need to satisfy a view's
/// dependency rather than exercise speed behavior. Reports no overrides and writes nowhere, which
/// is exactly what the coordinator does before an account exists.
@MainActor
enum PlaybackRateCoordinatorFixture {
  static func unbound() -> PlaybackRateCoordinator {
    // The harness engine rather than a real `AVQueuePlayerAudioEngine`: constructing one is the
    // one thing these tests must not do, and no intent sent here is meant to be heard.
    unbound(player: PlayerController(engine: HarnessAudioEngine(), clock: SystemPlaybackClock()))
  }

  /// The same coordinator over a caller-supplied player, for tests that assert which intents the
  /// coordinator sends.
  static func unbound(player: any PlaybackControlling) -> PlaybackRateCoordinator {
    PlaybackRateCoordinator(
      reading: NoOpItemPlaybackSettingsAccess(),
      writing: NoOpItemPlaybackSettingsAccess(),
      preferences: NoOpPlaybackPreferences(),
      player: player)
  }
}
