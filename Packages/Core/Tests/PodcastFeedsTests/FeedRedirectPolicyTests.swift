import Foundation
import PodcastFeeds
import Testing

@Test("RSS redirect policy evaluates origin, transport, and hop limits")
func feedRedirectPolicyMatrix() throws {
  struct Case {
    let name: String
    let original: String
    let target: String
    let hopNumber: Int
    let expected: FeedRedirectPolicy.Decision
  }

  let cases: [Case] = [
    Case(
      name: "same-origin HTTP", original: "http://a.example/feed", target: "http://a.example/x",
      hopNumber: 1, expected: .allow(stripAuthorization: false)),
    Case(
      name: "same-origin HTTPS", original: "https://a.example/feed", target: "https://a.example/x",
      hopNumber: 1, expected: .allow(stripAuthorization: false)),
    Case(
      name: "different port", original: "https://a.example:8443/feed",
      target: "https://a.example:9443/x", hopNumber: 1, expected: .allow(stripAuthorization: true)),
    Case(
      name: "implicit and explicit HTTPS port", original: "https://a.example/feed",
      target: "https://a.example:443/x", hopNumber: 1, expected: .allow(stripAuthorization: false)),
    Case(
      name: "cross-host", original: "https://a.example/feed", target: "https://cdn.example/x",
      hopNumber: 1, expected: .allow(stripAuthorization: true)),
    Case(
      name: "HTTPS downgrade same host", original: "https://a.example/feed",
      target: "http://a.example/x", hopNumber: 1, expected: .reject),
    Case(
      name: "HTTPS downgrade cross-host", original: "https://a.example/feed",
      target: "http://cdn.example/x", hopNumber: 1, expected: .reject),
    Case(
      name: "HTTP upgrade", original: "http://a.example/feed", target: "https://a.example/x",
      hopNumber: 1, expected: .allow(stripAuthorization: true)),
    Case(
      name: "maximum hop", original: "http://a.example/feed", target: "http://a.example/x",
      hopNumber: 5, expected: .allow(stripAuthorization: false)),
    Case(
      name: "sixth hop", original: "http://a.example/feed", target: "http://a.example/x",
      hopNumber: 6, expected: .reject),
    Case(
      name: "zero hop", original: "http://a.example/feed", target: "http://a.example/x",
      hopNumber: 0, expected: .reject),
    Case(
      name: "negative hop", original: "http://a.example/feed", target: "http://a.example/x",
      hopNumber: -1, expected: .reject),
    Case(
      name: "FTP target", original: "http://a.example/feed", target: "ftp://a.example/x",
      hopNumber: 1, expected: .reject),
    Case(
      name: "hostless target", original: "http://a.example/feed", target: "about:blank",
      hopNumber: 1, expected: .reject),
    Case(
      name: "case-insensitive host and scheme", original: "HTTPS://A.EXAMPLE/feed",
      target: "https://a.example/x", hopNumber: 1, expected: .allow(stripAuthorization: false)),
    Case(
      name: "same-origin target with user", original: "https://a.example/feed",
      target: "https://user@a.example/x", hopNumber: 1, expected: .reject),
    Case(
      name: "same-origin target with user and password", original: "https://a.example/feed",
      target: "https://user:password@a.example/x", hopNumber: 1, expected: .reject),
    Case(
      name: "same-origin target with empty user", original: "https://a.example/feed",
      target: "https://@a.example/x", hopNumber: 1, expected: .reject),
    Case(
      name: "cross-origin target with userinfo", original: "https://a.example/feed",
      target: "https://user:password@cdn.example/x", hopNumber: 1, expected: .reject),
    Case(
      name: "HTTP target with userinfo", original: "http://a.example/feed",
      target: "http://user@a.example/x", hopNumber: 1, expected: .reject),
    Case(
      name: "HTTP credential target with userinfo", original: "http://a.example/feed",
      target: "http://user:password@a.example/x", hopNumber: 1, expected: .reject),
  ]

  for testCase in cases {
    let original = try #require(URL(string: testCase.original))
    let target = try #require(URL(string: testCase.target))
    #expect(
      FeedRedirectPolicy.evaluate(
        original: original, target: target, hopNumber: testCase.hopNumber) == testCase.expected,
      "\(testCase.name)")
  }
}
