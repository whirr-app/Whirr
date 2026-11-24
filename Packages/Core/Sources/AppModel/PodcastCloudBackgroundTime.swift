import Foundation
import SyncEngine

/// Keeps the process alive while a send finishes after the app has left the foreground. If the
/// allowance expires, `work` is cancelled and the outbox keeps whatever did not go.
public protocol PodcastCloudBackgroundTimeGranting: Sendable {
  func run(_ work: @escaping @Sendable () async -> Void) async
}

/// Runs the work with no allowance: for hosts without a background lifecycle, and tests.
public struct PodcastCloudNoBackgroundTime: PodcastCloudBackgroundTimeGranting {
  public init() {}

  public func run(_ work: @escaping @Sendable () async -> Void) async {
    await work()
  }
}

/// The allowance the app's lifecycle grants, which in the App is `beginBackgroundTask`.
///
/// Unlike `AppLifecycle.runBoundedBackgroundTask`, expiry ends the allowance in the handler itself
/// rather than once the cancelled work returns: iOS terminates an app still holding an expired
/// allowance, and a CloudKit send is not guaranteed to stop promptly when cancelled.
public struct PodcastCloudLifecycleBackgroundTime: PodcastCloudBackgroundTimeGranting {
  private let lifecycle: any AppLifecycle

  public init(lifecycle: any AppLifecycle) {
    self.lifecycle = lifecycle
  }

  public func run(_ work: @escaping @Sendable () async -> Void) async {
    let allowance = Allowance(lifecycle: lifecycle)
    let task = Task { await work() }
    allowance.begin {
      task.cancel()
      allowance.end()
    }
    await task.value
    allowance.end()
  }

  /// Ends its token exactly once, whichever of expiry and completion comes first. Expiry can fire
  /// before `begin` has returned the token; the end then happens as soon as it has.
  private final class Allowance: @unchecked Sendable {
    private let lifecycle: any AppLifecycle
    private let lock = NSLock()
    private var token: BackgroundTaskToken?
    private var ended = false

    init(lifecycle: any AppLifecycle) {
      self.lifecycle = lifecycle
    }

    func begin(onExpiry: @escaping @Sendable () -> Void) {
      let token = lifecycle.beginBackgroundTask(expirationHandler: onExpiry)
      let endNow = lock.withLock { () -> Bool in
        self.token = token
        return ended
      }
      if endNow { lifecycle.endBackgroundTask(token) }
    }

    func end() {
      let token = lock.withLock { () -> BackgroundTaskToken? in
        guard ended == false else { return nil }
        ended = true
        return self.token
      }
      if let token { lifecycle.endBackgroundTask(token) }
    }
  }
}
