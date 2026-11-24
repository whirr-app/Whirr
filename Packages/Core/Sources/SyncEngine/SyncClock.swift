import Foundation

/// Injected wall-clock seam. Backoff is exponential, never a fixed-interval loop, and with no
/// background polling "schedule a backoff refresh" only means gating the next foreground or
/// explicit trigger until enough time has passed. Injecting the clock lets that gate be tested
/// without a real sleep.
public protocol SyncClock: Sendable {
  func now() -> Date
}

/// Production conformance.
public struct SystemSyncClock: SyncClock, Sendable {
  public init() {}
  public func now() -> Date { Date() }
}
