import TestSupport
import Testing

@testable import Whirr

@Suite(.timeLimit(.minutes(1)))
struct CoverDecodeAdmissionTests {
  @Test("a visible waiter outranks an earlier parked prefetch waiter")
  func visibleWaiterBeatsPrefetchWaiter() async throws {
    let admission = CoverDecodeAdmission(maximumConcurrent: 1)
    try await admission.acquire(priority: .visible)
    let prefetch = Task { try await admission.acquire(priority: .scrollPrefetch) }
    await waitUntilAdmission(
      "one visible waiter is queued",
      observing: { "queued=\(await admission.queuedCount)" },
      until: { await admission.queuedCount == 1 })
    let visible = Task { try await admission.acquire(priority: .visible) }
    await waitUntilAdmission(
      "two waiters are queued",
      observing: { "queued=\(await admission.queuedCount)" },
      until: { await admission.queuedCount == 2 })

    await admission.release(priority: .visible)
    try await visible.value
    #expect(await admission.queuedCount == 1)

    await admission.release(priority: .visible)
    try await prefetch.value
    await admission.release(priority: .scrollPrefetch)

    #expect(await admission.inFlightCount == 0)
    #expect(await admission.queuedCount == 0)
  }

  @Test("a cancelled parked waiter resumes without consuming a permit")
  func cancelledWaiterResumesImmediately() async throws {
    let admission = CoverDecodeAdmission(maximumConcurrent: 1)
    try await admission.acquire(priority: .visible)
    let cancelled = Task { try await admission.acquire(priority: .visible) }
    await waitUntilAdmission(
      "cancelled waiter is queued",
      observing: { "queued=\(await admission.queuedCount)" },
      until: { await admission.queuedCount == 1 })

    cancelled.cancel()

    await #expect(throws: CancellationError.self) {
      try await cancelled.value
    }
    #expect(await admission.queuedCount == 0)
    #expect(await admission.inFlightCount == 1)
    await admission.release(priority: .visible)
    #expect(await admission.inFlightCount == 0)
  }

  @Test("cancelling a parked waiter preserves FIFO order for survivors")
  func cancellationPreservesFIFO() async throws {
    let admission = CoverDecodeAdmission(maximumConcurrent: 1)
    try await admission.acquire(priority: .visible)
    // Each waiter is confirmed parked before the next is created: unstructured tasks reach the
    // actor in scheduling order, not creation order, so enqueueing all three at once would let
    // `last` take the head of the queue and the FIFO assertion below would deadlock.
    let first = Task { try await admission.acquire(priority: .visible) }
    await waitUntilAdmission(
      "first FIFO waiter is queued",
      observing: { "queued=\(await admission.queuedCount)" },
      until: { await admission.queuedCount == 1 })
    let cancelled = Task { try await admission.acquire(priority: .visible) }
    await waitUntilAdmission(
      "second FIFO waiter is queued",
      observing: { "queued=\(await admission.queuedCount)" },
      until: { await admission.queuedCount == 2 })
    let last = Task { try await admission.acquire(priority: .visible) }
    await waitUntilAdmission(
      "third FIFO waiter is queued",
      observing: { "queued=\(await admission.queuedCount)" },
      until: { await admission.queuedCount == 3 })

    cancelled.cancel()
    await #expect(throws: CancellationError.self) {
      try await cancelled.value
    }
    await admission.release(priority: .visible)
    try await first.value
    #expect(await admission.queuedCount == 1)
    await admission.release(priority: .visible)
    try await last.value
    await admission.release(priority: .visible)

    #expect(await admission.inFlightCount == 0)
    #expect(await admission.queuedCount == 0)
  }

  @Test("normal releases continue to wake queued waiters")
  func releaseWakesQueuedWaiter() async throws {
    let admission = CoverDecodeAdmission(maximumConcurrent: 1)
    try await admission.acquire(priority: .visible)
    let waiter = Task { try await admission.acquire(priority: .visible) }
    await waitUntilAdmission(
      "prefetch waiter is queued",
      observing: { "queued=\(await admission.queuedCount)" },
      until: { await admission.queuedCount == 1 })

    await admission.release(priority: .visible)
    try await waiter.value

    #expect(await admission.inFlightCount == 1)
    await admission.release(priority: .visible)
    #expect(await admission.inFlightCount == 0)
  }

  @Test("prefetch work leaves one slot available for visible work")
  func prefetchRespectsReservedSlot() async throws {
    let admission = CoverDecodeAdmission(maximumConcurrent: 3)
    try await admission.acquire(priority: .scrollPrefetch)
    try await admission.acquire(priority: .scrollPrefetch)

    let parkedPrefetch = Task { try await admission.acquire(priority: .scrollPrefetch) }
    await waitUntilAdmission(
      "parked prefetch waiter is queued",
      observing: { "queued=\(await admission.queuedCount)" },
      until: { await admission.queuedCount == 1 })

    let visible = Task { try await admission.acquire(priority: .visible) }
    try await visible.value
    #expect(await admission.inFlightCount == 3)
    #expect(await admission.queuedCount == 1)

    await admission.release(priority: .visible)
    #expect(await admission.queuedCount == 1)
    await admission.release(priority: .scrollPrefetch)
    try await parkedPrefetch.value
    await admission.release(priority: .scrollPrefetch)
    await admission.release(priority: .scrollPrefetch)

    #expect(await admission.inFlightCount == 0)
    #expect(await admission.queuedCount == 0)
  }

  @Test("a single-slot admission allows idle prefetch work")
  func singleSlotAllowsIdlePrefetch() async throws {
    let admission = CoverDecodeAdmission(maximumConcurrent: 1)
    try await admission.acquire(priority: .scrollPrefetch)
    #expect(await admission.inFlightCount == 1)
    await admission.release(priority: .scrollPrefetch)
    #expect(await admission.inFlightCount == 0)
  }

  @Test("cancelling one mixed-priority waiter removes exactly that waiter")
  func cancellationRemovesMixedPriorityWaiter() async throws {
    let admission = CoverDecodeAdmission(maximumConcurrent: 1)
    try await admission.acquire(priority: .visible)
    let first = Task { try await admission.acquire(priority: .scrollPrefetch) }
    await waitUntilAdmission(
      "mixed FIFO waiter is queued",
      observing: { "queued=\(await admission.queuedCount)" },
      until: { await admission.queuedCount == 1 })
    let cancelled = Task { try await admission.acquire(priority: .playbackCritical) }
    await waitUntilAdmission(
      "mixed cancelled waiter is queued",
      observing: { "queued=\(await admission.queuedCount)" },
      until: { await admission.queuedCount == 2 })
    let last = Task { try await admission.acquire(priority: .scrollPrefetch) }
    await waitUntilAdmission(
      "mixed final waiter is queued",
      observing: { "queued=\(await admission.queuedCount)" },
      until: { await admission.queuedCount == 3 })

    cancelled.cancel()
    await #expect(throws: CancellationError.self) {
      try await cancelled.value
    }
    #expect(await admission.queuedCount == 2)

    await admission.release(priority: .visible)
    try await first.value
    await admission.release(priority: .scrollPrefetch)
    try await last.value
    await admission.release(priority: .scrollPrefetch)

    #expect(await admission.inFlightCount == 0)
    #expect(await admission.queuedCount == 0)
  }
}

private func waitUntilAdmission(
  _ label: String,
  observing state: @escaping @Sendable () async -> String,
  until condition: @escaping @Sendable () async -> Bool
) async {
  _ = await awaitCondition(label, observing: state, until: condition)
}
