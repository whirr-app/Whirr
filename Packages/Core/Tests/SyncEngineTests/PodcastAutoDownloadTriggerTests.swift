import Foundation
import GRDB
import TestSupport
import Testing

@testable import ABSApi
@testable import Persistence
@testable import SyncEngine

/// The call sites: `SyncEngine`'s recent-episodes shelf commit, `PodcastRefreshCoordinator`'s
/// selected-show commit, and `PlaybackSessionCoordinator`'s playback-completion reap-only hook.
/// The coordinator and reaper prove their own gates, budgets and single-flight in
/// `PodcastAutoDownloadTests`/`PodcastAutoDownloadReapTests`; this suite proves the wiring: which
/// trigger fires which pass, only on a successful commit, and that two origins sharing one
/// coordinator coalesce into one reconciliation. Background tests live in
/// `App/WhirrTests/PodcastBackgroundRefreshTests.swift` (`PodcastBackgroundRefreshHardware` is an
/// App-target type).
@Suite("Podcast auto-download trigger wiring")
struct PodcastAutoDownloadTriggerTests {

  // MARK: - Recent-episodes shelf commit (SyncEngine.swift)

  @Test("a successful recent-episode shelf commit triggers exactly one pass, then a reap")
  func recentEpisodeCommitTriggersOnePass() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "show-1", episodeID: "ep-1")
    ])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let reapProvider = FakePodcastAutoDownloadReapCandidateProviding()
    let purging = FakePodcastAutoDownloadPurging()
    let harness = try await SyncEngineHarness(
      podcastAutoDownload: Self.makeCoordinator(selecting: selecting, planner: planner),
      podcastAutoDownloadReaper: PodcastAutoDownloadReaper(
        reapCandidateProvider: reapProvider, purging: purging))
    harness.enqueueSuccessfulRefresh(showID: "show-1", episodeID: "ep-1")

    await harness.syncEngine.refresh()

    #expect(await selecting.fetchCallCount == 1)
    #expect(await reapProvider.callCount == 1)
  }

  @Test("steady state - a shelf commit with nothing new enqueues nothing")
  func steadyStateWithNothingNewEnqueuesNothing() async throws {
    // Every episode the shelf carries is already decided, so the selection store offers zero
    // candidates. The pass still runs (reconciliation is unconditional on a successful commit)
    // but has nothing to enqueue.
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let reapProvider = FakePodcastAutoDownloadReapCandidateProviding()
    let purging = FakePodcastAutoDownloadPurging()
    let harness = try await SyncEngineHarness(
      podcastAutoDownload: Self.makeCoordinator(selecting: selecting, planner: planner),
      podcastAutoDownloadReaper: PodcastAutoDownloadReaper(
        reapCandidateProvider: reapProvider, purging: purging))
    harness.enqueueSuccessfulRefresh(showID: "show-1", episodeID: "ep-1")

    await harness.syncEngine.refresh()

    #expect(await selecting.fetchCallCount == 1, "the pass still runs")
    #expect(await planner.requests.isEmpty, "nothing new means nothing enqueued")
  }

  // MARK: - Selected-show refresh commit (PodcastRefreshCoordinator.swift)

  @Test("a successful selected-show refresh commit triggers exactly one pass, then a reap")
  func selectedShowCommitTriggersOnePass() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "show-1", episodeID: "ep-1")
    ])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let reapProvider = FakePodcastAutoDownloadReapCandidateProviding()
    let purging = FakePodcastAutoDownloadPurging()
    let harness = try ShowRefreshHarness(
      podcastAutoDownload: Self.makeCoordinator(selecting: selecting, planner: planner),
      podcastAutoDownloadReaper: PodcastAutoDownloadReaper(
        reapCandidateProvider: reapProvider, purging: purging))
    harness.enqueueExpandedShow(itemID: "show-1")

    _ = try await harness.coordinator.refresh(itemID: "show-1")

    #expect(await selecting.fetchCallCount == 1)
    #expect(await reapProvider.callCount == 1)
  }

  // MARK: - A failed/rolled-back commit never triggers

  @Test("a failed or rolled-back episode write never triggers a pass")
  func failedOrRolledBackEpisodeWriteDoesNotTrigger() async throws {
    // Scenario 1: the selected-show commit's own persistence write throws.
    do {
      let selecting = FakePodcastAutoDownloadSelecting(candidates: [
        Self.candidate(itemID: "show-1", episodeID: "ep-1")
      ])
      let planner = FakeAutomaticEpisodeDownloadPlanning()
      let persistence = FakeThrowingPodcastRefreshApplying()
      let harness = try ShowRefreshHarness(
        podcastAutoDownload: Self.makeCoordinator(selecting: selecting, planner: planner),
        podcastAutoDownloadReaper: PodcastAutoDownloadReaper(
          reapCandidateProvider: FakePodcastAutoDownloadReapCandidateProviding(),
          purging: FakePodcastAutoDownloadPurging()),
        persistence: persistence)
      harness.enqueueExpandedShow(itemID: "show-1")

      await #expect(throws: (any Error).self) {
        _ = try await harness.coordinator.refresh(itemID: "show-1")
      }

      #expect(await selecting.fetchCallCount == 0, "a rolled-back show refresh must never trigger")
    }

    // Scenario 2: the recent-episode shelf commit's own persistence write throws. Dropping the
    // `podcastEpisode` table forces a genuine SQL failure; a per-library fetch failure is
    // absorbed and must not count as failed.
    do {
      let selecting = FakePodcastAutoDownloadSelecting(candidates: [
        Self.candidate(itemID: "show-1", episodeID: "ep-1")
      ])
      let planner = FakeAutomaticEpisodeDownloadPlanning()
      let harness = try await SyncEngineHarness(
        podcastAutoDownload: Self.makeCoordinator(selecting: selecting, planner: planner),
        podcastAutoDownloadReaper: PodcastAutoDownloadReaper(
          reapCandidateProvider: FakePodcastAutoDownloadReapCandidateProviding(),
          purging: FakePodcastAutoDownloadPurging()))
      try await harness.database.writeAsync { db in try db.execute(sql: "DROP TABLE podcastEpisode") }
      harness.enqueueSuccessfulRefresh(showID: "show-1", episodeID: "ep-1")

      await harness.syncEngine.refresh()

      #expect(await selecting.fetchCallCount == 0, "a rolled-back shelf commit must never trigger")
    }
  }

  // MARK: - Coalescing across the two different trigger origins

  @Test("two different trigger origins sharing one coordinator instance still coalesce")
  func coalescedRefreshRunsOneReconciliation() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "show-1", episodeID: "ep-1")
    ])
    let gate = PlannerGate()
    let planner = FakeAutomaticEpisodeDownloadPlanning(gate: gate)
    let sharedCoordinator = Self.makeCoordinator(selecting: selecting, planner: planner)
    let sharedReaper = PodcastAutoDownloadReaper(
      reapCandidateProvider: FakePodcastAutoDownloadReapCandidateProviding(),
      purging: FakePodcastAutoDownloadPurging())

    let syncEngineHarness = try await SyncEngineHarness(
      podcastAutoDownload: sharedCoordinator, podcastAutoDownloadReaper: sharedReaper)
    syncEngineHarness.enqueueSuccessfulRefresh(showID: "show-1", episodeID: "ep-1")
    let showHarness = try ShowRefreshHarness(
      podcastAutoDownload: sharedCoordinator, podcastAutoDownloadReaper: sharedReaper)
    showHarness.enqueueExpandedShow(itemID: "show-1")

    let submissions = TestCountRecorder(label: "auto-download trigger submissions")
    let recentEpisodeTrigger = Task {
      submissions.record()
      await syncEngineHarness.syncEngine.refresh()
    }
    await gate.waitUntilStarted(episodeID: "ep-1")

    let showTrigger = Task {
      submissions.record()
      return try await showHarness.coordinator.refresh(itemID: "show-1")
    }
    await submissions.waitUntil(count: 2)
    // Both triggers must reach the coordinator before the first pass may finish, or the release
    // wins the race, the flight clears and the show trigger starts a second pass. The submission
    // recorder and HTTP traffic fire before the DB commit preceding `run`, so only the join count
    // proves it.
    #expect(await TestSupport.waitUntil { await sharedCoordinator.joinedFlightCount == 1 })

    await gate.release(episodeID: "ep-1")
    _ = await recentEpisodeTrigger.value
    _ = try await showTrigger.value

    #expect(await selecting.fetchCallCount == 1)
    #expect(await planner.requests.count == 1)
  }

  // MARK: - Reap runs after every pass, and after playback completion

  @Test("reap runs after every pass, and after playback completion - never a download pass")
  func reapRunsAfterEveryPassAndAfterPlaybackCompletion() async throws {
    // After a pass (the recent-episode commit stands in for the selected-show commit, whose
    // identical `run` → `reap` ordering is proven above).
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let reapProvider = FakePodcastAutoDownloadReapCandidateProviding()
    let purging = FakePodcastAutoDownloadPurging()
    let harness = try await SyncEngineHarness(
      podcastAutoDownload: Self.makeCoordinator(selecting: selecting, planner: planner),
      podcastAutoDownloadReaper: PodcastAutoDownloadReaper(
        reapCandidateProvider: reapProvider, purging: purging))
    harness.enqueueSuccessfulRefresh(showID: "show-1", episodeID: "ep-1")

    await harness.syncEngine.refresh()

    #expect(await reapProvider.callCount == 1, "a reap follows every pass")

    // After playback completion, a podcast episode's not-finished→finished transition reaps and
    // nothing else: `PlaybackSessionCoordinator` holds only a plain reap closure, so no download
    // pass is reachable from this hook.
    let reapCalls = CallCounter()
    let playback = try Self.makePlaybackCoordinator(requestPodcastAutoDownloadReap: {
      await reapCalls.increment()
    })

    await playback.recordProgressTick(
      itemID: "item-1", episodeID: "ep-1", currentTime: 590, listenedDelta: 5, isFinished: false,
      isSeek: false)
    #expect(await reapCalls.count == 0, "not finished yet")

    await playback.recordProgressTick(
      itemID: "item-1", episodeID: "ep-1", currentTime: 600, listenedDelta: 10, isFinished: true,
      isSeek: false)
    #expect(await reapCalls.count == 1, "the finished transition reaps exactly once")

    // A repeat "still finished" tick (e.g. the player reporting position at the very end again)
    // must not reap a second time.
    await playback.recordProgressTick(
      itemID: "item-1", episodeID: "ep-1", currentTime: 600, listenedDelta: 0, isFinished: true,
      isSeek: false)
    #expect(await reapCalls.count == 1, "an already-finished stream's later ticks never reap again")

    // A book (no episode) finishing must never reap: the feature is podcast-episode-only.
    await playback.recordProgressTick(
      itemID: "item-2", episodeID: nil, currentTime: 100, listenedDelta: 100, isFinished: true,
      isSeek: false)
    #expect(await reapCalls.count == 1, "a book's completion is out of scope for auto-download reap")
  }

  @Test("delete when finished removes both a completed book and the completed podcast episode")
  func deleteWhenFinishedCoversBooksAndPodcastEpisodes() async throws {
    let preferences = FakeDownloadPreferences(deleteWhenFinished: true)
    let deletions = FinishedDownloadDeletionRecorder()
    let playback = try Self.makePlaybackCoordinator(
      downloadPreferences: preferences,
      requestFinishedDownloadDeletion: { itemID, episodeID in
        await deletions.record(itemID: itemID, episodeID: episodeID)
      })

    // Each stream is driven through a genuine not-finished → finished transition. A single
    // already-finished tick is not enough (see the test below).
    await playback.recordProgressTick(
      itemID: "book-1", episodeID: nil, currentTime: 90, listenedDelta: 90, isFinished: false,
      isSeek: false)
    await playback.recordProgressTick(
      itemID: "book-1", episodeID: nil, currentTime: 100, listenedDelta: 100, isFinished: true,
      isSeek: false)
    await playback.recordProgressTick(
      itemID: "show-1", episodeID: "episode-1", currentTime: 590, listenedDelta: 590,
      isFinished: false, isSeek: false)
    await playback.recordProgressTick(
      itemID: "show-1", episodeID: "episode-1", currentTime: 600, listenedDelta: 600,
      isFinished: true, isSeek: false)

    #expect(
      await deletions.values
        == [
          FinishedDownloadIdentity(itemID: "book-1", episodeID: nil),
          FinishedDownloadIdentity(itemID: "show-1", episodeID: "episode-1"),
        ])
  }

  /// `previousFinishedForThisStream` is `nil` for a fresh stream. Auto-delete must not read that
  /// as "was not finished before", or an already-finished book deletes the transfer it is still
  /// fetching on its first tick. Only a witnessed transition may delete a download; the reap keeps
  /// its own nil-tolerant rule.
  @Test("a fresh stream that already reports finished never deletes its download")
  func deleteWhenFinishedIgnoresAnAlreadyFinishedFreshStream() async throws {
    let deletions = FinishedDownloadDeletionRecorder()
    let reapCalls = CallCounter()
    let playback = try Self.makePlaybackCoordinator(
      requestPodcastAutoDownloadReap: { await reapCalls.increment() },
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: true),
      requestFinishedDownloadDeletion: { itemID, episodeID in
        await deletions.record(itemID: itemID, episodeID: episodeID)
      })

    await playback.recordProgressTick(
      itemID: "book-1", episodeID: nil, currentTime: 100, listenedDelta: 0, isFinished: true,
      isSeek: false)
    await playback.recordProgressTick(
      itemID: "show-1", episodeID: "episode-1", currentTime: 600, listenedDelta: 0,
      isFinished: true, isSeek: false)

    #expect(await deletions.values.isEmpty)
    #expect(
      await reapCalls.count == 1,
      "the reap still fires for a fresh already-finished episode stream")
  }

  @Test("delete when finished stays inert while its setting is off")
  func deleteWhenFinishedDefaultsOff() async throws {
    let deletions = FinishedDownloadDeletionRecorder()
    let playback = try Self.makePlaybackCoordinator(
      downloadPreferences: FakeDownloadPreferences(),
      requestFinishedDownloadDeletion: { itemID, episodeID in
        await deletions.record(itemID: itemID, episodeID: episodeID)
      })

    await playback.recordProgressTick(
      itemID: "book-1", episodeID: nil, currentTime: 100, listenedDelta: 100, isFinished: true,
      isSeek: false)

    #expect(await deletions.values.isEmpty)
  }

  @Test("the shared planner gate holds a call until its episode is released")
  func sharedPlannerGateHoldsCallUntilReleased() async {
    let gate = PlannerGate()
    let completions = CallCounter()
    let task = Task {
      await gate.waitForRelease(episodeID: "ep-1")
      await completions.increment()
    }

    await gate.waitUntilStarted(episodeID: "ep-1")
    #expect(await gate.isWaitingForRelease(episodeID: "ep-1"))
    #expect(await completions.count == 0)

    await gate.release(episodeID: "ep-1")
    await task.value
    #expect(await completions.count == 1)
  }

  // MARK: - Fixtures

  private static func candidate(itemID: String, episodeID: String) -> PodcastAutoDownloadCandidate {
    PodcastAutoDownloadCandidate(
      itemID: itemID, episodeID: episodeID,
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private static func makeCoordinator(
    selecting: any PodcastAutoDownloadSelecting,
    planner: any AutomaticEpisodeDownloadPlanning
  ) -> PodcastAutoDownloadCoordinator {
    let lifecycle = FakeAccountLifecycle()
    lifecycle.isAuthenticated = true
    return PodcastAutoDownloadCoordinator(
      selecting: selecting,
      planner: planner,
      accountLifecycle: lifecycle,
      networkConditions: FakeNetworkConditions(),
      podcastSettingsReading: FakePodcastSettingsReading(global: .defaults),
      accountId: 1)
  }

  private static func makePlaybackCoordinator(
    requestPodcastAutoDownloadReap: @escaping @Sendable () async -> Void = {},
    downloadPreferences: any DownloadPreferences = NoOpDownloadPreferences(),
    requestFinishedDownloadDeletion: @escaping @Sendable (String, String?) async -> Void = { _, _ in }
  ) throws -> PlaybackSessionCoordinator {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://playback.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: tokenStore)
    let database = try AppDatabase.inMemory()
    let outbox = try OutboxStore(database: database)
    return PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox,
      requestPodcastAutoDownloadReap: requestPodcastAutoDownloadReap,
      downloadPreferences: downloadPreferences,
      requestFinishedDownloadDeletion: requestFinishedDownloadDeletion)
  }
}

