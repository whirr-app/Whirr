import Foundation
import Network

/// Which network the device is on, as far as server-address selection cares: the interface types
/// carrying the path and its gateways. Gateways tell one Wi-Fi network from another; an extra
/// `other` interface shows a VPN coming up. Held in memory only and never logged (SECURITY.md).
nonisolated struct NetworkSignature: Equatable, Sendable {
  let interfaces: [String]
  let gateways: [String]

  init(interfaces: [String], gateways: [String]) {
    self.interfaces = interfaces.sorted()
    self.gateways = gateways.sorted()
  }
}

/// Decides whether a path update means the device joined a different network. The first satisfied
/// path is the baseline; an unsatisfied path is ignored, so dropping off and rejoining the same
/// network is not a change.
nonisolated struct NetworkChangeDetector: Sendable {
  private var lastSatisfied: NetworkSignature?

  /// `nil` is an unsatisfied path.
  mutating func observe(_ signature: NetworkSignature?) -> Bool {
    guard let signature else { return false }
    defer { lastSatisfied = signature }
    guard let lastSatisfied else { return false }
    return lastSatisfied != signature
  }
}

/// Emits once each time the device settles on a different network. A dedicated `NWPathMonitor`,
/// separate from the refresh policy's `RealPathObserving`, because that adapter reduces the path
/// to cellular/constrained flags that cannot tell two Wi-Fi networks apart.
@MainActor
final class NetworkChangeSignal {
  /// Joining a network reports several paths in quick succession (Wi-Fi, then the VPN re-routing
  /// over it); selection runs once the path has held still for this long.
  static let settleInterval: Duration = .seconds(3)

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.remoteconcern.whirr.network-change-signal")
  private var detector = NetworkChangeDetector()
  private var pending: Task<Void, Never>?
  private var onChange: (@MainActor () -> Void)?

  func start(onChange: @escaping @MainActor () -> Void) {
    guard self.onChange == nil else { return }
    self.onChange = onChange
    monitor.pathUpdateHandler = { [weak self] path in
      let signature = Self.signature(path)
      Task { @MainActor [weak self] in self?.receive(signature) }
    }
    monitor.start(queue: queue)
  }

  func stop() {
    monitor.cancel()
    pending?.cancel()
    pending = nil
    onChange = nil
  }

  private func receive(_ signature: NetworkSignature?) {
    // Same network, or briefly offline: a pending change keeps its timer. Cancelling it on an
    // offline blip would lose the change, since the detector has already taken the new baseline.
    guard detector.observe(signature) else { return }
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(for: Self.settleInterval)
      guard Task.isCancelled == false, let self else { return }
      self.pending = nil
      self.onChange?()
    }
  }

  private nonisolated static func signature(_ path: NWPath) -> NetworkSignature? {
    guard path.status == .satisfied else { return nil }
    let types: [(NWInterface.InterfaceType, String)] = [
      (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"), (.other, "other"),
    ]
    return NetworkSignature(
      interfaces: types.filter { path.usesInterfaceType($0.0) }.map(\.1),
      gateways: path.gateways.map { "\($0)" })
  }
}
