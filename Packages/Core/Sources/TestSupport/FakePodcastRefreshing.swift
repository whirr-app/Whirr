import Foundation
import SyncEngine

/// `PodcastRefreshing`'s fake. Both entry points record a call and answer the next scripted
/// result, else the result stubbed for that show, else the default (`.success(.complete)`).
/// `refreshIfStale` is a call of its own, not a `refresh`, as the routing and gating decorators
/// forward them separately.
///
/// `gate` holds either entry point in flight: after `gate.hold()` a call parks until
/// `gate.release(_:)` hands it the result to return, or `gate.releaseNext(_:)` releases the oldest.
/// A parked call whose task is cancelled returns the stubbed result at once, as `TestGate` does.
public final class FakePodcastRefreshing: PodcastRefreshing, @unchecked Sendable {
  public typealias RefreshResult = Result<PodcastRefreshOutcome, any Error>

  public enum Call: Sendable, Equatable {
    case refresh(itemID: String)
    case refreshIfStale(itemID: String, maximumAge: TimeInterval)
  }

  /// Every call in order.
  public let recorder = CallRecorder<Call>(label: "FakePodcastRefreshing")
  public var calls: [Call] { recorder.calls }

  /// Parks calls between recording and answering.
  public let gate = TestGate<RefreshResult>(label: "FakePodcastRefreshing")

  private struct Script {
    var defaultResult: RefreshResult
    var resultsByItemID: [String: RefreshResult] = [:]
    var steps: [RefreshResult] = []
  }

  private let script: Locked<Script>
  private let cancelledCalls = Locked(0)
  private let completedCalls = Locked(0)

  public init(result: RefreshResult = .success(.complete)) {
    script = Locked(Script(defaultResult: result))
  }

  /// How many calls returned with their task cancelled, whether they were parked on `gate` or not.
  /// A parked call that is cancelled returns the stubbed result rather than throwing, so this is
  /// how a test sees that a cancellation reached it.
  public var cancelledCallCount: Int { cancelledCalls.value }

  /// How many calls have returned an answer, parked on `gate` or not.
  public var completedCallCount: Int { completedCalls.value }

  /// The item id of every `refresh` call, in order.
  public var refreshedItemIDs: [String] {
    calls.compactMap { call -> String? in
      if case .refresh(let itemID) = call { return itemID }
      return nil
    }
  }

  /// The item id of every `refreshIfStale` call, in order.
  public var staleRefreshedItemIDs: [String] {
    calls.compactMap { call -> String? in
      if case .refreshIfStale(let itemID, _) = call { return itemID }
      return nil
    }
  }

  /// The result of every call for `itemID`, or of every call without its own when omitted.
  public func stub(_ result: RefreshResult, itemID: String? = nil) {
    script.withValue { script in
      if let itemID {
        script.resultsByItemID[itemID] = result
      } else {
        script.defaultResult = result
      }
    }
  }

  /// The results of the next calls, one each in order, ahead of any stub.
  public func stubSequence(_ results: [RefreshResult]) {
    script.withValue { $0.steps = results }
  }

  public func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    recorder.record(.refresh(itemID: itemID))
    return try await answer(itemID: itemID)
  }

  public func refreshIfStale(itemID: String, maximumAge: TimeInterval) async throws
    -> PodcastRefreshOutcome
  {
    recorder.record(.refreshIfStale(itemID: itemID, maximumAge: maximumAge))
    return try await answer(itemID: itemID)
  }

  private func answer(itemID: String) async throws -> PodcastRefreshOutcome {
    let released = await gate.pass(otherwise: { [script] in
      script.withValue { script in
        script.steps.isEmpty
          ? script.resultsByItemID[itemID] ?? script.defaultResult
          : script.steps.removeFirst()
      }
    })
    if Task.isCancelled { cancelledCalls.withValue { $0 += 1 } }
    completedCalls.withValue { $0 += 1 }
    return try released.get()
  }
}