private struct FinishedDownloadIdentity: Sendable, Equatable {
  let itemID: String
  let episodeID: String?
}

private actor FinishedDownloadDeletionRecorder {
  private(set) var values: [FinishedDownloadIdentity] = []

  func record(itemID: String, episodeID: String?) {
    values.append(FinishedDownloadIdentity(itemID: itemID, episodeID: episodeID))
  }
}

// MARK: - SyncEngine harness (recent-episode shelf commit)

private final class SyncEngineHarness: @unchecked Sendable {
  let database: AppDatabase
  let http: FakeHTTPClient
  let syncEngine: SyncEngine
  private var libraryID: Int64 = 0
  private var accountID: Int64 = 0

  init(
    podcastAutoDownload: PodcastAutoDownloadCoordinator?,
    podcastAutoDownloadReaper: PodcastAutoDownloadReaper?
  ) async throws {
    database = try AppDatabase.inMemory()
    let server = try ABSServerConfig(url: try #require(URL(string: "https://trigger.example.test")))
    let clientUUID = "trigger-client"
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
    let fake = FakeHTTPClient()
    http = fake
    let client = ABSClient(server: server, httpClient: fake, tokenStore: tokenStore)
    let recentEpisodes = RecentEpisodeRefreshCoordinator(database: database, client: client)
    syncEngine = SyncEngine.make(
      client: client,
      database: database,
      diagnostics: FakeDiagnosticsRecording(),
      appLifecycle: FakeAppLifecycle(),
      clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
      recentEpisodes: recentEpisodes,
      podcastAutoDownload: podcastAutoDownload,
      podcastAutoDownloadReaper: podcastAutoDownloadReaper)

    let ids = try await database.writeAsync { db -> (Int64, Int64) in
      var accountRecord = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture", serverVersion: "2.35.1")
      try accountRecord.insert(db)
      var libraryRecord = LibraryRecord(
        accountId: accountRecord.id!, serverLibraryId: "podcasts", mediaType: "podcast",
        name: "Podcasts")
      try libraryRecord.insert(db)
      return (accountRecord.id!, libraryRecord.id!)
    }
    accountID = ids.0
    libraryID = ids.1
  }

  func enqueueSuccessfulRefresh(showID: String, episodeID: String) {
    http.enqueue(Self.librariesResponse())
    http.enqueue(Self.emptyProgressResponse())
    http.enqueue(Self.podcastPageResponse(showID: showID))
    http.enqueue(Self.shelfResponse(showID: showID, episodeID: episodeID))
  }

  private static func librariesResponse() -> HTTPResponse {
    Self.jsonResponse([
      "libraries": [["id": "podcasts", "name": "Podcasts", "mediaType": "podcast"]]
    ])
  }

  private static func emptyProgressResponse() -> HTTPResponse {
    Self.jsonResponse(["mediaProgresses": [] as [Any]])
  }

  private static func podcastPageResponse(showID: String) -> HTTPResponse {
    Self.jsonResponse([
      "results": [
        [
          "id": showID, "libraryId": "podcasts", "mediaType": "podcast",
          "media": ["metadata": ["title": "A Show"]],
        ]
      ],
      "total": 1,
      "limit": 100,
      "page": 0,
    ])
  }

  private static func shelfResponse(showID: String, episodeID: String) -> HTTPResponse {
    Self.jsonResponse([
      "episodes": [
        [
          "id": episodeID,
          "libraryItemId": showID,
          "title": "An Episode",
          "publishedAt": 1_785_107_100_000,
          "duration": 1_200.0,
          "podcast": ["metadata": ["title": "A Show", "author": "A Host"]],
        ]
      ]
    ])
  }

  private static func jsonResponse(_ object: [String: Any]) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}

// MARK: - Selected-show refresh harness (PodcastRefreshCoordinator.swift)

private final class ShowRefreshHarness: @unchecked Sendable {
  let http: FakeHTTPClient
  let coordinator: PodcastRefreshCoordinator

