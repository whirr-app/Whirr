import SyncEngine

/// Decides whether the shell shows its connectivity status indicator, from reachability alone.
///
/// Reachability alone drives it, not the consequences of an outage: a refused playback start
/// already raises the start-failure alert, so a consequence-driven indicator would light two
/// surfaces for one tap. The glyph is quiet enough to be state-driven.
///
/// `.unknown` renders as nothing and stays distinct from "offline": cold launch has no evidence
/// yet.
public enum ConnectivityStatusPolicy: Sendable {
  public static func indicator(
    for reachability: ServerReachability
  ) -> ConnectivityStatusDescription? {
    guard case .unreachable(let reason, _) = reachability else { return nil }
    return ConnectivityStatusCopy.status(for: reason)
  }
}
