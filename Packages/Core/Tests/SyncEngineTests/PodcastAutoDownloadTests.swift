import Foundation
import TestSupport
import Testing

@testable import Persistence
@testable import SyncEngine

/// The pass: gates → candidates → plan → decide. Every scenario drives
/// `PodcastAutoDownloadCoordinator` purely through its injected boundaries; the shared
/// selection/planning fakes are the one "did the pass do anything" signal.
@Suite("Podcast auto-download coordinator")
struct PodcastAutoDownloadTests {

  // MARK: - Candidates flow through the planning boundary

  @Test("candidates are enqueued through the automatic planning boundary")
  func candidatesAreEnqueuedThroughTheAutomaticPlanningBoundary() async throws {
    let candidates = [
      Self.candidate(itemID: "item-1", episodeID: "ep-1"),
      Self.candidate(itemID: "item-2", episodeID: "ep-2"),
    ]
    let selecting = FakePodcastAutoDownloadSelecting(candidates: candidates)
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let coordinator = Self.makeCoordinator(selecting: selecting, planner: planner)

    await coordinator.run()

    let requests = await planner.requests
    #expect(Set(requests.map(\.episodeID)) == ["ep-1", "ep-2"])
  }

  @Test("enqueued episodes are marked decided")
  func enqueuedEpisodesAreMarkedDecided() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1")
    ])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let coordinator = Self.makeCoordinator(selecting: selecting, planner: planner)

    await coordinator.run()

    let decided = await selecting.decided
    #expect(decided.contains(.init(itemID: "item-1", episodeID: "ep-1")))
  }

  @Test("an episode the planner reports unavailable is never marked decided")
  func unavailableEpisodeIsNotMarkedDecided() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1")
    ])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    await planner.stubFailure(episodeID: "ep-1", error: DownloadPlanningError.episodeUnavailable)
    let coordinator = Self.makeCoordinator(selecting: selecting, planner: planner)

    await coordinator.run()

    let decided = await selecting.decided
    #expect(decided.isEmpty)
  }

  @Test("one planning failure does not stop later candidates in the same pass")
  func onePlanningFailureDoesNotStopLaterCandidates() async throws {
    let candidates = [
      Self.candidate(itemID: "item-1", episodeID: "ep-1"),
      Self.candidate(itemID: "item-2", episodeID: "ep-2"),
      Self.candidate(itemID: "item-3", episodeID: "ep-3"),
    ]
    let selecting = FakePodcastAutoDownloadSelecting(candidates: candidates)
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    await planner.stubFailure(episodeID: "ep-2", error: DownloadPlanningError.episodeUnavailable)
    let coordinator = Self.makeCoordinator(selecting: selecting, planner: planner)

    await coordinator.run()

    let requests = await planner.requests
    #expect(requests.map(\.episodeID) == ["ep-1", "ep-2", "ep-3"])
    let decided = await selecting.decided
    #expect(
      decided == [
        .init(itemID: "item-1", episodeID: "ep-1"), .init(itemID: "item-3", episodeID: "ep-3"),
      ])
  }

  @Test("a candidate that failed planning stays eligible for a later pass")
  func failedCandidateRemainsEligibleForALaterPass() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1")
    ])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    await planner.stubFailure(episodeID: "ep-1", error: DownloadPlanningError.episodeUnavailable)
    let coordinator = Self.makeCoordinator(selecting: selecting, planner: planner)

    await coordinator.run()
    #expect(await selecting.decided.isEmpty)

    // A later pass still offers the same candidate: nothing marked it decided, so the store has
    // no reason to withhold it.
    await planner.clearFailures()
    await coordinator.run()

    let requests = await planner.requests
    #expect(requests.map(\.episodeID) == ["ep-1", "ep-1"])
    #expect(await selecting.decided.contains(.init(itemID: "item-1", episodeID: "ep-1")))
  }

  // MARK: - Gates: a blocked pass decides nothing and enqueues nothing

  @Test("Low Power Mode blocks the pass and decides nothing")
  func lowPowerModeBlocksThePassAndDecidesNothing() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1")
    ])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let networkConditions = FakeNetworkConditions()
    networkConditions.isLowPowerMode = true
    let coordinator = Self.makeCoordinator(
      selecting: selecting, planner: planner, networkConditions: networkConditions)

    await coordinator.run()

    #expect(await selecting.fetchCallCount == 0)
    #expect(await planner.requests.isEmpty)
  }

  @Test("a constrained/cellular path blocks the pass unless cellular auto-download is on")
  func constrainedPathBlocksThePassUnlessCellularAutoDownloadIsOn() async throws {
    let networkConditions = FakeNetworkConditions()
    networkConditions.isConstrainedOrCellular = true

    let blockedSelecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1")
    ])
    let blockedCoordinator = Self.makeCoordinator(
      selecting: blockedSelecting, planner: FakeAutomaticEpisodeDownloadPlanning(),
      networkConditions: networkConditions,
      podcastSettingsReading: FakePodcastSettingsReading(
        global: Self.globalSettings(allowCellularAutoDownload: false)))

    await blockedCoordinator.run()
    #expect(await blockedSelecting.fetchCallCount == 0)

    let allowedSelecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1")
    ])
    let allowedPlanner = FakeAutomaticEpisodeDownloadPlanning()
    let allowedCoordinator = Self.makeCoordinator(
      selecting: allowedSelecting, planner: allowedPlanner, networkConditions: networkConditions,
      podcastSettingsReading: FakePodcastSettingsReading(
        global: Self.globalSettings(allowCellularAutoDownload: true)))

    await allowedCoordinator.run()
    #expect(await allowedSelecting.fetchCallCount == 1)
    #expect(await allowedPlanner.requests.count == 1)
  }

  @Test("a low-disk queue pause blocks the pass")
  func lowDiskQueuePauseBlocksThePass() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1")
    ])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let coordinator = Self.makeCoordinator(
      selecting: selecting, planner: planner,
      lowDiskGating: FakeLowDiskGating(isPaused: true))

    await coordinator.run()

    #expect(await selecting.fetchCallCount == 0)
    #expect(await planner.requests.isEmpty)
  }

  @Test("an unauthenticated account, or one with a pending removal, does nothing")
  func unauthenticatedAndRemovalPendingPassesDoNothing() async throws {
    let loggedOutLifecycle = FakeAccountLifecycle()
    loggedOutLifecycle.isAuthenticated = false
    let loggedOutSelecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1")
    ])
    let loggedOutCoordinator = Self.makeCoordinator(
      selecting: loggedOutSelecting, planner: FakeAutomaticEpisodeDownloadPlanning(),
      accountLifecycle: loggedOutLifecycle)
    await loggedOutCoordinator.run()
    #expect(await loggedOutSelecting.fetchCallCount == 0)

    let pendingLifecycle = FakeAccountLifecycle()
    pendingLifecycle.isAuthenticated = true
    pendingLifecycle.isRemovalPendingValue = true
    let pendingSelecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1")
    ])
    let pendingCoordinator = Self.makeCoordinator(
      selecting: pendingSelecting, planner: FakeAutomaticEpisodeDownloadPlanning(),
      accountLifecycle: pendingLifecycle)
    await pendingCoordinator.run()
    #expect(await pendingSelecting.fetchCallCount == 0)
  }

  // MARK: - Single-flight and cancellation

  @Test("concurrent triggers coalesce onto the one in-flight pass")
  func concurrentTriggersCoalesce() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1")
    ])
    let gate = PlannerGate()
    let planner = FakeAutomaticEpisodeDownloadPlanning(gate: gate)
    let coordinator = Self.makeCoordinator(selecting: selecting, planner: planner)
    let submissions = TestCountRecorder(label: "auto-download submissions")

    let first = Task {
      submissions.record()
      await coordinator.run()
    }
    await gate.waitUntilStarted(episodeID: "ep-1")

    let second = Task {
      submissions.record()
      await coordinator.run()
    }
    let third = Task {
      submissions.record()
      await coordinator.run()
    }
    // The handoff signal makes task submission deterministic; the planner gate keeps the first
    // pass in flight while the two coalesced callers enter the coordinator.
    await submissions.waitUntil(count: 3)

    await gate.release(episodeID: "ep-1")
    _ = await (first.value, second.value, third.value)

    #expect(await selecting.fetchCallCount == 1)
    #expect(await planner.requests.count == 1)
  }

  @Test("cancellation leaves already-committed decisions intact")
  func cancellationLeavesCommittedDecisionsIntact() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1"),
      Self.candidate(itemID: "item-2", episodeID: "ep-2"),
    ])
    let gate = PlannerGate()
    let planner = FakeAutomaticEpisodeDownloadPlanning(gate: gate)
    let coordinator = Self.makeCoordinator(selecting: selecting, planner: planner)

    let task = Task { await coordinator.run() }
    await gate.waitUntilStarted(episodeID: "ep-1")
    await coordinator.cancel()
    await gate.release(episodeID: "ep-1")
    await task.value

    let requests = await planner.requests
    #expect(requests.map(\.episodeID) == ["ep-1"], "cancellation must stop the loop before ep-2")
    #expect(await selecting.decided.contains(.init(itemID: "item-1", episodeID: "ep-1")))
  }

  // MARK: - No transport, and the budgets

  @Test("a pass never issues any request beyond the selection store and the planning boundary")
  func passNeverIssuesAnyServerRequest() async throws {
    // `PodcastAutoDownloadCoordinator.init` takes no client or transport, so `selecting` and
    // `planner` are the only collaborators `run` can reach beyond the local gates. Every
    // observable effect of a pass is therefore the calls recorded on these two fakes.
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [
      Self.candidate(itemID: "item-1", episodeID: "ep-1"),
      Self.candidate(itemID: "item-2", episodeID: "ep-2"),
    ])
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let coordinator = Self.makeCoordinator(selecting: selecting, planner: planner)

    await coordinator.run()

    #expect(await selecting.repairCallCount == 1)
    #expect(await selecting.fetchCallCount == 1)
    #expect(await planner.requests.count == 2)
  }

  @Test("a backwards clock clamps automatic-download diagnostic duration to zero")
  func backwardsClockClampsDiagnosticDurationToZero() async throws {
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [])
    let diagnostics = FakeDiagnosticsRecording()
    let clock = AutoDownloadDiagnosticClock([
      Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 99),
    ])
    let coordinator = Self.makeCoordinator(
      selecting: selecting,
      planner: FakeAutomaticEpisodeDownloadPlanning(),
      diagnostics: diagnostics,
      now: { clock.now() })

    await coordinator.run()

    let event = try #require(diagnostics.recorded.first)
    #expect(event.durationMilliseconds == 0)
  }

  @Test("the per-pass budget bounds how many candidates are enqueued")
  func perPassBudgetBoundsEnqueues() async throws {
    let policy = PodcastAutoDownloadPolicy()
    let candidates = (0..<policy.maxEpisodesPerPass).map {
      Self.candidate(itemID: "item-\($0)", episodeID: "ep-\($0)")
    }
    let selecting = FakePodcastAutoDownloadSelecting(candidates: candidates)
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let coordinator = Self.makeCoordinator(
      selecting: selecting, planner: planner, policy: policy)

    await coordinator.run()

    #expect(await selecting.lastMaxPerShow == policy.maxEpisodesPerShow)
    #expect(await selecting.lastMaxPerPass == policy.maxEpisodesPerPass)
    #expect(await planner.requests.count == policy.maxEpisodesPerPass)
    #expect(await selecting.fetchCallCount == 1)
  }

  @Test("the shared selecting fake records limits and removes decided candidates")
  func sharedSelectingFakeRecordsLimitsAndRemovesDecidedCandidates() async throws {
    let first = Self.candidate(itemID: "item-1", episodeID: "ep-1")
    let second = Self.candidate(itemID: "item-2", episodeID: "ep-2")
    let selecting = FakePodcastAutoDownloadSelecting(candidates: [first, second])

    let initial = try await selecting.fetchCandidates(maxPerShow: 2, maxPerPass: 1)
    #expect(initial == [first, second])
    #expect(await selecting.lastMaxPerShow == 2)
    #expect(await selecting.lastMaxPerPass == 1)

    try await selecting.markDecided(itemID: "item-1", episodeID: "ep-1")

    #expect(
      await selecting.decided == [
        .init(itemID: "item-1", episodeID: "ep-1")
      ])
    let remaining = try await selecting.fetchCandidates(maxPerShow: 2, maxPerPass: 1)
    #expect(remaining == [second])
    #expect(await selecting.fetchCallCount == 2)
  }

  @Test("the shared planner fake records requests and injects a configured failure")
  func sharedPlannerFakeRecordsRequestsAndInjectsFailure() async throws {
    let planner = FakeAutomaticEpisodeDownloadPlanning()
    await planner.stubFailure(
      episodeID: "ep-1", error: DownloadPlanningError.episodeUnavailable)

    await #expect(throws: DownloadPlanningError.episodeUnavailable) {
      try await planner.requestAutomaticEpisodeDownload(itemID: "item-1", episodeID: "ep-1")
    }
    #expect(
      await planner.requests == [
        .init(itemID: "item-1", episodeID: "ep-1")
      ])

    await planner.clearFailures()
    try await planner.requestAutomaticEpisodeDownload(itemID: "item-1", episodeID: "ep-1")
    #expect(await planner.requests.count == 2)
  }

  // MARK: - Fixtures

  private static func candidate(itemID: String, episodeID: String) -> PodcastAutoDownloadCandidate {
    PodcastAutoDownloadCandidate(
      itemID: itemID, episodeID: episodeID,
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private static func globalSettings(allowCellularAutoDownload: Bool) -> PodcastGlobalSettings {
    PodcastGlobalSettings(
      autoDownloadEnabled: true, keepLatestCount: 3, deleteAfterPlayed: false,
      allowCellularAutoDownload: allowCellularAutoDownload, enabledAt: nil)
  }

  private static func makeCoordinator(
    selecting: any PodcastAutoDownloadSelecting,
    planner: any AutomaticEpisodeDownloadPlanning,
    accountLifecycle: any AccountLifecycle = Self.authenticatedLifecycle(),
    networkConditions: any NetworkConditions = FakeNetworkConditions(),
    podcastSettingsReading: any PodcastSettingsReading = FakePodcastSettingsReading(
      global: .defaults),
    lowDiskGating: any PodcastAutoDownloadLowDiskGating = FakeLowDiskGating(isPaused: false),
    policy: PodcastAutoDownloadPolicy = PodcastAutoDownloadPolicy(),
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    now: @escaping @Sendable () -> Date = Date.init
  ) -> PodcastAutoDownloadCoordinator {
    PodcastAutoDownloadCoordinator(
      selecting: selecting,
      planner: planner,
      accountLifecycle: accountLifecycle,
      networkConditions: networkConditions,
      podcastSettingsReading: podcastSettingsReading,
      lowDiskGating: lowDiskGating,
      diagnostics: diagnostics,
      accountId: 1,
      policy: policy,
      now: now)
  }

  private static func authenticatedLifecycle() -> FakeAccountLifecycle {
    let lifecycle = FakeAccountLifecycle()
    lifecycle.isAuthenticated = true
    return lifecycle
  }
}

private final class AutoDownloadDiagnosticClock: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Date]

  init(_ values: [Date]) {
    self.values = values
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    if values.count > 1 {
      return values.removeFirst()
    }
    return values[0]
  }
}

// MARK: - Fakes

private struct FakeLowDiskGating: PodcastAutoDownloadLowDiskGating {
  let isPaused: Bool
  func isQueuePausedForLowDisk() async -> Bool { isPaused }
}
