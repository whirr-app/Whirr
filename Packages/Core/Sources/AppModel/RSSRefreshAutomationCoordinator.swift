import Foundation
import Persistence
import SyncEngine

/// Narrow lifecycle surfaces for the existing shared automatic-download actors. Keeping the
/// wrapper protocol-based makes the RSS orchestration independently testable without introducing
/// a second implementation of either pass or its gates/budgets.
public protocol PodcastAutoDownloadRunning: Sendable {
  func run() async
  func cancel() async
}

extension PodcastAutoDownloadCoordinator: PodcastAutoDownloadRunning {}

public protocol PodcastAutoDownloadReaping: Sendable {
  func reap() async
  func cancel() async
}

extension PodcastAutoDownloadReaper: PodcastAutoDownloadReaping {}

/// Composes one bounded all-feed refresh with the existing automatic-selection and retention
/// actors. The refresh result is returned unchanged so its feed/time budgets remain observable;
/// automation starts only after at least one feed committed successfully and never when the
/// device-owned feature is disabled. Concurrent triggers of the same kind join one whole flight.
public actor RSSRefreshAutomationCoordinator: RSSFeedRefreshCoordinating {
  private struct Flight {
    let id: UUID
    let task: Task<RSSFeedRefreshPassResult, Never>
    var waiters: Set<UUID>
  }

  private let refresh: any RSSFeedRefreshCoordinating
  private let autoDownload: (any PodcastAutoDownloadRunning)?
  private let reaper: (any PodcastAutoDownloadReaping)?
  private let nativeSubscriptions: any NativePodcastSubscriptionsReading
  private var flights: [RSSFeedRefreshTrigger: Flight] = [:]
  private var cancellationsInProgress: [RSSFeedRefreshTrigger: Int] = [:]

  public init(
    refresh: any RSSFeedRefreshCoordinating,
    autoDownload: (any PodcastAutoDownloadRunning)?,
    reaper: (any PodcastAutoDownloadReaping)?,
    nativeSubscriptions: any NativePodcastSubscriptionsReading
  ) {
    self.refresh = refresh
    self.autoDownload = autoDownload
    self.reaper = reaper
    self.nativeSubscriptions = nativeSubscriptions
  }

  public func run(_ trigger: RSSFeedRefreshTrigger) async -> RSSFeedRefreshPassResult {
    guard cancellationsInProgress[trigger] == nil else { return .gated }
    let waiterID = UUID()
    let flight: Flight
    if var existing = flights[trigger] {
      existing.waiters.insert(waiterID)
      flights[trigger] = existing
      flight = existing
    } else {
      let task = Task<RSSFeedRefreshPassResult, Never> { [weak self] in
        guard let self else { return RSSFeedRefreshPassResult.gated }
        return await self.perform(trigger)
      }
      flight = Flight(id: UUID(), task: task, waiters: [waiterID])
      flights[trigger] = flight
    }

    let result = await withTaskCancellationHandler {
      await flight.task.value
    } onCancel: {
      Task {
        await self.cancelWaiter(
          trigger, flightID: flight.id, waiterID: waiterID)
      }
    }
    if flights[trigger]?.id == flight.id { flights[trigger] = nil }
    return Task.isCancelled ? .gated : result
  }

  public func cancel(_ trigger: RSSFeedRefreshTrigger) async {
    cancellationsInProgress[trigger, default: 0] += 1
    defer {
      let remaining = (cancellationsInProgress[trigger] ?? 1) - 1
      cancellationsInProgress[trigger] = remaining == 0 ? nil : remaining
    }
    let flight = flights.removeValue(forKey: trigger)
    flight?.task.cancel()
    await refresh.cancel(trigger)
    await autoDownload?.cancel()
    await reaper?.cancel()
  }

  private func cancelWaiter(
    _ trigger: RSSFeedRefreshTrigger, flightID: UUID, waiterID: UUID
  ) {
    guard var flight = flights[trigger], flight.id == flightID,
      flight.waiters.remove(waiterID) != nil
    else { return }
    guard flight.waiters.isEmpty == false else {
      flights[trigger] = nil
      flight.task.cancel()
      return
    }
    flights[trigger] = flight
  }

  private func perform(_ trigger: RSSFeedRefreshTrigger) async -> RSSFeedRefreshPassResult {
    guard Task.isCancelled == false, await nativeSubscriptions.isEnabled() else { return .gated }
    let result = await refresh.run(trigger)
    guard Task.isCancelled == false, result.succeededCount > 0, result.timedOut == false,
      await nativeSubscriptions.isEnabled()
    else { return result }

    await autoDownload?.run()
    guard Task.isCancelled == false, await nativeSubscriptions.isEnabled() else { return result }
    await reaper?.reap()
    return result
  }
}