  init(
    podcastAutoDownload: PodcastAutoDownloadCoordinator?,
    podcastAutoDownloadReaper: PodcastAutoDownloadReaper?,
    persistence: any PodcastRefreshApplying = FakeSucceedingPodcastRefreshApplying()
  ) throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://show.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
    let fake = FakeHTTPClient()
    http = fake
    let client = ABSClient(server: server, httpClient: fake, tokenStore: tokenStore)
    coordinator = PodcastRefreshCoordinator(
      client: client,
      persistence: persistence,
      resolveContext: { [account] itemID in
        PodcastRefreshContext(accountID: 1, localItemID: 11, tokenAccount: account)
      },
      podcastAutoDownload: podcastAutoDownload,
      podcastAutoDownloadReaper: podcastAutoDownloadReaper)
  }

  /// One expanded-item response, then one (empty) `/api/me` progress response: the two requests
  /// `refresh(itemID:)`'s no-args overload issues when not handed prefetched data.
  func enqueueExpandedShow(itemID: String) {
    http.enqueue(Self.expandedItemResponse(itemID: itemID))
    http.enqueue(
      HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: ["mediaProgresses": [] as [Any]])))
  }

  private static func expandedItemResponse(itemID: String) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: [
        "id": itemID, "libraryId": "podcasts", "mediaType": "podcast",
        "media": [
          "metadata": ["title": "A Show", "author": "An Author"],
          "episodes": [["id": "\(itemID)-episode", "title": "An Episode"]],
        ],
      ]))
  }
}

// MARK: - Fakes

private actor FakeSucceedingPodcastRefreshApplying: PodcastRefreshApplying {
  func applyPodcastRefresh(
    _ refresh: PodcastRefresh, decideProgress: @escaping PodcastProgressMergeDecider
  ) async throws {}
}

private enum FakeThrowingPodcastRefreshApplyingError: Error { case rolledBack }

private actor FakeThrowingPodcastRefreshApplying: PodcastRefreshApplying {
  func applyPodcastRefresh(
    _ refresh: PodcastRefresh, decideProgress: @escaping PodcastProgressMergeDecider
  ) async throws {
    throw FakeThrowingPodcastRefreshApplyingError.rolledBack
  }
}

private actor CallCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}
