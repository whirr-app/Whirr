import Foundation
import Persistence
import Testing
import UserNotifications

@testable import Whirr

@Suite("Podcast local notification payloads")
struct PodcastLocalNotificationTests {
  @Test("typed routes round-trip without titles or feed URLs")
  func typedRouteRoundTrips() throws {
    let route = RSSNotificationRoute.episode(feedID: 42, identityKey: "episode-guid")
    let encoded = try JSONEncoder().encode(route).base64EncodedString()

    #expect(
      PodcastLocalNotificationCenter.route(
        from: [
          PodcastLocalNotificationCenter.routeUserInfoKey: encoded
        ],
        actionIdentifier: UNNotificationDefaultActionIdentifier) == route)
  }

  @Test("dismissing a delivered notification never produces a route")
  func dismissedNotificationFailsClosed() throws {
    let route = RSSNotificationRoute.episode(feedID: 42, identityKey: "episode-guid")
    let encoded = try JSONEncoder().encode(route).base64EncodedString()

    #expect(
      PodcastLocalNotificationCenter.route(
        from: [PodcastLocalNotificationCenter.routeUserInfoKey: encoded],
        actionIdentifier: UNNotificationDismissActionIdentifier) == nil)
  }

  @Test("malformed payloads fail closed")
  func malformedPayloadFailsClosed() {
    #expect(
      PodcastLocalNotificationCenter.route(
        from: [
          PodcastLocalNotificationCenter.routeUserInfoKey: "not-base64"
        ],
        actionIdentifier: UNNotificationDefaultActionIdentifier) == nil)
    #expect(
      PodcastLocalNotificationCenter.route(
        from: [:], actionIdentifier: UNNotificationDefaultActionIdentifier) == nil)
  }

  @Test("a stale consumer cannot remove an identical route stored after logout")
  func mailboxConsumptionIsIdentitySafe() throws {
    let suiteName = "PodcastLocalNotificationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let mailbox = PodcastNotificationRouteMailbox(
      defaults: defaults, notificationCenter: NotificationCenter())
    let route = RSSNotificationRoute.episode(feedID: 42, identityKey: "episode-guid")

    mailbox.store(route)
    let stale = try #require(mailbox.peek())
    mailbox.clear()
    mailbox.store(route)
    let current = try #require(mailbox.peek())

    #expect(mailbox.consume(stale) == false)
    #expect(mailbox.peek()?.route == route)
    #expect(mailbox.consume(current))
    #expect(mailbox.peek() == nil)
  }

}
