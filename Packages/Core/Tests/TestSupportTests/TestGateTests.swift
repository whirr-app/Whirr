import Foundation
import Testing

@testable import TestSupport

@Suite("Test gate")
struct TestGateTests {
  @Test func anOpenGatePassesStraightThrough() async {
    let gate = TestGate<Int>(label: "fetch")
    #expect(await gate.pass { 7 } == 7)
  }

  @Test func aHeldGateParksUntilReleasedWithTheReleasedValue() async {
    let gate = TestGate<Int>(label: "fetch")
    gate.hold()
    let first = Task { await gate.pass { 0 } }
    let second = Task { await gate.pass { 0 } }
    #expect(await gate.waitUntilParked(count: 2) == .observed)
    gate.release(5)
    #expect(await first.value == 5)
    #expect(await second.value == 5)
    #expect(gate.isHeld == false)
    #expect(gate.parkedCount == 0)
  }

  @Test func releaseNextResumesOnlyTheOldestAndKeepsTheHold() async {
    let gate = TestGate<Int>(label: "fetch")
    gate.hold()
    let first = Task { await gate.pass { 0 } }
    #expect(await gate.waitUntilParked() == .observed)
    let second = Task { await gate.pass { 0 } }
    #expect(await gate.waitUntilParked(count: 2) == .observed)
    gate.releaseNext(1)
    #expect(await first.value == 1)
    #expect(gate.isHeld)
    #expect(gate.parkedCount == 1)
    gate.release(2)
    #expect(await second.value == 2)
  }

  @Test func aThrowingCallReleasesThroughAResult() async {
    struct Refused: Error {}
    let gate = TestGate<Result<Int, any Error>>(label: "start")
    gate.hold()
    let call = Task { try await gate.pass { .success(0) }.get() }
    #expect(await gate.waitUntilParked() == .observed)
    gate.release(.failure(Refused()))
    await #expect(throws: Refused.self) { try await call.value }
  }

  @Test func aVoidGateReleases() async {
    let gate = TestGate<Void>(label: "stop")
    gate.hold()
    let call = Task { await gate.pass() }
    #expect(await gate.waitUntilParked() == .observed)
    gate.release()
    await call.value
  }

  @Test func cancellingAParkedCallReturnsTheOpenValue() async {
    let gate = TestGate<Int>(label: "fetch")
    gate.hold()
    let call = Task { await gate.pass { -1 } }
    #expect(await gate.waitUntilParked() == .observed)
    call.cancel()
    #expect(await call.value == -1)
    #expect(gate.parkedCount == 0)
  }

  @Test func aCallNeverReleasedFailsInsteadOfHanging() async {
    let gate = TestGate<Int>(label: "fetch")
    gate.hold()
    await withKnownIssue {
      #expect(await gate.pass(timeout: 0.05) { -1 } == -1)
    }
    #expect(gate.parkedCount == 0)
  }

  @Test func aGateThatIgnoresCancellationKeepsTheCallParkedUntilReleased() async {
    let gate = TestGate<Int>(label: "start", ignoresCancellation: true)
    gate.hold()
    let call = Task { await gate.pass { -1 } }
    #expect(await gate.waitUntilParked() == .observed)
    call.cancel()
    #expect(gate.parkedCount == 1)
    gate.release(3)
    #expect(await call.value == 3)
  }
}
