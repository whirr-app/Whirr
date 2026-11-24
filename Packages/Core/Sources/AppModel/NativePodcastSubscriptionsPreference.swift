import Foundation
import Persistence

/// The small defaults surface the native-subscriptions preference needs. The optional read is
/// intentional: `UserDefaults.bool(forKey:)` turns an absent key into `false`, but this preference
/// is default-on.
public protocol NativePodcastSubscriptionsDefaults: AnyObject {
  func boolValue(forKey key: String) -> Bool?
  func setBoolValue(_ value: Bool, forKey key: String)
}

extension UserDefaults: NativePodcastSubscriptionsDefaults {
  public func boolValue(forKey key: String) -> Bool? {
    object(forKey: key) as? Bool
  }

  public func setBoolValue(_ value: Bool, forKey key: String) {
    set(value, forKey: key)
  }
}

/// Durable device-local preference for whether native podcast subscriptions are enabled.
///
/// Composition must share one instance: the stored value is cached at initialization and every
/// Settings write is broadcast from that same object to the shell and refresh gate.
public final class NativePodcastSubscriptionsPreference: NativePodcastSubscriptionsReading,
  NativePodcastSubscriptionsWriting, @unchecked Sendable
{
  public static let storageKey = "podcasts.nativeSubscriptions.enabled"

  private let lock = NSLock()
  private let defaults: any NativePodcastSubscriptionsDefaults
  private var enabled: Bool
  private var subscribers: [UUID: AsyncStream<Bool>.Continuation] = [:]

  public init(defaults: any NativePodcastSubscriptionsDefaults) {
    self.defaults = defaults
    enabled = defaults.boolValue(forKey: Self.storageKey) ?? true
  }

  public func isEnabled() async -> Bool {
    currentValue()
  }

  /// The value in force now, for a synchronous factory that must not cache it.
  public var isEnabledNow: Bool { currentValue() }

  public func observeEnabled() -> AsyncStream<Bool> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }

      lock.lock()
      subscribers[id] = continuation
      continuation.yield(enabled)
      lock.unlock()

      continuation.onTermination = { [weak self] _ in
        self?.removeSubscriber(id: id)
      }
    }
  }

  public func setEnabled(_ enabled: Bool) async {
    setEnabledSynchronously(enabled)
  }

  private func currentValue() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return enabled
  }

  private func setEnabledSynchronously(_ enabled: Bool) {
    lock.lock()
    guard self.enabled != enabled else {
      lock.unlock()
      return
    }

    self.enabled = enabled
    defaults.setBoolValue(enabled, forKey: Self.storageKey)
    for continuation in subscribers.values {
      continuation.yield(enabled)
    }
    lock.unlock()
  }

  private func removeSubscriber(id: UUID) {
    lock.lock()
    subscribers.removeValue(forKey: id)
    lock.unlock()
  }
}
