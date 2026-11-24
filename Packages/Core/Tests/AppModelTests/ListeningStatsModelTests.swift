import Foundation
import Persistence
import SyncEngine
import Testing

@testable import AppModel

/// `ListeningStatsModel` publishes the cached snapshot first, then refreshes; a failed
/// refresh keeps what it had and sets `isStale`, as `ItemHistoryModel` does.
@Suite struct ListeningStatsModelTests {

  @MainActor
  @Test("the cached snapshot is summarised before the refresh finishes")
  func cachedFirst() async {
    let provider = FakeProvider()
    provider.cached = ListeningStatsSummaryTests.snapshot(days: ["2026-11-05": 420])
    provider.refreshResult = true
    let model = Self.model(provider)

    await model.refresh(trigger: .appearance)

    #expect(model.summary?.todaySeconds == 420)
    #expect(model.isStale == false)
    #expect(provider.triggers == [.appearance])
  }

  @MainActor
  @Test("a successful refresh republishes the newly stored snapshot")
  func refreshRepublishes() async {
    let provider = FakeProvider()
    provider.cached = ListeningStatsSummaryTests.snapshot(days: ["2026-11-05": 60])
    provider.refreshResult = true
    provider.onRefresh = { provider.cached = ListeningStatsSummaryTests.snapshot(days: ["2026-11-05": 600]) }
    let model = Self.model(provider)

    await model.refresh(trigger: .explicit)

    #expect(model.summary?.todaySeconds == 600)
  }

  @MainActor
  @Test("a failed refresh keeps the cached figures and marks them stale")
  func failureIsStale() async {
    let provider = FakeProvider()
    provider.cached = ListeningStatsSummaryTests.snapshot(days: ["2026-11-05": 60])
    provider.refreshResult = false
    let model = Self.model(provider)

    await model.refresh(trigger: .explicit)

    #expect(model.summary?.todaySeconds == 60)
    #expect(model.isStale)
  }

  @MainActor
  @Test("with no snapshot and a failed refresh there is nothing to show")
  func nothingToShow() async {
    let provider = FakeProvider()
    provider.refreshResult = false
    let model = Self.model(provider)

    await model.refresh(trigger: .appearance)

    #expect(model.summary == nil)
  }

  @MainActor
  @Test("the upload drain is handed to the provider as its before-fetch step")
  func drainIsPassedThrough() async {
    let provider = FakeProvider()
    provider.refreshResult = true
    let drained = DrainFlag()
    let model = ListeningStatsModel(
      stats: provider, uploadDrain: { await drained.set() },
      now: { ListeningStatsSummaryTests.date(2026, 11, 5, hour: 12) },
      calendar: ListeningStatsSummaryTests.calendar)

    await model.refresh(trigger: .explicit)

    #expect(await drained.value)
  }

  @MainActor
  private static func model(_ provider: FakeProvider) -> ListeningStatsModel {
    ListeningStatsModel(
      stats: provider, now: { ListeningStatsSummaryTests.date(2026, 11, 5, hour: 12) },
      calendar: ListeningStatsSummaryTests.calendar)
  }
}

private actor DrainFlag {
  private(set) var value = false
  func set() { value = true }
}

private final class FakeProvider: ListeningStatsProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var _cached: ListeningStatsSnapshot?
  private var _triggers: [ListeningStatsRefreshTrigger] = []
  var refreshResult = false
  var onRefresh: (@Sendable () -> Void)?

  var cached: ListeningStatsSnapshot? {
    get { lock.withLock { _cached } }
    set { lock.withLock { _cached = newValue } }
  }

  var triggers: [ListeningStatsRefreshTrigger] { lock.withLock { _triggers } }

  func cachedListeningStats() async -> ListeningStatsSnapshot? { cached }

  func refreshListeningStats(
    trigger: ListeningStatsRefreshTrigger, beforeFetch: @escaping @Sendable () async -> Void
  ) async -> Bool {
    lock.withLock { _triggers.append(trigger) }
    await beforeFetch()
    onRefresh?()
    return refreshResult
  }
}
