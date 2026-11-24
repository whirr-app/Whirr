import Persistence

/// `ListeningQueueStoring`'s fake. Every call is recorded in order; the stubs decide what the
/// answering calls return, and a failure can be armed for the next call or for every call.
///
/// Rows are seeded with `stubRows(_:)` and consumed as the real store would for the two calls that
/// read them: `peekNextLive()` returns the first row that is not a tombstone, and `remove`,
/// `acknowledgeStarted` drop the rows they name. `append`, `insertNext` and `move` only record, so
/// a test that needs a queue that really reorders asserts on the calls instead.
public final class FakeListeningQueueStoring: ListeningQueueStoring, @unchecked Sendable {
  /// One call, in the order the fake received it. `chapter` and `rowID` default to `nil`, so a
  /// whole-title call reads `.append(identity)`.
  public enum Call: Equatable, Sendable {
    case append(ListeningIdentity, chapter: ListeningQueueChapter? = nil)
    case insertNext(ListeningIdentity, chapter: ListeningQueueChapter? = nil)
    case insertNextBatch([ListeningIdentity])
    case remove(ListeningIdentity)
    case removeRow(Int64)
    case move(Int64, Int)
    case clear
    case restore
    case peekNextLive
    case acknowledgeStarted(ListeningIdentity, rowID: Int64? = nil)
    case swapStarted(ListeningIdentity, rowID: Int64? = nil, returning: ListeningIdentity)
  }

  /// The error a failure throws when the test names none.
  public struct Failure: Error, Equatable, Sendable {
    public init() {}
  }

  private struct PendingFailure {
    var error: any Error
    /// Calls left to fail; `nil` fails every call until the test clears it.
    var remaining: Int?
    /// Throwing calls that still succeed before the failure takes effect.
    var skip = 0
  }

  private struct State {
    var rows: [ListeningQueueItem]
    var appendOutcome: ListeningQueueAppendOutcome
    var scriptedOutcomes: [ListeningQueueAppendOutcome] = []
    var batchSkipped: [ListeningIdentity]
    var failure: PendingFailure?
  }

  /// Every call, in order, including one that throws.
  public let recorder = CallRecorder<Call>(label: "FakeListeningQueueStoring")
  public var calls: [Call] { recorder.calls }

  private let state: Locked<State>

  /// - Parameters:
  ///   - appendOutcome: what `append` reports once the scripted outcomes run out.
  ///   - batchSkipped: what `insertNext(identities:)` returns as skipped.
  ///   - rows: the queue `peekNextLive()` reads.
  public init(
    appendOutcome: ListeningQueueAppendOutcome = .appended,
    batchSkipped: [ListeningIdentity] = [],
    rows: [ListeningQueueItem] = []
  ) {
    state = Locked(State(rows: rows, appendOutcome: appendOutcome, batchSkipped: batchSkipped))
  }

  // MARK: - Stubs and observations

  /// What every following `append` reports, after any scripted outcomes.
  public func stubAppendOutcome(_ outcome: ListeningQueueAppendOutcome) {
    state.withValue { $0.appendOutcome = outcome }
  }

  /// Answers the next appends with `outcomes` in order, then falls back to `stubAppendOutcome`.
  public func stubAppendOutcomes(_ outcomes: [ListeningQueueAppendOutcome]) {
    state.withValue { $0.scriptedOutcomes = outcomes }
  }

  /// What every following `insertNext(identities:)` returns as skipped.
  public func stubBatchSkipped(_ skipped: [ListeningIdentity]) {
    state.withValue { $0.batchSkipped = skipped }
  }

  /// Replaces the rows `peekNextLive()` reads and the removals consume.
  public func stubRows(_ rows: [ListeningQueueItem]) {
    state.withValue { $0.rows = rows }
  }

  /// Fails the next throwing call with `error`, then behaves normally again.
  public func failNext(_ error: any Error = Failure()) {
    state.withValue { $0.failure = PendingFailure(error: error, remaining: 1) }
  }

  /// Fails every following throwing call with `error`; `nil` stops failing.
  public func stubFailure(_ error: (any Error)?) {
    state.withValue { $0.failure = error.map { PendingFailure(error: $0, remaining: nil) } }
  }

