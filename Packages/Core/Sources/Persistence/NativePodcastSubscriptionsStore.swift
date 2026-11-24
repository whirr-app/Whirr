/// Device-local reading boundary for native podcast subscriptions.
public protocol NativePodcastSubscriptionsReading: Sendable {
  func isEnabled() async -> Bool
  func observeEnabled() -> AsyncStream<Bool>
}

public protocol NativePodcastSubscriptionsWriting: Sendable {
  func setEnabled(_ enabled: Bool) async
}

/// Unwired compositions remain default-on, matching the production preference.
public struct NoOpNativePodcastSubscriptionsReading: NativePodcastSubscriptionsReading, Sendable {
  public init() {}

  public func isEnabled() async -> Bool { true }

  public func observeEnabled() -> AsyncStream<Bool> {
    AsyncStream { continuation in
      continuation.yield(true)
      continuation.finish()
    }
  }
}

public struct NoOpNativePodcastSubscriptionsWriting: NativePodcastSubscriptionsWriting, Sendable {
  public init() {}
  public func setEnabled(_ enabled: Bool) async {}
}
