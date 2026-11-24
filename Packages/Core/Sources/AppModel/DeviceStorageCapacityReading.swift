/// Optional read-side boundary for the device capacity shown in Downloads settings.
///
/// Failure stays `nil`: unlike the low-disk scheduler's separate fail-open boundary, UI copy must
/// never turn an unavailable capacity into a sentinel that looks like a real byte figure.
public protocol DeviceStorageCapacityReading: Sendable {
  func availableCapacityBytes() async -> Int64?
}

public struct NoOpDeviceStorageCapacityReading: DeviceStorageCapacityReading, Sendable {
  public init() {}

  public func availableCapacityBytes() async -> Int64? { nil }
}
