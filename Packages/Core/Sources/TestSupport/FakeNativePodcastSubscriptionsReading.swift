import Foundation
import Persistence

/// `NativePodcastSubscriptionsReading`'s fake: the device preference as a value a test can flip.
/// `observeEnabled()` is live, starts with the current value and then follows `stubEnabled` and
/// `setEnabled`, for every subscription.
///
/// `enabled: nil` is the preference before it has reported: `isEnabled()` answers `false` and
/// `observeEnabled()` stays silent until the first `stubEnabled`. `finishObservations()` ends
/// every stream, including later ones, without a value: a stream that finishes empty.
public final class FakeNativePodcastSubscriptionsReading: NativePodcastSubscriptionsReading,
  NativePodcastSubscriptionsWriting, @unchecked Sendable
{
  public enum Call: Sendable, Equatable {
    case isEnabled
    case observeEnabled
    case setEnabled(Bool)
  }

  /// Every call in order.
  public let recorder = CallRecorder<Call>(label: "FakeNativePodcastSubscriptionsReading")
  public var calls: [Call] { recorder.calls }

  /// How many `observeEnabled()` streams have been opened.
  public var observeEnabledCallCount: Int { calls.filter { $0 == .observeEnabled }.count }

  private struct Subscription {
    let continuation: AsyncStream<Bool>.Continuation
    var isTerminated = false
  }

  private struct State {
    var enabled: Bool?
    var subscriptions: [Subscription] = []
    var isFinished = false
  }

  private let state: Locked<State>

  public init(enabled: Bool? = true) {
    state = Locked(State(enabled: enabled))
  }

  /// How many opened streams have been cancelled or dropped by their consumer.
  public var terminatedObservationCount: Int {
    state.withValue { $0.subscriptions.filter(\.isTerminated).count }
  }

  /// Sets the preference and tells every live subscription.
  public func stubEnabled(_ enabled: Bool) {
    state.withValue { state in
      state.enabled = enabled
      for subscription in state.subscriptions where subscription.isTerminated == false {
        subscription.continuation.yield(enabled)
      }
    }
  }

  /// Ends every open stream and makes later ones finish at once, with no value.
  public func finishObservations() {
    let finished = state.withValue { state -> [AsyncStream<Bool>.Continuation] in
      state.isFinished = true
      return state.subscriptions.map(\.continuation)
    }
    for continuation in finished { continuation.finish() }
  }

  public func isEnabled() async -> Bool {
    recorder.record(.isEnabled)
    return state.value.enabled ?? false
  }

  public func observeEnabled() -> AsyncStream<Bool> {
    recorder.record(.observeEnabled)
    return AsyncStream { continuation in
      let index = state.withValue { state -> Int? in
        guard state.isFinished == false else { return nil }
        state.subscriptions.append(Subscription(continuation: continuation))
        if let enabled = state.enabled { continuation.yield(enabled) }
        return state.subscriptions.count - 1
      }
      guard let index else {
        continuation.finish()
        return
      }
      continuation.onTermination = { [weak self] _ in
        self?.state.withValue { $0.subscriptions[index].isTerminated = true }
      }
    }
  }

  public func setEnabled(_ enabled: Bool) async {
    recorder.record(.setEnabled(enabled))
    stubEnabled(enabled)
  }
}
