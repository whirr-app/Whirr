import Foundation
import TestSupport
import Testing

@testable import ReaderCore

@Suite(.timeLimit(.minutes(1))) struct ReadingSessionTrackerTests {
  private let syncInterval = ReadingSessionTracker.syncInterval

  @Test func aBurstOfPositionUpdatesEmitsOneIntentAtTheSixtySecondBoundaryCarryingTheLatestPosition()
    async
  {
    let clock = ManualReadingClock(now: 0)
    let emitter = RecordingIntentEmitter()
    let restore = RecordingRestoreTargetProvider(target: nil)
    let finishOfferer = RecordingFinishOfferer()
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: restore,
      intentEmitter: emitter,
      finishOfferer: finishOfferer,
      clock: clock)
    let stream = PositionStream()
    let first = position(totalProgression: 0.1)
    let middle = position(totalProgression: 0.2)
    let latest = position(totalProgression: 0.3)

    await tracker.open(positions: stream.stream)
    stream.yield(first)
    stream.yield(middle)
    stream.yield(latest)

    #expect(await waitUntil { clock.pendingSleepCount > 0 })
    #expect(emitter.intents.isEmpty)

    clock.advance(by: syncInterval - 1)
    #expect(emitter.intents.isEmpty)

    clock.advance(by: 1)
    #expect(await waitUntil { emitter.intents.count == 1 })
    #expect(emitter.intents.first?.position == latest)
  }

  @Test func aFailedPositionWriteLeavesThePositionEligibleForTheNextEmissionOpportunity() async {
    let clock = ManualReadingClock(now: 0)
    let emitter = RecordingIntentEmitter(failuresRemaining: 1)
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: RecordingRestoreTargetProvider(target: nil),
      intentEmitter: emitter,
      finishOfferer: RecordingFinishOfferer(),
      clock: clock)
    let stream = PositionStream()
    let position = position(totalProgression: 0.2)

    await tracker.open(positions: stream.stream)
    stream.yield(position)
    #expect(await waitUntil { clock.pendingSleepCount > 0 })

    await tracker.background()
    #expect(await waitUntil { emitter.failureCount == 1 })
    #expect(emitter.intents.count == 1)

    await tracker.background()
    #expect(await waitUntil { emitter.intents.count == 2 })
    #expect(emitter.intents.map(\.position) == [position, position])
  }

  @Test func aSuccessfulPositionWriteAdvancesTheBaselineExactlyOnce() async {
    let clock = ManualReadingClock(now: 0)
    let emitter = RecordingIntentEmitter()
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: RecordingRestoreTargetProvider(target: nil),
      intentEmitter: emitter,
      finishOfferer: RecordingFinishOfferer(),
      clock: clock)
    let stream = PositionStream()

    await tracker.open(positions: stream.stream)
    stream.yield(position(totalProgression: 0.2))
    #expect(await waitUntil { clock.pendingSleepCount > 0 })

    await tracker.background()
    #expect(await waitUntil { emitter.intents.count == 1 })

    await tracker.background()
    #expect(emitter.intents.count == 1)
  }

  @Test func closeFlushesImmediatelyExactlyOnceAndResetsTheDebounceWindow() async {
    let clock = ManualReadingClock(now: 0)
    let emitter = RecordingIntentEmitter()
    let restore = RecordingRestoreTargetProvider(target: nil)
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: restore,
      intentEmitter: emitter,
      finishOfferer: RecordingFinishOfferer(),
      clock: clock)
    let firstStream = PositionStream()

    await tracker.open(positions: firstStream.stream)
    firstStream.yield(position(totalProgression: 0.1))
    #expect(await waitUntil { clock.pendingSleepCount > 0 })

    await tracker.close()
    await tracker.close()
    #expect(emitter.intents.count == 1)

    let reopenedStream = PositionStream()
    await tracker.open(positions: reopenedStream.stream)
    let sleepRequestsBeforeReopen = clock.sleepRequestCount
    reopenedStream.yield(position(totalProgression: 0.2))
    #expect(await waitUntil { clock.sleepRequestCount > sleepRequestsBeforeReopen })

    clock.advance(by: syncInterval - 1)
    #expect(emitter.intents.count == 1)
    clock.advance(by: 1)
    #expect(await waitUntil { emitter.intents.count == 2 })
  }

  @Test func backgroundFlushesImmediatelyExactlyOnceAndResetsTheDebounceWindow() async {
    let clock = ManualReadingClock(now: 0)
    let emitter = RecordingIntentEmitter()
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: RecordingRestoreTargetProvider(target: nil),
      intentEmitter: emitter,
      finishOfferer: RecordingFinishOfferer(),
      clock: clock)
    let stream = PositionStream()

    await tracker.open(positions: stream.stream)
    stream.yield(position(totalProgression: 0.1))
    #expect(await waitUntil { clock.pendingSleepCount > 0 })

    await tracker.background()
    await tracker.background()
    #expect(emitter.intents.count == 1)

    let sleepRequestsBeforeSecondPosition = clock.sleepRequestCount
    stream.yield(position(totalProgression: 0.2))
    #expect(await waitUntil { clock.sleepRequestCount > sleepRequestsBeforeSecondPosition })
    clock.advance(by: syncInterval - 1)
    #expect(emitter.intents.count == 1)
    clock.advance(by: 1)
    #expect(await waitUntil { emitter.intents.count == 2 })
  }

  @Test func unchangedPositionCloseEmitsNothing() async {
    let unchanged = position(totalProgression: 0.4)
    let emitter = RecordingIntentEmitter()
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: RecordingRestoreTargetProvider(target: unchanged),
      intentEmitter: emitter,
      finishOfferer: RecordingFinishOfferer(),
      clock: ManualReadingClock(now: 0))
    let stream = PositionStream()

    await tracker.open(positions: stream.stream)
    stream.yield(unchanged)
    await tracker.close()

    #expect(emitter.intents.isEmpty)
  }

  @Test func positionsArrivingDuringAnInFlightEmissionQueueExactlyOneTrailingEmission() async {
    let clock = ManualReadingClock(now: 0)
    let emitter = RecordingIntentEmitter(holdsEmissions: true)
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: RecordingRestoreTargetProvider(target: nil),
      intentEmitter: emitter,
      finishOfferer: RecordingFinishOfferer(),
      clock: clock)
    let stream = PositionStream()
    let first = position(totalProgression: 0.1)
    let middle = position(totalProgression: 0.2)
    let latest = position(totalProgression: 0.3)

    await tracker.open(positions: stream.stream)
    stream.yield(first)
    #expect(await waitUntil { clock.pendingSleepCount > 0 })
    clock.advance(by: syncInterval)
    #expect(await waitUntil { emitter.intents.count == 1 })

    let sleepRequestsBeforeTrailing = clock.sleepRequestCount
    stream.yield(middle)
    stream.yield(latest)
    // Both must be consumed before the held emission is released. Releasing first lets the trailing
    // emission carry `middle`, so `latest` earns a third emission of its own. That would be a
    // failure of the test's staging, not of the coalescing it is checking.
    #expect(await waitUntil { await tracker.latestPosition == latest })
    await emitter.releaseAll()

    #expect(await waitUntil { clock.sleepRequestCount > sleepRequestsBeforeTrailing })
    clock.advance(by: syncInterval)
    #expect(await waitUntil { emitter.intents.count == 2 })
    #expect(emitter.intents.map(\.position) == [first, latest])

    await emitter.releaseAll()
    clock.advance(by: syncInterval * 10)
    #expect(emitter.intents.count == 2)
  }

  @Test func closeFlushesTheLatestPositionAfterAHeldEmissionBeforeReturning() async {
    let clock = ManualReadingClock(now: 0)
    let emitter = RecordingIntentEmitter(holdsEmissions: true)
    let finishOfferer = RecordingFinishOfferer()
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: RecordingRestoreTargetProvider(target: nil),
      intentEmitter: emitter,
      finishOfferer: finishOfferer,
      clock: clock)
    let stream = PositionStream()
    let first = position(totalProgression: 0.1)
    let latest = position(totalProgression: 1.0)

    await tracker.open(positions: stream.stream)
    stream.yield(first)
    #expect(await waitUntil { clock.pendingSleepCount > 0 })
    clock.advance(by: syncInterval)
    #expect(await waitUntil { emitter.intents.count == 1 })

    // The finish offer acknowledges that the actor received the newer position while the first
    // write is still held. Close starts before either held write is released.
    stream.yield(latest)
    #expect(await waitUntil { finishOfferer.offerCount == 1 })
    let closeTask = Task { await tracker.close() }

    await emitter.releaseAll()
    #expect(await waitUntil { emitter.intents.count == 2 })
    #expect(emitter.intents.map(\.position) == [first, latest])

    await emitter.releaseAll()
    await closeTask.value
    #expect(emitter.intents.map(\.position) == [first, latest])
  }

  @Test func endOfBookRaisesTheFinishOfferOncePerOpening() async {
    let finishOfferer = RecordingFinishOfferer()
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: RecordingRestoreTargetProvider(target: nil),
      intentEmitter: RecordingIntentEmitter(),
      finishOfferer: finishOfferer,
      clock: ManualReadingClock(now: 0))
    let firstStream = PositionStream()
    let finalPosition = position(totalProgression: 1.0)

    await tracker.open(positions: firstStream.stream)
    firstStream.yield(finalPosition)
    firstStream.yield(finalPosition)
    #expect(await waitUntil { finishOfferer.offerCount == 1 })

    await tracker.close()
    let reopenedStream = PositionStream()
    await tracker.open(positions: reopenedStream.stream)
    reopenedStream.yield(finalPosition)
    #expect(await waitUntil { finishOfferer.offerCount == 2 })

    #expect(finishOfferer.offerCount == 2)
  }

  @Test func restoreTargetIsRequestedExactlyOncePerOpenAndAppliedBeforeAnyEmission() async {
    let clock = ManualReadingClock(now: 0)
    let emitter = RecordingIntentEmitter()
    let restored = position(totalProgression: 0.5)
    let restore = RecordingRestoreTargetProvider(target: restored, holdsRequests: true)
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: restore,
      intentEmitter: emitter,
      finishOfferer: RecordingFinishOfferer(),
      clock: clock)
    let stream = PositionStream()
    let openTask = Task { await tracker.open(positions: stream.stream) }

    #expect(await waitUntil { restore.requestCount == 1 })
    stream.yield(restored)
    clock.advance(by: syncInterval * 10)
    #expect(emitter.intents.isEmpty)

    await restore.releaseAll(with: restored)
    await openTask.value
    #expect(restore.requestCount == 1)
    #expect(emitter.intents.isEmpty)

    await tracker.close()
    let reopenedStream = PositionStream()
    let reopenedTask = Task { await tracker.open(positions: reopenedStream.stream) }
    #expect(await waitUntil { restore.requestCount == 2 })
    await restore.releaseAll(with: restored)
    await reopenedTask.value
    await tracker.close()
  }

  @Test func rapidOpenCloseCannotLeakAnEmissionForAClosedSession() async {
    let clock = ManualReadingClock(now: 0)
    let emitter = RecordingIntentEmitter()
    let restore = RecordingRestoreTargetProvider(
      target: position(totalProgression: 0.2), holdsRequests: true)
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: restore,
      intentEmitter: emitter,
      finishOfferer: RecordingFinishOfferer(),
      clock: clock)
    let stream = PositionStream()
    let openTask = Task { await tracker.open(positions: stream.stream) }

    #expect(await waitUntil { restore.requestCount == 1 })
    stream.yield(position(totalProgression: 0.9))
    clock.advance(by: syncInterval * 10)
    await tracker.close()

    await restore.releaseAll(with: position(totalProgression: 0.2))
    await openTask.value
    #expect(emitter.intents.isEmpty)
  }

  @Test func anEmittedIntentCarriesACFIOnlyWhenThePositionGatePassed() async {
    let clock = ManualReadingClock(now: 0)
    let emitter = RecordingIntentEmitter()
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: RecordingRestoreTargetProvider(target: nil),
      intentEmitter: emitter,
      finishOfferer: RecordingFinishOfferer(),
      clock: clock)
    let stream = PositionStream()
    let cfi = "epubcfi(/6/4!/4/2/1:0)"
    let gated = position(totalProgression: 0.1, cfi: cfi)
    let ungated = position(totalProgression: 0.2, cfi: "/4/2/1:0")

    await tracker.open(positions: stream.stream)
    stream.yield(gated)
    #expect(await waitUntil { clock.pendingSleepCount > 0 })
    await tracker.background()
    #expect(await waitUntil { emitter.intents.count == 1 })

    let sleepRequestsBeforeUngatedPosition = clock.sleepRequestCount
    stream.yield(ungated)
    #expect(await waitUntil { clock.sleepRequestCount > sleepRequestsBeforeUngatedPosition })
    await tracker.background()
    #expect(await waitUntil { emitter.intents.count == 2 })

    #expect(emitter.intents[0].ebookLocation == cfi)
    #expect(emitter.intents[1].ebookLocation == nil)
  }

  @Test func anIntentWithNoCFIIsWellFormedRatherThanSuppressed() async {
    let clock = ManualReadingClock(now: 0)
    let emitter = RecordingIntentEmitter()
    let tracker = ReadingSessionTracker(
      restoreTargetProvider: RecordingRestoreTargetProvider(target: nil),
      intentEmitter: emitter,
      finishOfferer: RecordingFinishOfferer(),
      clock: clock)
    let stream = PositionStream()
    let withoutCFI = position(totalProgression: 0.42)

    await tracker.open(positions: stream.stream)
    stream.yield(withoutCFI)
    #expect(await waitUntil { clock.pendingSleepCount > 0 })
    await tracker.background()

    #expect(await waitUntil { emitter.intents.count == 1 })
    let intent = try! #require(emitter.intents.first)
    #expect(intent.position == withoutCFI)
    #expect(intent.ebookProgress == withoutCFI.ebookProgress)
    #expect(intent.ebookLocation == nil)
  }

  private func position(totalProgression: Double, cfi: String? = nil) -> ReadingPosition {
    ReadingPosition(
      href: "Text/chapter-\(Int(totalProgression * 100)).xhtml",
      progression: totalProgression,
      totalProgression: totalProgression,
      position: Int(totalProgression * 100),
      cfi: cfi)
  }
}

