import Foundation
import Observation
import SyncEngine

/// Device-local user intent. Absence reads as false, so migration never opts a user in.
public final class PodcastNotificationPreference: RSSNotificationIntentReading,
  RSSNotificationIntentWriting, @unchecked Sendable
{
  public static let storageKey = "podcasts.newEpisodeNotifications.enabled"
  private let lock = NSLock()
  private let defaults: any NativePodcastSubscriptionsDefaults
  private var enabled: Bool

  public init(defaults: any NativePodcastSubscriptionsDefaults) {
    self.defaults = defaults
    enabled = defaults.boolValue(forKey: Self.storageKey) ?? false
  }

  public func isNewEpisodeNotificationEnabled() async -> Bool {
    lock.withLock { enabled }
  }

  public func setNewEpisodeNotificationEnabled(_ enabled: Bool) async {
    lock.withLock {
      self.enabled = enabled
      defaults.setBoolValue(enabled, forKey: Self.storageKey)
    }
  }
}

/// Whether iOS will run the scheduled feed check. New-episode alerts depend on it as much as on
/// notification permission, but iOS has no prompt for it: it can only be turned on in Settings.
public enum BackgroundRefreshStatus: Sendable, Equatable {
  case available
  /// Reported off while Low Power Mode is on. Temporary, so it warns but never refuses an enable.
  case pausedByLowPowerMode
  case denied
  /// Device management or Screen Time; the listener cannot change it.
  case restricted
}

public enum FeedEnableAuthorization: Sendable, Equatable {
  case permitted
  /// Denied in the system prompt just now; nothing more to explain.
  case declined
  case refused(NotificationEnableRefusal)
}

/// Why an explicit enable was refused when the system would not deliver on it.
public enum NotificationEnableRefusal: Sendable, Equatable {
  case notificationsDenied
  case backgroundRefreshDenied
  case backgroundRefreshRestricted

  public var title: String {
    switch self {
    case .notificationsDenied: SettingsCopy.notificationsDeniedRefusalTitle
    case .backgroundRefreshDenied: SettingsCopy.backgroundRefreshDeniedRefusalTitle
    case .backgroundRefreshRestricted: SettingsCopy.backgroundRefreshRestrictedRefusalTitle
    }
  }

  public var message: String {
    switch self {
    case .notificationsDenied: SettingsCopy.notificationsDeniedRefusalMessage
    case .backgroundRefreshDenied: SettingsCopy.backgroundRefreshDeniedRefusalMessage
    case .backgroundRefreshRestricted: SettingsCopy.backgroundRefreshRestrictedRefusalMessage
    }
  }

  /// A restriction cannot be lifted from Whirr's page in Settings.
  public var offersSystemSettings: Bool { self != .backgroundRefreshRestricted }
}

public protocol RSSLocalNotificationAuthorizing: Sendable {
  func authorizationStatus() async -> RSSLocalNotificationAuthorizationStatus
  func requestAuthorization() async -> RSSLocalNotificationAuthorizationStatus
  func backgroundRefreshStatus() async -> BackgroundRefreshStatus
}

/// Joins independently exposed dependency slots back into the single read/write existential the
/// settings model needs, while preserving one underlying production preference instance.
public struct NotificationIntentAccess: RSSNotificationIntentReading,
  RSSNotificationIntentWriting
{
  private let reading: any RSSNotificationIntentReading
  private let writing: any RSSNotificationIntentWriting
  public init(
    reading: any RSSNotificationIntentReading, writing: any RSSNotificationIntentWriting
  ) {
    self.reading = reading
    self.writing = writing
  }
  public func isNewEpisodeNotificationEnabled() async -> Bool {
    await reading.isNewEpisodeNotificationEnabled()
  }
  public func setNewEpisodeNotificationEnabled(_ enabled: Bool) async {
    await writing.setNewEpisodeNotificationEnabled(enabled)
  }
}

