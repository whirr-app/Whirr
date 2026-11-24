import Foundation
import SyncEngine
import Testing

/// `ResolutionCenterAccess`'s fake: every call is recorded (in order) and stubbable, in the same
/// shape as `FakeDownloadIntents`. Seeded open items are removed from
/// `openItems` once their matching action is called, simulating `refresh()` seeing the real
/// `ResolutionCenter`'s post-action enumeration without needing a real Persistence store.
public final class FakeResolutionCenterAccess: ResolutionCenterAccess, @unchecked Sendable {
  public enum RecordedCall: Sendable, Equatable {
    case fetchOpenItems
    case openCount
    case keepLocalProgress(conflictId: Int64)
    case takeServerProgress(conflictId: Int64)
    case keepLocalSkew(operationId: Int64, sessionId: Int64)
    case takeServerSkew(operationId: Int64, sessionId: Int64)
    case discardDeadLetter(operationId: Int64)
    case refreshMetadataDeadLetter(operationId: Int64)
    case requestReAuthentication
  }

  private let callsBox = Locked<[RecordedCall]>([])
  public var calls: [RecordedCall] { callsBox.value }

  private let itemsBox = Locked<[ResolutionOpenItem]>([])
  public var openItems: [ResolutionOpenItem] {
    get { itemsBox.value }
    set { itemsBox.value = newValue }
  }

  private let errorBox = Locked<Error?>(nil)
  public let fetchItemsGate = TestGate<Void>(label: "FakeResolutionCenterAccess.fetchOpenItems")

  public func stubNextCall(throwing error: Error?) {
    errorBox.value = error
  }

  private let bulkResultBox = Locked<BulkProgressConflictResolutionResult?>(nil)
  /// When set, `takeServerForAllProgressConflicts()` returns this instead of applying take-server
  /// to each seeded progress conflict.
  public var stubbedBulkResult: BulkProgressConflictResolutionResult? {
    get { bulkResultBox.value }
    set { bulkResultBox.value = newValue }
  }

  /// Applies `takeServerProgress` to each seeded progress conflict, as `ResolutionCenter` does, so
  /// the calls record one per conflict.
  public func takeServerForAllProgressConflicts() async throws -> BulkProgressConflictResolutionResult {
    if let stubbedBulkResult { return stubbedBulkResult }
    let conflictIds = openItems.compactMap { item -> Int64? in
      guard case .progressConflict(let conflictId) = item.kind else { return nil }
      return conflictId
    }
    var resolvedCount = 0
    var failedCount = 0
    for conflictId in conflictIds {
      do {
        try await takeServerProgress(conflictId: conflictId)
        resolvedCount += 1
      } catch {
        failedCount += 1
      }
    }
    return BulkProgressConflictResolutionResult(resolvedCount: resolvedCount, failedCount: failedCount)
  }

  public init() {}

  /// Test-only: makes `fetchOpenItems()` park until `releaseFetchItems()` is called, so a caller
  /// can be cancelled after the fetch has started but before its result is published.
  public func holdFetchItems() {
    fetchItemsGate.hold()
  }

  /// Test-only: resumes every currently parked `fetchOpenItems()` call with the current items.
  public func releaseFetchItems() {
    fetchItemsGate.release()
  }

  public func fetchOpenItems() async throws -> [ResolutionOpenItem] {
    callsBox.withValue { $0.append(.fetchOpenItems) }
    if let error = errorBox.value { throw error }
    if fetchItemsGate.isHeld {
      await fetchItemsGate.pass()
      // A caller cancelled while parked sees the cancellation, as it would from the real fetch.
      try Task.checkCancellation()
    }
    return itemsBox.value
  }

  public func openCount() async throws -> Int {
    callsBox.withValue { $0.append(.openCount) }
    if let error = errorBox.value { throw error }
    return itemsBox.value.count
  }

  public func keepLocalProgress(conflictId: Int64) async throws {
    callsBox.withValue { $0.append(.keepLocalProgress(conflictId: conflictId)) }
    if let error = errorBox.value { throw error }
    removeItem {
      if case .progressConflict(let id) = $0 { return id == conflictId }
      return false
    }
  }

  public func takeServerProgress(conflictId: Int64) async throws {
    callsBox.withValue { $0.append(.takeServerProgress(conflictId: conflictId)) }
    if let error = errorBox.value { throw error }
    removeItem {
      if case .progressConflict(let id) = $0 { return id == conflictId }
      return false
    }
  }

  public func keepLocalSkew(operationId: Int64, sessionId: Int64, now: Date) async throws {
    callsBox.withValue { $0.append(.keepLocalSkew(operationId: operationId, sessionId: sessionId)) }
    if let error = errorBox.value { throw error }
    removeItem {
      if case .skewConfirmation(let opId, let sessId) = $0 { return opId == operationId && sessId == sessionId }
      return false
    }
  }

  public func takeServerSkew(operationId: Int64, sessionId: Int64) async throws {
    callsBox.withValue { $0.append(.takeServerSkew(operationId: operationId, sessionId: sessionId)) }
    if let error = errorBox.value { throw error }
    removeItem {
      if case .skewConfirmation(let opId, let sessId) = $0 { return opId == operationId && sessId == sessionId }
      return false
    }
  }

  public func discardDeadLetter(operationId: Int64) async throws {
    callsBox.withValue { $0.append(.discardDeadLetter(operationId: operationId)) }
    if let error = errorBox.value { throw error }
    removeItem {
      if case .deadLetter(let opId, _) = $0 { return opId == operationId }
      return false
    }
  }

  public func refreshMetadataDeadLetter(operationId: Int64) async throws {
    callsBox.withValue { $0.append(.refreshMetadataDeadLetter(operationId: operationId)) }
    if let error = errorBox.value { throw error }
    removeItem {
      if case .deadLetter(let opId, _) = $0 { return opId == operationId }
      return false
    }
  }

  public func requestReAuthentication() async {
    callsBox.withValue { $0.append(.requestReAuthentication) }
  }

  private func removeItem(matching predicate: @escaping (ResolutionOpenItem.Kind) -> Bool) {
    itemsBox.withValue { items in
      items.removeAll { predicate($0.kind) }
    }
  }
}
