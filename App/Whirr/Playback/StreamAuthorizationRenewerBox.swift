import PlayerCore

/// Ties the same construction-order knot as `PlaybackCoordinatorBox`, in the other direction.
/// `PlaybackHardware` (and its one `PlayerController`) is built before any account exists, while
/// what can re-mint stream credentials (`StreamConfiguringPlaybackSyncing` over the account-scoped
/// `PlaybackSessionCoordinator`) is rebuilt per `AppEnvironment`; each environment points this box
/// at its decorator. `weak`, so a superseded stack isn't kept alive. An unset or released slot
/// answers `false`, leaving the item failed rather than reloading into the same 401.
final class StreamAuthorizationRenewerBox: StreamAuthorizationRenewing, @unchecked Sendable {
  /// The concrete decorator rather than `any StreamAuthorizationRenewing`: a weak reference needs
  /// a class-bound type, and constraining PlayerCore's protocol to `AnyObject` for this box's
  /// convenience would be the wrong way round.
  weak var underlying: StreamConfiguringPlaybackSyncing?

  func renewStreamAuthorizationAndReconfigure() async -> Bool {
    guard let underlying else { return false }
    return await underlying.renewStreamAuthorizationAndReconfigure()
  }
}
