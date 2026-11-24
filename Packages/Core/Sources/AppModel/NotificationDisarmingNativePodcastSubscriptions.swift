import Persistence
import SyncEngine

/// Native toggle-off is a lifecycle boundary, not a settings deletion: overrides remain stored,
/// while pending/scheduled requests are disarmed before the preference becomes inert.
public struct NotificationDisarmingNativePodcastSubscriptions: NativePodcastSubscriptionsWriting {
  private let writing: any NativePodcastSubscriptionsWriting
  private let notifications: any RSSNotificationLifecycleHandling
  public init(
    writing: any NativePodcastSubscriptionsWriting,
    notifications: any RSSNotificationLifecycleHandling
  ) {
    self.writing = writing
    self.notifications = notifications
  }
  public func setEnabled(_ enabled: Bool) async {
    if enabled == false { await notifications.disarm(feedID: nil) }
    await writing.setEnabled(enabled)
  }
}
