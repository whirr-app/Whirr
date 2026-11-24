import AdSkip
import AppModel
import BackgroundTasks
import CoreSupport
import Foundation
import Persistence
import SyncEngine
import UIKit
import os

/// Overnight analysis on charge: a processing task that lets the coordinator drain its backlog
/// while the phone is plugged in, without the app being open. The coordinator does the work; this
/// only gives it time to run.
@MainActor
enum AdSkipBackgroundAnalysis {
  /// Listed in `BGTaskSchedulerPermittedIdentifiers`, beside the `processing` background mode.
  static let identifier = "com.remoteconcern.whirr.adskip-analysis"

  private static let log = CoreLogging.logger(category: "AdSkip")

  /// Must run before launch finishes, so the system can deliver a request submitted by an
  /// earlier process. Registered whatever the setting: the handler checks it.
  static func register() {
    let isRegistered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: identifier, using: .main
    ) { task in
      MainActor.assumeIsolated { handle(task) }
    }
    if isRegistered == false {
      log.error("Ad-skip background analysis was not registered")
    }
  }

  /// How far ahead a same-night retry asks to run, and how many one night allows.
  static let retryDelay: TimeInterval = 30 * 60
  static let maximumRetriesPerNight = 4

  private static let retryStateKey = "com.remoteconcern.whirr.adSkipAnalysisRetry"

  /// Asks for a run on the next charge while the setting is on; cancels any pending request
  /// otherwise. `retryAt` asks for a same-night run instead. Every request goes through here,
  /// because a second submit with this identifier replaces the first. Best effort: the scheduler
  /// chooses when, and may decline.
  static func schedule(retryAt: Date? = nil) {
    schedule(
      isEnabled: AdSkipPreference.isEnabled(),
      hasCoordinator: AdSkipComposition.coordinator != nil,
      scheduler: BGTaskScheduler.shared,
      retryAt: retryAt)
  }

  static func schedule(
    isEnabled: Bool, hasCoordinator: Bool, scheduler: any AdSkipTaskScheduling,
    retryAt: Date? = nil
  ) {
    guard isEnabled, hasCoordinator else {
      scheduler.cancel(taskRequestWithIdentifier: identifier)
      return
    }
    let request = BGProcessingTaskRequest(identifier: identifier)
    // Transcription is on-device, so power is the only condition.
    request.requiresExternalPower = true
    if let retryAt {
      // A retry exists to let outstanding downloads arrive, so it needs the network too.
      request.earliestBeginDate = retryAt
      request.requiresNetworkConnectivity = true
    } else {
      request.requiresNetworkConnectivity = false
    }
    do {
      try scheduler.submit(request)
    } catch {
      // Unavailable, not permitted or too many pending: analysis still runs in the foreground.
      log.notice("Ad-skip background analysis not scheduled: \(String(describing: type(of: error)), privacy: .public)")
    }
  }

  private static func handle(_ task: BGTask) {
    guard AdSkipPreference.isEnabled(), let coordinator = AdSkipComposition.coordinator else {
      if AdSkipPreference.isEnabled(), AdSkipComposition.isAwaitingDatabase {
        // Before the first unlock: ask again rather than let `schedule()` read the missing
        // coordinator as a reason to cancel.
        schedule(isEnabled: true, hasCoordinator: true, scheduler: BGTaskScheduler.shared)
      }
      task.setTaskCompleted(success: true)
      return
    }
    let completion = Completion(task)
    let work = Task {
      await runOvernightPass(
        deliver: {
          // Record what the background session finished while the app was gone, and start
          // queued downloads. Awaited explicitly: composing only launches the coordinator's
          // reconcile.
          if let services = PodcastBackgroundRefreshHardware.backgroundServices() {
            await services.downloadCoordinator.reconcileAfterLaunch()
          }
        },
        refresh: {
          // The app-refresh task may not have run since tonight's episodes were published.
          await PodcastBackgroundRefreshHardware.refreshFollowedShows(
            rssTrigger: .overnight,
            timeLimit: PodcastBackgroundRefreshHardware.overnightPassTimeLimit)
        },
        analyse: {
          await AdSkipComposition.runForLaunch()
          // A run that expired earlier in this process left analysis paused.
          await coordinator.setAllowed(AdSkipAnalysisConditions.isAllowed())
          await coordinator.drainBacklog()
        })
      // The drain does not wait for the downloads started above; a retry picks them up the same
      // night.
      let retryAt = await retryDateAfterDrain()
      // The expiration handler has already asked for the next run.
      guard Task.isCancelled == false else { return }
      schedule(retryAt: retryAt)
      completion.finish(success: true)
    }
    task.expirationHandler = {
      Task { @MainActor in
        work.cancel()
        // Pause rather than let the process suspend mid-transcription: a cancelled episode is
        // not recorded and is transcribed again later, where an interrupted one could be
        // recorded as failed. The next activation, power or thermal change lifts the pause. A
        // Check Now is stopped too: it would otherwise run on through the suspension.
        if UIApplication.shared.applicationState != .active {
          await coordinator.suspendForExpiry()
        }
        schedule()
        completion.finish(success: false)
      }
    }
  }

  /// Delivery first, so finished transfers are recorded before the refresh plans against what is
  /// on the phone; analysis last, so it reads both. Each step is skipped once the task is
  /// cancelled.
  static func runOvernightPass(
    deliver: () async -> Void, refresh: () async -> Void, analyse: () async -> Void
  ) async {
    guard Task.isCancelled == false else { return }
    await deliver()
    guard Task.isCancelled == false else { return }
    await refresh()
    guard Task.isCancelled == false else { return }
    await analyse()
  }

  // MARK: - Same-night retry

  /// One night's retry bookkeeping, kept in `UserDefaults` because it is a scheduling hint, not
  /// data.
  struct RetryState: Codable, Equatable {
    var night: String
    var retries: Int
    var completedAnalysable: Int
  }

  /// Retries while an analysable download is outstanding, the run made progress (more analysable
  /// episodes on the phone than at the previous run tonight, or this is the night's first run),
  /// and the night's budget allows. A download held for Wi-Fi or low disk therefore stops
  /// retrying after one run that gains nothing.
  static func retryDecision(
    isOutstanding: Bool, completedAnalysable: Int, previous: RetryState?, night: String
  ) -> (shouldRetry: Bool, state: RetryState) {
    let tonight = previous?.night == night ? previous : nil
    let madeProgress = tonight.map { completedAnalysable > $0.completedAnalysable } ?? true
    let retries = tonight?.retries ?? 0
    let shouldRetry = isOutstanding && madeProgress && retries < maximumRetriesPerNight
    return (
      shouldRetry,
      RetryState(
        night: night, retries: retries + (shouldRetry ? 1 : 0),
        completedAnalysable: completedAnalysable)
    )
  }

  /// Names the night `date` belongs to: the calendar day twelve hours earlier, so a run before
  /// and a run after midnight share one budget.
  static func nightKey(for date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date.addingTimeInterval(-12 * 60 * 60))
    return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
  }

  private static func retryDateAfterDrain(now: Date = Date()) async -> Date? {
    guard let database = DatabaseHardware.sharedIfAvailable() else { return nil }
    let reader = AdSkipComposition.makeLocalEpisodeReader(database: database)
    guard
      let outstanding = try? await reader.outstandingDownloadLanguageTags(),
      let local = try? await reader.localEpisodes()
    else { return nil }
    let decision = retryDecision(
      isOutstanding: outstanding.contains { ShowLanguagePolicy.isAnalysable(languageTag: $0) },
      completedAnalysable: local.filter {
        ShowLanguagePolicy.isAnalysable(languageTag: $0.languageTag)
      }.count,
      previous: loadRetryState(), night: nightKey(for: now))
    saveRetryState(decision.state)
    return decision.shouldRetry ? now.addingTimeInterval(retryDelay) : nil
  }

  private static func loadRetryState(defaults: UserDefaults = .standard) -> RetryState? {
    defaults.data(forKey: retryStateKey).flatMap { try? JSONDecoder().decode(RetryState.self, from: $0) }
  }

  private static func saveRetryState(_ state: RetryState, defaults: UserDefaults = .standard) {
    defaults.set(try? JSONEncoder().encode(state), forKey: retryStateKey)
  }

  /// `setTaskCompleted` once, whichever of the drain and the expiration ends the task first.
  private final class Completion {
    private var task: BGTask?

    init(_ task: BGTask) { self.task = task }

    func finish(success: Bool) {
      task?.setTaskCompleted(success: success)
      task = nil
    }
  }
}

/// The two `BGTaskScheduler` calls scheduling needs, so tests can see what was asked.
protocol AdSkipTaskScheduling {
  func submit(_ taskRequest: BGTaskRequest) throws
  func cancel(taskRequestWithIdentifier identifier: String)
}

extension BGTaskScheduler: AdSkipTaskScheduling {}
