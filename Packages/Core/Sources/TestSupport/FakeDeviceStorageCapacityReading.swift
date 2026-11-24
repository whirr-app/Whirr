import AppModel
import Foundation
import Testing

/// Controllable optional-capacity fake. Values are consumed in order, and reads can be parked so
/// coalescing tests can overlap callers without relying on wall-clock timing.
public final class FakeDeviceStorageCapacityReading: DeviceStorageCapacityReading, @unchecked Sendable {
  private let valuesBox: Locked<[Int64?]>
  private let callCountBox = Locked(0)
  public let reads = TestGate<Void>(label: "FakeDeviceStorageCapacityReading.availableCapacityBytes")

  public var callCount: Int { callCountBox.value }
  public var isReadSuspended: Bool { reads.parkedCount > 0 }

  public init(values: [Int64?] = [nil], suspendsReads: Bool = false) {
    valuesBox = Locked(values)
    if suspendsReads { reads.hold() }
  }

  public func availableCapacityBytes() async -> Int64? {
    callCountBox.withValue { $0 += 1 }
    let value = valuesBox.withValue { values -> Int64? in
      guard values.isEmpty == false else { return nil }
      return values.removeFirst()
    }
    await reads.pass()
    return value
  }

  public func holdReads() { reads.hold() }
  public func resumeReads() { reads.release() }
}
