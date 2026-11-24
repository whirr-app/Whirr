import ABSApi
import Foundation
import Persistence

/// File cleanup owned by the shared RSS download coordinator. The feed manager snapshots these
/// rows before deleting a subscription, then asks the coordinator to remove only those persisted
/// RSS paths after the database delete succeeds.
public protocol RSSDownloadFileCleaning: Sendable {
  func rssDownloadFiles(forFeedID feedID: Int64) async throws -> [RSSDownloadRecord]
  func removeRSSDownloadFiles(_ records: [RSSDownloadRecord]) async throws
}

/// Plans a per-file download from `AudioFileCatalog`, gates and drives transfers through
/// `BackgroundTransferring` and `DownloadFileStore`, and reconciles launch state. No wire DTO
/// escapes this file: `ItemDetail`/`BookMedia` (ABSApi) are mapped away here.
public actor DownloadCoordinator: DownloadIntents, AutomaticEpisodeDownloadPlanning,
  FeedCredentialUpdateHandling, RSSDownloadFileCleaning
{
  let database: AppDatabase
  let client: ABSClient

  let accountDAO: AccountDAO

  let itemDAO: ItemDAO

  let itemChapterStore: ItemChapterStore

  let supplementStore: ItemSupplementStore

  /// Writes back an expanded response fetched for planning (as `ItemDetailExtrasService` does),
  /// so a corrected file identity is visible to every reader, not only the row this request
  /// enqueues.
  let expandedItemPersistor: ExpandedItemPersistor

  let podcastEpisodeDAO: PodcastEpisodeDAO

  let downloadStore: DownloadStore

  let downloadFileStore: DownloadFileStore

  /// Device-owned RSS download spine. Optional only for ABS-only test compositions; production
  /// and RSS compositions provide both together. Once account removal begins the computed
  /// accessors return nil: account teardown must leave RSS rows and files alone, and this
  /// coordinator is also the purge boundary used by the RSS retention reaper.
  private let rssDownloadStoreStorage: RSSDownloadStore?
  private let rssFileStoreStorage: RSSFileStore?

  var rssDownloadStore: RSSDownloadStore? {
    guard isRemovingAccount == false else { return nil }
    return rssDownloadStoreStorage
  }

  var rssFileStore: RSSFileStore? {
    guard isRemovingAccount == false else { return nil }
    return rssFileStoreStorage
  }

  /// Feed-only credentials, in their own Keychain service. Never consulted by an ABS request or
  /// token-refresh path.
  let feedCredentialStore: (any FeedCredentialStoring)?

  let backgroundTransferring: any BackgroundTransferring

  let downloadPreferences: any DownloadPreferences

  let networkConditions: any NetworkConditions

  private let diagnostics: any DiagnosticsRecording

  let freeSpaceReporting: any FreeSpaceReporting

  private var subscriptionTasks: [Task<Void, Never>] = []

  /// Downloads that have used their one renewal for the current `.downloading` attempt, so a
  /// second consecutive `.authChallenge` durably pauses instead of renewing again. Cleared when
  /// the row leaves `.downloading`, so a fresh attempt starts clean.
  var authRetriedDownloadIds: Set<Int64> = []

  /// Rows pending in the store whose live adapter task is suspended (network-held work or a
  /// user-requested resume), as opposed to never-started work that is enqueued when a slot opens.
  /// They are resumed before other pending work, and each consumes a transfer slot.
  var liveTaskOwnedDownloadIds: Set<Int64> = []

  /// Rows durably `.paused` whose adapter task is suspended, not gone. The adapter's `resume` is
  /// silent when no task exists, so only a row recorded here may take the live-task path; every
  /// other `.paused`/`.failed`/`.interrupted` row restarts through `startTransfer` or would sit
  /// `.downloading` with nothing running.
  var suspendedTaskDownloadIds: Set<Int64> = []

  var rssLiveTaskOwnedDownloadIds: Set<Int64> = []
  var rssSuspendedTaskDownloadIds: Set<Int64> = []
  var rssEventFailedDownloadIds: Set<Int64> = []

  /// Stops a failed event's trailing schedule claiming a row a fresh coordinator already requeued.
  /// Lasts until this coordinator performs that explicit resume, closing the cross-incarnation
  /// window when an async failure handler outlives its coordinator.
  var eventFailedDownloadIds: Set<Int64> = []

  /// Low-disk queue pause: sticky until a transfer actually starts again (proof the disk
  /// condition has cleared), not recomputed on every `schedule()` pass.
  var queuePauseReason: DownloadQueuePauseReason?

  var subscriptionsTornDown = false

  /// Set once `AccountRemovalCoordinator` begins and never cleared (removal is terminal; a fresh
  /// instance is composed afterwards). While set, planning refuses work and `schedule()` starts no
  /// transfers, so the purge cannot race an earlier-admitted request.
  var isRemovingAccount = false

  /// The device trace's emit (`WHIRRDL`), behind a substitutable sink because production is a
  /// DEBUG-only `NSLog` no test can observe. Only tests replace it, and no record influences any
  /// decision here.
  var emitDeviceTraceRecord: @Sendable (DownloadDeviceTrace.Record) -> Void = {
    DownloadDeviceTrace.emit($0)
  }

  var progressTraceThrottle = DownloadProgressTraceThrottle()

  /// Tail of the coordinator's serial chain. Every schedule pass and per-row intent links behind
  /// whatever was already linked and awaits its own link, so no read-decide-write sequence that
  /// spans a suspension can interleave with another mutating operation.
  var serialTail: Task<Void, Never>?

  /// Links `body` behind everything already on the chain and awaits it. Any read-decide-write
  /// sequence that spans a suspension belongs here: the chain, not the actor, is what keeps two
  /// of them from interleaving, because actors are re-entrant across `await`.
  func onChain<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let predecessor = serialTail
    let work = Task<T, any Error> {
      await predecessor?.value
      return try await body()
    }
    // The tail is a happens-before marker only, so it must never fail and never propagate.
    serialTail = Task { _ = try? await work.value }
    return try await work.value
  }

  static let maxConcurrentTransfers = 2

  /// The clock for automatic-retry deadlines, injected so tests drive time without sleeping.
  let now: @Sendable () -> Date

  let automaticRetryPolicy = AutomaticDownloadRetryPolicy.standard

  public init(
    client: ABSClient,
    database: AppDatabase,
    downloadStore: DownloadStore,
    downloadFileStore: DownloadFileStore,
    backgroundTransferring: any BackgroundTransferring,
    downloadPreferences: any DownloadPreferences,
    networkConditions: any NetworkConditions,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    freeSpaceReporting: any FreeSpaceReporting = UnboundedFreeSpaceReporting(),
    rssDownloadStore: RSSDownloadStore? = nil,
    rssFileStore: RSSFileStore? = nil,
    feedCredentialStore: (any FeedCredentialStoring)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    self.now = now
    self.client = client
    accountDAO = AccountDAO(database: database)
    itemDAO = ItemDAO(database: database)
    itemChapterStore = ItemChapterStore(database: database)
    expandedItemPersistor = ExpandedItemPersistor(database: database)
    podcastEpisodeDAO = PodcastEpisodeDAO(database: database)
    self.downloadStore = downloadStore
    self.downloadFileStore = downloadFileStore
    supplementStore = ItemSupplementStore(
      database: database, downloadRootURL: downloadFileStore.rootURL)
    rssDownloadStoreStorage = rssDownloadStore
    rssFileStoreStorage = rssFileStore
    self.feedCredentialStore = feedCredentialStore
    self.backgroundTransferring = backgroundTransferring
    self.downloadPreferences = downloadPreferences
    self.networkConditions = networkConditions
    self.diagnostics = diagnostics
    self.freeSpaceReporting = freeSpaceReporting
  }

  /// Production construction: also wires the subscriptions, since a plain actor `init` cannot let
  /// `self` escape into a `Task` closure before every stored property is initialised.
  /// `backgroundTransferring.events` drives state transitions; `networkConditions.changes` and
  /// `downloadPreferences.changes` each re-run `schedule()` so a Wi-Fi-held transfer starts as
  /// soon as either condition allows it.
  public static func make(
    client: ABSClient,
    database: AppDatabase,
    downloadStore: DownloadStore,
    downloadFileStore: DownloadFileStore,
    backgroundTransferring: any BackgroundTransferring,
    downloadPreferences: any DownloadPreferences,
    networkConditions: any NetworkConditions,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    freeSpaceReporting: any FreeSpaceReporting = UnboundedFreeSpaceReporting(),
    rssDownloadStore: RSSDownloadStore? = nil,
    rssFileStore: RSSFileStore? = nil,
    feedCredentialStore: (any FeedCredentialStoring)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) -> DownloadCoordinator {
    let coordinator = DownloadCoordinator(
      client: client, database: database, downloadStore: downloadStore,
      downloadFileStore: downloadFileStore, backgroundTransferring: backgroundTransferring,
      downloadPreferences: downloadPreferences, networkConditions: networkConditions,
      diagnostics: diagnostics, freeSpaceReporting: freeSpaceReporting,
      rssDownloadStore: rssDownloadStore, rssFileStore: rssFileStore,
      feedCredentialStore: feedCredentialStore, now: now)

    let events = backgroundTransferring.events
    let eventTask = Task { [weak coordinator] in
      for await event in events {
        guard let coordinator else { return }
        await coordinator.handleTransferEvent(event)
      }
    }
    let conditionChanges = networkConditions.changes
    let conditionTask = Task { [weak coordinator] in
      for await _ in conditionChanges {
        guard let coordinator else { return }
        await coordinator.scheduleFromSubscription()
      }
    }
    let preferenceChanges = downloadPreferences.changes
    let preferenceTask = Task { [weak coordinator] in
      for await _ in preferenceChanges {
        guard let coordinator else { return }
        await coordinator.scheduleFromSubscription()
      }
    }
    // Installed back onto the actor rather than a `nonisolated` box, so the handles are guarded
    // by actor isolation like the rest of the coordinator state.
    let tasks = [eventTask, conditionTask, preferenceTask]
    Task { [weak coordinator] in
      await coordinator?.installSubscriptionTasks(tasks)
    }
    return coordinator
  }

  /// ABS-only construction for callers that do not own feed credentials, so they cannot begin
  /// consulting the feed store.
  public static func make(
    client: ABSClient,
    database: AppDatabase,
    downloadStore: DownloadStore,
    downloadFileStore: DownloadFileStore,
    backgroundTransferring: any BackgroundTransferring,
    downloadPreferences: any DownloadPreferences,
    networkConditions: any NetworkConditions,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    freeSpaceReporting: any FreeSpaceReporting = UnboundedFreeSpaceReporting(),
    rssDownloadStore: RSSDownloadStore? = nil,
    rssFileStore: RSSFileStore? = nil
  ) -> DownloadCoordinator {
    make(
      client: client, database: database, downloadStore: downloadStore,
      downloadFileStore: downloadFileStore, backgroundTransferring: backgroundTransferring,
      downloadPreferences: downloadPreferences, networkConditions: networkConditions,
      diagnostics: diagnostics, freeSpaceReporting: freeSpaceReporting,
      rssDownloadStore: rssDownloadStore, rssFileStore: rssFileStore,
      feedCredentialStore: nil)
  }

  private func installSubscriptionTasks(_ tasks: [Task<Void, Never>]) {
    guard subscriptionsTornDown == false else {
      // `teardown()` won the race with this hand-off, so cancel the tasks here rather than store
      // handles nothing will ever stop.
      for task in tasks { task.cancel() }
      return
    }
    subscriptionTasks = tasks
  }

  /// Returns whether an ABS or RSS row currently owns an active transfer. Wi-Fi-held rows remain
  /// `.pending` with a suspended task and therefore do not block an endpoint composition switch.
  public func hasActiveTransfers() async -> Bool {
    let absRows = (try? await downloadStore.fetchAllAsync()) ?? []
    if absRows.contains(where: { $0.state == .downloading }) {
      return true
    }
    let rssRows = (try? await rssDownloadStore?.fetchAllAsync()) ?? []
    return rssRows.contains(where: { $0.state == .downloading })
  }

  /// Test seam for the device trace; see `emitDeviceTraceRecord`.
  func setDeviceTraceSink(_ sink: @escaping @Sendable (DownloadDeviceTrace.Record) -> Void) {
    emitDeviceTraceRecord = sink
  }

  /// Stops all three environment subscribers. App composition calls this before discarding the
  /// coordinator during account removal or environment rebuild; repeated calls are harmless.
  public func teardown() {
    subscriptionsTornDown = true
    for task in subscriptionTasks { task.cancel() }
    subscriptionTasks.removeAll()
  }

  // MARK: - Auth recovery

  /// Called by `ResolutionCenter` once the user's re-authentication succeeds, the only automatic
  /// exit from `.pausedAuth`. Requeues every `.pausedAuth` row to `.pending` and resumes through
  /// the scheduler, never a direct restart.
  public func handleSuccessfulReauthentication() async {
    let rows = (try? await downloadStore.fetchAllAsync()) ?? []
    for row in rows where row.state == .pausedAuth {
      guard let id = row.id else { continue }
      _ = try? await downloadStore.transitionAsync(downloadId: id, to: .pending)
    }
    await schedule()
  }

  /// Requeues only `.pausedAuth(.feedCredentials)` rows for the updated feed, then lets the
  /// scheduler mint a new request with the current Keychain value. ABS auth rows and token
  /// refresh are unreachable from here.
  public func handleFeedCredentialUpdate(feedId: Int64) async {
    guard let rssDownloadStore else { return }
    _ = try? await rssDownloadStore.releaseFeedCredentialHolds(feedId: feedId)
    await schedule()
  }

  // MARK: - RSS feed deletion (NativeFeedManaging)

  public func rssDownloadFiles(forFeedID feedID: Int64) async throws -> [RSSDownloadRecord] {
    guard let rssDownloadStore else { return [] }
    let episodeStore = RSSEpisodeStore(database: database)
    var matchingRows: [RSSDownloadRecord] = []
    for row in try await rssDownloadStore.fetchAllAsync() {
      guard let episode = try await episodeStore.fetchEpisode(episodeId: row.episodeId),
        episode.feedId == feedID
      else { continue }
      matchingRows.append(row)
    }
    return matchingRows
  }

  public func removeRSSDownloadFiles(_ records: [RSSDownloadRecord]) async throws {
    guard let rssFileStore else { return }
    for record in records {
      let destination = try rssFileStore.transferDestinationURL(
        forRelativePath: record.relativePath)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
    }
  }

  // MARK: - Launch reconciliation

  /// Called once per launch by app composition. `DownloadStore.init` has already rewritten
  /// `.downloading` rows to `.interrupted`; this joins them against the adapter's live-task
  /// snapshot. An `.interrupted` row with a live task, or an undelivered finish, is restored to
  /// `.downloading` without a duplicate enqueue; otherwise it is requeued to `.pending`. Any live
  /// task with no row is cancelled.
  public func reconcileAfterLaunch() async {
    _ = try? await onChain { [self] in
      await self.performReconcileAfterLaunch()
    }
    await schedule()
  }

  private func performReconcileAfterLaunch() async {
    // `run()` is synchronous; its post-walk row re-verification is the orphan safety boundary
    // if it ever gains suspension points.
    _ = try? DownloadIntegritySweep(
      rootURL: downloadFileStore.rootURL, downloadStore: downloadStore
    ).run()
    if let rssDownloadStore {
      _ = try? RSSDownloadIntegritySweep(
        rootURL: downloadFileStore.rootURL, downloadStore: rssDownloadStore
      ).run()
    }

    let rows = (try? await downloadStore.fetchAllAsync()) ?? []
    let rssRows = (try? await rssDownloadStore?.fetchAllAsync()) ?? []
    let liveTasks = await backgroundTransferring.currentTasks()
    let liveTaskIdentities = Set(liveTasks.map(\.identity))
    // A transfer that finished while the process was gone has left `currentTasks()` but not yet
    // been delivered. Its `.interrupted` row is reattached like a live one so the buffered
    // `.finished` completes it. It owns no live or suspended task, so the joins below use
    // `liveTaskIdentities` alone.
    let reattachableIdentities = liveTaskIdentities.union(
      await backgroundTransferring.undeliveredFinishes())
    let adopted = rows.compactMap { row -> Int64? in
      guard row.state == .pending, row.holdReason == .waitingForWiFi,
        let id = row.id, liveTaskIdentities.contains(.abs(rowID: id))
      else { return nil }
      return id
    }
    liveTaskOwnedDownloadIds.formUnion(adopted)
    // A `.paused` row whose suspended task outlived the process is what the in-memory set records
    // mid-session. Adopt it, or the first resume after launch would enqueue a second transfer
    // beside the one still in the background session.
    suspendedTaskDownloadIds.formUnion(
      rows.compactMap { row -> Int64? in
        guard row.state == .paused, let id = row.id, liveTaskIdentities.contains(.abs(rowID: id)) else { return nil }
        return id
      })
    rssLiveTaskOwnedDownloadIds.formUnion(
      rssRows.compactMap { row -> Int64? in
        guard row.state == .pending, row.holdReason == .waitingForWiFi,
          let id = row.id, liveTaskIdentities.contains(.rss(rowID: id))
        else { return nil }
        return id
      })
    rssSuspendedTaskDownloadIds.formUnion(
      rssRows.compactMap { row -> Int64? in
        guard row.state == .paused, let id = row.id, liveTaskIdentities.contains(.rss(rowID: id)) else { return nil }
        return id
      })
    var reattached = 0
    var requeued = 0
    for row in rows where row.state == .interrupted {
      guard let id = row.id else { continue }
      // `rows` predates this method's awaits, so a redelivered cancellation may already have
      // moved the row `.interrupted -> .failed` (a legal edge) and inserted its marker.
      // Requeuing is still right, but the marker must not outlive the `.failed` state, or the
      // row returns to `.pending` yet is skipped by every later pass for a failure that is no
      // longer true (`active=0 pending=1 slots=2` with every gate open).
      if (try? await downloadStore.transitionAsync(downloadId: id, to: .pending)) != nil {
        eventFailedDownloadIds.remove(id)
      }
      if reattachableIdentities.contains(.abs(rowID: id)) {
        _ = try? await downloadStore.transitionAsync(downloadId: id, to: .downloading)
        reattached += 1
      } else {
        requeued += 1
      }
    }
    if let rssDownloadStore {
      for row in rssRows where row.state == .interrupted {
        guard let id = row.id else { continue }
        // Same stale-snapshot marker rule as the ABS loop.
        if (try? await rssDownloadStore.transitionAsync(downloadId: id, to: .pending)) != nil {
          rssEventFailedDownloadIds.remove(id)
          if reattachableIdentities.contains(.rss(rowID: id)) {
            _ = try? await rssDownloadStore.transitionAsync(downloadId: id, to: .downloading)
            reattached += 1
          } else {
            requeued += 1
          }
        }
      }
    }

    // Planning may create a row while the adapter snapshot is in flight. Schedules are fenced by
    // the serial chain, and this final read decides orphans against the durable identities at
    // the cancellation boundary rather than the entry snapshot.
    let currentRows = (try? await downloadStore.fetchAllAsync()) ?? []
    let currentRSSRows = (try? await rssDownloadStore?.fetchAllAsync()) ?? []
    let rowIdentities = Set(currentRows.compactMap(\.id).map { TransferIdentity.abs(rowID: $0) })
      .union(currentRSSRows.compactMap(\.id).map { TransferIdentity.rss(rowID: $0) })
    var orphansCancelled = 0
    for task in liveTasks where rowIdentities.contains(task.identity) == false {
      await backgroundTransferring.cancel(identity: task.identity)
      orphansCancelled += 1
    }

    // One line for the whole join: a reattach and a restart-from-zero leave the same durable table
    // and progress bar, so this is the only way to tell them apart.
    emitDeviceTraceRecord(
      .reconcile(
        DownloadDeviceTrace.Reconcile(
          rows: rows.count, liveTasks: liveTasks.count, reattached: reattached, requeued: requeued,
          orphansCancelled: orphansCancelled, heldAdopted: adopted.count)))
  }

  private func scheduleFromSubscription() async {
    guard subscriptionsTornDown == false else { return }
    await schedule()
  }

  func recordDownloadDiagnostic(
    accountId: Int64, statusClass: DiagnosticsStatusClass
  ) async {
    await diagnostics.record(
      DiagnosticsEvent(category: .download, statusClass: statusClass, durationMilliseconds: 0),
      accountId: accountId)
  }
}
