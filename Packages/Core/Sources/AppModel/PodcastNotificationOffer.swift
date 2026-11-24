import Foundation
import SyncEngine

/// The one-time offer of New Episode Notifications on the Podcasts root. It is driven
/// by state, not by the follow action: a follow has four entry points and none of them reaches
/// listeners who already follow shows.
public enum PodcastNotificationOfferPresentation {
  /// The offer shows only when it can be acted on and has something to say.
  public struct Inputs: Equatable, Sendable {
    /// `PodcastNotificationSettingsModel.hasLoaded`. Unloaded, the model reads as off for a
    /// listener who has notifications on.
    public var hasLoaded: Bool
    public var nativeSubscriptionsEnabled: Bool
    public var hasFollowedShows: Bool
    /// False under the Downloaded filter, where an empty state can cover the card while shows are
    /// followed.
    public var filterShowsOffer: Bool
    public var hasPlaceholder: Bool
    public var isEnabled: Bool
    public var authorizationStatus: RSSLocalNotificationAuthorizationStatus
    public var backgroundRefreshStatus: BackgroundRefreshStatus
    public var isAnswered: Bool

    public init(
      hasLoaded: Bool, nativeSubscriptionsEnabled: Bool, hasFollowedShows: Bool,
      filterShowsOffer: Bool, hasPlaceholder: Bool, isEnabled: Bool,
      authorizationStatus: RSSLocalNotificationAuthorizationStatus,
      backgroundRefreshStatus: BackgroundRefreshStatus = .available, isAnswered: Bool
    ) {
      self.hasLoaded = hasLoaded
      self.nativeSubscriptionsEnabled = nativeSubscriptionsEnabled
      self.hasFollowedShows = hasFollowedShows
      self.filterShowsOffer = filterShowsOffer
      self.hasPlaceholder = hasPlaceholder
      self.isEnabled = isEnabled
      self.authorizationStatus = authorizationStatus
      self.backgroundRefreshStatus = backgroundRefreshStatus
      self.isAnswered = isAnswered
    }
  }

  /// An already granted authorization still presents: turning on then raises no system prompt.
  /// A denied one does not, because the card's button could not fix it; nor does Background App
  /// Refresh that is off or restricted, which would refuse the enable.
  public static func shouldPresent(_ inputs: Inputs) -> Bool {
    inputs.hasLoaded
      && inputs.nativeSubscriptionsEnabled
      && inputs.hasFollowedShows
      && inputs.filterShowsOffer
      && inputs.hasPlaceholder == false
      && inputs.isEnabled == false
      && inputs.authorizationStatus != .denied
      && inputs.backgroundRefreshStatus != .denied
      && inputs.backgroundRefreshStatus != .restricted
      && inputs.isAnswered == false
  }
}

public enum PodcastNotificationOfferCopy {
  public static let title = "New episode alerts"
  public static let detail = "Get a notification when a show you follow releases an episode."
  public static let accept = "Turn On"
  public static let decline = "Not Now"
}

public protocol PodcastNotificationOfferMarking: Sendable {
  func isAnswered() -> Bool
  func markAnswered()
}

/// Device-local marker: either button answers the offer for good. Keep the key out of
/// `ICloudSettingsSync.syncedKeys`; notification intent and authorization belong to the device.
public final class PodcastNotificationOfferPreference: PodcastNotificationOfferMarking,
  @unchecked Sendable
{
  public static let storageKey = "podcasts.newEpisodeNotifications.offerAnswered"

  private let lock = NSLock()
  private let defaults: any NativePodcastSubscriptionsDefaults

  public init(defaults: any NativePodcastSubscriptionsDefaults) {
    self.defaults = defaults
  }

  public func isAnswered() -> Bool {
    lock.withLock { defaults.boolValue(forKey: Self.storageKey) ?? false }
  }

  public func markAnswered() {
    lock.withLock { defaults.setBoolValue(true, forKey: Self.storageKey) }
  }
}
