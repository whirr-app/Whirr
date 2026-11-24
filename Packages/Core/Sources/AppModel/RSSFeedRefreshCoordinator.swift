import Foundation
import Persistence
import SyncEngine

/// The device-owned feed rows an all-feeds pass may visit. Keeping the query behind this narrow
/// boundary lets the coordinator own budgets and cancellation without owning GRDB details.
public protocol RSSFeedRefreshCandidateProviding: Sendable {
  func refreshFeedIDs() async throws -> [Int64]
  /// Called as a pass reaches a feed, before its refresh, so the candidate order rotates past a
  /// feed whatever the refresh's outcome.
  func recordRefreshAttempt(feedID: Int64, at date: Date) async throws
}

extension RSSFeedStore: RSSFeedRefreshCandidateProviding {
  public func refreshFeedIDs() async throws -> [Int64] {
    try await fetchRefreshableFeedIDs()
  }
}

public enum RSSFeedRefreshTrigger: Sendable, Equatable, Hashable, CaseIterable {
  case foreground
  case background
  /// The overnight ad-analysis processing task: on charge, with minutes rather than seconds.
  case overnight

  /// System-scheduled passes classify discoveries for notifications and run the
  /// background-completion hook; a foreground pass does neither.
  var isSystemScheduled: Bool { self != .foreground }
}

/// Named limits for one all-feeds pass. `FeedFetchClient` remains the owner of its independent
/// four-request pool and one `BackoffPolicy` per URL; this outer policy prevents a large
/// subscription collection from consuming an unbounded foreground or system wake.
public struct RSSFeedRefreshPassPolicy: Sendable, Equatable {
  public var maxFeedsPerPass: Int
  public var maximumDuration: Duration

  public init(maxFeedsPerPass: Int, maximumDuration: Duration) {
    self.maxFeedsPerPass = max(0, maxFeedsPerPass)
    self.maximumDuration = maximumDuration
  }

  public static let foreground = Self(maxFeedsPerPass: 20, maximumDuration: .seconds(20))
  /// Strictly smaller than both the foreground pass and the existing 25-second whole-BG pass.
  public static let background = Self(maxFeedsPerPass: 4, maximumDuration: .seconds(8))
  /// Strictly inside the overnight whole-pass limit, leaving the rest of the processing window to
  /// transcription.
  public static let overnight = Self(maxFeedsPerPass: 50, maximumDuration: .seconds(90))
}

public struct RSSFeedRefreshPolicies: Sendable, Equatable {
  public var foreground: RSSFeedRefreshPassPolicy
  public var background: RSSFeedRefreshPassPolicy
  public var overnight: RSSFeedRefreshPassPolicy

  public init(
    foreground: RSSFeedRefreshPassPolicy = .foreground,
    background: RSSFeedRefreshPassPolicy = .background,
    overnight: RSSFeedRefreshPassPolicy = .overnight
  ) {
    self.foreground = foreground
    self.background = background
    self.overnight = overnight
  }

  func policy(for trigger: RSSFeedRefreshTrigger) -> RSSFeedRefreshPassPolicy {
    switch trigger {
    case .foreground: foreground
    case .background: background
    case .overnight: overnight
    }
  }
}

public struct RSSFeedRefreshPassResult: Sendable, Equatable {
  public var attemptedCount: Int
  public var succeededCount: Int
  public var failedCount: Int
  public var hitFeedBudget: Bool
  public var timedOut: Bool

  public init(
    attemptedCount: Int,
    succeededCount: Int,
    failedCount: Int,
    hitFeedBudget: Bool,
    timedOut: Bool = false
  ) {
    self.attemptedCount = attemptedCount
    self.succeededCount = succeededCount
    self.failedCount = failedCount
    self.hitFeedBudget = hitFeedBudget
    self.timedOut = timedOut
  }

  public static let gated = Self(
    attemptedCount: 0, succeededCount: 0, failedCount: 0, hitFeedBudget: false)
  public static let timedOut = Self(
    attemptedCount: 0, succeededCount: 0, failedCount: 0, hitFeedBudget: false,
    timedOut: true)
}

public protocol RSSFeedRefreshCoordinating: Sendable {
  func run(_ trigger: RSSFeedRefreshTrigger) async -> RSSFeedRefreshPassResult
  func cancel(_ trigger: RSSFeedRefreshTrigger) async
}

public struct NoOpRSSFeedRefreshCoordinator: RSSFeedRefreshCoordinating, Sendable {
  public init() {}
  public func run(_: RSSFeedRefreshTrigger) async -> RSSFeedRefreshPassResult { .gated }
  public func cancel(_: RSSFeedRefreshTrigger) async {}
}

