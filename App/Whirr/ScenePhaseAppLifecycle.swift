import Foundation
import SwiftUI
import SyncEngine

/// The concrete `ScenePhase` to `AppLifecycle` adapter. Thin: whether a phase change is a real
/// foreground/background transition is `ScenePhaseLifecycleMapper`'s decision table (SyncEngine,
/// unit-tested on the macOS host); this owns the `AsyncStream` continuation and translates to the
/// mapper's `AppScenePhase`. Lock-protected, as `TestSupport.FakeAppLifecycle` is, so a plain
/// `@unchecked Sendable` rather than actor-isolated (SyncEngine reads `transitions` synchronously
/// at construction). `beginBackgroundTask`/`endBackgroundTask` delegate to a `BackgroundTaskPolicy`
/// over the injected `BackgroundTaskProviding`, not `AppLifecycle`'s no-op default.
final class ScenePhaseAppLifecycle: AppLifecycle, @unchecked Sendable {
  private let lock = NSLock()
  private var foreground = false
  private var lastPhase: AppScenePhase?
  private let backgroundTaskPolicy: BackgroundTaskPolicy

  private var subscribers: [UUID: AsyncStream<AppLifecycleTransition>.Continuation] = [:]

  var isForeground: Bool {
    lock.lock()
    defer { lock.unlock() }
    return foreground
  }

  var transitions: AsyncStream<AppLifecycleTransition> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      lock.lock()
      subscribers[id] = continuation
      lock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeSubscriber(id)
      }
    }
  }

  init(backgroundTaskProviding: BackgroundTaskProviding) {
    backgroundTaskPolicy = BackgroundTaskPolicy(provider: backgroundTaskProviding)
  }

  func beginBackgroundTask(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken {
    backgroundTaskPolicy.beginBackgroundTask(expirationHandler: expirationHandler)
  }

  func endBackgroundTask(_ token: BackgroundTaskToken) {
    backgroundTaskPolicy.endBackgroundTask(token)
  }

  /// The one SwiftUI-facing shim, called from the root view's `.onChange(of: scenePhase)`. Every
  /// phase change is safe to feed through: `ScenePhaseLifecycleMapper` decides whether it carries
  /// a real transition (`.inactive` never does).
  func handle(scenePhase: ScenePhase) {
    let newPhase: AppScenePhase
    switch scenePhase {
    case .active: newPhase = .active
    case .inactive: newPhase = .inactive
    case .background: newPhase = .background
    @unknown default: newPhase = .inactive
    }

    lock.lock()
    let oldPhase = lastPhase
    lastPhase = newPhase
    lock.unlock()

    guard let transition = ScenePhaseLifecycleMapper.transition(from: oldPhase, to: newPhase) else {
      return
    }

    lock.lock()
    foreground = transition == .foreground
    for continuation in subscribers.values {
      continuation.yield(transition)
    }
    lock.unlock()
  }

  private func removeSubscriber(_ id: UUID) {
    lock.lock()
    subscribers.removeValue(forKey: id)
    lock.unlock()
  }
}
