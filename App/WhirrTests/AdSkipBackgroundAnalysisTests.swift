import BackgroundTasks
import Foundation
import Testing

@testable import Whirr

/// Overnight analysis on charge: what is asked of the scheduler.
@MainActor
@Suite("Ad skip background analysis")
struct AdSkipBackgroundAnalysisTests {

  final class Scheduler: AdSkipTaskScheduling {
    var submitted: [BGTaskRequest] = []
    var cancelled: [String] = []

    func submit(_ taskRequest: BGTaskRequest) throws { submitted.append(taskRequest) }
    func cancel(taskRequestWithIdentifier identifier: String) { cancelled.append(identifier) }
  }

  @Test func theIdentifierIsTheOneTheInfoPlistPermits() throws {
    let url = try #require(Bundle.main.url(forResource: "Info", withExtension: "plist"))
    let plist = try #require(NSDictionary(contentsOf: url))
    let permitted = plist["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
    #expect(permitted.contains(AdSkipBackgroundAnalysis.identifier))
  }

  @Test func withTheSettingOnAProcessingTaskIsRequestedThatNeedsPowerButNoNetwork() throws {
    let scheduler = Scheduler()
    AdSkipBackgroundAnalysis.schedule(isEnabled: true, hasCoordinator: true, scheduler: scheduler)

    #expect(scheduler.submitted.count == 1)
    let request = try #require(scheduler.submitted.first as? BGProcessingTaskRequest)
    #expect(request.identifier == AdSkipBackgroundAnalysis.identifier)
    #expect(request.requiresExternalPower)
    #expect(request.requiresNetworkConnectivity == false)
    #expect(scheduler.cancelled.isEmpty)
  }

  @Test func withTheSettingOffAnyPendingRequestIsCancelled() {
    let scheduler = Scheduler()
    AdSkipBackgroundAnalysis.schedule(isEnabled: false, hasCoordinator: true, scheduler: scheduler)

    #expect(scheduler.submitted.isEmpty)
    #expect(scheduler.cancelled == [AdSkipBackgroundAnalysis.identifier])
  }

  @Test func withoutACoordinatorAnyPendingRequestIsCancelled() {
    let scheduler = Scheduler()
    AdSkipBackgroundAnalysis.schedule(isEnabled: true, hasCoordinator: false, scheduler: scheduler)

    #expect(scheduler.submitted.isEmpty)
    #expect(scheduler.cancelled == [AdSkipBackgroundAnalysis.identifier])
  }

  // MARK: - Overnight pass order

  @Test func theOvernightPassDeliversThenRefreshesThenAnalyses() async {
    let steps = StepRecorder()
    await AdSkipBackgroundAnalysis.runOvernightPass(
      deliver: { await steps.record("deliver") },
      refresh: { await steps.record("refresh") },
      analyse: { await steps.record("analyse") })

    #expect(await steps.steps == ["deliver", "refresh", "analyse"])
  }

  @Test func aCancelledOvernightPassStopsAfterTheStepInProgress() async {
    let steps = StepRecorder()
    let pass = Task {
      await AdSkipBackgroundAnalysis.runOvernightPass(
        deliver: {
          await steps.record("deliver")
          withUnsafeCurrentTask { $0?.cancel() }
        },
        refresh: { await steps.record("refresh") },
        analyse: { await steps.record("analyse") })
    }
    await pass.value

    #expect(await steps.steps == ["deliver"])
  }

  actor StepRecorder {
    private(set) var steps: [String] = []
    func record(_ step: String) { steps.append(step) }
  }

  // MARK: - Same-night retry

  @Test func aRetryAsksForALaterRunThatNeedsPowerAndTheNetwork() throws {
    let scheduler = Scheduler()
    let retryAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    AdSkipBackgroundAnalysis.schedule(
      isEnabled: true, hasCoordinator: true, scheduler: scheduler, retryAt: retryAt)

    let request = try #require(scheduler.submitted.first as? BGProcessingTaskRequest)
    #expect(scheduler.submitted.count == 1)
    #expect(request.earliestBeginDate == retryAt)
    #expect(request.requiresExternalPower)
    #expect(request.requiresNetworkConnectivity)
  }

  @Test func anOrdinaryRequestHasNoEarliestDate() throws {
    let scheduler = Scheduler()
    AdSkipBackgroundAnalysis.schedule(isEnabled: true, hasCoordinator: true, scheduler: scheduler)

    let request = try #require(scheduler.submitted.first as? BGProcessingTaskRequest)
    #expect(request.earliestBeginDate == nil)
  }

  @Test func theNightsFirstRunRetriesOnlyWhileADownloadIsOutstanding() {
    let retrying = AdSkipBackgroundAnalysis.retryDecision(
      isOutstanding: true, completedAnalysable: 3, previous: nil, night: "2026-10-8")
    #expect(retrying.shouldRetry)
    #expect(retrying.state == .init(night: "2026-10-8", retries: 1, completedAnalysable: 3))

    let idle = AdSkipBackgroundAnalysis.retryDecision(
      isOutstanding: false, completedAnalysable: 3, previous: nil, night: "2026-10-8")
    #expect(idle.shouldRetry == false)
    #expect(idle.state.retries == 0)
  }

  @Test func aLaterRunRetriesOnlyIfMoreEpisodesArrived() {
    let previous = AdSkipBackgroundAnalysis.RetryState(
      night: "2026-10-8", retries: 1, completedAnalysable: 3)

    let stalled = AdSkipBackgroundAnalysis.retryDecision(
      isOutstanding: true, completedAnalysable: 3, previous: previous, night: "2026-10-8")
    #expect(stalled.shouldRetry == false, "a download held for Wi-Fi gains nothing from retrying")

    let progressed = AdSkipBackgroundAnalysis.retryDecision(
      isOutstanding: true, completedAnalysable: 4, previous: previous, night: "2026-10-8")
    #expect(progressed.shouldRetry)
    #expect(progressed.state == .init(night: "2026-10-8", retries: 2, completedAnalysable: 4))
  }

  @Test func theNightsBudgetCapsRetries() {
    let spent = AdSkipBackgroundAnalysis.RetryState(
      night: "2026-10-8", retries: AdSkipBackgroundAnalysis.maximumRetriesPerNight,
      completedAnalysable: 3)

    let decision = AdSkipBackgroundAnalysis.retryDecision(
      isOutstanding: true, completedAnalysable: 9, previous: spent, night: "2026-10-8")
    #expect(decision.shouldRetry == false)
  }

  @Test func aNewNightStartsAFreshBudget() {
    let lastNight = AdSkipBackgroundAnalysis.RetryState(
      night: "2026-10-7", retries: AdSkipBackgroundAnalysis.maximumRetriesPerNight,
      completedAnalysable: 9)

    let decision = AdSkipBackgroundAnalysis.retryDecision(
      isOutstanding: true, completedAnalysable: 2, previous: lastNight, night: "2026-10-8")
    #expect(decision.shouldRetry)
    #expect(decision.state == .init(night: "2026-10-8", retries: 1, completedAnalysable: 2))
  }

  @Test func runsEitherSideOfMidnightShareANight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
    func date(_ day: Int, _ hour: Int) throws -> Date {
      try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)))
    }

    let evening = AdSkipBackgroundAnalysis.nightKey(for: try date(8, 23), calendar: calendar)
    let earlyMorning = AdSkipBackgroundAnalysis.nightKey(for: try date(9, 4), calendar: calendar)
    let nextEvening = AdSkipBackgroundAnalysis.nightKey(for: try date(9, 23), calendar: calendar)
    #expect(evening == earlyMorning)
    #expect(evening != nextEvening)
  }
}