public struct NoOpRSSLocalNotificationAuthorizer: RSSLocalNotificationAuthorizing {
  public init() {}
  public func authorizationStatus() async -> RSSLocalNotificationAuthorizationStatus { .denied }
  public func requestAuthorization() async -> RSSLocalNotificationAuthorizationStatus { .denied }
  public func backgroundRefreshStatus() async -> BackgroundRefreshStatus { .available }
}

@MainActor
@Observable
public final class PodcastNotificationSettingsModel {
  public private(set) var isEnabled = false
  /// True once `isEnabled` has been published from the stored intent. Awaiting `load()` does not
  /// prove that: an operation queued behind it supersedes its publication, and the scene refresh
  /// is queued on every activation. A reader outside Settings waits for this instead.
  public private(set) var hasLoaded = false
  public private(set) var authorizationStatus: RSSLocalNotificationAuthorizationStatus =
    .notDetermined
  public private(set) var backgroundRefreshStatus: BackgroundRefreshStatus = .available
  /// Set when an explicit enable was refused for a permission the listener had already withheld.
  /// A denial answered in the system prompt just now sets nothing.
  public private(set) var enableRefusal: NotificationEnableRefusal?

  /// Something Whirr's page in Settings can fix.
  public var requiresSystemSettingsRecovery: Bool {
    authorizationStatus == .denied || backgroundRefreshStatus == .denied
  }

  public var showsSystemSettingsRecovery: Bool {
    isEnabled && requiresSystemSettingsRecovery
  }

  /// Footer copy while alerts are on but the scheduled check cannot run. A revoked permission
  /// keeps the listener's intent, so this is how they learn alerts have stopped.
  public var backgroundRefreshWarning: String? {
    guard isEnabled else { return nil }
    return switch backgroundRefreshStatus {
    case .available: nil
    case .pausedByLowPowerMode: SettingsCopy.backgroundRefreshPausedWarning
    case .denied: SettingsCopy.backgroundRefreshOffWarning
    case .restricted: SettingsCopy.backgroundRefreshRestrictedWarning
    }
  }

  private let preference: any RSSNotificationIntentReading & RSSNotificationIntentWriting
  private let authorizer: any RSSLocalNotificationAuthorizing
  private let lifecycle: any RSSNotificationLifecycleHandling
  private var operationGeneration: UInt64 = 0
  @ObservationIgnored private var operationTask: Task<Void, Never>?

  public init(
    preference: any RSSNotificationIntentReading & RSSNotificationIntentWriting,
    authorizer: any RSSLocalNotificationAuthorizing,
    lifecycle: any RSSNotificationLifecycleHandling = NoOpRSSNotificationLifecycle()
  ) {
    self.preference = preference
    self.authorizer = authorizer
    self.lifecycle = lifecycle
  }

  /// Read-only launch/setup path. This can never prompt.
  public func load() async {
    await enqueueOperation { model, generation in
      let enabled = await model.preference.isNewEpisodeNotificationEnabled()
      let status = await model.authorizer.authorizationStatus()
      let refresh = await model.authorizer.backgroundRefreshStatus()
      guard model.operationGeneration == generation else { return }
      model.isEnabled = enabled
      model.authorizationStatus = status
      model.backgroundRefreshStatus = refresh
      model.hasLoaded = true
    }.value
  }

  /// Called only from the user's toggle action. An enable the system would not deliver on is
  /// refused and leaves the stored intent off; see `authorizeEnable`.
  public func setEnabled(_ enabled: Bool) async {
    await requestEnabled(enabled).value
  }

  /// Starts the complete toggle operation synchronously, so two SwiftUI binding writes enter the
  /// model-owned serial chain in invocation order rather than in scheduler order.
  @discardableResult
  public func requestEnabled(_ enabled: Bool) -> Task<Void, Never> {
    enqueueOperation { model, generation in
      guard enabled else {
        await model.lifecycle.disarm(feedID: nil)
        await model.preference.setNewEpisodeNotificationEnabled(false)
        let status = await model.authorizer.authorizationStatus()
        let refresh = await model.authorizer.backgroundRefreshStatus()
        guard model.operationGeneration == generation else { return }
        model.isEnabled = false
        model.authorizationStatus = status
        model.backgroundRefreshStatus = refresh
        model.enableRefusal = nil
        model.hasLoaded = true
        return
      }
      let decision = await model.authorizeEnable()
      if decision.permitted { await model.preference.setNewEpisodeNotificationEnabled(true) }
      guard model.operationGeneration == generation else { return }
      model.publish(decision)
      model.isEnabled = decision.permitted
      model.hasLoaded = true
    }
  }

