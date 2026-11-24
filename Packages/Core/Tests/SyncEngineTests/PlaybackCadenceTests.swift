import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `PlaybackSessionCoordinator`'s cadence state machine: scheduling policy only (API-CONVENTIONS
/// rules 7/7a/8/20). Covers the 15/60 s boundaries, degraded-condition transitions, every
/// immediate trigger, coalescing, phases that schedule no periodic work, backgrounded playback,
/// a fresh interval on resume, session-switch cancellation, and teardown leaving no live callback.
/// Request bodies, response classification and acknowledgement are asserted elsewhere.
@Suite struct PlaybackCadenceTests {

  // MARK: - Exact 15/60 s boundaries (rule 7)

  @Test func playingSchedulesFifteenSecondsUnderNormalConditions() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.pendingInterval == 15)
    #expect(harness.scheduler.scheduleCount == 1)
  }

  @Test func lowPowerModeSchedulesSixtySeconds() async throws {
    let harness = try await CadenceHarness(initialLowPowerMode: true)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.pendingInterval == 60)
  }

  @Test func constrainedOrCellularSchedulesSixtySeconds() async throws {
    let harness = try await CadenceHarness(initialConstrainedOrCellular: true)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.pendingInterval == 60)
  }

  // MARK: - The cadence trace's interruption reset

  /// A 40 s pause during a 15 s series is not a missed deadline (`since=55.7 nominal=15.0`):
  /// `firePeriodicDrain`'s `.playing` guard suppresses every drain meanwhile. The reset belongs
  /// wherever the phase leaves `.playing`, so the first interval after resume reports `first`
  /// rather than the wall gap.
  @Test func aPausedStretchIsNotReportedAsACadenceInterval() async throws {
    let harness = try await CadenceHarness()
    let records = Locked<[DrainCadenceTrace.Record]>([])
    await harness.coordinator.setCadenceRecordSink { record in
      records.withValue { $0.append(record) }
    }

    await harness.coordinator.notifyPlaybackPhase(.playing)
    harness.clock.advance(by: 15)
    try #require(await harness.scheduler.fire())
    harness.clock.advance(by: 15)
    try #require(await harness.scheduler.fire())
    #expect(records.value.map(\.sincePreviousDrain) == [nil, 15])

    await harness.coordinator.notifyPlaybackPhase(.paused)
    harness.clock.advance(by: 40)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    harness.clock.advance(by: 15)
    try #require(await harness.scheduler.fire())

    #expect(records.value.count == 3)
    #expect(records.value.last?.sincePreviousDrain == nil)
  }

  /// Every non-playing phase suppresses periodic drains, so each breaks the series: `.buffering`
  /// (a scrub, or the cold side of a file boundary) and `.stopped` (an item switch) as much as
  /// `.paused`.
  @Test func everyPhaseThatLeavesPlayingBreaksTheSeries() async throws {
    for interruption in [PlaybackCadencePhase.buffering, .stopped, .idle] {
      let harness = try await CadenceHarness()
      let records = Locked<[DrainCadenceTrace.Record]>([])
      await harness.coordinator.setCadenceRecordSink { record in
        records.withValue { $0.append(record) }
      }

      await harness.coordinator.notifyPlaybackPhase(.playing)
      harness.clock.advance(by: 15)
      try #require(await harness.scheduler.fire())

      await harness.coordinator.notifyPlaybackPhase(interruption)
      harness.clock.advance(by: 600)
      await harness.coordinator.notifyPlaybackPhase(.playing)
      harness.clock.advance(by: 15)
      try #require(await harness.scheduler.fire())

      #expect(
        records.value.last?.sincePreviousDrain == nil,
        "\(interruption) left a stale interval behind")
    }
  }

  /// A degraded-condition change cancels the pending deadline and schedules a fresh full interval
  /// from the change instant, so the next drain follows its predecessor by the elapsed remainder
  /// plus the whole new nominal (`since=67 nominal=60` for a transition 7 s into a 15 s interval).
  /// Playback never stopped, but the series is broken.
  @Test func aDegradedConditionChangeBreaksTheSeriesItReschedules() async throws {
    let harness = try await CadenceHarness()
    let records = Locked<[DrainCadenceTrace.Record]>([])
    await harness.coordinator.setCadenceRecordSink { record in
      records.withValue { $0.append(record) }
    }

    await harness.coordinator.notifyPlaybackPhase(.playing)
    harness.clock.advance(by: 15)
    try #require(await harness.scheduler.fire())
    harness.clock.advance(by: 15)
    try #require(await harness.scheduler.fire())
    #expect(records.value.map(\.sincePreviousDrain) == [nil, 15])

    harness.clock.advance(by: 7)
    harness.networkConditions.simulateChange(isLowPowerMode: true)
    #expect(await TestSupport.waitUntil { harness.scheduler.pendingInterval == 60 })
    harness.clock.advance(by: 60)
    try #require(await harness.scheduler.fire())

    #expect(records.value.count == 3)
    #expect(records.value.last?.sincePreviousDrain == nil)
    #expect(records.value.last?.nominal == 60)
  }

  /// A condition change that does not cross the degraded boundary reschedules nothing, so it
  /// breaks nothing. Resetting on every emission would blank a series that never stopped.
  @Test func aConditionChangeThatReschedulesNothingLeavesTheSeriesIntact() async throws {
    let harness = try await CadenceHarness(initialLowPowerMode: true)
    let records = Locked<[DrainCadenceTrace.Record]>([])
    await harness.coordinator.setCadenceRecordSink { record in
      records.withValue { $0.append(record) }
    }

    await harness.coordinator.notifyPlaybackPhase(.playing)
    harness.clock.advance(by: 60)
    try #require(await harness.scheduler.fire())

    // Low Power to cellular: both booleans move, both are degraded, so the cadence is untouched.
    harness.networkConditions.simulateChange(isLowPowerMode: false, isConstrainedOrCellular: true)
    harness.clock.advance(by: 60)
    try #require(await harness.scheduler.fire())

    #expect(records.value.map(\.sincePreviousDrain) == [nil, 60])
  }

  /// An item switch never goes through `notifyPlaybackPhase` (`resetCadenceForSessionChange`
  /// cancels and drops to `.idle` directly), so the phase-side reset alone would miss it.
  @Test func switchingItemsBreaksTheSeries() async throws {
    let harness = try await CadenceHarness()
    let records = Locked<[DrainCadenceTrace.Record]>([])
    await harness.coordinator.setCadenceRecordSink { record in
      records.withValue { $0.append(record) }
    }

    harness.enqueuePlayResponse(itemID: CadenceHarness.itemID)
    _ = try await harness.coordinator.startSession(itemID: CadenceHarness.itemID, episodeID: nil)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    harness.clock.advance(by: 15)
    try #require(await harness.scheduler.fire())

    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    harness.enqueuePlayResponse(itemID: CadenceHarness.secondItemID)
    _ = try await harness.coordinator.startSession(
      itemID: CadenceHarness.secondItemID, episodeID: nil)
    harness.clock.advance(by: 300)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    harness.clock.advance(by: 15)
    try #require(await harness.scheduler.fire())

    #expect(records.value.count == 2)
    #expect(records.value.last?.sincePreviousDrain == nil)
  }

  /// The reset must not fire on every deadline. An uninterrupted series still measures, or the
  /// trace would report `first` forever.
  @Test func anUninterruptedSeriesKeepsMeasuringItsIntervals() async throws {
    let harness = try await CadenceHarness()
    let records = Locked<[DrainCadenceTrace.Record]>([])
    await harness.coordinator.setCadenceRecordSink { record in
      records.withValue { $0.append(record) }
    }

    await harness.coordinator.notifyPlaybackPhase(.playing)
    for _ in 0..<4 {
      harness.clock.advance(by: 15)
      try #require(await harness.scheduler.fire())
    }

    #expect(records.value.map(\.sincePreviousDrain) == [nil, 15, 15, 15])
  }

  // MARK: - Degraded-condition transitions (no eager/duplicate send)

  @Test func enteringADegradedConditionCancelsTheOldDeadlineAndReschedulesFromTheChangeInstant() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.pendingInterval == 15)

    harness.networkConditions.simulateChange(isLowPowerMode: true)
    #expect(await TestSupport.waitUntil { harness.scheduler.scheduleCount == 2 })

    #expect(harness.scheduler.pendingInterval == 60)
    #expect(harness.scheduler.scheduleCount == 2)
    // Entering the degraded condition never drains; only a fired deadline or an immediate
    // trigger does.
    #expect(harness.drainCalls == 0)
  }

  @Test func leavingADegradedConditionCancelsTheOldDeadlineAndReschedulesFromTheChangeInstant() async throws {
    let harness = try await CadenceHarness(initialLowPowerMode: true)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.pendingInterval == 60)

    harness.networkConditions.simulateChange(isLowPowerMode: false)
    #expect(await TestSupport.waitUntil { harness.scheduler.scheduleCount == 2 })

    #expect(harness.scheduler.pendingInterval == 15)
    #expect(harness.scheduler.scheduleCount == 2)
  }

  @Test func unchangedConditionEmissionsDoNothing() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.scheduleCount == 1)

    harness.networkConditions.simulateChange(isLowPowerMode: false)

    #expect(harness.scheduler.scheduleCount == 1)
    #expect(harness.scheduler.pendingInterval == 15)
  }

  @Test func duplicateDegradationWithDifferentFieldsButSameOverallBoundaryDoesNothing() async throws {
    let harness = try await CadenceHarness(initialLowPowerMode: true)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.scheduleCount == 1)

    // Still degraded overall (both now true), so the 15/60 s boundary is not crossed and nothing
    // reschedules, even though the snapshot's fields changed.
    harness.networkConditions.simulateChange(isConstrainedOrCellular: true)

    #expect(harness.scheduler.scheduleCount == 1)
    #expect(harness.scheduler.pendingInterval == 60)
  }

  @Test func conditionChangesWhileNotPlayingScheduleNothing() async throws {
    let harness = try await CadenceHarness()
    harness.networkConditions.simulateChange(isLowPowerMode: true)

    #expect(harness.scheduler.scheduleCount == 0)
    #expect(harness.scheduler.pendingInterval == nil)
  }

  // MARK: - Immediate triggers (pause, seek completion, background, item switch, close)

  @Test func pauseCancelsPeriodicWorkBeforeItsPostTickTriggerRequestsOneImmediateSync() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.pendingInterval == 15)

    await harness.coordinator.notifyPlaybackPhase(.paused)
    #expect(harness.drainCalls == 0, "the phase arrives before the final tick and must not drain it early")
    await harness.coordinator.notifyImmediateSyncTrigger(.paused)

    #expect(harness.drainCalls == 1)
    #expect(harness.scheduler.pendingInterval == nil)
  }

  @Test func seekCompletedRequestsOneImmediateSync() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyImmediateSyncTrigger(.seekCompleted)
    #expect(harness.drainCalls == 1)
  }

  @Test func backgroundedRequestsOneImmediateSync() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyImmediateSyncTrigger(.backgrounded)
    #expect(harness.drainCalls == 1)
  }

  @Test func itemSwitchingRequestsOneImmediateSync() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyImmediateSyncTrigger(.itemSwitching)
    #expect(harness.drainCalls == 1)
  }

  @Test func closingRequestsOneImmediateSync() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyImmediateSyncTrigger(.closing)
    #expect(harness.drainCalls == 1)
  }

  @Test func sequentialNonCoincidentTriggersEachProduceTheirOwnDrainRequest() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyImmediateSyncTrigger(.seekCompleted)
    await harness.coordinator.notifyImmediateSyncTrigger(.backgrounded)
    #expect(harness.drainCalls == 2)
  }

  @Test func backgroundedActivePlaybackContinuesTheApplicableCadence() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.pendingInterval == 15)
    let scheduleCountBeforeBackground = harness.scheduler.scheduleCount
    let cancelCountBeforeBackground = harness.scheduler.cancelCount

    await harness.coordinator.notifyImmediateSyncTrigger(.backgrounded)

    #expect(harness.drainCalls == 1)
    // Backgrounding is not a phase change, so the periodic deadline is untouched.
    #expect(harness.scheduler.pendingInterval == 15)
    #expect(harness.scheduler.scheduleCount == scheduleCountBeforeBackground)
    #expect(harness.scheduler.cancelCount == cancelCountBeforeBackground)
  }

  // MARK: - Coalescing (co-incident triggers collapse into one extra call)

  @Test func coIncidentImmediateTriggersCoalesceIntoASingleFollowUpDrainRequest() async throws {
    let harness = try await CadenceHarness()
    let gate = DrainGate()
    let gatedCoordinator = harness.makeCoordinator(requestDrain: { await gate.requestDrain() })

    let firstTrigger = Task { await gatedCoordinator.notifyImmediateSyncTrigger(.closing) }
    await gate.waitUntilStarted()
    #expect(await gate.count == 1)

    // Three more triggers arrive while the first request is in flight. They must collapse into
    // one follow-up call, not one each.
    await gatedCoordinator.notifyImmediateSyncTrigger(.itemSwitching)
    await gatedCoordinator.notifyImmediateSyncTrigger(.seekCompleted)
    await gatedCoordinator.notifyImmediateSyncTrigger(.backgrounded)
    #expect(await gate.count == 1)

    await gate.release()
    await gate.waitUntilStarted()
    #expect(await gate.count == 2)

    await gate.release()
    await firstTrigger.value
    #expect(await gate.count == 2)
  }

  // MARK: - No periodic work while buffering/paused/stopped/idle

  @Test(arguments: [PlaybackCadencePhase.buffering, .stopped, .idle])
  func nonPlayingNonPausedPhasesScheduleNoPeriodicWorkAndRequestNoImmediateDrain(
    _ phase: PlaybackCadencePhase
  ) async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.pendingInterval == 15)

    await harness.coordinator.notifyPlaybackPhase(phase)

    #expect(harness.scheduler.pendingInterval == nil)
    #expect(harness.drainCalls == 0)
  }

  @Test func directlyEnteringBufferingStoppedOrIdleWithoutHavingPlayedSchedulesNothing() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyPlaybackPhase(.buffering)
    #expect(harness.scheduler.pendingInterval == nil)
    #expect(harness.scheduler.scheduleCount == 0)
    #expect(harness.drainCalls == 0)
  }

  // MARK: - Resume starts one fresh full interval

  @Test func resumingPlayingStartsOneFreshFullIntervalRatherThanInheritingAStaleDeadline() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.scheduleCount == 1)

    await harness.coordinator.notifyPlaybackPhase(.paused)
    #expect(harness.scheduler.pendingInterval == nil)

    await harness.coordinator.notifyPlaybackPhase(.playing)

    #expect(harness.scheduler.scheduleCount == 2)
    #expect(harness.scheduler.pendingInterval == 15)
  }

  // MARK: - Firing the deadline requests a drain and reschedules the next one

  @Test func firingTheDeadlineRequestsADrainAndSchedulesTheNextInterval() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.scheduleCount == 1)

    let fired = await harness.scheduler.fire()

    #expect(fired)
    #expect(harness.drainCalls == 1)
    // Still playing: one fresh deadline exists for the next interval.
    #expect(harness.scheduler.scheduleCount == 2)
    #expect(harness.scheduler.pendingInterval == 15)
  }

  // MARK: - The next deadline is independent of the drain request

  /// The drain's round-trip must overlap the period, not add to it (a flat +1.0 s bias at 15 s
  /// nominal on a LAN, `since=127.5 nominal=60.0` across a Wi-Fi to cellular handover). So the
  /// next deadline must exist before the request it asks for has returned.
  @Test func aSlowDrainDoesNotDelayTheNextPeriodicDeadline() async throws {
    let harness = try await CadenceHarness()
    let gate = DrainGate()
    let scheduler = FakePlaybackCadenceScheduling()
    let coordinator = harness.makeCoordinator(
      scheduler: scheduler, requestDrain: { await gate.requestDrain() })

    await coordinator.notifyPlaybackPhase(.playing)
    #expect(scheduler.scheduleCount == 1)

    let firing = Task { await scheduler.fire() }
    await gate.waitUntilStarted()

    // The drain is still in flight. The next deadline already exists, and it is a full nominal
    // interval, not `interval + however long this request ends up taking`.
    #expect(scheduler.scheduleCount == 2)
    #expect(scheduler.pendingInterval == 15)

    await gate.release()
    _ = await firing.value
  }

  /// The handover case at the 60 s cellular nominal. Deadlines that fall while a request is
  /// stalled must still fire on their own clock; the drains they ask for coalesce onto the one in
  /// flight, so recovery costs one catch-up request for the whole stall (rule 14, no
  /// fixed-interval retry pile-up).
  @Test func aStalledDrainDoesNotConsumeTheDeadlinesThatFallDuringIt() async throws {
    let harness = try await CadenceHarness()
    let gate = DrainGate()
    let scheduler = FakePlaybackCadenceScheduling()
    let conditions = FakeNetworkConditions()
    conditions.isConstrainedOrCellular = true
    let coordinator = harness.makeCoordinator(
      scheduler: scheduler, networkConditions: conditions,
      requestDrain: { await gate.requestDrain() })

    await coordinator.notifyPlaybackPhase(.playing)
    #expect(scheduler.pendingInterval == 60)

    let firing = Task { await scheduler.fire() }
    await gate.waitUntilStarted()
    #expect(await gate.count == 1)

    // Two further nominal deadlines fall inside the stall (127.5 s of it, at 60 s nominal).
    // `#require`, not `#expect`: with no deadline pending the coalesced follow-up drain is never
    // requested, and the `waitUntilStarted` after the release would hang rather than fail.
    try #require(await scheduler.fire(), "the deadline after the stalled one still exists")
    try #require(await scheduler.fire(), "and so does the one after that")
    #expect(await gate.count == 1, "neither opened a second concurrent request")

    // Recovery: one catch-up drain for the whole stall, and the cadence carries on.
    await gate.release()
    await gate.waitUntilStarted()
    #expect(await gate.count == 2)
    await gate.release()
    _ = await firing.value

    #expect(await gate.count == 2)
    #expect(scheduler.pendingInterval == 60)
  }

  /// Scheduling before the request also closes a reentrancy hole: a pause landing while a
  /// periodic drain is in flight cancels the deadline, and the resuming `firePeriodicDrain` must
  /// not schedule a fresh one behind it, which would revive the cadence for a paused session.
  @Test func pausingWhileAPeriodicDrainIsInFlightLeavesNoDeadlineBehind() async throws {
    let harness = try await CadenceHarness()
    let gate = DrainGate()
    let scheduler = FakePlaybackCadenceScheduling()
    let coordinator = harness.makeCoordinator(
      scheduler: scheduler, requestDrain: { await gate.requestDrain() })

    await coordinator.notifyPlaybackPhase(.playing)
    let firing = Task { await scheduler.fire() }
    await gate.waitUntilStarted()
    #expect(scheduler.pendingInterval == 15)

    await coordinator.notifyPlaybackPhase(.paused)
    #expect(scheduler.pendingInterval == nil)
    await coordinator.notifyImmediateSyncTrigger(.paused)

    await gate.release()
    // Pause's post-tick trigger (rule 7) coalesced onto the in-flight one and runs now.
    await gate.waitUntilStarted()
    #expect(await gate.count == 2)
    await gate.release()
    _ = await firing.value

    #expect(scheduler.pendingInterval == nil, "the finished drain must not revive a paused cadence")
  }

  // MARK: - Switching sessions cancels the former session's deadline

  @Test func switchingSessionsCancelsTheFormerSessionsDeadlineAndNeverFiresAgainstItsSuccessor() async throws {
    let harness = try await CadenceHarness()
    harness.enqueuePlayResponse(itemID: CadenceHarness.itemID)
    _ = try await harness.coordinator.startSession(itemID: CadenceHarness.itemID, episodeID: nil)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.pendingInterval == 15)

    // The switch closes the former session (network `/close`) before calling `/play` for the
    // new item.
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    harness.enqueuePlayResponse(itemID: CadenceHarness.secondItemID)
    _ = try await harness.coordinator.startSession(itemID: CadenceHarness.secondItemID, episodeID: nil)

    #expect(harness.scheduler.pendingInterval == nil)

    let firedAfterSwitch = await harness.scheduler.fire()
    #expect(firedAfterSwitch == false)
    #expect(harness.drainCalls == 1, "the switch's durable close requests its ordered drain")
  }

  // MARK: - Cancellation and teardown leave no live callback

  @Test func explicitCancellationLeavesNoPendingDeadlineAbleToFireLater() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyPlaybackPhase(.playing)
    await harness.coordinator.notifyPlaybackPhase(.stopped)

    let fired = await harness.scheduler.fire()

    #expect(fired == false)
    #expect(harness.drainCalls == 0)
  }

  @Test func coordinatorTeardownLeavesNoCallbackAbleToEnqueueOrDrainLater() async throws {
    let harness = try await CadenceHarness()
    await harness.coordinator.notifyPlaybackPhase(.playing)
    #expect(harness.scheduler.pendingInterval == 15)

    // Drop the only strong reference to the coordinator. The scheduler (a separate object the
    // test still holds) keeps the captured `[weak self]` action around regardless.
    harness.dropCoordinator()

    let fired = await harness.scheduler.fire()

    // The action still "fires" (the fake runs whatever closure it was given), but the weak `self`
    // inside it has nothing left to unwrap, so nothing observable happens.
    #expect(fired)
    #expect(harness.drainCalls == 0)
  }

  @Test func aNetworkTransitionYieldedAfterQuiesceIsNotHandled() async throws {
    let harness = try await SubscriberTeardownHarness()
    #expect(
      await TestSupport.waitUntil(timeout: 1) { harness.networkConditions.subscriberCount > 0 },
      "the coordinator owns the subscriber before teardown")

    await harness.coordinator.notifyPlaybackPhase(.playing)

    // Positive control. After `quiesceForLogout` the cadence is torn down anyway, so "no new
    // schedule" holds whether or not the transition was ignored. Proving a live transition
    // reschedules first makes the post-quiesce comparison meaningful.
    let scheduleCountBeforeTransition = harness.scheduler.scheduleCount
    harness.networkConditions.simulateChange(isLowPowerMode: true)
    #expect(
      await TestSupport.waitUntil {
        harness.scheduler.scheduleCount > scheduleCountBeforeTransition
      },
      "a network transition reschedules the cadence while the subscriber is live")

    await harness.coordinator.quiesceForLogout()
    #expect(
      await TestSupport.waitUntil(timeout: 1) { harness.networkConditions.subscriberCount == 0 },
      "quiesceForLogout cancels the subscriber task")

    // A different snapshot: `handleNetworkConditionsChange` ignores an unchanged one, which
    // would make this pass for the wrong reason.
    let scheduleCountBeforeQuiescedTransition = harness.scheduler.scheduleCount
    harness.networkConditions.simulateChange(isLowPowerMode: false)

    #expect(harness.scheduler.scheduleCount == scheduleCountBeforeQuiescedTransition)
  }
}

