import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

/// The two background-specific auto-download trigger tests.
///
/// `PodcastBackgroundRefreshHardware.handle()` resolves the account, keychain and on-disk
/// database directly (cold-launch safety), so these drive its extracted core,
/// `runBackgroundPass(shelfRefresh:podcastAutoDownload:podcastAutoDownloadReaper:)`. Here because
/// Core tests cannot reach this App type; other triggers are tested in Core.
@Suite("Podcast background refresh trigger wiring")
struct PodcastBackgroundRefreshTests {

  @Test("the RSS leg runs when there is no included ABS podcast shelf")
  func backgroundRSSLegIsIndependentOfABSPodcastLibraries() async {
    let rssRefresh = FakeBackgroundRSSFeedRefresh(
      result: .init(
        attemptedCount: 1, succeededCount: 1, failedCount: 0, hitFeedBudget: false))

    await PodcastBackgroundRefreshHardware.runBackgroundPass(
      shelfRefresh: {
        .init(writtenCount: 0, failedLibraryIDs: [], commitOutcome: .notCommitted)
      },
      podcastAutoDownload: nil,
      podcastAutoDownloadReaper: nil,
      rssFeedRefreshCoordinator: rssRefresh)

    #expect(await rssRefresh.triggers == [.background])
  }

  @Test("the RSS budget is strictly inside the unchanged whole-pass B9 ceiling")
  func backgroundRSSBudgetDoesNotWidenB9() {
    #expect(RSSFeedRefreshPassPolicy.background.maxFeedsPerPass < RSSFeedRefreshPassPolicy.foreground.maxFeedsPerPass)
    #expect(
      RSSFeedRefreshPassPolicy.background.maximumDuration < PodcastBackgroundRefreshHardware.backgroundPassTimeLimit)
    #expect(PodcastBackgroundRefreshHardware.backgroundPassTimeLimit == .seconds(25))
  }

  @Test("an overnight pass asks the RSS leg for its overnight budget and cancels that flight")
  func overnightPassUsesTheOvernightRSSTrigger() async {
    let rssRefresh = FakeBackgroundRSSFeedRefresh(suspendsUntilCancelled: true)

    await PodcastBackgroundRefreshHardware.runBackgroundPass(
      shelfRefresh: {
        .init(writtenCount: 0, failedLibraryIDs: [], commitOutcome: .notCommitted)
      },
      podcastAutoDownload: nil,
      podcastAutoDownloadReaper: nil,
      rssFeedRefreshCoordinator: rssRefresh,
      rssTrigger: .overnight,
      timeLimit: .milliseconds(20))

    #expect(await rssRefresh.triggers == [.overnight])
    #expect(await rssRefresh.cancellations == [.overnight])
  }

  @Test("the overnight RSS budget is strictly inside the overnight whole-pass limit")
  func overnightRSSBudgetFitsTheOvernightPass() {
    #expect(
      RSSFeedRefreshPassPolicy.overnight.maximumDuration
        < PodcastBackgroundRefreshHardware.overnightPassTimeLimit)
    #expect(
      PodcastBackgroundRefreshHardware.overnightPassTimeLimit
        > PodcastBackgroundRefreshHardware.backgroundPassTimeLimit)
  }

  @Test("waiting for the first path still leaves the app-refresh pass inside its ~30 s budget")
  func firstPathWaitFitsTheAppRefreshBudget() {
    #expect(
      PodcastBackgroundRefreshHardware.firstPathWait + PodcastBackgroundRefreshHardware.backgroundPassTimeLimit
        < .seconds(30))
  }

  @Test("the whole-pass deadline cooperatively cancels the RSS leg")
  func backgroundDeadlineCancelsRSSLeg() async {
    let rssRefresh = FakeBackgroundRSSFeedRefresh(suspendsUntilCancelled: true)

    await PodcastBackgroundRefreshHardware.runBackgroundPass(
      shelfRefresh: {
        .init(writtenCount: 0, failedLibraryIDs: [], commitOutcome: .notCommitted)
      },
      podcastAutoDownload: nil,
      podcastAutoDownloadReaper: nil,
      rssFeedRefreshCoordinator: rssRefresh,
      timeLimit: .milliseconds(20))

    #expect(await rssRefresh.cancellations == [.background])
  }

  @Test("the background pass enqueues through the coordinator without awaiting any transfer")
  func backgroundRefreshEnqueuesWithoutAwaitingTransfers() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      PodcastAutoDownloadCandidate(
        itemID: "show-1", episodeID: "ep-1", publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
    ])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let reapProvider = FakeReapCandidateProvider()
    let coordinator = Self.makeCoordinator(selecting: selecting, planner: planner)
    let reaper = PodcastAutoDownloadReaper(
      reapCandidateProvider: reapProvider, purging: FakePodcastAutoDownloadPurging())

    await PodcastBackgroundRefreshHardware.runBackgroundPass(
      shelfRefresh: { .init(writtenCount: 0, failedLibraryIDs: [], commitOutcome: .committed) },
      podcastAutoDownload: coordinator,
      podcastAutoDownloadReaper: reaper)

    // `PodcastAutoDownloadCoordinator.run` enqueues through `planner` and returns. This fake has no
    // transfer concept; it records the enqueue request and returns at once. So the pass completing,
    // followed by the reap, is what "enqueue only, never await a transfer" looks like from outside.
    #expect(await planner.requests.count == 1)
    #expect(await reapProvider.callCount == 1, "a reap follows the pass")
  }

  @Test("a shelf without a commit does not select or reap")
  func backgroundPassDoesNotActOnAnUncommittedShelf() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let coordinator = Self.makeCoordinator(selecting: selecting, planner: planner)
    let reapProvider = FakeReapCandidateProvider()
    let reaper = PodcastAutoDownloadReaper(
      reapCandidateProvider: reapProvider, purging: FakePodcastAutoDownloadPurging())

    await PodcastBackgroundRefreshHardware.runBackgroundPass(
      shelfRefresh: { .init(writtenCount: 0, failedLibraryIDs: [], commitOutcome: .notCommitted) },
      podcastAutoDownload: coordinator,
      podcastAutoDownloadReaper: reaper)

    #expect(await selecting.fetchCallCount == 0)
    #expect(await reapProvider.callCount == 0)
  }

  @Test("smart-list expansion runs after the surfaces even when the shelf did not commit")
  func smartListExpansionIsNotGatedOnTheShelfCommit() async {
    let expansion = ExpansionProbe()

    await PodcastBackgroundRefreshHardware.runBackgroundPass(
      shelfRefresh: { .init(writtenCount: 0, failedLibraryIDs: [], commitOutcome: .notCommitted) },
      podcastAutoDownload: nil,
      podcastAutoDownloadReaper: nil,
      smartListShowExpansion: { await expansion.run() })

    #expect(await expansion.runs == 1)
  }

  @Test("the whole-pass deadline cancels the smart-list expansion stage")
  func smartListExpansionStopsAtTheDeadline() async {
    let expansion = ExpansionProbe(suspendsUntilCancelled: true)

    await PodcastBackgroundRefreshHardware.runBackgroundPass(
      shelfRefresh: { .init(writtenCount: 0, failedLibraryIDs: [], commitOutcome: .notCommitted) },
      podcastAutoDownload: nil,
      podcastAutoDownloadReaper: nil,
      smartListShowExpansion: { await expansion.run() },
      timeLimit: .milliseconds(20))

    #expect(await expansion.runs == 1)
    #expect(await expansion.wasCancelled)
  }

  @Test("a cancelled pass never starts the smart-list expansion stage")
  func cancelledPassSkipsSmartListExpansion() async {
    let expansion = ExpansionProbe()
    let task = Task {
      await PodcastBackgroundRefreshHardware.runBackgroundPass(
        shelfRefresh: { .init(writtenCount: 0, failedLibraryIDs: [], commitOutcome: .notCommitted) },
        podcastAutoDownload: nil,
        podcastAutoDownloadReaper: nil,
        smartListShowExpansion: { await expansion.run() })
    }
    task.cancel()
    await task.value

    #expect(await expansion.runs == 0)
  }

  @Test("a cancelled background task never starts the auto-download pass")
  func backgroundPassRespectsTheWallClockBudget() async throws {
    // `WhirrApp`'s `.backgroundTask(.appRefresh(...))` cancels the wrapping `Task` when the
    // system's wall-clock budget expires. `runBackgroundPass` checks `Task.isCancelled` after the
    // shelf commit and before touching the coordinator. This proves the check stops the pass,
    // rather than merely racing it.
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      PodcastAutoDownloadCandidate(
        itemID: "show-1", episodeID: "ep-1", publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
    ])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let coordinator = Self.makeCoordinator(selecting: selecting, planner: planner)
    let reapProvider = FakeReapCandidateProvider()
    let reaper = PodcastAutoDownloadReaper(
      reapCandidateProvider: reapProvider, purging: FakePodcastAutoDownloadPurging())

    let task = Task {
      await PodcastBackgroundRefreshHardware.runBackgroundPass(
        shelfRefresh: { .init(writtenCount: 0, failedLibraryIDs: [], commitOutcome: .committed) },
        podcastAutoDownload: coordinator,
        podcastAutoDownloadReaper: reaper)
    }
    task.cancel()
    await task.value

    #expect(await selecting.fetchCallCount == 0, "the budget expired before the pass could start")
    #expect(await reapProvider.callCount == 0)
  }

  @Test("the background path refreshes library discovery before selecting podcast libraries")
  func backgroundPathReconcilesDiscovery() async {
    let discovery = FakeBackgroundLibraryDiscovery()

    await PodcastBackgroundRefreshHardware.refreshLibraryDiscovery(discovery)

    #expect(await discovery.callCount == 1)
  }

  /// A background pass is a strong task that clearing the cache does not cancel, and its discovery
  /// re-reads the current account. Its client is bound to the account the entry resolved, so a
  /// pass that outlives that account cannot authenticate as the next one.
  @Test("a background entry's client is bound to the account it resolved")
  @MainActor
  func backgroundServicesClientIsBoundToTheResolvedAccount() async throws {
    let database = try AppDatabase.inMemory()
    let suffix = UUID().uuidString.lowercased()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "bg-bound-\(suffix)",
        serverBaseURL: "https://bg-bound-\(suffix).invalid",
        serverUserId: "bg-bound-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "bg-bound-library"))
    // Built by hand rather than through `backgroundAccount()`, whose custom-header read fails in
    // the unsigned test host.
    let resolved = PodcastBackgroundRefreshHardware.BackgroundAccount(
      database: database, accountId: try #require(account.id),
      tokenAccount: try account.credentialTokenAccount,
      server: try ABSServerConfig(url: try #require(URL(string: account.serverBaseURL))),
      tokenStore: try KeychainTokenStore(), customHeaderStore: try KeychainCustomHeaderStore(),
      feedCredentialStore: try KeychainFeedCredentialStore())

    let services = PodcastBackgroundRefreshHardware.services(
      for: resolved, networkConditions: FakeNetworkConditions(),
      applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "whirr-bg-bound-\(suffix)", isDirectory: true))

    #expect(services.client.boundAccount == resolved.tokenAccount)
    let replacement = try TokenAccount(
      credentialNamespace: "account:bg-replacement-client", userID: "bg-replacement-user")
    await #expect(throws: APIError.cancelled) {
      _ = try await services.client.listLibraries(account: replacement)
    }
  }

  // MARK: - Fixtures

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
}

