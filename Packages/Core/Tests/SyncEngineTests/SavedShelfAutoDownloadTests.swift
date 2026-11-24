import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite("Saved for Later auto-download")
struct SavedShelfAutoDownloadTests {

  @Test("the policy is Codable and defaults to never")
  func policyDefaultsToNeverAndRoundTrips() throws {
    #expect(SavedShelfAutoDownloadPolicy() == .never)
    #expect(SavedShelfAutoDownloadPolicy.never.rawValue == "never")
    #expect(SavedShelfAutoDownloadPolicy.wifiOnly.rawValue == "wifiOnly")
    #expect(SavedShelfAutoDownloadPolicy.always.rawValue == "always")

    let data = try JSONEncoder().encode(SavedShelfAutoDownloadPolicy.wifiOnly)
    #expect(try JSONDecoder().decode(SavedShelfAutoDownloadPolicy.self, from: data) == .wifiOnly)
  }

  @Test("each policy gates a save's request on cellular and Wi-Fi")
  func policyGatesAdmission() async throws {
    let cases: [(SavedShelfAutoDownloadPolicy, Bool, Bool)] = [
      (.never, false, false),
      (.never, true, false),
      (.wifiOnly, false, true),
      (.wifiOnly, true, false),
      (.always, false, true),
      (.always, true, true),
    ]

    for (policy, cellular, shouldRequest) in cases {
      let requester = RecordingSavedShelfRequester()
      let network = FakeNetworkConditions()
      network.isConstrainedOrCellular = cellular
      let shelf = SavedShelfAutoDownload(
        store: FakeSavedShelfStoring(),
        targets: StubDownloadTargets([.audio(itemID: "book-1")]),
        requesting: requester,
        preferences: FixedSavedShelfAutoDownloadPolicy(policy),
        networkConditions: network)

      #expect(try await shelf.save(.item(itemID: "book-1")) == .saved)
      #expect(await requester.requests.count == (shouldRequest ? 1 : 0))
    }
  }