  /// Lets the next `count` calls succeed, then fails every following throwing call with `error`
  /// until the test clears it with `stubFailure(nil)`.
  public func stubFailure(_ error: any Error, afterCalls count: Int) {
    state.withValue {
      $0.failure = PendingFailure(error: error, remaining: nil, skip: count)
    }
  }

  /// The rows still queued.
  public var rows: [ListeningQueueItem] { state.value.rows }
  /// The identities of the rows still queued, in order.
  public var identities: [ListeningIdentity] { state.value.rows.map(\.identity) }
  /// Identities passed to `remove(identity:)`, in order.
  public var removed: [ListeningIdentity] {
    var identities: [ListeningIdentity] = []
    for case .remove(let identity) in calls { identities.append(identity) }
    return identities
  }
  /// The identities of each `insertNext(identities:)` call, in order.
  public var batches: [[ListeningIdentity]] {
    var batches: [[ListeningIdentity]] = []
    for case .insertNextBatch(let identities) in calls { batches.append(identities) }
    return batches
  }
  /// How many times `peekNextLive()` ran.
  public var peekCount: Int { calls.filter { $0 == .peekNextLive }.count }

  // MARK: - ListeningQueueStoring

  @discardableResult
  public func append(
    identity: ListeningIdentity, chapter: ListeningQueueChapter?
  ) async throws -> ListeningQueueAppendOutcome {
    try begin(.append(identity, chapter: chapter))
    return state.withValue { state in
      state.scriptedOutcomes.isEmpty ? state.appendOutcome : state.scriptedOutcomes.removeFirst()
    }
  }

  public func insertNext(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws {
    try begin(.insertNext(identity, chapter: chapter))
  }

  @discardableResult
  public func insertNext(identities: [ListeningIdentity]) async throws -> [ListeningIdentity] {
    try begin(.insertNextBatch(identities))
    return state.value.batchSkipped
  }

  public func remove(identity: ListeningIdentity) async throws {
    try begin(.remove(identity))
    state.withValue { state in state.rows.removeAll { $0.identity == identity } }
  }

  public func remove(rowID: Int64) async throws {
    try begin(.removeRow(rowID))
    state.withValue { state in state.rows.removeAll { $0.id == rowID } }
  }

  public func move(rowID: Int64, to position: Int) async throws {
    try begin(.move(rowID, position))
  }

  /// Returns the real store's empty restore token (the token cannot be built outside Persistence).
  public func clear() async throws -> ListeningQueueRestoreToken {
    try begin(.clear)
    return try await NoOpListeningQueueStore().clear()
  }

  public func restore(token: ListeningQueueRestoreToken) async throws {
    try begin(.restore)
  }

  public func peekNextLive() async -> ListeningQueueItem? {
    recorder.record(.peekNextLive)
    return state.value.rows.first { $0.isTombstone == false }
  }

  /// Drops the title's whole-book or episode row and the chapter row `rowID` names; the book's
  /// other chapter rows stay, as in the real store.
  public func acknowledgeStarted(identity: ListeningIdentity, rowID: Int64?) async throws {
    try begin(.acknowledgeStarted(identity, rowID: rowID))
    state.withValue { state in
      state.rows.removeAll { $0.identity == identity && ($0.chapter == nil || $0.id == rowID) }
    }
  }

  /// Drops the started rows as `acknowledgeStarted` does and records the displaced title, which,
  /// like `insertNext`, it does not add to `rows`.
  public func acknowledgeStarted(
    identity: ListeningIdentity, rowID: Int64?, returning displaced: ListeningIdentity
  ) async throws -> Bool {
    try begin(.swapStarted(identity, rowID: rowID, returning: displaced))
    state.withValue { state in
      state.rows.removeAll { $0.identity == identity && ($0.chapter == nil || $0.id == rowID) }
    }
    return true
  }

  /// Records the call, then throws the armed failure if there is one.
  private func begin(_ call: Call) throws {
    recorder.record(call)
    let failure = state.withValue { state -> (any Error)? in
      guard var pending = state.failure else { return nil }
      if pending.skip > 0 {
        pending.skip -= 1
        state.failure = pending
        return nil
      }
      if let remaining = pending.remaining {
        pending.remaining = remaining - 1
        state.failure = remaining <= 1 ? nil : pending
      }
      return pending.error
    }
    if let failure { throw failure }
  }
}