private final class PositionStream: @unchecked Sendable {
  let stream: AsyncStream<ReadingPosition>
  private let continuation: AsyncStream<ReadingPosition>.Continuation

  init() {
    var continuation: AsyncStream<ReadingPosition>.Continuation!
    stream = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  func yield(_ position: ReadingPosition) {
    continuation.yield(position)
  }
}

private final class ManualReadingClock: ReadingSessionClock, @unchecked Sendable {
  private struct Sleeper {
    let deadline: TimeInterval
    let continuation: CheckedContinuation<Void, Never>
  }

  private let lock = NSLock()
  private var current: TimeInterval
  private var sleepers: [Sleeper] = []
  private var sleepRequests = 0

  init(now: TimeInterval) {
    current = now
  }

  var pendingSleepCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return sleepers.count
  }

  var sleepRequestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return sleepRequests
  }

  func now() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func sleep(until deadline: TimeInterval) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      sleepRequests += 1
      if current >= deadline {
        lock.unlock()
        continuation.resume()
      } else {
        sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
        lock.unlock()
      }
    }
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    current += interval
    let due = sleepers.filter { $0.deadline <= current }
    sleepers.removeAll { $0.deadline <= current }
    lock.unlock()

    for sleeper in due {
      sleeper.continuation.resume()
    }
  }
}

