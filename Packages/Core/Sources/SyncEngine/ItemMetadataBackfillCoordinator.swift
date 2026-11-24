import ABSApi
import CoreSupport
import Foundation
import Persistence

/// Incrementally enriches book rows written by the paginated library pull. The actor owns only
/// admission and pacing; coverage remains the database's `expandedMetadataFetchedAt` projection.
public actor ItemMetadataBackfillCoordinator {
  private static let pageSize = 200
  private static let batchSize = 50

  private let accountDAO: AccountDAO
  private let itemDAO: ItemDAO
  private let client: ABSClient
  private let persistor: any ExpandedItemBatchPersisting
  private let clock: any SyncClock
  private let randomSource: @Sendable () -> Double

  private var backoff: ABSApi.BackoffPolicy?
  private var nextAttemptAllowedAt: Date?
  private var isRunning = false

  public init(
    database: AppDatabase,
    client: ABSClient,
    clock: any SyncClock = SystemSyncClock(),
    randomSource: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    self.init(
      database: database,
      client: client,
      clock: clock,
      randomSource: randomSource,
      persistor: ExpandedItemPersistor(database: database))
  }

  init(
    database: AppDatabase,
    client: ABSClient,
    clock: any SyncClock,
    randomSource: @escaping @Sendable () -> Double,
    persistor: any ExpandedItemBatchPersisting
  ) {
    accountDAO = AccountDAO(database: database)
    itemDAO = ItemDAO(database: database)
    self.client = client
    self.persistor = persistor
    self.clock = clock
    self.randomSource = randomSource
  }

  /// Runs at most the next 200 missing book ids (four sequential batch/get requests).
  public func backfillOnePage() async {
    await run(pageBudget: 1)
  }

  /// Continues page by page until SQL reports no missing book metadata or the caller cancels.
  public func backfillAll() async {
    await run(pageBudget: nil)
  }

  /// Returns the database-owned coverage projection without keeping a second progress counter.
  public func census() async -> ItemDAO.MetadataCensus {
    guard let accountRecord = try? await accountDAO.fetchAsync(),
      let accountID = accountRecord.id
    else {
      return ItemDAO.MetadataCensus(covered: 0, total: 0)
    }
    return
      (try? await itemDAO.expandedMetadataCensusAsync(accountId: accountID))
      ?? ItemDAO.MetadataCensus(covered: 0, total: 0)
  }

  private func run(pageBudget: Int?) async {
    guard isRunning == false, Task.isCancelled == false else { return }
    isRunning = true
    defer { isRunning = false }

    guard canAttemptNow() else { return }
    guard let accountRecord = try? await accountDAO.fetchAsync(),
      let accountID = accountRecord.id,
      let account = try? tokenAccount(for: accountRecord)
    else {
      return
    }

    var pagesRemaining = pageBudget
    // Ids this pass will not ask for again (declined by the server, or already refreshed). The
    // query also claims rows changed after their last expand, so an item dated ahead of this
    // device stays selectable after its refresh; without this ledger the loop never ends.
    var skippedServerIDs: Set<String> = []

    while pagesRemaining == nil || pagesRemaining! > 0 {
      guard Task.isCancelled == false, canAttemptNow() else { return }
      guard
        let page = try? await itemDAO.serverItemIdsNeedingExpandedMetadataAsync(
          accountId: accountID, limit: Self.pageSize)
      else {
        return
      }

      let ids = page.filter { skippedServerIDs.contains($0) == false }
      guard ids.isEmpty == false else { return }

      var committedBatches = 0
      for batch in Self.batches(ids) {
        guard Task.isCancelled == false, canAttemptNow() else { return }

        let details: [ItemDetail]
        do {
          details = try await client.batchGetItems(account: account, ids: batch)
        } catch {
          guard isCancellation(error) == false, Task.isCancelled == false else { return }
          scheduleBackoff()
          return
        }
        resetBackoff()

        let fetchedAt = clock.now()
        let entries = details.map {
          ExpandedItemBatchEntry(
            serverItemId: $0.id,
            extras: ExpandedItemPersistor.persistable(from: $0))
        }

        // Do not check cancellation inside this call: once a batch has returned, its persistence
        // is allowed to finish as one cancellation-safe unit.
        let persistence = Task.detached { [persistor] in
          try await persistor.persist(entries, accountId: accountID, fetchedAt: fetchedAt)
        }
        do {
          try await persistence.value
        } catch {
          return
        }

        committedBatches += 1
        LibraryRefreshPerfTrace.emit(
          .metadataCommit(index: committedBatches, items: entries.count))

        // Claim the requested ids only after their returned details have committed. The server
        // may omit an id, so the whole requested batch is claimed to let this pass terminate.
        skippedServerIDs.formUnion(batch)
      }

      if let remaining = pagesRemaining {
        pagesRemaining = remaining - 1
      }
    }
  }

  private func canAttemptNow() -> Bool {
    guard let nextAttemptAllowedAt else { return true }
    return clock.now() >= nextAttemptAllowedAt
  }

  private func scheduleBackoff() {
    let now = clock.now()
    var policy = backoff ?? ABSApi.BackoffPolicy()
    let delay = policy.nextDelay(now: now, randomUnit: randomSource())
    backoff = policy
    nextAttemptAllowedAt = now.addingTimeInterval(delay)
  }

  private func resetBackoff() {
    backoff = nil
    nextAttemptAllowedAt = nil
  }

  private func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? APIError) == .cancelled
  }

  private static func batches(_ ids: [String]) -> [[String]] {
    stride(from: 0, to: ids.count, by: Self.batchSize).map { start in
      Array(ids[start..<Swift.min(start + Self.batchSize, ids.count)])
    }
  }
}
