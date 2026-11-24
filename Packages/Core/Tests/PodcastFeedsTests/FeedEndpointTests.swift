import Foundation
import PodcastFeeds
import Testing

@Suite("Feed endpoint")
struct FeedEndpointTests {
  @Test(
    "accepts HTTP and HTTPS URLs without changing their spelling",
    arguments: [
      "https://MiXeD.example:8443/feed?b=2&a=1#latest",
      "HTTP://feed.example/feed/",
    ])
  func acceptsHTTPAndHTTPSURLsExactlyAsGiven(string: String) throws {
    let url = try #require(URL(string: string))
    let endpoint = try #require(FeedEndpoint(url: url))

    #expect(endpoint.url.absoluteString == string)
  }

  @Test("accepts a URL created from a string")
  func constructsFromString() throws {
    let endpoint = try #require(
      FeedEndpoint(string: "https://feed.example/podcast.xml?format=rss:2"))

    #expect(endpoint.url.absoluteString == "https://feed.example/podcast.xml?format=rss:2")
  }

  @Test(
    "rejects embedded credentials",
    arguments: [
      "https://user:pass@host/feed",
      "https://user@host/feed",
    ])
  func rejectsEmbeddedCredentials(string: String) throws {
    let url = try #require(URL(string: string))

    #expect(FeedEndpoint(url: url) == nil)
  }

  @Test(
    "rejects non-feed URL forms",
    arguments: [
      "ftp://host/feed",
      "about:blank",
      "mailto:a@b",
      "/feed",
      "https:///feed",
    ])
  func rejectsNonFeedURLForms(string: String) {
    #expect(FeedEndpoint(string: string) == nil)
  }

  @Test("credential references require a non-empty identifier")
  func credentialReferenceValidationAndRoundTrip() throws {
    #expect(FeedEndpoint.CredentialReference(id: "") == nil)

    let reference = try #require(FeedEndpoint.CredentialReference(id: "feed-credential-7"))
    let endpoint = try #require(
      FeedEndpoint(string: "https://feed.example/feed", credentialReference: reference))

    #expect(endpoint.credentialReference == reference)
    #expect(reference.id == "feed-credential-7")
  }

  @Test("description and debug description redact feed details")
  func descriptionsContainOnlySafeIdentity() throws {
    let reference = try #require(FeedEndpoint.CredentialReference(id: "secret-reference-id"))
    let endpoint = try #require(
      FeedEndpoint(
        string: "https://private.example/feed",
        credentialReference: reference))

    let description = String(describing: endpoint)
    let debugDescription = String(reflecting: endpoint)

    #expect(description == "/rss/<redacted-feed> (hasCredential: true)")
    #expect(debugDescription == description)
    #expect(!description.contains("private.example"))
    #expect(!description.contains("https"))
    #expect(!description.contains("user"))
    #expect(!description.contains("secret-reference-id"))
    #expect(!debugDescription.contains("private.example"))
    #expect(!debugDescription.contains("https"))
    #expect(!debugDescription.contains("user"))
    #expect(!debugDescription.contains("secret-reference-id"))
  }

  @Test("descriptions report absent credentials without revealing the URL")
  func descriptionReportsMissingCredential() throws {
    let endpoint = try #require(FeedEndpoint(string: "http://feed.example/feed"))

    #expect(String(describing: endpoint) == "/rss/<redacted-feed> (hasCredential: false)")
  }

  @Test("same URL and reference are equal, different references are distinct")
  func equalityAndHashingIncludeCredentialReference() throws {
    let firstReference = try #require(FeedEndpoint.CredentialReference(id: "first"))
    let secondReference = try #require(FeedEndpoint.CredentialReference(id: "second"))
    let first = try #require(
      FeedEndpoint(string: "https://feed.example/feed", credentialReference: firstReference))
    let same = try #require(
      FeedEndpoint(string: "https://feed.example/feed", credentialReference: firstReference))
    let different = try #require(
      FeedEndpoint(string: "https://feed.example/feed", credentialReference: secondReference))

    #expect(first == same)
    #expect(first.hashValue == same.hashValue)
    #expect(first != different)
  }
}