  @Test("only a fresh save requests; re-saving and removal never do")
  func triggerRules() async throws {
    let requester = RecordingSavedShelfRequester()
    let underlying = FakeSavedShelfStoring(saveOutcome: .saved)
    let shelf = SavedShelfAutoDownload(
      store: underlying,
      targets: StubDownloadTargets([.audio(itemID: "book-1")]),
      requesting: requester,
      preferences: FixedSavedShelfAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    #expect(try await shelf.save(.item(itemID: "book-1")) == .saved)

    underlying.stubSaveOutcome(.alreadySaved)
    #expect(try await shelf.save(.item(itemID: "book-1")) == .alreadySaved)
    try await shelf.remove(.item(itemID: "book-1"))

    #expect(await requester.requests == [.item(itemID: "book-1")])
    #expect(underlying.calls.contains(.remove(.item(itemID: "book-1"))))
  }

  @Test("each medium routes to its own request method")
  func mediumRouting() async throws {
    let requester = RecordingSavedShelfRequester()
    let shelf = SavedShelfAutoDownload(
      store: FakeSavedShelfStoring(),
      targets: StubDownloadTargets([
        .audio(itemID: "book-1"), .ebook(itemID: "book-1"),
        .episode(itemID: "show-1", episodeID: "episode-1"),
      ]),
      requesting: requester,
      preferences: FixedSavedShelfAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    _ = try await shelf.save(.item(itemID: "book-1"))

    #expect(
      await requester.requests == [
        .item(itemID: "book-1"), .ebook(itemID: "book-1"),
        .episode(itemID: "show-1", episodeID: "episode-1"),
      ])
  }

  @Test("one medium's failure does not suppress the other")
  func mixedItemRequestsBothDespiteAudioFailure() async throws {
    let requester = RecordingSavedShelfRequester(failing: [.item(itemID: "book-1")])
    let shelf = SavedShelfAutoDownload(
      store: FakeSavedShelfStoring(),
      targets: StubDownloadTargets([.audio(itemID: "book-1"), .ebook(itemID: "book-1")]),
      requesting: requester,
      preferences: FixedSavedShelfAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    let outcome = try await shelf.save(.item(itemID: "book-1"))

    #expect(outcome == .saved)
    #expect(
      await requester.requests == [.item(itemID: "book-1"), .ebook(itemID: "book-1")])
  }

  @Test("a request failure never fails a committed save")
  func requestFailureDoesNotFailSave() async throws {
    let requester = RecordingSavedShelfRequester(failing: [.item(itemID: "book-1")])
    let shelf = SavedShelfAutoDownload(
      store: FakeSavedShelfStoring(),
      targets: StubDownloadTargets([.audio(itemID: "book-1")]),
      requesting: requester,
      preferences: FixedSavedShelfAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    #expect(try await shelf.save(.item(itemID: "book-1")) == .saved)
  }

  @Test("a target-read failure never fails a committed save and requests nothing")
  func targetReadFailureDoesNotFailSave() async throws {
    let requester = RecordingSavedShelfRequester()
    let shelf = SavedShelfAutoDownload(
      store: FakeSavedShelfStoring(),
      targets: StubDownloadTargets([], shouldFail: true),
      requesting: requester,
      preferences: FixedSavedShelfAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    #expect(try await shelf.save(.item(itemID: "book-1")) == .saved)
    #expect(await requester.requests.isEmpty)
  }

  @Test("an identity that resolves to nothing downloadable requests nothing")
  func unsupportedDocumentRequestsNothing() async throws {
    let requester = RecordingSavedShelfRequester()
    let shelf = SavedShelfAutoDownload(
      store: FakeSavedShelfStoring(),
      targets: StubDownloadTargets([]),
      requesting: requester,
      preferences: FixedSavedShelfAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    #expect(try await shelf.save(.item(itemID: "document-1")) == .saved)
    #expect(await requester.requests.isEmpty)
  }

  @Test("the media resolution is asked about the identity that was saved")
  func targetsAreResolvedForTheSavedIdentity() async throws {
    let targets = StubDownloadTargets([.episode(itemID: "show-1", episodeID: "episode-1")])
    let shelf = SavedShelfAutoDownload(
      store: FakeSavedShelfStoring(),
      targets: targets,
      requesting: RecordingSavedShelfRequester(),
      preferences: FixedSavedShelfAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    _ = try await shelf.save(.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))

    #expect(
      await targets.requested == [.podcastEpisode(itemID: "show-1", episodeID: "episode-1")])
  }
}

private struct FixedSavedShelfAutoDownloadPolicy: SavedShelfAutoDownloadPolicyProviding {
  let savedShelfAutoDownloadPolicy: SavedShelfAutoDownloadPolicy

  init(_ policy: SavedShelfAutoDownloadPolicy) {
    savedShelfAutoDownloadPolicy = policy
  }
}

private actor StubDownloadTargets: SavedShelfDownloadTargetReading {
  struct ReadFailure: Error {}

  private let targets: [SavedShelfDownloadTarget]
  private let shouldFail: Bool
  private(set) var requested: [SavedShelfIdentity] = []

  init(_ targets: [SavedShelfDownloadTarget], shouldFail: Bool = false) {
    self.targets = targets
    self.shouldFail = shouldFail
  }

  func downloadTargets(for identity: SavedShelfIdentity) async throws -> [SavedShelfDownloadTarget] {
    requested.append(identity)
    if shouldFail { throw ReadFailure() }
    return targets
  }
}

private actor RecordingSavedShelfRequester: SavedShelfAutoDownloadRequesting {
  enum Request: Equatable, Hashable, Sendable {
    case item(itemID: String)
    case ebook(itemID: String)
    case episode(itemID: String, episodeID: String)
  }

  struct RequestFailure: Error {}

  private(set) var requests: [Request] = []
  private let failing: Set<Request>

  init(failing: [Request] = []) {
    self.failing = Set(failing)
  }

  func requestDownload(itemID: String) async throws {
    try record(.item(itemID: itemID))
  }

  func requestEbookDownload(itemID: String) async throws {
    try record(.ebook(itemID: itemID))
  }

  func requestEpisodeDownload(itemID: String, episodeID: String) async throws {
    try record(.episode(itemID: itemID, episodeID: episodeID))
  }

  private func record(_ request: Request) throws {
    requests.append(request)
    if failing.contains(request) { throw RequestFailure() }
  }
}
