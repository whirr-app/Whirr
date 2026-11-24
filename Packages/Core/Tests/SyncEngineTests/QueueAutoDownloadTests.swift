import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite("Queue auto-download")
struct QueueAutoDownloadTests {

  @Test("the policy is Codable and defaults to never")
  func policyDefaultsToNeverAndRoundTrips() throws {
    #expect(QueueAutoDownloadPolicy() == .never)
    #expect(QueueAutoDownloadPolicy.never.rawValue == "never")
    #expect(QueueAutoDownloadPolicy.wifiOnly.rawValue == "wifiOnly")
    #expect(QueueAutoDownloadPolicy.always.rawValue == "always")

    let data = try JSONEncoder().encode(QueueAutoDownloadPolicy.wifiOnly)
    #expect(try JSONDecoder().decode(QueueAutoDownloadPolicy.self, from: data) == .wifiOnly)
  }

  @Test("each policy gates an audiobook request on cellular and Wi-Fi")
  func policyGatesAdmission() async throws {
    let cases: [(QueueAutoDownloadPolicy, Bool, Bool)] = [
      (.never, false, false),
      (.never, true, false),
      (.wifiOnly, false, true),
      (.wifiOnly, true, false),
      (.always, false, true),
      (.always, true, true),
    ]

    for (policy, cellular, shouldRequest) in cases {
      let requester = RecordingDownloadRequester()
      let network = FakeNetworkConditions()
      network.isConstrainedOrCellular = cellular
      let queue = QueueAutoDownload(
        store: FakeListeningQueueStoring(), requesting: requester,
        preferences: FixedQueueAutoDownloadPolicy(policy), networkConditions: network)

      let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
      #expect(try await queue.append(identity: identity) == .appended)
      #expect(await requester.requests.isEmpty == !shouldRequest)
      #expect(await requester.requests.count == (shouldRequest ? 1 : 0))
    }
  }

