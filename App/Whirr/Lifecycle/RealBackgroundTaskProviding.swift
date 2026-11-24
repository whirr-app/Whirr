import SyncEngine
import UIKit

/// Real `BackgroundTaskProviding`, wrapping `UIApplication.beginBackgroundTask(expirationHandler:)`/
/// `endBackgroundTask(_:)`. Both are documented callable from any thread (`NS_SWIFT_NONISOLATED`
/// in `UIApplication.h`) though `UIApplication` is `@MainActor`-isolated. `application` is
/// captured once on the `@MainActor` composition root (`AppEnvironment`), so no per-call actor
/// hop is needed.
final class RealBackgroundTaskProviding: BackgroundTaskProviding, @unchecked Sendable {
  private let application: UIApplication

  // No default for `application`: a default-parameter expression is evaluated at the call
  // site's isolation, not this initializer's, so `.shared` (main-actor-isolated) cannot be a
  // default even though `init` is `@MainActor`. Callers (`AppEnvironment`) pass `.shared`.
  @MainActor
  init(application: UIApplication) {
    self.application = application
  }

  func beginTask(expirationHandler: @escaping @Sendable () -> Void) -> Int? {
    let identifier = application.beginBackgroundTask(expirationHandler: expirationHandler)
    guard identifier != .invalid else { return nil }
    return identifier.rawValue
  }

  func endTask(_ rawValue: Int) {
    application.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: rawValue))
  }
}
