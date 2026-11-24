import Foundation
import Observation
import Persistence
import SyncEngine

/// Home's listening-stats card and the Stats screen.
///
/// Cache-then-refresh like `ItemHistoryModel`: the stored snapshot is summarised first, so figures
/// show offline and at once. A failed refresh keeps the cached figures and sets `isStale`.
/// Overlapping refreshes need no coalescing: the provider shares one request between them.
@MainActor
@Observable
public final class ListeningStatsModel {
  /// `nil` until a snapshot exists for the account.
  public private(set) var summary: ListeningStatsSummary?
  /// `true` after a refresh failed, until one succeeds.
  public private(set) var isStale = false
  public private(set) var isRefreshing = false

  private let stats: any ListeningStatsProviding
  private let uploadDrain: @Sendable () async -> Void
  private let now: () -> Date
  private let calendar: Calendar

  public init(
    stats: any ListeningStatsProviding,
    uploadDrain: @escaping @Sendable () async -> Void = {},
    now: @escaping () -> Date = { Date() },
    calendar: Calendar = .autoupdatingCurrent
  ) {
    self.stats = stats
    self.uploadDrain = uploadDrain
    self.now = now
    self.calendar = calendar
  }

  /// Publishes the cached figures, then refreshes. The upload drain runs only if a request is
  /// actually made, so locally recorded listening is on the server before it is counted.
  public func refresh(trigger: ListeningStatsRefreshTrigger) async {
    await publishCached()
    isRefreshing = true
    let succeeded = await stats.refreshListeningStats(trigger: trigger, beforeFetch: uploadDrain)
    isRefreshing = false
    isStale = !succeeded
    if succeeded { await publishCached() }
  }

  private func publishCached() async {
    guard let snapshot = await stats.cachedListeningStats() else { return }
    summary = ListeningStatsSummary.make(snapshot: snapshot, now: now(), calendar: calendar)
  }
}
