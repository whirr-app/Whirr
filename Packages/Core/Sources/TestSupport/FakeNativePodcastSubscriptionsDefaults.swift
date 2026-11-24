import AppModel
import Foundation

/// `NativePodcastSubscriptionsDefaults`' fake: an in-memory store of booleans, empty unless
/// `init(values:)` seeds it, so a key never written reads as absent, as in `UserDefaults`.
public final class FakeNativePodcastSubscriptionsDefaults: NativePodcastSubscriptionsDefaults,
  @unchecked Sendable
{
  public enum Call: Sendable, Equatable {
    case setBoolValue(key: String, value: Bool)
  }

  /// Every write in order.
  public let recorder = CallRecorder<Call>(label: "FakeNativePodcastSubscriptionsDefaults")
  public var calls: [Call] { recorder.calls }

  private let storage: Locked<[String: Bool]>

  public init(values: [String: Bool] = [:]) {
    storage = Locked(values)
  }

  /// What is stored now.
  public var values: [String: Bool] { storage.value }

  public func boolValue(forKey key: String) -> Bool? {
    storage.withValue { $0[key] }
  }

  public func setBoolValue(_ value: Bool, forKey key: String) {
    recorder.record(.setBoolValue(key: key, value: value))
    storage.withValue { $0[key] = value }
  }
}
