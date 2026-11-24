import Foundation
import Testing

@testable import Persistence

@Suite struct PodcastFeedIdentityTests {
  @Test func normalizationKeepsTheApprovedIdentityMatrix() {
    #expect(
      PodcastFeedIdentity.normalized("HTTP://EXAMPLE.COM:80/Feed/")
        == "http://example.com/Feed")
    #expect(
      PodcastFeedIdentity.normalized("https://Example.com:443/Feed/?Key=MiXeD")
        == "https://example.com/Feed?Key=MiXeD")
    #expect(
      PodcastFeedIdentity.normalized("https://example.com/Feed/")
        == PodcastFeedIdentity.normalized("https://example.com/Feed"))
    #expect(
      PodcastFeedIdentity.normalized("https://example.com/Feed")
        != PodcastFeedIdentity.normalized("https://example.com/feed"))
    #expect(
      PodcastFeedIdentity.normalized("https://example.com/Feed")
        != PodcastFeedIdentity.normalized("https://example.com/Feed?x=1"))
    #expect(
      PodcastFeedIdentity.normalized("http://example.com/Feed")
        != PodcastFeedIdentity.normalized("https://example.com/Feed"))
    #expect(
      PodcastFeedIdentity.normalized("https://example.com/Feed#part")
        == "https://example.com/Feed#part")
  }

  @Test func rejectsNonHTTPHostsAndCredentials() {
    for rawValue in [
      "", "ftp://example.com/feed", "file:///tmp/feed", "https:///feed",
      "https://user:password@example.com/feed", "https://example.com/feed?",
    ] {
      if rawValue == "https://example.com/feed?" {
        #expect(PodcastFeedIdentity.normalized(rawValue) == "https://example.com/feed")
      } else {
        #expect(PodcastFeedIdentity.normalized(rawValue) == nil)
      }
    }
  }

  @Test func fingerprintIsDeterministicLowercaseSHA256OfNormalizedValue() {
    let fingerprint = PodcastFeedIdentity.fingerprint("HTTPS://EXAMPLE.COM:443/Feed/")
    #expect(fingerprint == "fbb60562bd8c5ed5ce427d09753df8a1d083eb2b6dae87a1a7b7aebd5ae76adf")
    #expect(fingerprint?.count == PodcastFeedIdentity.fingerprintCharacterCount)
    #expect(
      fingerprint?.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) } == true)
    #expect(
      PodcastFeedIdentity.fingerprint("HTTPS://EXAMPLE.COM:443/Feed/")
        == PodcastFeedIdentity.fingerprint("https://example.com/Feed"))
    #expect(
      PodcastFeedIdentity.fingerprint("https://example.com/Feed")
        != PodcastFeedIdentity.fingerprint("https://example.com/feed"))
  }

  @Test func malformedPersistedFingerprintsFailOpen() {
    let valid = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    #expect(PodcastFeedIdentity.validatedFingerprint(valid) == valid)
    #expect(PodcastFeedIdentity.validatedFingerprint(valid.uppercased()) == nil)
    #expect(PodcastFeedIdentity.validatedFingerprint(String(valid.dropLast())) == nil)
    #expect(PodcastFeedIdentity.validatedFingerprint(valid + "0") == nil)
    #expect(PodcastFeedIdentity.validatedFingerprint(nil) == nil)
  }
}
