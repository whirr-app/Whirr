import AppModel
import Foundation
import Persistence
import SyncEngine
import UIKit
import UserNotifications

final class PodcastLocalNotificationCenter: RSSLocalNotificationScheduling,
  RSSLocalNotificationAuthorizing, @unchecked Sendable
{
  static let shared = PodcastLocalNotificationCenter()
  static let routeUserInfoKey = "rssNotificationRoute"
  private let center = UNUserNotificationCenter.current()

  func authorizationStatus() async -> RSSLocalNotificationAuthorizationStatus {
    switch await center.notificationSettings().authorizationStatus {
    case .notDetermined: .notDetermined
    case .authorized, .provisional, .ephemeral: .allowed
    case .denied: .denied
    @unknown default: .denied
    }
  }

  func requestAuthorization() async -> RSSLocalNotificationAuthorizationStatus {
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
    return await authorizationStatus()
  }

  /// Low Power Mode reports Background App Refresh as denied, which cannot be told apart from the
  /// listener's own switch while it lasts; it is read as the temporary pause.
  func backgroundRefreshStatus() async -> BackgroundRefreshStatus {
    await MainActor.run {
      switch UIApplication.shared.backgroundRefreshStatus {
      case .available: .available
      case .restricted: .restricted
      case .denied:
        ProcessInfo.processInfo.isLowPowerModeEnabled ? .pausedByLowPowerMode : .denied
      @unknown default: .denied
      }
    }
  }

  func schedule(_ request: RSSNotificationRequest) async throws {
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.sound = request.playsSound ? .default : nil
    if let data = try? JSONEncoder().encode(request.route) {
      content.userInfo[Self.routeUserInfoKey] = data.base64EncodedString()
    }
    try await center.add(
      UNNotificationRequest(
        identifier: request.identifier, content: content, trigger: nil))
  }

  func cancel(requestIDs: [String]) async {
    center.removePendingNotificationRequests(withIdentifiers: requestIDs)
    center.removeDeliveredNotifications(withIdentifiers: requestIDs)
  }

  static func route(
    from userInfo: [AnyHashable: Any], actionIdentifier: String
  ) -> RSSNotificationRoute? {
    guard actionIdentifier != UNNotificationDismissActionIdentifier,
      let raw = userInfo[routeUserInfoKey] as? String,
      let data = Data(base64Encoded: raw)
    else { return nil }
    return try? JSONDecoder().decode(RSSNotificationRoute.self, from: data)
  }
}