// MARK: - Fakes local to this file

private actor FakeBackgroundLibraryDiscovery: LibrarySelectionDiscovering {
  private(set) var callCount = 0

  func discoverAccessibleLibraries() async throws -> [SelectableLibrary] {
    callCount += 1
    return []
  }
}

private actor FakeReapCandidateProvider: PodcastAutoDownloadReapCandidateProviding {
  private(set) var callCount = 0

  func reapCandidates() async throws -> [EpisodeDownloadKey] {
    callCount += 1
    return []
  }
}

private actor FakeBackgroundRSSFeedRefresh: RSSFeedRefreshCoordinating {
  private let result: RSSFeedRefreshPassResult
  private let suspendsUntilCancelled: Bool
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var triggers: [RSSFeedRefreshTrigger] = []
  private(set) var cancellations: [RSSFeedRefreshTrigger] = []

  init(
    result: RSSFeedRefreshPassResult = .gated,
    suspendsUntilCancelled: Bool = false
  ) {
    self.result = result
    self.suspendsUntilCancelled = suspendsUntilCancelled
  }

  func run(_ trigger: RSSFeedRefreshTrigger) async -> RSSFeedRefreshPassResult {
    triggers.append(trigger)
    if suspendsUntilCancelled {
      await withCheckedContinuation { continuation = $0 }
    }
    return result
  }

  func cancel(_ trigger: RSSFeedRefreshTrigger) {
    cancellations.append(trigger)
    continuation?.resume()
    continuation = nil
  }
}

private actor ExpansionProbe {
  private let suspendsUntilCancelled: Bool
  private(set) var runs = 0
  private(set) var wasCancelled = false

  init(suspendsUntilCancelled: Bool = false) {
    self.suspendsUntilCancelled = suspendsUntilCancelled
  }

  func run() async {
    runs += 1
    guard suspendsUntilCancelled else { return }
    // Sleep throws only on cancellation, so this returns once the refresh cancels the expansion.
    do { try await Task.sleep(for: .seconds(60)) } catch {}
    wasCancelled = true
  }
}