// MARK: - Harness

private final class CadenceHarness: @unchecked Sendable {
  static let itemID = "item_book_fixture"
  static let secondItemID = "item_book_second_fixture"

  let http: FakeHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let networkConditions: FakeNetworkConditions
  let scheduler: FakePlaybackCadenceScheduling
  let clock: FakeSyncClock
  private let drainCallCount = Locked<Int>(0)
  var drainCalls: Int { drainCallCount.value }

  private let client: ABSClient
  var coordinator: PlaybackSessionCoordinator!

  init(
    initialLowPowerMode: Bool = false,
    initialConstrainedOrCellular: Bool = false
  ) async throws {
    clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000))
    let server = try ABSServerConfig(url: try #require(URL(string: "https://cadence.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    http = FakeHTTPClient()
    client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

    let localDatabase = try AppDatabase.inMemory()
    let savedAccount = try await localDatabase.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture", serverVersion: "2.35.1")
      try record.insert(db)
      return record
    }
    let localAccountId = try #require(savedAccount.id)

    let libraryId = try await localDatabase.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: localDatabase)
    _ = try await itemDAO.upsertAsync(
      ItemRecord(
        accountId: localAccountId, libraryId: libraryId, serverItemId: Self.itemID, mediaKind: "book",
        title: "Title", sortTitle: "title"))
    _ = try await itemDAO.upsertAsync(
      ItemRecord(
        accountId: localAccountId, libraryId: libraryId, serverItemId: Self.secondItemID, mediaKind: "book",
        title: "Second Title", sortTitle: "second title"))

    database = localDatabase
    outbox = try OutboxStore(database: database)

    networkConditions = FakeNetworkConditions()
    networkConditions.isLowPowerMode = initialLowPowerMode
    networkConditions.isConstrainedOrCellular = initialConstrainedOrCellular
    scheduler = FakePlaybackCadenceScheduling()

    let counter = drainCallCount
    let drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account,
      accountId: localAccountId)
    coordinator = PlaybackSessionCoordinator.make(
      client: client, database: database, outbox: outbox, networkConditions: networkConditions,
      clock: clock, scheduler: scheduler,
      requestDrain: {
        counter.withValue { $0 += 1 }
        await drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))
      })
  }

  /// A second coordinator sharing this harness's fixtures but with a caller-supplied
  /// `requestDrain`, for tests that need a gate-controlled closure instead of the plain counter.
  /// Cadence tests also pass their own scheduler and conditions to observe the deadline while the
  /// drain is held open.
  func makeCoordinator(
    scheduler: FakePlaybackCadenceScheduling = FakePlaybackCadenceScheduling(),
    networkConditions: FakeNetworkConditions = FakeNetworkConditions(),
    requestDrain: @escaping @Sendable () async -> Void
  ) -> PlaybackSessionCoordinator {
    PlaybackSessionCoordinator.make(
      client: client, database: database, outbox: outbox, networkConditions: networkConditions,
      clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)), scheduler: scheduler,
      requestDrain: requestDrain)
  }

  func dropCoordinator() {
    coordinator = nil
  }

  func enqueuePlayResponse(itemID: String) {
    let object: [String: Any] = [
      "id": "session_\(itemID)",
      "libraryItemId": itemID,
      "mediaType": "book",
      "displayTitle": "Fixture Book",
      "duration": 3600,
      "currentTime": 0,
      "playMethod": 0,
      "deviceInfo": ["deviceId": "server-echoed-id"],
      "audioTracks": [
        [
          "index": 1, "startOffset": 0, "duration": 100, "title": "Track 1",
          "contentUrl": "/api/items/\(itemID)/file/101", "mimeType": "audio/mpeg",
        ]
      ],
      "chapters": [] as [Any],
    ]
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: object)))
  }
}

