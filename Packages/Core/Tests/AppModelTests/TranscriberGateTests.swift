import AdSkip
import Foundation
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// `TranscriberGate`: one analyser at a time between ad skip and the transcript session.
@Suite struct TranscriberGateTests {

  /// A transcriber whose calls block until the test lets each one finish, recording the order
  /// they started in and how many ran at once.
  final class BlockingTranscriber: EpisodeTranscribing {
    private struct State {
      var started: [String] = []
      var running = 0
      var maxRunning = 0
      var gates: [String: TestGate<Void>] = [:]
    }

    private let state = Mutex(State())

    var started: [String] { state.withLock { $0.started } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }

    func transcript(ofFileAt url: URL, windows: [TimeSpan]) async throws -> Transcript {
      let name = url.lastPathComponent
      // One gate per call, so `finish(_:)` frees exactly the call it names. A call stays parked on
      // task cancellation until its gate is released.
      let gate = TestGate<Void>(label: "BlockingTranscriber \(name)", ignoresCancellation: true)
      gate.hold()
      state.withLock {
        $0.started.append(name)
        $0.running += 1
        $0.maxRunning = max($0.maxRunning, $0.running)
        $0.gates[name] = gate
      }
      await gate.pass()
      state.withLock { $0.running -= 1 }
      return Transcript(words: [], duration: 1)
    }

    /// Lets the named call return, once it has started.
    func finish(_ name: String) async {
      _ = await awaitCondition("call \(name) waiting") {
        state.withLock { $0.gates[name] != nil }
      }
      state.withLock { $0.gates.removeValue(forKey: name) }?.release()
    }

    func waitUntilStarted(_ name: String) async {
      _ = await awaitCondition("call \(name) started") { started.contains(name) }
    }
  }

  private func url(_ name: String) -> URL { URL(fileURLWithPath: "/\(name)") }

  /// Waits until `condition` holds, so a test can wait for queued waiters to register.
  private func eventually(
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async -> Bool
  ) async {
    _ = await awaitCondition("condition", sourceLocation: sourceLocation, until: condition)
  }

  @Test func aSessionWaitsForTheCallInFlightThenGoesAheadOfWaitingAdSkipCalls() async throws {
    let gate = TranscriberGate()
    let base = BlockingTranscriber()
    let adSkip = gate.gating(base)
    let order = Mutex<[String]>([])

    let first = Task { _ = try await adSkip.transcript(ofFileAt: url("a"), windows: []) }
    await base.waitUntilStarted("a")
    let second = Task { _ = try await adSkip.transcript(ofFileAt: url("b"), windows: []) }
    await eventually { await gate.waitingCount == 1 }
    let session = Task {
      try await gate.acquire(for: .session)
      order.withLock { $0.append("session") }
      await gate.release()
    }
    await eventually { await gate.waitingCount == 2 }

    await base.finish("a")
    try await session.value
    #expect(order.withLock { $0 } == ["session"])
    await base.finish("b")
    try await first.value
    try await second.value
    #expect(base.started == ["a", "b"])
    #expect(base.maxRunning == 1)
  }

  @Test func aCancelledWaiterLeavesTheQueue() async throws {
    let gate = TranscriberGate()
    let base = BlockingTranscriber()
    let adSkip = gate.gating(base)

    let holder = Task { _ = try await adSkip.transcript(ofFileAt: url("a"), windows: []) }
    await base.waitUntilStarted("a")
    let cancelled = Task { _ = try await adSkip.transcript(ofFileAt: url("b"), windows: []) }
    await eventually { await gate.waitingCount == 1 }
    let next = Task { _ = try await adSkip.transcript(ofFileAt: url("c"), windows: []) }
    await eventually { await gate.waitingCount == 2 }

    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    await eventually { await gate.waitingCount == 1 }
    await base.finish("a")
    await base.finish("c")
    try await holder.value
    try await next.value
    #expect(base.started == ["a", "c"])
  }

