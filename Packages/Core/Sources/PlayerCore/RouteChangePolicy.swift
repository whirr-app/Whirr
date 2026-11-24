/// Plain route-change reason, mapped from `AVAudioSession.RouteChangeReason` by the App-target
/// notification adapter. Only `.oldDeviceUnavailable` produces an action. A new device, a category
/// change, an override or any other reason is inert.
public enum RouteChangeEvent: Sendable, Equatable {
  case oldDeviceUnavailable
  case newDeviceAvailable
  case categoryChange
  case override
  case other
}

/// Pure route-change policy: pause on old-device-unavailable. `Action` has no resume case, so this
/// type can never produce an automatic resume.
///
/// Stateless. A duplicate `.oldDeviceUnavailable` is a no-op: the first `.pause` has already moved
/// `PlaybackControlling.state.phase` to `.paused` when it arrives.
public struct RouteChangePolicy: Sendable, Equatable {
  public enum Action: Sendable, Equatable {
    case pause
    case none
  }

  public init() {}

  public func handle(_ event: RouteChangeEvent, phase: PlayerPhase) -> Action {
    guard event == .oldDeviceUnavailable, phase == .playing else { return .none }
    return .pause
  }
}