private final class SubscriberTeardownHarness: @unchecked Sendable {
  let networkConditions: FakeNetworkConditions
  let scheduler: FakePlaybackCadenceScheduling
  let coordinator: PlaybackSessionCoordinator

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://subscriber.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    let database = try AppDatabase.inMemory()
    let outbox = try OutboxStore(database: database)
    let networkConditions = FakeNetworkConditions()
    let scheduler = FakePlaybackCadenceScheduling()

    self.networkConditions = networkConditions
    self.scheduler = scheduler
    coordinator = PlaybackSessionCoordinator.make(
      client: ABSClient(
        server: server, httpClient: FakeHTTPClient(), tokenStore: tokenStore),
      database: database,
      outbox: outbox,
      networkConditions: networkConditions,
      clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
      scheduler: scheduler)
  }
}

/// Holds a request open so a test can prove that other triggers arriving meanwhile coalesce
/// rather than each starting a concurrent call. `started` is checked before registering a waiter
/// so `waitUntilStarted` cannot register after the resume already happened and hang.
private actor DrainGate {
  // Every request parks until `release()`, which keeps the gate held for the next one. A held
  // request runs to completion regardless of cancellation, as the real one would.
  private nonisolated let gate = TestGate<Void>(label: "DrainGate", ignoresCancellation: true)
  private(set) var count = 0

  init() { gate.hold() }

  func requestDrain() async {
    count += 1
    await gate.pass()
  }

  /// Waits until a request is parked. After `release()` it waits for the next call to park rather
  /// than returning because the first already happened.
  func waitUntilStarted() async {
    await gate.waitUntilParked()
  }

  func release() {
    gate.releaseParked()
  }
}
