import Foundation

/// Narrow abstraction over `UIApplication.beginBackgroundTask(expirationHandler:)`/
/// `endBackgroundTask(_:)` (ARCHITECTURE.md §3/D15: no Core target may import `UIKit`). `nil`
/// from `beginTask` mirrors `UIBackgroundTaskIdentifier.invalid`: no background execution time
/// was available. The `UIApplication`-backed conformance lives in App
/// (`RealBackgroundTaskProviding`); tests inject a fake.
public protocol BackgroundTaskProviding: Sendable {
  func beginTask(expirationHandler: @escaping @Sendable () -> Void) -> Int?
  /// Ends the task identified by `rawValue`. Mirrors `UIApplication.endBackgroundTask(_:)`:
  /// exactly one matching call per successful `beginTask`. `BackgroundTaskPolicy` guarantees that,
  /// so a conformance never has to guard against a duplicate.
  func endTask(_ rawValue: Int)
}

/// `AppLifecycle`'s bounded-background-task pair over an injected `BackgroundTaskProviding`, so
/// the begin/end-exactly-once bookkeeping is unit-testable on the macOS host.
/// `ScenePhaseAppLifecycle` delegates its begin/end overrides to one, built with the real
/// `UIApplication`-wrapping conformance.
public final class BackgroundTaskPolicy: @unchecked Sendable {
  /// The `BackgroundTaskToken.rawValue` handed back when `provider.beginTask` reports no
  /// background time was available. A real `UIApplication` identifier is never negative, so
  /// `endBackgroundTask` can recognise it and skip `provider.endTask`.
  private static let unavailableRawValue = -1

  private let provider: BackgroundTaskProviding
  private let lock = NSLock()
  private var endedRawValues: Set<Int> = []

  public init(provider: BackgroundTaskProviding) {
    self.provider = provider
  }

  public func beginBackgroundTask(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken {
    guard let rawValue = provider.beginTask(expirationHandler: expirationHandler) else {
      return BackgroundTaskToken(rawValue: Self.unavailableRawValue)
    }
    return BackgroundTaskToken(rawValue: rawValue)
  }

  /// Idempotent per token: only the first call for a `rawValue` reaches `provider.endTask`, so a
  /// caller that always calls this once (like `AppLifecycle.runBoundedBackgroundTask`), whether or
  /// not expiration already fired, never double-ends the same background task. A token from an
  /// unavailable `beginTask` is a no-op.
  public func endBackgroundTask(_ token: BackgroundTaskToken) {
    guard token.rawValue != Self.unavailableRawValue else { return }
    lock.lock()
    let alreadyEnded = endedRawValues.contains(token.rawValue)
    endedRawValues.insert(token.rawValue)
    lock.unlock()
    guard !alreadyEnded else { return }
    provider.endTask(token.rawValue)
  }
}