/// One bounded, serial walk over device-owned RSS subscriptions. Concurrent callers with the
/// same trigger join one flight; foreground and background retain separate budgets, while the
/// child `RSSPodcastRefreshing` still coalesces an overlapping feed request across those flights.
public actor RSSFeedRefreshCoordinator: RSSFeedRefreshCoordinating {
  private struct Flight {
    let id: UUID
    let task: Task<RSSFeedRefreshPassResult, Never>
    var waiters: Set<UUID>
  }

  private enum RaceResult {
    case work(RSSFeedRefreshPassResult)
    case deadline
  }

  private let candidates: any RSSFeedRefreshCandidateProviding
  private let refreshing: any PodcastRefreshing
  private let networkConditions: any NetworkConditions
  private let nativeSubscriptions: any NativePodcastSubscriptionsReading
  private let notificationIntent: any RSSNotificationIntentReading
  private let backgroundCompletion: any RSSBackgroundRefreshCompleting
  private let policies: RSSFeedRefreshPolicies
  private let now: @Sendable () -> Date
  private var flights: [RSSFeedRefreshTrigger: Flight] = [:]
  public private(set) var joinedFlightCount = 0

  public init(
    candidates: any RSSFeedRefreshCandidateProviding,
    refreshing: any PodcastRefreshing,
    networkConditions: any NetworkConditions,
    nativeSubscriptions: any NativePodcastSubscriptionsReading,
    notificationIntent: any RSSNotificationIntentReading = DisabledRSSNotificationIntent(),
    backgroundCompletion: any RSSBackgroundRefreshCompleting = NoOpRSSBackgroundRefreshCompletion(),
    policies: RSSFeedRefreshPolicies = RSSFeedRefreshPolicies(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.candidates = candidates
    self.refreshing = refreshing
    self.networkConditions = networkConditions
    self.nativeSubscriptions = nativeSubscriptions
    self.notificationIntent = notificationIntent
    self.backgroundCompletion = backgroundCompletion
    self.policies = policies
    self.now = now
  }

  public func run(_ trigger: RSSFeedRefreshTrigger) async -> RSSFeedRefreshPassResult {
    let waiterID = UUID()
    let flight: Flight
    if var existing = flights[trigger] {
      joinedFlightCount += 1
      existing.waiters.insert(waiterID)
      flights[trigger] = existing
      flight = existing
    } else {
      let policy = policies.policy(for: trigger)
      let task = Task { [self] in await perform(trigger: trigger, policy: policy) }
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

  public func cancel(_ trigger: RSSFeedRefreshTrigger) {
    let flight = flights.removeValue(forKey: trigger)
    flight?.task.cancel()
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

  private func perform(
    trigger: RSSFeedRefreshTrigger, policy: RSSFeedRefreshPassPolicy
  ) async -> RSSFeedRefreshPassResult {
    guard Task.isCancelled == false else { return .gated }

    // A task-group scope waits for cancellation-insensitive children before it returns. Keep
    // cancellable handles instead so the pass deadline still bounds the coordinator itself.
    let (results, continuation) = AsyncStream<RaceResult>.makeStream()
    let work = Task { [self] in
      let result = await performWork(trigger: trigger, policy: policy)
      continuation.yield(.work(result))
    }
    let deadline = Task {
      do {
        try await Task.sleep(for: policy.maximumDuration)
        continuation.yield(.deadline)
      } catch {}
    }
    let first = await withTaskCancellationHandler {
      var iterator = results.makeAsyncIterator()
      return await iterator.next()
    } onCancel: {
      work.cancel()
      deadline.cancel()
      continuation.finish()
    }
    continuation.finish()
    work.cancel()
    deadline.cancel()

    guard Task.isCancelled == false, let first else { return .gated }
    switch first {
    case .work(let result): return result
    case .deadline: return .timedOut
    }
  }

  private func performWork(
    trigger: RSSFeedRefreshTrigger, policy: RSSFeedRefreshPassPolicy
  ) async -> RSSFeedRefreshPassResult {
    guard await refreshIsAllowed(),
      let feedIDs = try? await candidates.refreshFeedIDs(),
      Task.isCancelled == false
    else { return .gated }

    let boundedFeedIDs = Array(feedIDs.prefix(policy.maxFeedsPerPass))
    let hitFeedBudget = feedIDs.count > boundedFeedIDs.count
    guard boundedFeedIDs.isEmpty == false else {
      return RSSFeedRefreshPassResult(
        attemptedCount: 0, succeededCount: 0, failedCount: 0,
        hitFeedBudget: hitFeedBudget)
    }

    var attemptedCount = 0
    var succeededCount = 0
    var failedCount = 0
    let globalEnabled =
      trigger.isSystemScheduled
      ? await notificationIntent.isNewEpisodeNotificationEnabled() : false
    let context = RSSNotificationDiscoveryContext(
      source: trigger.isSystemScheduled ? .background : .foreground,
      globalEnabled: globalEnabled, discoveredAt: Date())
    for feedID in boundedFeedIDs {
      guard await refreshIsAllowed() else { break }
      // Stamped before the refresh, not on its outcome: a deadline that cuts this feed off
      // mid-fetch leaves nothing to record afterwards, and the feed must still rotate back. A
      // failed stamp costs the feed one pass's place, never its refresh.
      try? await candidates.recordRefreshAttempt(feedID: feedID, at: now())
      attemptedCount += 1
      do {
        guard let itemID = PodcastSourceIdentity.rss(feedId: feedID)?.itemId else {
          failedCount += 1
          continue
        }
        _ = try await RSSNotificationDiscoveryScope.$context.withValue(context) {
          try await refreshing.refresh(itemID: itemID)
        }
        succeededCount += 1
      } catch is CancellationError {
        break
      } catch {
        failedCount += 1
      }
    }
    if trigger.isSystemScheduled, Task.isCancelled == false {
      await backgroundCompletion.completeBackgroundRefresh(now: Date())
    }
    return RSSFeedRefreshPassResult(
      attemptedCount: attemptedCount,
      succeededCount: succeededCount,
      failedCount: failedCount,
      hitFeedBudget: hitFeedBudget)
  }

  private func refreshIsAllowed() async -> Bool {
    guard Task.isCancelled == false,
      await nativeSubscriptions.isEnabled(),
      networkConditions.isLowPowerMode == false,
      networkConditions.isConstrainedOrCellular == false
    else { return false }
    return true
  }
}
