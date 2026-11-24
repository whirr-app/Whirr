import ABSApi
import Foundation
import Testing

@testable import PodcastFeeds

@Suite("Feed credentials")
struct FeedCredentialTests {
  @Test("permits only a validated Authorization field")
  func validatesAuthorizationField() throws {
    let credential = try FeedCredential(authorization: "Basic dXNlcjpwYXNz")

    #expect(credential.headerFields == ["Authorization": "Basic dXNlcjpwYXNz"])
    #expect(credential.authorization == "Basic dXNlcjpwYXNz")
  }

  /// The rule every credentialed feed request is admitted by: feed fetch, artwork, enclosure
  /// download, and playback stream all ask this before stamping a header.
  @Test("carries a credential only to the feed's exact origin")
  func carriesCredentialOnlyToTheFeedOrigin() throws {
    let feed = URL(string: "https://feeds.example.test/show.xml")!

    #expect(
      FeedCredentialOrigin.carriesCredential(
        feedURL: feed, target: URL(string: "https://feeds.example.test/media/ep.mp3")!))
    #expect(
      FeedCredentialOrigin.carriesCredential(
        feedURL: feed, target: URL(string: "https://feeds.example.test:443/ep.mp3")!))

    for target in [
      "https://media.example.test/ep.mp3",  // another host
      "https://evil.feeds.example.test/ep.mp3",  // a subdomain is not the origin
      "http://feeds.example.test/ep.mp3",  // scheme downgrade
      "https://feeds.example.test:8443/ep.mp3",  // another port
      "ftp://feeds.example.test/ep.mp3",  // non-http(s)
      "file:///private/tmp/ep.mp3",  // no host at all
      "https://someone:else@feeds.example.test/ep.mp3",  // userinfo the app did not mint
    ] {
      #expect(
        FeedCredentialOrigin.carriesCredential(feedURL: feed, target: URL(string: target)!) == false,
        "\(target) must not receive the feed credential")
    }

    // A feed URL that still carries userinfo is never a credential origin: the stored credential
    // and the embedded one would travel together.
    #expect(
      FeedCredentialOrigin.carriesCredential(
        feedURL: URL(string: "https://user:pass@feeds.example.test/show.xml")!,
        target: URL(string: "https://feeds.example.test/ep.mp3")!) == false)
  }

  @Test("rejects empty, non-ASCII, and injected Authorization values")
  func rejectsUnsafeAuthorizationValues() {
    for value in ["", "Basic café", "Basic abc\r", "Basic abc\n", "Basic abc\r\nX-Evil: 1"] {
      #expect(throws: FeedCredentialError.invalidAuthorization) {
        try FeedCredential(authorization: value)
      }
    }
  }

  @Test("builds Basic authorization without retaining username or password in descriptions")
  func buildsRedactedBasicCredential() throws {
    let credential = try FeedCredential.basic(username: "private-user", password: "private-password")

    #expect(credential.authorization == "Basic cHJpdmF0ZS11c2VyOnByaXZhdGUtcGFzc3dvcmQ=")
    for rendered in [String(describing: credential), String(reflecting: credential)] {
      #expect(rendered.contains("private-user") == false)
      #expect(rendered.contains("private-password") == false)
      #expect(rendered.contains(credential.authorization) == false)
    }
  }

  @Test("rejects an ambiguous Basic username")
  func rejectsBasicUsernameContainingColon() {
    #expect(throws: FeedCredentialError.invalidBasicUsername) {
      try FeedCredential.basic(username: "user:name", password: "password")
    }
  }

  @Test("fingerprint changes without exposing credential material")
  func fingerprintsCredentialMaterial() throws {
    let first = try FeedCredential(authorization: "Bearer first-secret")
    let same = try FeedCredential(authorization: "Bearer first-secret")
    let second = try FeedCredential(authorization: "Bearer second-secret")

    #expect(first.fingerprint == same.fingerprint)
    #expect(first.fingerprint != second.fingerprint)
    #expect(first.fingerprint.count == 64)
    #expect(first.fingerprint.contains("secret") == false)
  }
}

@Suite("Feed credential store")
struct FeedCredentialStoreTests {
  @Test("saves, overwrites, loads, and clears by positive feed identity")
  func inMemoryContract() throws {
    let store = InMemoryFeedCredentialStore()
    let first = try FeedCredential.basic(username: "one", password: "first")
    let replacement = try FeedCredential.basic(username: "two", password: "second")

    try store.save(first, forFeedID: 41)
    #expect(try store.load(forFeedID: 41) == first)
    #expect(try store.load(forFeedID: 42) == nil)

    try store.save(replacement, forFeedID: 41)
    #expect(try store.load(forFeedID: 41) == replacement)

    try store.clear(forFeedID: 41)
    #expect(try store.load(forFeedID: 41) == nil)
  }

  @Test("rejects non-persisted feed identities")
  func rejectsInvalidFeedIdentity() throws {
    let store = InMemoryFeedCredentialStore()
    let credential = try FeedCredential(authorization: "Bearer secret")

    for feedID in [Int64.min, -1, 0] {
      #expect(throws: FeedCredentialStoreError.invalidFeedIdentity) {
        try store.save(credential, forFeedID: feedID)
      }
      #expect(throws: FeedCredentialStoreError.invalidFeedIdentity) {
        try store.load(forFeedID: feedID)
      }
      #expect(throws: FeedCredentialStoreError.invalidFeedIdentity) {
        try store.clear(forFeedID: feedID)
      }
    }
  }
}

#if canImport(Security)
  @Suite("Keychain feed credential store")
  struct KeychainFeedCredentialStoreTests {
    @Test("uses a dedicated service and the feed identity as the Keychain account")
    func secureFeedScopedQuery() throws {
      let client = RecordingFeedSecItemClient()
      let store = try KeychainFeedCredentialStore(
        serviceNamespace: "test-feed-credential-service", client: client)
      let credential = try FeedCredential.basic(username: "user", password: "password")

      try store.save(credential, forFeedID: 73)
      #expect(try store.load(forFeedID: 73) == credential)
      #expect(client.lastQuery?.service == "test-feed-credential-service")
      #expect(client.lastQuery?.account == "feed:73")
      #expect(client.lastAdded?.accessibility == .afterFirstUnlockThisDeviceOnly)

      try store.clear(forFeedID: 73)
      #expect(try store.load(forFeedID: 73) == nil)
    }
  }

  private final class RecordingFeedSecItemClient: SecItemClient, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var query: KeychainItemQuery?
    private var added: KeychainItemAttributes?

    var lastQuery: KeychainItemQuery? { lock.withLock { query } }
    var lastAdded: KeychainItemAttributes? { lock.withLock { added } }

    func add(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws {
      try lock.withLock {
        guard values[query.key] == nil else { throw KeychainStoreError.itemAlreadyExists }
        values[query.key] = attributes.data
        self.query = query
        added = attributes
      }
    }

    func update(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws {
      try lock.withLock {
        guard values[query.key] != nil else { throw KeychainStoreError.itemNotFound }
        values[query.key] = attributes.data
        self.query = query
      }
    }

    func copyData(for query: KeychainItemQuery) throws -> Data? {
      lock.withLock {
        self.query = query
        return values[query.key]
      }
    }

    func delete(for query: KeychainItemQuery) throws {
      lock.withLock {
        values.removeValue(forKey: query.key)
        self.query = query
      }
    }
  }
#endif