  @Test func aCancelledHolderKeepsTheGateUntilItsCallReturns() async throws {
    let gate = TranscriberGate()
    let base = BlockingTranscriber()
    let adSkip = gate.gating(base)

    let holder = Task { _ = try await adSkip.transcript(ofFileAt: url("a"), windows: []) }
    await base.waitUntilStarted("a")
    let session = Task { try await gate.acquire(for: .session) }
    await eventually { await gate.waitingCount == 1 }

    holder.cancel()
    await awaitQuiescence("the cancelled holder") { "\(await gate.waitingCount)" }
    #expect(await gate.waitingCount == 1)

    await base.finish("a")
    try await holder.value
    try await session.value
    #expect(await gate.waitingCount == 0)
    await gate.release()
    #expect(await gate.isHeldForTesting == false)
  }

  @Test func aCancelledSessionWaiterNeverHoldsTheGate() async throws {
    let gate = TranscriberGate()
    try await gate.acquire(for: .adSkip)
    let session = Task { try await gate.acquire(for: .session) }
    await eventually { await gate.waitingCount == 1 }

    session.cancel()
    await #expect(throws: CancellationError.self) { try await session.value }
    await gate.release()
    #expect(await gate.isHeldForTesting == false)
  }

  /// The cancellation that lands in the gap between `acquire`'s first cancellation check and the
  /// waiter's registration must still remove the waiter. A waiter left behind is granted by the
  /// next `release()` and runs its work holding the gate although its task is cancelled.
  @Test func aWaiterCancelledBeforeItRegistersNeverTakesTheGate() async throws {
    for _ in 0..<200 {
      let gate = TranscriberGate()
      try await gate.acquire(for: .adSkip)
      let acquirer = Task { try await gate.acquire(for: .session) }
      let canceller = Task.detached(priority: .high) { acquirer.cancel() }
      await canceller.value
      _ = await awaitCondition(
        "the cancelled waiter leaves the queue", timeout: 1, recordingIssue: false
      ) { await gate.waitingCount == 0 }
      // With the gate held, `acquire` can return only for a waiter the cancellation missed.
      await gate.release()
      let granted = (try? await acquirer.value) != nil
      #expect(granted == false, "a waiter cancelled before registration was granted the gate")
      if granted { break }
    }
  }

  /// A `release` that hands the gate over before the cancellation's `leave` reaches the actor must
  /// not leave the cancelled waiter holding it.
  @Test func aCancelledWaiterReleasedBeforeItsLeaveLandsDoesNotHoldTheGate() async throws {
    let gate = TranscriberGate()
    try await gate.acquire(for: .adSkip)
    let waiter = Task { try await gate.acquire(for: .session) }
    await eventually { await gate.waitingCount == 1 }

    waiter.cancel()
    await gate.release()

    await #expect(throws: CancellationError.self) { try await waiter.value }
    #expect(await gate.isHeldForTesting == false)
  }

  @Test func lookBackGoesAheadOfWaitingSessionsAndAdSkipCalls() async throws {
    let gate = TranscriberGate()
    try await gate.acquire(for: .adSkip)
    let order = Mutex<[String]>([])
    func claim(_ claimant: TranscriberGate.Claimant, _ name: String) -> Task<Void, any Error> {
      Task {
        try await gate.acquire(for: claimant)
        order.withLock { $0.append(name) }
        await gate.release()
      }
    }
    let adSkip = claim(.adSkip, "adSkip")
    await eventually { await gate.waitingCount == 1 }
    let session = claim(.session, "session")
    await eventually { await gate.waitingCount == 2 }
    let lookBack = claim(.lookBack, "lookBack")
    await eventually { await gate.waitingCount == 3 }

    await gate.release()
    try await adSkip.value
    try await session.value
    try await lookBack.value
    #expect(order.withLock { $0 } == ["lookBack", "session", "adSkip"])
    #expect(await gate.isHeldForTesting == false)
  }

  @Test func aCancelledLookBackWaiterLeavesTheQueue() async throws {
    let gate = TranscriberGate()
    try await gate.acquire(for: .session)
    let lookBack = Task { try await gate.acquire(for: .lookBack) }
    await eventually { await gate.waitingCount == 1 }

    lookBack.cancel()
    await #expect(throws: CancellationError.self) { try await lookBack.value }
    #expect(await gate.waitingCount == 0)
    await gate.release()
    #expect(await gate.isHeldForTesting == false)
  }
}
