import SyncEngine

/// Short status copy for the mini-player. The expanded player reuses
/// `ConnectivityStatusCopy` because its title and message have room to explain the remedy.
public enum PlaybackUnavailableCopy: Sendable {
  public static func subtitle(for reason: ServerUnreachableReason) -> String {
    switch reason {
    case .noNetworkPath:
      return "Offline"
    case .serverUnreachable:
      return "Server unavailable"
    }
  }
}