private final class RecordingRestoreTargetProvider: ReadingRestoreTargetProviding, @unchecked Sendable {
  private let lock = NSLock()
  private let target: ReadingPosition?
  private let holdsRequests: Bool
  private var requests = 0
  private var released = 0
  // A held request runs to completion regardless of cancellation, so a cancelled one stays parked.
  private let gate = TestGate<ReadingPosition?>(
    label: "RecordingRestoreTargetProvider restore target", ignoresCancellation: true)

  init(target: ReadingPosition?, holdsRequests: Bool = false) {
    self.target = target
    self.holdsRequests = holdsRequests
    if holdsRequests { gate.hold() }
  }

  var requestCount: Int {
    withLock { requests }
  }

  func resolvedRestoreTarget() async -> ReadingPosition? {
    let holds = withLock { holdsRequests }
    if holds == false {
      return withLock {
        requests += 1
        return target
      }
    }

    withLock { requests += 1 }
    let fallback = target
    return await gate.pass(otherwise: { fallback })
  }

  func releaseAll(with target: ReadingPosition?) async {
    // A request counts itself before it parks, so wait for the parks this release must free.
    let pending = withLock { requests - released }
    if pending > 0 { await gate.waitUntilParked(count: pending) }
    withLock { released += pending }
    gate.releaseParked(target)
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private final class RecordingIntentEmitter: ReadingSyncIntentEmitting, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [ReadingSyncIntent] = []
  private var heldCount = 0
  private var releasedCount = 0
  // A held emission runs to completion regardless of cancellation, so a cancelled one stays parked.
  private let gate = TestGate<Void>(
    label: "RecordingIntentEmitter held emission", ignoresCancellation: true)
  private let holdsEmissions: Bool
  private var failuresRemaining: Int
  private var recordedFailureCount = 0

  init(holdsEmissions: Bool = false, failuresRemaining: Int = 0) {
    self.holdsEmissions = holdsEmissions
    self.failuresRemaining = failuresRemaining
    if holdsEmissions { gate.hold() }
  }

  var intents: [ReadingSyncIntent] {
    withLock { recorded }
  }

  var failureCount: Int {
    withLock { recordedFailureCount }
  }

  func emit(_ intent: ReadingSyncIntent) async throws {
    let shouldFail = withLock { () -> Bool in
      guard failuresRemaining > 0 else { return false }
      recorded.append(intent)
      failuresRemaining -= 1
      recordedFailureCount += 1
      return true
    }

    if shouldFail { throw TestIntentEmitterError.write }
    guard holdsEmissions else {
      withLock { recorded.append(intent) }
      return
    }
    withLock {
      recorded.append(intent)
      heldCount += 1
    }
    await gate.pass()
  }

  func releaseAll() async {
    // A held intent becomes visible before it parks, so wait for the parks this release must free.
    let pending = withLock { heldCount - releasedCount }
    if pending > 0 { await gate.waitUntilParked(count: pending) }
    withLock { releasedCount += pending }
    gate.releaseParked()
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private enum TestIntentEmitterError: Error, Sendable {
  case write
}

private final class RecordingFinishOfferer: ReadingFinishOffering, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCount = 0

  var offerCount: Int {
    withLock { recordedCount }
  }

  func offerFinish() async {
    withLock { recordedCount += 1 }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
