import CoreSupport
import Foundation
import SyncEngine
import UIKit
import UserNotifications

/// The one `BackgroundDownloadSessionAdapter` per process, shared like `PlaybackHardware`. Both
/// wake routes (`BackgroundDownloadAppDelegate.adapter` and the `.backgroundTask(.urlSession(...))`
/// modifier in `WhirrApp`) read it; both are wired as it is unclear which is reliable.
/// `BackgroundDownloadCompositionTests` proves neither builds its own.
nonisolated enum BackgroundDownloadHardware {
  static let sessionIdentifier = "com.remoteconcern.whirr.background-downloads"

  static let adapter: BackgroundDownloadSessionAdapter = BackgroundDownloadSessionAdapter(
    sessionIdentifier: sessionIdentifier,
    fileMover: FileManagerDownloadFileMover(),
    sessionFactory: RealBackgroundDownloadSessionFactory.make
  )

  /// Fans `adapter`'s one `events` stream out to every `DownloadCoordinator` `AppEnvironment`
  /// composes across the process's lifetime (see `BackgroundTransferEventMulticaster`). A
  /// `static let` initialiser runs once, thread-safely, on first access (from `adapter` or
  /// `transferring`), which starts this relay once however many `AppEnvironment`/
  /// `DownloadCoordinator` rebuilds follow.
  static let transferEventMulticaster: BackgroundTransferEventMulticaster = {
    let multicaster = BackgroundTransferEventMulticaster()
    let events = adapter.events
    Task {
      for await event in events {
        multicaster.yield(event)
      }
      multicaster.finish()
    }
    return multicaster
  }()

  /// The `BackgroundTransferring` conformance `AppEnvironment` composes `DownloadCoordinator`
  /// around (see `MulticastBackgroundTransferring`).
  static var transferring: BackgroundTransferring { MulticastBackgroundTransferring() }

  /// A background-session wake's whole budget for recording what the session delivered. Bounded,
  /// so the system's completion is always signalled.
  static let wakeDeliveryTimeout: Duration = .seconds(20)

  /// The SwiftUI `.backgroundTask(.urlSession(...))` route, whose closure returning is the
  /// completion signal. Composes the shared download services, so a coordinator records each
  /// finish and starts the next queued row, then waits for the session to finish handing over its
  /// events and for every finish to be acknowledged.
  @MainActor
  static func deliverWakeEvents(timeout: Duration = wakeDeliveryTimeout) async {
    let baseline = adapter.finishedSessionEvents
    // With nothing composed (no account, or the keychain unreadable before first unlock) no
    // finish can be acknowledged, so waiting would only spend the budget.
    guard PodcastBackgroundRefreshHardware.backgroundServices() != nil else { return }
    await waitForWakeDelivery(
      sessionEventsFinished: { adapter.finishedSessionEvents > baseline },
      undeliveredFinishes: { await adapter.undeliveredFinishes() },
      timeout: timeout)
  }

  /// Returns once the session has finished its events and nothing it finished is still
  /// undelivered, or at `timeout`. Polls: the wait is rare, short and bounded. `now` and `sleep`
  /// are seams for tests, which drive the deadline by hand instead of measuring it.
  static func waitForWakeDelivery(
    sessionEventsFinished: @Sendable () -> Bool,
    undeliveredFinishes: @Sendable () async -> Set<TransferIdentity>,
    timeout: Duration,
    pollInterval: Duration = .milliseconds(100),
    now: @Sendable () -> ContinuousClock.Instant = { .now },
    sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async {
    let deadline = now().advanced(by: timeout)
    while now() < deadline {
      if sessionEventsFinished(), await undeliveredFinishes().isEmpty { return }
      try? await sleep(pollInterval)
    }
  }
}

/// The `@UIApplicationDelegateAdaptor` bridge (a belt-and-braces route alongside the
/// `.backgroundTask(.urlSession(...))` scene modifier in `WhirrApp`): implements the one
/// AppDelegate hook background sessions need, `handleEventsForBackgroundURLSession`, and hands
/// its completion handler to the shared adapter.
final class BackgroundDownloadAppDelegate: NSObject, UIApplicationDelegate,
  UNUserNotificationCenterDelegate
{
  var adapter: BackgroundDownloadSessionAdapter { BackgroundDownloadHardware.adapter }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    _ = application
    _ = launchOptions
    UNUserNotificationCenter.current().delegate = self
    // Every launch, background or not, so a CloudKit push that launched the app has an engine.
    PodcastCloudSyncLaunch.startForLaunch()
    return true
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    _ = center
    guard
      let route = PodcastLocalNotificationCenter.route(
        from: response.notification.request.content.userInfo,
        actionIdentifier: response.actionIdentifier)
    else { return }
    PodcastNotificationRouteMailbox.shared.store(route)
  }

  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == adapter.sessionIdentifier else { return }
    // A coordinator must exist before the session hands over its events, or a finish completed
    // while the app was terminated is never recorded and the queue behind it never starts.
    let isComposed = PodcastBackgroundRefreshHardware.backgroundServices() != nil
    // `completionHandler` is a plain, non-`@Sendable` UIKit closure. `CompletionHandlerBox`
    // makes it capturable inside the adapter's `@Sendable` stored-handler API without weakening
    // that API's signature for every other caller.
    let box = CompletionHandlerBox(completionHandler)
    let adapter = adapter
    guard isComposed else {
      adapter.storeLaunchEventsCompletionHandler { box.call() }
      return
    }
    adapter.storeLaunchEventsCompletionHandler {
      // The session has finished its events; hold the system's handler until each finish is
      // recorded, since the process may be suspended as soon as it is called.
      Task { @MainActor in
        await BackgroundDownloadHardware.waitForWakeDelivery(
          sessionEventsFinished: { true },
          undeliveredFinishes: { await adapter.undeliveredFinishes() },
          timeout: BackgroundDownloadHardware.wakeDeliveryTimeout)
        box.call()
      }
    }
  }
}

/// Wraps a plain (non-`@Sendable`) completion handler so it can be captured inside a `@Sendable`
/// closure (Swift 6 strict concurrency). Only this box's single call-through is asserted safe,
/// not the wrapped closure's own internals.
private nonisolated final class CompletionHandlerBox: @unchecked Sendable {
  private let handler: () -> Void

  init(_ handler: @escaping () -> Void) {
    self.handler = handler
  }

  func call() {
    handler()
  }
}
