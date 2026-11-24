import Foundation
import Persistence

/// Persists a tapped destination until the authenticated shell can resolve it. Only typed local
/// ids are stored; no feed URL, show title, or episode title crosses this boundary.
final class PodcastNotificationRouteMailbox: @unchecked Sendable {
  static let shared = PodcastNotificationRouteMailbox()
  static let receivedNotification = Notification.Name("PodcastNotificationRouteReceived")
  private static let storageKey = "podcasts.pendingNotificationRoute"

  struct PendingRoute: Sendable, Equatable {
    fileprivate let identity: UUID
    let route: RSSNotificationRoute
  }

  private struct StoredRoute: Codable {
    let identity: UUID
    let route: RSSNotificationRoute
  }

  private let lock = NSLock()
  private let defaults: UserDefaults
  private let notificationCenter: NotificationCenter

  init(
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    self.defaults = defaults
    self.notificationCenter = notificationCenter
  }

  func store(_ route: RSSNotificationRoute) {
    let stored = StoredRoute(identity: UUID(), route: route)
    guard let data = try? JSONEncoder().encode(stored) else { return }
    lock.withLock {
      defaults.set(data, forKey: Self.storageKey)
    }
    notificationCenter.post(name: Self.receivedNotification, object: nil)
  }

  func peek() -> PendingRoute? {
    lock.withLock {
      guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
      if let stored = try? JSONDecoder().decode(StoredRoute.self, from: data) {
        return PendingRoute(identity: stored.identity, route: stored.route)
      }

      // Upgrade a route written by an earlier app build while holding the same lock used by
      // `store` and `consume`, so the migration cannot overwrite a newly received destination.
      guard let route = try? JSONDecoder().decode(RSSNotificationRoute.self, from: data) else {
        return nil
      }
      let stored = StoredRoute(identity: UUID(), route: route)
      guard let upgraded = try? JSONEncoder().encode(stored) else { return nil }
      defaults.set(upgraded, forKey: Self.storageKey)
      return PendingRoute(identity: stored.identity, route: route)
    }
  }

  /// Removes only the exact entry the caller resolved. A task suspended in route resolution can
  /// therefore neither consume nor navigate a newer entry stored after an account-graph rebuild.
  func consume(_ pending: PendingRoute) -> Bool {
    lock.withLock {
      guard let data = defaults.data(forKey: Self.storageKey),
        let stored = try? JSONDecoder().decode(StoredRoute.self, from: data),
        stored.identity == pending.identity
      else { return false }
      defaults.removeObject(forKey: Self.storageKey)
      return true
    }
  }

  func clear() {
    lock.withLock { defaults.removeObject(forKey: Self.storageKey) }
  }
}
