import Foundation
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// `SerialAnalysisQueue`: one pass at a time, coalesced wakes, one idle hook when nothing else is
/// queued, waiters resumed exactly once, and a cancelled or failed pass left until the next input.
@Suite(.timeLimit(.minutes(1)))
struct SerialAnalysisQueueTests {

  /// Counts the calls a queue's hooks make.
  final class Counter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    @discardableResult func increment() -> Int {
      count.withLock {
        $0 += 1
        return $0
      }
    }
  }

  /// Holds a pass open until the test releases it.
  final class Gate: Sendable {
    // A pass runs to completion regardless of cancellation, so a cancelled one stays parked.
    private let gate = TestGate<Void>(label: "Gate analysis pass", ignoresCancellation: true)

    init() {
      gate.hold()
    }

    var isWaiting: Bool { gate.parkedCount > 0 }

    func wait() async {
      await gate.pass()
    }

    func release() {
      gate.releaseParked()
    }
  }

  /// A place for a hook to reach the queue it belongs to without the queue's init seeing itself.
  final class QueueBox: Sendable {
    private let storage = Mutex<SerialAnalysisQueue?>(nil)

    var queue: SerialAnalysisQueue? {
      get { storage.withLock { $0 } }
      set { storage.withLock { $0 = newValue } }
    }
  }

  struct ProbeError: Error {}

  private func makeQueue(
    pass: @escaping @Sendable () async throws -> Void = {},
    passDidRun: (@Sendable () async -> Void)? = nil,
    idle: (@Sendable () async -> Void)? = nil,
    willIdle: (@Sendable () async -> Void)? = nil,
    cancelled: @escaping @Sendable () -> Void = {},
    failed: @escaping @Sendable (any Error) -> Void = { _ in }
  ) -> SerialAnalysisQueue {
    SerialAnalysisQueue(
      hooks: .init(pass: pass, passDidRun: passDidRun, idle: idle, willIdle: willIdle),
      reporting: .init(cancelled: cancelled, failed: failed))
  }

  @Test func aWakeRunsOnePassThenGoesIdle() async throws {
    let passes = Counter()
    let queue = makeQueue(pass: { passes.increment() })

    await queue.wake()
    await queue.waitUntilIdle()

    #expect(passes.value == 1)
  }

  /// Whatever arrives while a pass runs is one queued pass, not one per wake.
  @Test func wakesDuringAPassCoalesceIntoOneFollowUpPass() async throws {
    let passes = Counter()
    let gate = Gate()
    let queue = makeQueue(pass: {
      if passes.increment() == 1 { await gate.wait() }
    })

    await queue.wake()
    #expect(await waitUntil("the pass is held") { gate.isWaiting })
    await queue.wake()
    await queue.wake()
    gate.release()
    await queue.waitUntilIdle()

    #expect(passes.value == 2)
  }

  @Test func aWaiterJoiningAPassIsResumedOnce() async throws {
    let passes = Counter()
    let gate = Gate()
    let queue = makeQueue(pass: {
      if passes.increment() == 1 { await gate.wait() }
    })
    await queue.wake()
    #expect(await waitUntil("the pass is held") { gate.isWaiting })

    let resumed = Counter()
    let waiter = Task {
      await queue.waitUntilIdle()
      resumed.increment()
    }
    // A second waiter joins the same drain.
    let joining = Task {
      await queue.waitUntilIdle()
      resumed.increment()
    }
    await Task.yield()
    gate.release()
    await waiter.value
    await joining.value
    // With no worker left it returns at once rather than parking.
    await queue.waitUntilIdle()

    #expect(resumed.value == 2)
  }

  @Test func aCancelledPassIsNotRetriedUntilTheNextInput() async throws {
    let passes = Counter()
    let cancellations = Counter()
    let queue = makeQueue(
      pass: {
        if passes.increment() == 1 { throw CancellationError() }
      },
      cancelled: { cancellations.increment() })

    await queue.wake()
    await queue.waitUntilIdle()
    #expect(passes.value == 1)
    #expect(cancellations.value == 1)

    await queue.wake()
    await queue.waitUntilIdle()
    #expect(passes.value == 2)
  }

  @Test func aFailedPassIsNotRetriedUntilTheNextInput() async throws {
    let passes = Counter()
    let failures = Counter()
    let queue = makeQueue(
      pass: {
        if passes.increment() == 1 { throw ProbeError() }
      },
      failed: { _ in failures.increment() })

    await queue.wake()
    await queue.waitUntilIdle()
    #expect(passes.value == 1)
    #expect(failures.value == 1)

    await queue.wake()
    await queue.waitUntilIdle()
    #expect(passes.value == 2)
  }

  /// Whatever the outcome, the follow-up work a pass does after every attempt still runs.
  @Test func thePassFollowUpRunsAfterACancelledPass() async throws {
    let passes = Counter()
    let followUps = Counter()
    let queue = makeQueue(
      pass: {
        if passes.increment() == 1 { throw CancellationError() }
      },
      passDidRun: { followUps.increment() })

    await queue.wake()
    await queue.waitUntilIdle()

    #expect(followUps.value == 1)
  }

  @Test func stopResumesEveryWaiterAndRunsNothingAfter() async throws {
    let passes = Counter()
    let gate = Gate()
    let queue = makeQueue(pass: {
      if passes.increment() == 1 { await gate.wait() }
    })
    await queue.wake()
    #expect(await waitUntil("the pass is held") { gate.isWaiting })

    let resumed = Counter()
    let waiters = (0..<2).map { _ in
      Task {
        await queue.waitUntilIdle()
        resumed.increment()
      }
    }
    await Task.yield()
    await queue.stop()
    #expect(await queue.hasStopped)
    gate.release()
    for waiter in waiters { await waiter.value }

    #expect(resumed.value == 2)

    await queue.wake()
    await queue.waitUntilIdle()
    #expect(passes.value == 1)
  }

  @Test func theIdleHookRunsOnceTheQueueIsEmpty() async throws {
    let passes = Counter()
    let idleRuns = Counter()
    let queue = makeQueue(
      pass: { passes.increment() }, idle: { idleRuns.increment() })

    await queue.wake()
    await queue.waitUntilIdle()

    #expect(passes.value == 1)
    #expect(idleRuns.value == 1)
  }

  /// AdSkip's carried-plan check queues what it finds as a further pass.
  @Test func theIdleHookCanRequestAnotherPass() async throws {
    let passes = Counter()
    let idleRuns = Counter()
    let willIdleRuns = Counter()
    let box = QueueBox()
    let queue = makeQueue(
      pass: { passes.increment() },
      idle: {
        if idleRuns.increment() == 1 { await box.queue?.requestPass() }
      },
      willIdle: { willIdleRuns.increment() })
    box.queue = queue

    await queue.wake()
    await queue.waitUntilIdle()

    #expect(passes.value == 2)
    #expect(idleRuns.value == 2)
    #expect(willIdleRuns.value == 1)
  }

  /// A wake arriving while the end-of-drain hook runs still gets the pass it asked for; the
  /// worker must not be dropped with work queued.
  @Test func aWakeDuringTheEndOfDrainHookStillRunsItsPass() async throws {
    let passes = Counter()
    let willIdles = Counter()
    let box = QueueBox()
    let queue = makeQueue(
      pass: { passes.increment() },
      willIdle: {
        if willIdles.increment() == 1 { await box.queue?.wake() }
      })
    box.queue = queue

    await queue.wake()
    await queue.waitUntilIdle()

    #expect(passes.value == 2)
    #expect(willIdles.value == 2)
  }

  /// A coordinator stopped mid-pass must not start its idle work during teardown.
  @Test func theIdleHookDoesNotRunAfterStop() async throws {
    let passes = Counter()
    let idleRuns = Counter()
    let gate = Gate()
    let queue = makeQueue(
      pass: {
        if passes.increment() == 1 { await gate.wait() }
      },
      idle: { idleRuns.increment() })

    await queue.wake()
    #expect(await waitUntil("the pass is held") { gate.isWaiting })
    await queue.stop()
    gate.release()
    await queue.waitUntilIdle()

    #expect(idleRuns.value == 0)
  }

  @Test func feedersInstallOnceAreCancelledAtStopAndSkipStoppedQueues() async throws {
    let finished = Counter()
    let queue = makeQueue()

    let installed = await queue.installFeeders {
      [
        Task {
          // Ending only on cancellation, as a feeder over a stream that never finishes does.
          do { try await Task.sleep(for: .seconds(60)) } catch {}
          finished.increment()
        }
      ]
    }
    #expect(installed)
    #expect(await queue.installFeeders { [] } == false)

    await queue.stop()
    #expect(await queue.installFeeders { [] } == false)
    #expect(await waitUntil("the feeder is cancelled") { finished.value == 1 })
  }
}