  @Test("append, insert-next, and restore follow their exact trigger rules")
  func mutationTriggerRules() async throws {
    let requester = RecordingDownloadRequester()
    let underlying = FakeListeningQueueStoring(appendOutcome: .appended)
    let network = FakeNetworkConditions()
    let queue = QueueAutoDownload(
      store: underlying, requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always), networkConditions: network)
    let audiobook = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))

    #expect(try await queue.append(identity: audiobook) == .appended)

    underlying.stubAppendOutcome(.alreadyQueued)
    #expect(try await queue.append(identity: audiobook) == .alreadyQueued)

    try await queue.insertNext(identity: episode)
    let token = try await NoOpListeningQueueStore().clear()
    try await queue.restore(token: token)

    #expect(
      await requester.requests == [
        .item(itemID: "book-1"), .episode(itemID: "show-1", episodeID: "episode-1"),
      ])
  }

  @Test("a chapter is forwarded to the store and its download is the whole book")
  func chapterRowsRequestTheWholeBook() async throws {
    let requester = RecordingDownloadRequester()
    let underlying = FakeListeningQueueStoring(appendOutcome: .replaced)
    let queue = QueueAutoDownload(
      store: underlying, requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())
    let audiobook = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let chapter = ListeningQueueChapter(start: 600, end: 900, title: "Three")

    // Replacing a row's chapter can be the first request for a book queued under `never`.
    #expect(try await queue.append(identity: audiobook, chapter: chapter) == .replaced)
    try await queue.insertNext(identity: audiobook, chapter: chapter)

    #expect(
      underlying.calls == [
        .append(audiobook, chapter: chapter), .insertNext(audiobook, chapter: chapter),
      ])
    #expect(await requester.requests == [.item(itemID: "book-1"), .item(itemID: "book-1")])
  }

  @Test("Play Next and a chapter change leave a declined entry alone; a new entry still requests")
  func declinedEntriesAreNotRequestedByQueueActions() async throws {
    let requester = RecordingDownloadRequester()
    let underlying = FakeListeningQueueStoring(appendOutcome: .replaced)
    let declined = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let fresh = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    let queue = QueueAutoDownload(
      store: underlying, requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions(),
      declines: FakeQueueDownloadDeclines(declined: [declined]))
    let chapter = ListeningQueueChapter(start: 0, end: 60, title: "One")

    #expect(try await queue.append(identity: declined, chapter: chapter) == .replaced)
    try await queue.insertNext(identity: declined)
    _ = try await queue.insertNext(identities: [declined, fresh])

    #expect(await requester.requests == [.item(itemID: "book-2")])
  }

  @Test("a download request failure never fails a committed append")
  func requestFailureDoesNotFailQueueMutation() async throws {
    let requester = RecordingDownloadRequester(shouldFail: true)
    let queue = QueueAutoDownload(
      store: FakeListeningQueueStoring(), requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let outcome = try await queue.append(identity: identity)

    #expect(outcome == .appended)
    #expect(await requester.requests == [.item(itemID: "book-1")])
  }

  @Test("audiobook and podcast episode identities use their matching request methods")
  func identityRouting() async throws {
    let requester = RecordingDownloadRequester()
    let queue = QueueAutoDownload(
      store: FakeListeningQueueStoring(), requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    let audiobook = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))
    _ = try await queue.append(identity: audiobook)
    try await queue.insertNext(identity: episode)

    #expect(
      await requester.requests == [
        .item(itemID: "book-1"), .episode(itemID: "show-1", episodeID: "episode-1"),
      ])
  }

  @Test("a batch insert-next requests a download for each inserted identity and not the skipped")
  func batchInsertNextRequestsOnlyInsertedIdentities() async throws {
    let requester = RecordingDownloadRequester()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let skipped = try #require(ListeningIdentity.audiobook(itemID: "ebook-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))
    let underlying = FakeListeningQueueStoring(batchSkipped: [skipped])
    let queue = QueueAutoDownload(
      store: underlying, requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    let result = try await queue.insertNext(identities: [book, skipped, episode, book])

    #expect(result == [skipped])
    #expect(underlying.calls == [.insertNextBatch([book, skipped, episode, book])])
    #expect(
      await requester.requests == [
        .item(itemID: "book-1"), .episode(itemID: "show-1", episodeID: "episode-1"),
      ])
  }

  @Test("a swap requests the returned title's download and not the started one's")
  func swapRequestsOnlyTheReturnedTitle() async throws {
    let requester = RecordingDownloadRequester()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))
    let underlying = FakeListeningQueueStoring()
    let queue = QueueAutoDownload(
      store: underlying, requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    #expect(try await queue.acknowledgeStarted(identity: episode, rowID: nil, returning: book))

    #expect(underlying.calls == [.swapStarted(episode, returning: book)])
    #expect(await requester.requests == [.item(itemID: "book-1")])
  }

  @Test("a batch insert-next requests nothing when the policy is never")
  func batchInsertNextHonoursPolicy() async throws {
    let requester = RecordingDownloadRequester()
    let queue = QueueAutoDownload(
      store: FakeListeningQueueStoring(), requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.never),
      networkConditions: FakeNetworkConditions())
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    #expect(try await queue.insertNext(identities: [book]).isEmpty)
    #expect(await requester.requests.isEmpty)
  }

  @Test("an RSS episode queued under the policy uses the episode download request")
  func rssEpisodeIdentityRouting() async throws {
    let requester = RecordingDownloadRequester()
    let queue = QueueAutoDownload(
      store: FakeListeningQueueStoring(), requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    _ = try await queue.append(
      identity: try #require(
        ListeningIdentity.rssEpisode(feedID: 7, episodeID: "episode-1")))

    #expect(
      await requester.requests == [
        .episode(itemID: "rss:7", episodeID: "episode-1")
      ])
  }
}

private struct FixedQueueAutoDownloadPolicy: QueueAutoDownloadPolicyProviding {
  let queueAutoDownloadPolicy: QueueAutoDownloadPolicy

  init(_ policy: QueueAutoDownloadPolicy) {
    queueAutoDownloadPolicy = policy
  }
}
