import Foundation
import TestSupport
import Testing

@testable import ABSApi

@Test func liveServerFixturesAreLoadableThroughTestSupport() throws {
  let fixtureNames = [
    "status",
    "login-response",
    "me-profile-response",
    "libraries-response",
    "library-items-minified",
    "book-item-expanded",
    "podcast-item-expanded",
    "media-progress",
  ]

  for name in fixtureNames {
    let data = try Fixtures.data(named: name)
    #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
  }
}
