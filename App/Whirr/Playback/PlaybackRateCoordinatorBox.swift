import AppModel

/// Late binding between the process-lifetime `PlaybackHardware` and the account-scoped
/// `PlaybackRateCoordinator`, as `StreamAuthorizationRenewerBox` does for stream credentials.
///
/// `RemoteCommandAdapter` registers once per process, but the coordinator is rebuilt per
/// `AppEnvironment` (bound to one account's database); holding one in the other would leave the
/// lock screen writing to the previous account's store after logout. Weak, so a superseded
/// coordinator isn't kept alive; when unbound a lock-screen rate change is refused.
@MainActor
final class PlaybackRateCoordinatorBox {
  weak var underlying: PlaybackRateCoordinator?

  /// Routes to whichever scope governs the loaded title. Returns false when nothing is bound, which
  /// the adapter turns into a failed command rather than a silent no-op.
  func setRateForLoadedTitle(_ rate: Double) -> Bool {
    guard let underlying else { return false }
    return underlying.setRateForLoadedTitle(rate)
  }
}