  /// Returning from System Settings, or a system status change while on screen, is a read-only
  /// refresh. It never presents the OS prompt.
  @discardableResult
  public func sceneDidBecomeActive() -> Task<Void, Never> {
    enqueueOperation { model, generation in
      let status = await model.authorizer.authorizationStatus()
      let refresh = await model.authorizer.backgroundRefreshStatus()
      guard model.operationGeneration == generation else { return }
      model.authorizationStatus = status
      model.backgroundRefreshStatus = refresh
    }
  }

  /// Per-feed “On” is also an explicit enable action, under the same refusal rules. It may
  /// request permission without changing the global default the feed overrides. The refusal is
  /// returned rather than published here, so only the screen that asked presents it.
  @discardableResult
  public func authorizeExplicitFeedEnableIfNeeded() async -> FeedEnableAuthorization {
    let outcome = FeedEnableOutcome()
    await enqueueOperation { model, generation in
      let decision = await model.authorizeEnable()
      if let refusal = decision.refusal {
        outcome.value = .refused(refusal)
      } else if decision.permitted {
        outcome.value = .permitted
      }
      guard model.operationGeneration == generation else { return }
      model.authorizationStatus = decision.authorization
      model.backgroundRefreshStatus = decision.backgroundRefresh
    }.value
    return outcome.value
  }

  /// Carries the decision out of the serial chain, whose operations return nothing.
  @MainActor private final class FeedEnableOutcome {
    var value = FeedEnableAuthorization.declined
  }

  public func dismissEnableRefusal() {
    enableRefusal = nil
  }

  private struct EnableDecision {
    var authorization: RSSLocalNotificationAuthorizationStatus
    var backgroundRefresh: BackgroundRefreshStatus
    var refusal: NotificationEnableRefusal?
    var permitted: Bool { refusal == nil && authorization == .allowed }
  }

  /// Background App Refresh is checked before the notification prompt, so a listener is never
  /// asked for a permission the toggle would then refuse for another reason.
  private func authorizeEnable() async -> EnableDecision {
    let refresh = await authorizer.backgroundRefreshStatus()
    var status = await authorizer.authorizationStatus()
    let refusal: NotificationEnableRefusal? =
      switch (refresh, status) {
      case (.restricted, _): .backgroundRefreshRestricted
      case (_, .denied): .notificationsDenied
      case (.denied, _): .backgroundRefreshDenied
      default: nil
      }
    if refusal == nil, status == .notDetermined {
      status = await authorizer.requestAuthorization()
    }
    return EnableDecision(authorization: status, backgroundRefresh: refresh, refusal: refusal)
  }

  private func publish(_ decision: EnableDecision) {
    authorizationStatus = decision.authorization
    backgroundRefreshStatus = decision.backgroundRefresh
    enableRefusal = decision.refusal
  }

  /// Serializing the side effects, rather than only fencing their publications, preserves the
  /// user's invocation order. In particular, a superseded disable still performs its required
  /// notification disarm before a later enable is applied.
  private func enqueueOperation(
    _ operation:
      @escaping @MainActor @Sendable (
        PodcastNotificationSettingsModel,
        UInt64
      ) async -> Void
  ) -> Task<Void, Never> {
    operationGeneration &+= 1
    let generation = operationGeneration
    let preceding = operationTask
    let task = Task { @MainActor [self, preceding] in
      await preceding?.value
      await operation(self, generation)
    }
    operationTask = task
    return task
  }
}
