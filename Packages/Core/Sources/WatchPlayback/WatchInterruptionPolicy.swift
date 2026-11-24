/// What an audio-session interruption or route change does to Watch playback.
///
/// | Notification | Action |
/// |---|---|
/// | interruption began | pause if playing; otherwise nothing |
/// | interruption ended, `shouldResume` | resume, only if the interruption paused it |
/// | interruption ended, no `shouldResume` | stay paused |
/// | route `oldDeviceUnavailable` | pause if playing |
/// | other route changes | nothing |
public struct WatchInterruptionPolicy: Sendable, Equatable {
  public enum RouteChange: Sendable, Equatable {
    case oldDeviceUnavailable
    case newDeviceAvailable
    case categoryChange
    case other
  }

  public enum Notification: Sendable, Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(RouteChange)
  }

  public enum Action: Sendable, Equatable {
    case none
    case pause
    case resume
  }

  /// The interruption paused playback, so its end may resume it.
  private var pausedForInterruption = false

  public init() {}

  /// `playing` says whether playback is wanted when the notification arrives.
  public mutating func handle(_ notification: Notification, playing: Bool) -> Action {
    switch notification {
    case .interruptionBegan:
      pausedForInterruption = playing
      return playing ? .pause : .none
    case .interruptionEnded(let shouldResume):
      defer { pausedForInterruption = false }
      return shouldResume && pausedForInterruption ? .resume : .none
    case .routeChanged(.oldDeviceUnavailable):
      pausedForInterruption = false
      return playing ? .pause : .none
    case .routeChanged:
      return .none
    }
  }

  /// The listener played, stopped or started something during the interruption: its end must not
  /// override that.
  public mutating func listenerActed() {
    pausedForInterruption = false
  }
}
