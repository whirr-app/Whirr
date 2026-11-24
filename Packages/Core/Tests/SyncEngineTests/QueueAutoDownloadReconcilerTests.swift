import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite("Queue auto-download reconciler", .timeLimit(.minutes(1)))
struct QueueAutoDownloadReconcilerTests {

  @Test("requests only the identities supplied as missing-download candidates")
  func requestsMissingCandidates() async throws {
    let candidates = [
      try #require(ListeningIdentity.audiobook(itemID: "book-1")),
      try #require(
        ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1")),
    ]
    let provider = RecordingCandidateProvider(candidates: candidates)
    let requester = RecordingDownloadRequester()
    let reconciler = QueueAutoDownloadReconciler(
      candidateProvider: provider, requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    await reconciler.run()

    #expect(await provider.callCount == 1)
    #expect(
      await requester.requests == [
        .item(itemID: "book-1"), .episode(itemID: "show-1", episodeID: "episode-1"),
      ])
  }

  @Test("the reconciler requests missing RSS episode downloads")
  func requestsMissingRSSEpisodeCandidate() async throws {
    let identity = try #require(
      ListeningIdentity.rssEpisode(feedID: 7, episodeID: "episode-1"))
    let provider = RecordingCandidateProvider(
      candidates: [identity])
    let requester = RecordingDownloadRequester()
    let reconciler = QueueAutoDownloadReconciler(
      candidateProvider: provider, requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    await reconciler.run()

    #expect(
      await requester.requests == [
        .episode(itemID: "rss:7", episodeID: "episode-1")
      ])
  }

  @Test("never does not query or request")
  func neverSkipsThePass() async throws {
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let provider = RecordingCandidateProvider(
      candidates: [identity])
    let requester = RecordingDownloadRequester()
    let reconciler = QueueAutoDownloadReconciler(
      candidateProvider: provider, requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.never),
      networkConditions: FakeNetworkConditions())

    await reconciler.run()

    #expect(await provider.callCount == 0)
    #expect(await requester.requests.isEmpty)
  }

  @Test("a candidate declined after the fetch is not requested")
  func declinedCandidateIsSkippedAtRequestTime() async throws {
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))
    let provider = RecordingCandidateProvider(candidates: [book, episode])
    let requester = RecordingDownloadRequester()
    let declines = FakeQueueDownloadDeclines(declined: [book])
    let reconciler = QueueAutoDownloadReconciler(
      candidateProvider: provider, requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions(), declines: declines)

    await reconciler.run()

    #expect(await requester.requests == [.episode(itemID: "show-1", episodeID: "episode-1")])
  }

  @Test("concurrent runs coalesce onto one in-flight pass")
  func concurrentRunsCoalesce() async throws {
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let provider = BlockingCandidateProvider(candidates: [identity])
    let requester = RecordingDownloadRequester()
    let reconciler = QueueAutoDownloadReconciler(
      candidateProvider: provider, requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions())

    let first = Task { await reconciler.run() }
    #expect(await TestSupport.waitUntil { await provider.callCount == 1 })

    let second = Task { await reconciler.run() }
    #expect(await TestSupport.waitUntil { await reconciler.joinedFlightCount == 1 })
    await provider.release()

    await first.value
    await second.value

    #expect(await provider.callCount == 1)
    #expect(await requester.requests == [.item(itemID: "book-1")])
  }

  /// A failed candidate read is a completed pass, not a stuck flight: the next trigger must start
  /// its own pass rather than joining one that will never settle.
  @Test("a failed candidate read is recorded and leaves the flight free for the next run")
  func failedCandidateReadIsRecordedAndSettlesTheFlight() async throws {
    let requester = RecordingDownloadRequester()
    let diagnostics = FakeDiagnosticsRecording()
    let reconciler = QueueAutoDownloadReconciler(
      candidateProvider: FailingCandidateProvider(),
      requesting: requester,
      preferences: FixedQueueAutoDownloadPolicy(.always),
      networkConditions: FakeNetworkConditions(),
      diagnostics: diagnostics,
      accountId: 1)

    await reconciler.run()
    await reconciler.run()

    #expect(await requester.requests.isEmpty)
    #expect(diagnostics.recorded.map(\.statusClass) == [.clientError, .clientError])
    #expect(await reconciler.joinedFlightCount == 0, "each run started its own pass")
  }
}

private actor FailingCandidateProvider: ListeningQueueDownloadCandidateReading {
  func fetchQueueIdentitiesWithoutDownloads() async throws -> [ListeningIdentity] {
    throw URLError(.unknown)
  }
}

private struct FixedQueueAutoDownloadPolicy: QueueAutoDownloadPolicyProviding {
  let queueAutoDownloadPolicy: QueueAutoDownloadPolicy

  init(_ policy: QueueAutoDownloadPolicy) {
    queueAutoDownloadPolicy = policy
  }
}

private actor RecordingCandidateProvider: ListeningQueueDownloadCandidateReading {
  private let candidates: [ListeningIdentity]
  private(set) var callCount = 0

  init(candidates: [ListeningIdentity]) {
    self.candidates = candidates
  }

  func fetchQueueIdentitiesWithoutDownloads() async throws -> [ListeningIdentity] {
    callCount += 1
    return candidates
  }
}

private actor BlockingCandidateProvider: ListeningQueueDownloadCandidateReading {
  private let candidates: [ListeningIdentity]
  private(set) var callCount = 0
  // Stays parked on task cancellation, as the fetch it stands in for runs to completion.
  private nonisolated let gate = TestGate<Void>(
    label: "BlockingCandidateProvider fetch", ignoresCancellation: true)

  init(candidates: [ListeningIdentity]) {
    self.candidates = candidates
    gate.hold()
  }

  func fetchQueueIdentitiesWithoutDownloads() async throws -> [ListeningIdentity] {
    callCount += 1
    await gate.pass()
    return candidates
  }

  func release() {
    gate.release()
  }
}
