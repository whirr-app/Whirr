import Foundation
import Testing

@testable import WatchPlayback

/// ADR 0020 Decision 3's post-completion redirect check, including the chains seen on device.
struct WatchEnclosureRedirectCheckTests {
  private func url(_ text: String) -> URL {
    URL(string: text)!
  }

  private func https(_ host: String, _ path: String = "/audio.mp3") -> URL {
    url("https://\(host)\(path)")
  }

  private func http(_ host: String, _ path: String = "/audio.mp3") -> URL {
    url("http://\(host)\(path)")
  }

  @Test func sevenHTTPSHopsAreAccepted() {
    let hops = [
      https("a.example.test", "/1"),
      https("b.example.test", "/2"),
      https("c.example.test", "/3"),
      https("d.example.test", "/4"),
      https("e.example.test", "/5"),
      https("f.example.test", "/6"),
      https("g.example.test", "/7"),
    ]
    #expect(
      WatchEnclosureRedirectCheck.evaluate(requested: hops[0], hops: hops) == .accepted)
  }

  /// A chain seen on device: a plain-http enclosure upgrades to https and stays there.
  @Test func anHTTPEnclosureMayUpgradeToHTTPS() {
    let hops = [
      http("plain.example.test", "/1"),
      http("plain.example.test", "/2"),
      https("cdn.example.test", "/3"),
      https("cdn.example.test", "/4"),
    ]
    #expect(WatchEnclosureRedirectCheck.evaluate(requested: hops[0], hops: hops) == .accepted)
  }

  @Test func aDowngradeAfterHTTPSIsRejected() {
    let hops = [https("a.example.test", "/1"), http("b.example.test", "/2")]
    #expect(WatchEnclosureRedirectCheck.evaluate(requested: hops[0], hops: hops) == .rejected)

    let mixed = [
      https("a.example.test", "/1"),
      https("b.example.test", "/2"),
      http("c.example.test", "/3"),
      https("d.example.test", "/4"),
    ]
    #expect(WatchEnclosureRedirectCheck.evaluate(requested: mixed[0], hops: mixed) == .rejected)
  }

  /// The requested URL counts as the chain's origin even when the metrics omit it.
  @Test func anHTTPSRequestCannotDowngradeOnItsFirstHop() {
    let hops = [http("a.example.test", "/1"), https("b.example.test", "/2")]
    #expect(
      WatchEnclosureRedirectCheck.evaluate(requested: https("a.example.test"), hops: hops)
        == .rejected)
  }

  @Test func anHTTPHopWithUserinfoIsRejected() {
    let hops = [https("a.example.test", "/1"), url("https://user:password@b.example.test/2")]
    #expect(WatchEnclosureRedirectCheck.evaluate(requested: hops[0], hops: hops) == .rejected)

    let downgraded = [url("http://user@a.example.test/1")]
    #expect(WatchEnclosureRedirectCheck.evaluate(requested: downgraded[0], hops: downgraded) == .rejected)
  }

  @Test func aNonHTTPHopIsRejected() {
    let hops = [url("ftp://a.example.test/1")]
    #expect(WatchEnclosureRedirectCheck.evaluate(requested: hops[0], hops: hops) == .rejected)

    let hostless = [url("about:blank")]
    #expect(WatchEnclosureRedirectCheck.evaluate(requested: https("a.example.test"), hops: hostless) == .rejected)
  }

  /// Missing metrics are a rejection: there is no chain to check, so the bytes cannot be trusted.
  @Test func anEmptyChainIsRejected() {
    #expect(WatchEnclosureRedirectCheck.evaluate(requested: https("a.example.test"), hops: []) == .rejected)
  }

  @Test func aSingleHopIsAccepted() {
    #expect(
      WatchEnclosureRedirectCheck.evaluate(
        requested: http("a.example.test"), hops: [http("a.example.test")]) == .accepted)
  }

  @Test func schemeAndHostCaseDoesNotMatter() {
    let hops = [url("HTTPS://A.EXAMPLE.TEST/audio.mp3"), url("https://b.example.test/audio.mp3")]
    #expect(WatchEnclosureRedirectCheck.evaluate(requested: hops[0], hops: hops) == .accepted)
  }
}
