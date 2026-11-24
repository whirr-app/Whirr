import Foundation
import SyncEngine
import Testing

/// Confirms `NetworkConditionsReducer`, composed as `AppEnvironment` wires it with the real
/// `RealPathObserving`/`RealPowerObserving` adapters, works from the App target through injected
/// `PathObserving`/`PowerObserving` fakes, never touching a real radio or `ProcessInfo`
/// notification. Mapping scenarios (Wi-Fi, cellular, constrained, Low Power Mode, dedup) are in
/// Core; these prove only the App-side wiring.
@Suite("NetworkConditionsReducer (App-target wiring)")
struct NetworkConditionsAdapterTests {

  @Test("Wi-Fi is not degraded; a switch to cellular is")
  func wifiThenCellular() async {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: false)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    #expect(reducer.isConstrainedOrCellular == false)

    var iterator = reducer.changes.makeAsyncIterator()
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))
    // Every subscription opens with the snapshot current at subscribe time, then the changes.
    let replayed = await iterator.next()
    let next = await iterator.next()

    #expect(replayed?.isConstrainedOrCellular == false)
    #expect(next?.isConstrainedOrCellular == true)
    #expect(reducer.isConstrainedOrCellular == true)
  }

  @Test("Low Power Mode is readable immediately from the injected PowerObserving's current value")
  func lowPowerModeReadableImmediately() {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: true)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    #expect(reducer.isLowPowerMode == true)
  }

  @Test("a repeated identical condition never re-emits a duplicate change")
  func duplicateIsNotReemitted() async {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: false)
    let reducer = NetworkConditionsReducer(path: path, power: power)

    var iterator = reducer.changes.makeAsyncIterator()
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false))  // Exact repeat, no-op.
    _ = await iterator.next()  // the subscribe-time snapshot replay
    let first = await iterator.next()
    #expect(first?.isConstrainedOrCellular == true)

    // If the duplicate above had actually been buffered, this would return it instead of the
    // real second change below.
    path.simulate(PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let second = await iterator.next()
    #expect(second?.isConstrainedOrCellular == false)
  }

  @Test("teardown cancels both injected observers")
  func teardownCancelsObservers() {
    let path = FakePathObserving(initial: PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false))
    let power = FakePowerObserving(initial: false)

    do {
      let reducer = NetworkConditionsReducer(path: path, power: power)
      _ = reducer.isConstrainedOrCellular
    }

    #expect(path.stopObservingCallCount == 1)
    #expect(power.stopObservingCallCount == 1)
  }
}
