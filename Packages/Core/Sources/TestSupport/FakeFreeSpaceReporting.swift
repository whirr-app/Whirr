import SyncEngine

/// `FreeSpaceReporting`'s fake: a plain mutable value with no stream, matching the protocol's
/// synchronous-only shape. Unlike `DownloadPreferences`/`NetworkConditions`, `DownloadCoordinator`
/// polls this only when it considers starting a transfer, so there is nothing to subscribe to.
public final class FakeFreeSpaceReporting: FreeSpaceReporting, @unchecked Sendable {
  private let capacityBox: Locked<Int64>

  public init(availableCapacityBytes: Int64 = .max) {
    capacityBox = Locked(availableCapacityBytes)
  }

  public var availableCapacityBytesValue: Int64 {
    get { capacityBox.value }
    set { capacityBox.value = newValue }
  }

  public func availableCapacityBytes() -> Int64 { capacityBox.value }
}
