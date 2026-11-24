import Foundation
import TestSupport
import Testing

@testable import SyncEngine

/// `NetworkConditionsReducer`'s pure mapping from raw `PathObserving`/`PowerObserving` updates
/// onto the `isConstrainedOrCellular`/`isLowPowerMode` predicate. No real `NWPathMonitor` or
/// `ProcessInfo`: both are injected fakes driven directly by each test.
@Suite("NetworkConditionsReducer mapping")
struct NetworkConditionMappingTests {

  @Test("Wi-Fi (unconstrained, satisfied, not cellular) is not degraded")
  func wifiIsNotDegraded() {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: false)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    #expect(reducer.isConstrainedOrCellular == false)
    #expect(reducer.isLowPowerMode == false)
  }

  @Test("cellular-only path is degraded")
  func cellularOnlyIsDegraded() {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))
    let power = FakePowerObserving(initial: false)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    #expect(reducer.isConstrainedOrCellular == true)
  }

  @Test("constrained Wi-Fi is degraded")
  func constrainedWiFiIsDegraded() {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: true))
    let power = FakePowerObserving(initial: false)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    #expect(reducer.isConstrainedOrCellular == true)
  }

  @Test("an unavailable/unknown path is not itself treated as degraded - not an online/offline oracle")
  func unavailablePathIsNotDegraded() {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: false, isCellular: true, isConstrained: true))
    let power = FakePowerObserving(initial: false)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    #expect(reducer.isConstrainedOrCellular == false)
  }

  @Test("Low Power Mode reads through independently of path state")
  func lowPowerModeReadsThrough() {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: true)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    #expect(reducer.isLowPowerMode == true)
    #expect(reducer.isConstrainedOrCellular == false)
  }

  @Test("current values are immediately readable at construction, before any update fires")
  func currentValuesReadableImmediately() {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))
    let power = FakePowerObserving(initial: true)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    #expect(reducer.isConstrainedOrCellular == true)
    #expect(reducer.isLowPowerMode == true)
  }

  @Test("a real path/power change is published on the changes stream")
  func changePublishesOnStream() async {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: false)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    var iterator = reducer.changes.makeAsyncIterator()
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))
    power.simulate(true)
    let initial = await iterator.next()
    let next = await iterator.next()

    #expect(initial == NetworkConditionsSnapshot(isLowPowerMode: false, isConstrainedOrCellular: false))
    #expect(next == NetworkConditionsSnapshot(isLowPowerMode: false, isConstrainedOrCellular: true))
  }

  @Test("every subscriber receives the current snapshot and every subsequent change")
  func changesAreMulticastWithSnapshotReplay() async {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: false)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    var first = reducer.changes.makeAsyncIterator()
    var second = reducer.changes.makeAsyncIterator()

    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))
    power.simulate(true)
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    power.simulate(false)
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))
    power.simulate(true)

    let expected = [
      NetworkConditionsSnapshot(isLowPowerMode: false, isConstrainedOrCellular: false),
      NetworkConditionsSnapshot(isLowPowerMode: false, isConstrainedOrCellular: true),
      NetworkConditionsSnapshot(isLowPowerMode: true, isConstrainedOrCellular: true),
    ]
    let firstValues = [await first.next(), await first.next(), await first.next()]
    let secondValues = [await second.next(), await second.next(), await second.next()]

    #expect(firstValues == expected)
    #expect(secondValues == expected)
  }

  @Test("a late subscriber receives the latest snapshot before the next change")
  func lateSubscriberReceivesCurrentSnapshot() async {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: false)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))
    power.simulate(true)

    var iterator = reducer.changes.makeAsyncIterator()
    power.simulate(false)

    #expect(
      await iterator.next()
        == NetworkConditionsSnapshot(isLowPowerMode: true, isConstrainedOrCellular: true))
    #expect(
      await iterator.next()
        == NetworkConditionsSnapshot(isLowPowerMode: false, isConstrainedOrCellular: true))
  }

  @Test("the shared fake mirrors replay and multicast production semantics")
  func fakeNetworkConditionsMulticastsWithReplay() async {
    let conditions = FakeNetworkConditions()
    var first = conditions.changes.makeAsyncIterator()
    var second = conditions.changes.makeAsyncIterator()

    conditions.simulateChange(isConstrainedOrCellular: true)
    conditions.simulateChange(isLowPowerMode: true)
    conditions.simulateChange(isConstrainedOrCellular: false)
    conditions.simulateChange(isLowPowerMode: false)
    conditions.simulateChange(isConstrainedOrCellular: true)
    conditions.simulateChange(isLowPowerMode: true)

    let expected = [
      NetworkConditionsSnapshot(isLowPowerMode: false, isConstrainedOrCellular: false),
      NetworkConditionsSnapshot(isLowPowerMode: false, isConstrainedOrCellular: true),
      NetworkConditionsSnapshot(isLowPowerMode: true, isConstrainedOrCellular: true),
    ]

    #expect([await first.next(), await first.next(), await first.next()] == expected)
    #expect([await second.next(), await second.next(), await second.next()] == expected)
  }

  @Test("repeating the same effective condition never re-emits a duplicate change")
  func duplicateConditionsAreDeduplicated() async {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: false)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    var iterator = reducer.changes.makeAsyncIterator()

    // A genuine change, then two updates that map to the same effective value. Neither of the
    // latter two may add a second buffered element to the stream.
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: true))  // still degraded, no-op
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))  // exact repeat, no-op
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))

    _ = await iterator.next()
    let first = await iterator.next()
    #expect(first?.isConstrainedOrCellular == true)

    // If either duplicate update above had been buffered, this `next()` would return one of
    // those instead of the real second change.
    let second = await iterator.next()
    #expect(second?.isConstrainedOrCellular == false)
  }

  @Test(
    "changes continue to be delivered to the single subscriber across multiple updates, as during an active playback session"
  )
  func changesDuringPlaybackAreAllDelivered() async {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: false)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    var iterator = reducer.changes.makeAsyncIterator()
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))
    power.simulate(true)
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    power.simulate(false)
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))

    let values = [
      await iterator.next(), await iterator.next(), await iterator.next(), await iterator.next(),
      await iterator.next(),
    ]
    #expect(
      values == [
        NetworkConditionsSnapshot(isLowPowerMode: false, isConstrainedOrCellular: false),
        NetworkConditionsSnapshot(isLowPowerMode: false, isConstrainedOrCellular: true),
        NetworkConditionsSnapshot(isLowPowerMode: true, isConstrainedOrCellular: true),
        NetworkConditionsSnapshot(isLowPowerMode: true, isConstrainedOrCellular: false),
        NetworkConditionsSnapshot(isLowPowerMode: false, isConstrainedOrCellular: false),
      ])
  }

  @Test("teardown cancels both the path and power observers exactly once")
  func teardownCancelsObservers() {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: false)

    do {
      let reducer = NetworkConditionsReducer(path: path, power: power)
      _ = reducer.isLowPowerMode
    }

    #expect(path.stopObservingCallCount == 1)
    #expect(power.stopObservingCallCount == 1)
  }
}

/// Test double for `PowerObserving`: no real `ProcessInfo` notification. Tests drive updates
/// directly via `simulate(_:)`.
private final class FakePowerObserving: PowerObserving, @unchecked Sendable {
  let isLowPowerModeEnabled: Bool
  private var onChange: (@Sendable (Bool) -> Void)?
  private(set) var stopObservingCallCount = 0

  init(initial: Bool) {
    isLowPowerModeEnabled = initial
  }

  func startObserving(onChange: @escaping @Sendable (Bool) -> Void) {
    self.onChange = onChange
  }

  func stopObserving() {
    stopObservingCallCount += 1
  }

  func simulate(_ isLowPowerModeEnabled: Bool) {
    onChange?(isLowPowerModeEnabled)
  }
}
