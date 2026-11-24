import ABSApi
import Foundation
import Persistence

/// What asked for a listening-stats refresh.
public enum ListeningStatsRefreshTrigger: Sendable, Equatable {
  /// The listener asked: the Stats screen opened, or Home was pulled to refresh. Always fetches.
  case explicit
  /// Home appeared. Fetches only when the snapshot is missing or older than
  /// `ListeningStatsCoordinator.appearanceRefreshInterval`.
  case appearance
}

/// The account's cached listening stats and the throttled refresh behind them.
public protocol ListeningStatsProviding: Sendable {
  /// The stored snapshot for the current account. Never touches the network.
  func cachedListeningStats() async -> ListeningStatsSnapshot?

  /// Refreshes the snapshot when `trigger` allows, running `beforeFetch` first only when a request
  /// will actually be made (the caller's local-session upload drain, so offline listening is
  /// counted). Returns `true` when the snapshot is current: freshly fetched, or fresh enough that
  /// no request was needed. Never throws.
  @discardableResult
  func refreshListeningStats(
    trigger: ListeningStatsRefreshTrigger, beforeFetch: @escaping @Sendable () async -> Void
  ) async -> Bool
}

extension ListeningStatsProviding {
  @discardableResult
  public func refreshListeningStats(trigger: ListeningStatsRefreshTrigger) async -> Bool {
    await refreshListeningStats(trigger: trigger, beforeFetch: {})
  }
}

/// For compositions with no server account: always empty, never refreshed.
public struct NoOpListeningStatsProviding: ListeningStatsProviding {
  public init() {}
  public func cachedListeningStats() async -> ListeningStatsSnapshot? { nil }

  @discardableResult
  public func refreshListeningStats(
    trigger: ListeningStatsRefreshTrigger, beforeFetch: @escaping @Sendable () async -> Void
  ) async -> Bool { false }
}

/// Fetches `GET /api/me/listening-stats` and keeps the trimmed result as the account's snapshot.
///
/// The route reads every session ever on each call, so API-CONVENTIONS applies: appearance
/// refreshes are throttled, overlapping refreshes share one request, and nothing runs from
/// background refresh. A separate actor, like `ListeningHistoryCoordinator`.
public actor ListeningStatsCoordinator: ListeningStatsProviding {
  /// Home's appearance refetches at most this often.
  public static let appearanceRefreshInterval: TimeInterval = 30 * 60
  /// The most recent days with listening kept in the snapshot: enough for a year of chart and any
  /// realistic streak.
  static let retainedDays = 400
  /// The largest titles kept; the Stats screen shows ten.
  static let retainedTitles = 50

  private let client: ABSClient
  private let accountDAO: AccountDAO
  private let store: ListeningStatsSnapshotStore
  private let now: @Sendable () -> Date
  private var inFlight: (accountId: Int64, task: Task<Bool, Never>)?
  /// Callers that joined a refresh already in flight rather than starting their own. Lets a test
  /// know an overlapping caller has joined before it releases the first request.
  private(set) var joinedRefreshCount = 0

  public init(client: ABSClient, database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
    self.client = client
    accountDAO = AccountDAO(database: database)
    store = ListeningStatsSnapshotStore(database: database)
    self.now = now
  }

  public func cachedListeningStats() async -> ListeningStatsSnapshot? {
    guard let accountId = try? accountDAO.fetch()?.id else { return nil }
    return try? await store.snapshot(accountId: accountId)
  }

  @discardableResult
  public func refreshListeningStats(
    trigger: ListeningStatsRefreshTrigger, beforeFetch: @escaping @Sendable () async -> Void
  ) async -> Bool {
    guard let accountRecord = try? accountDAO.fetch(), let accountId = accountRecord.id,
      let account = try? tokenAccount(for: accountRecord)
    else { return false }

    if let inFlight, inFlight.accountId == accountId {
      joinedRefreshCount += 1
      return await inFlight.task.value
    }
    if trigger == .appearance, let stored = try? await store.snapshot(accountId: accountId) {
      let age = now().timeIntervalSince(stored.fetchedAt)
      // A snapshot dated in the future (the device clock moved back) is treated as stale.
      if age >= 0, age < Self.appearanceRefreshInterval { return true }
    }

    let task = Task { await self.fetchAndStore(accountId: accountId, account: account, beforeFetch: beforeFetch) }
    inFlight = (accountId, task)
    let result = await task.value
    if inFlight?.accountId == accountId { inFlight = nil }
    return result
  }

  private func fetchAndStore(
    accountId: Int64, account: TokenAccount, beforeFetch: @Sendable () async -> Void
  ) async -> Bool {
    await beforeFetch()
    guard let response = try? await client.fetchListeningStats(account: account) else { return false }
    let snapshot = Self.snapshot(from: response, fetchedAt: now())
    do {
      try await store.replace(accountId: accountId, with: snapshot)
      return true
    } catch {
      return false
    }
  }

  static func snapshot(from response: ListeningStatsResponse, fetchedAt: Date) -> ListeningStatsSnapshot {
    var weekdaySeconds: [Int: Double] = [:]
    for (weekday, seconds) in response.weekdays {
      weekdaySeconds[weekday.calendarWeekday] = seconds
    }
    return ListeningStatsSnapshot(
      fetchedAt: fetchedAt,
      totalSeconds: response.totalSeconds,
      days: response.days.suffix(retainedDays).map { .init(date: $0.date, seconds: $0.seconds) },
      weekdaySeconds: weekdaySeconds,
      titles: response.items.prefix(retainedTitles).map {
        .init(serverItemId: $0.id, title: $0.title, author: $0.author, seconds: $0.seconds)
      })
  }
}
