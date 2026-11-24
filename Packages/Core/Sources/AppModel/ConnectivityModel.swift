import Observation
import SyncEngine

/// The observable projection of the configured server's reachability. The enum is kept intact so
/// cold-launch evidence (`.unknown`) cannot be mistaken for a proven outage.
@MainActor
@Observable
public final class ConnectivityModel {
  public private(set) var reachability: ServerReachability = .unknown

  @ObservationIgnored private let monitor: ServerReachabilityMonitor
  @ObservationIgnored private var changesTask: Task<Void, Never>?

  public init(monitor: ServerReachabilityMonitor) {
    self.monitor = monitor
    let changes = monitor.changes
    changesTask = Task { [weak self] in
      for await reachability in changes {
        guard Task.isCancelled == false, let self else { return }
        self.reachability = reachability
      }
    }
  }

  deinit {
    changesTask?.cancel()
  }
}
