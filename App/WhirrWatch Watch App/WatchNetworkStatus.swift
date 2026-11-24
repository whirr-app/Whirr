import Foundation
import Network
import WatchPlayback

/// URLSession enforces the cellular restriction too; this signal controls user-visible queue admission.
nonisolated final class WatchNetworkStatus: @unchecked Sendable {
  private let lock = NSLock()
  /// Before the first path update the monitor has said nothing, which is treated like the
  /// unsatisfied path a restricted Watch reports.
  private var admits = WatchDownloadNetworkPolicy.admitsAutomaticTransfer(
    pathSatisfied: false, pathUsesCellular: false)
  private let monitor = NWPathMonitor()

  /// True when the current path is one the Wi-Fi-only policy should admit automatically.
  var isWiFiAvailable: Bool { lock.withLock { admits } }

  /// Every narrower predicate has parked all transfers on real hardware: `usesInterfaceType(.wifi)`
  /// because the companion relay reports as `.other`, `!isExpensive && !isConstrained` because the
  /// relay is marked expensive, and `status == .satisfied` because of the TN3135 restriction
  /// documented on `WatchDownloadNetworkPolicy.admitsAutomaticTransfer`.
  init(onChange: @escaping @Sendable () -> Void) {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let admits = WatchDownloadNetworkPolicy.admitsAutomaticTransfer(
        pathSatisfied: path.status == .satisfied, pathUsesCellular: path.usesInterfaceType(.cellular))
      self.lock.withLock { self.admits = admits }
      onChange()
    }
    monitor.start(queue: DispatchQueue(label: "com.remoteconcern.whirr.watch-network"))
  }

  deinit { monitor.cancel() }
}
