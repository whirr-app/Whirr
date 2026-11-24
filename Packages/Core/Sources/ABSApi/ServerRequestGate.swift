import Foundation

/// FIFO admission for foreground requests. The permit set is the source of truth so
/// releasing a permit twice cannot inflate the available capacity. This is public so
/// `PodcastFeeds` can run its own independent pool (API-CONVENTIONS.md rule 27).
public actor ServerRequestGate {
  public struct Permit: Sendable {
    private let gate: ServerRequestGate
    private let id: UUID

    fileprivate init(gate: ServerRequestGate, id: UUID) {
      self.gate = gate
      self.id = id
    }

    public func release() async {
      await gate.release(id: id)
    }
  }

  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Permit, Error>
  }

  private let maximumConcurrent: Int
  private var activeIDs: Set<UUID> = []
  private var waiters: [Waiter] = []

  public init(maximumConcurrent: Int = 4) {
    precondition(maximumConcurrent > 0)
    self.maximumConcurrent = maximumConcurrent
  }

  public var inFlightCount: Int { activeIDs.count }
  public var queuedCount: Int { waiters.count }

  public func acquire() async throws -> Permit {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard Task.isCancelled == false else {
          continuation.resume(throwing: CancellationError())
          return
        }

        if activeIDs.count < maximumConcurrent {
          activeIDs.insert(id)
          continuation.resume(returning: Permit(gate: self, id: id))
        } else {
          waiters.append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }
  }

  public func withPermit<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    let permit = try await acquire()
    do {
      let value = try await operation()
      await permit.release()
      return value
    } catch {
      await permit.release()
      throw error
    }
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  fileprivate func release(id: UUID) {
    guard activeIDs.remove(id) != nil else { return }
    admitQueuedWaiters()
  }

  private func admitQueuedWaiters() {
    while activeIDs.count < maximumConcurrent, waiters.isEmpty == false {
      let waiter = waiters.removeFirst()
      activeIDs.insert(waiter.id)
      waiter.continuation.resume(returning: Permit(gate: self, id: waiter.id))
    }
  }
}
