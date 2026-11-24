import Persistence

/// `SavedShelfStoring`'s fake: records every `save` and `remove`, answers `save` with a stubbed
/// outcome, and can fail the next call or every call. It keeps no shelf of its own, so a second
/// `save` of the same identity reports whatever outcome is stubbed, not `.alreadySaved`.
public final class FakeSavedShelfStoring: SavedShelfStoring, @unchecked Sendable {
  /// One call, in the order the fake received it.
  public enum Call: Equatable, Sendable {
    case save(SavedShelfIdentity)
    case remove(SavedShelfIdentity)
  }

  /// The error a failure throws when the test names none.
  public struct Failure: Error, Equatable, Sendable {
    public init() {}
  }

  private struct PendingFailure {
    var error: any Error
    /// Calls left to fail; `nil` fails every call until the test clears it.
    var remaining: Int?
  }

  private struct State {
    var saveOutcome: SavedShelfSaveOutcome
    var scriptedOutcomes: [SavedShelfSaveOutcome] = []
    var failure: PendingFailure?
  }

  /// Every call, in order, including one that throws.
  public let recorder = CallRecorder<Call>(label: "FakeSavedShelfStoring")
  public var calls: [Call] { recorder.calls }

  private let state: Locked<State>

  /// - Parameter saveOutcome: what every `save` reports.
  public init(saveOutcome: SavedShelfSaveOutcome = .saved) {
    state = Locked(State(saveOutcome: saveOutcome))
  }

  /// What every following `save` reports, after any scripted outcomes.
  public func stubSaveOutcome(_ outcome: SavedShelfSaveOutcome) {
    state.withValue { $0.saveOutcome = outcome }
  }

  /// Answers the next saves with `outcomes` in order, then falls back to `stubSaveOutcome`. A
  /// save that throws does not use one up.
  public func stubSaveOutcomes(_ outcomes: [SavedShelfSaveOutcome]) {
    state.withValue { $0.scriptedOutcomes = outcomes }
  }

  /// Fails the next `save` or `remove` with `error`, then behaves normally again.
  public func failNext(_ error: any Error = Failure()) {
    state.withValue { $0.failure = PendingFailure(error: error, remaining: 1) }
  }

  /// Fails every following `save` and `remove` with `error`; `nil` stops failing.
  public func stubFailure(_ error: (any Error)?) {
    state.withValue { $0.failure = error.map { PendingFailure(error: $0, remaining: nil) } }
  }

  @discardableResult
  public func save(_ identity: SavedShelfIdentity) async throws -> SavedShelfSaveOutcome {
    try begin(.save(identity))
    return state.withValue { state in
      state.scriptedOutcomes.isEmpty ? state.saveOutcome : state.scriptedOutcomes.removeFirst()
    }
  }

  public func remove(_ identity: SavedShelfIdentity) async throws {
    try begin(.remove(identity))
  }

  /// Records the call, then throws the armed failure if there is one.
  private func begin(_ call: Call) throws {
    recorder.record(call)
    let failure = state.withValue { state -> (any Error)? in
      guard var pending = state.failure else { return nil }
      if let remaining = pending.remaining {
        pending.remaining = remaining - 1
        state.failure = remaining <= 1 ? nil : pending
      }
      return pending.error
    }
    if let failure { throw failure }
  }
}
