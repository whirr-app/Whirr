import CoreSupport
import Foundation
import GRDB
import Persistence

/// The current account's record-name key, readable synchronously.
///
/// `PodcastCloudSavedIntentResolver` asks for the key from inside a GRDB write transaction, where
/// it cannot await an actor, so the coordinator publishes the key here as it resolves it. `nil`
/// means the cloud cannot name records right now, which the resolver treats as a skip.
public final class PodcastCloudRecordNameKeyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var key: PodcastCloudRecordNameKey?

  public init(_ key: PodcastCloudRecordNameKey? = nil) {
    self.key = key
  }

  public var current: PodcastCloudRecordNameKey? {
    lock.lock()
    defer { lock.unlock() }
    return key
  }

  func set(_ key: PodcastCloudRecordNameKey?) {
    lock.lock()
    defer { lock.unlock() }
    self.key = key
  }
}

public enum PodcastCloudSyncCoordinatorError: Error, Sendable, Equatable {
  /// `enable` before `attach`: there is no engine to start.
  case notAttached
  case notEnabled
}

/// The outbox-backed `PodcastCloudSyncHandling` conformer.
///
/// The App's `CKSyncEngine` adapter is translation only; every decision lives here, where
/// `FakePodcastCloudSyncing` can drive it without an iCloud account: the fetch-before-upload
/// barrier, batch contents, split or repair of a failed batch, conflict merge, what a fetched
/// record may change, and account change, quota and zone loss.
///
/// Lifecycle:
///
/// 1. `enable` with a resolved installation and a fence. A completed bootstrap in the same
///    namespace resumes directly into a converging engine; anything else closes the barrier and
///    bootstraps.
/// 2. Bootstrap: an engine with `automaticallySync: false` is started, even for an unavailable
///    account, so account changes have a listener. On first enable it creates the zone first, then
///    fetches, applying every event durably. Only a successful fetch, with nothing having fenced
///    the session meanwhile, completes the barrier.
/// 3. The bootstrap engine is stopped and its single replacement starts with
///    `automaticallySync: true` and the persisted serialization.
///
/// Engine teardown never happens inside `handle`: events arrive inside the engine's own delegate
/// callback, so stopping it there would wait on the operation delivering the event. Events set
/// state; the command awaiting the engine acts on it afterwards.
public actor PodcastCloudSyncCoordinator: PodcastCloudSyncHandling {
  enum Phase: Equatable {
    case idle
    case bootstrapping
    case running
    /// Signed out, switched, or started without a user record. Sends stay off until `enable` is
    /// called again with the new fence (the App advances the account epoch).
    case signedOut
    case zoneLost
  }

  let database: AppDatabase
  let transport: PodcastCloudTransportStore
  let applier: any PodcastCloudRemoteApplying
  let keyringStore: (any PodcastCloudKeyringStore)?
  public nonisolated let recordNameKeys: PodcastCloudRecordNameKeyBox
  let now: @Sendable () -> Date
  let monotonic: PodcastCloudMonotonicSource
  /// Failure kinds, record kinds, service codes and counts only: record names, titles, URLs and
  /// payloads never reach this log.
  static let log = CoreLogging.logger(category: "PodcastCloudSync")

  var engine: (any PodcastCloudSyncing)?
  var resolution: PodcastCloudInstallationResolution?
  var fence: PodcastCloudAccountFence?
  var namespace: Data?
  var phase: Phase = .idle
  var status: PodcastCloudSyncStatus = .off
  /// When a fetch last completed without error. Process-local; the runtime keeps it across
  /// launches.
  public internal(set) var lastSuccessfulFetch: Date?
  /// A zone fetch reported failure since the current explicit fetch began.
  var zoneFetchFailed = false
  var zoneIntent: PodcastCloudZoneIntent = .expectExisting
  var bootstrapFetchSucceeded = false
  var zoneDeletionSucceeded = false
  var quotaPaused = false
  /// A local edit failed to publish and is still in the dirty log. `.interrupted` outlasts a clean
  /// fetch or send until a drain gets it out, so the status never reads as done while it is stuck.
  var drainFaulted = false
  /// Sends handed to the engine and not yet reported on, by record name. Process-local on
  /// purpose: a ledger lost to process death costs a resend, which comes back as
  /// `serverRecordChanged` against this device's own write and merges to a no-op.
  var inFlight: [String: PodcastCloudPendingSend] = [:]
  /// The adaptive record ceiling. `limitExceeded` halves it; a clean batch doubles it back.
  var recordCeiling = PodcastCloudBatchLimits.standard.maximumRecords
  /// The local row ids playing right now, from `RSSActivePlaybackTracker` by way of
  /// `PodcastCloudSyncRuntime`. SyncEngine cannot import AppModel, so this is how a currently
  /// playing episode's local row reaches the admission decision. Defaults to empty.
  let activeEpisodeRowIDs: @Sendable () -> Set<Int64>

  public init(
    database: AppDatabase,
    applier: any PodcastCloudRemoteApplying = PodcastCloudHoldingApplier(),
    keyringStore: (any PodcastCloudKeyringStore)? = nil,
    recordNameKeys: PodcastCloudRecordNameKeyBox = PodcastCloudRecordNameKeyBox(),
    now: @escaping @Sendable () -> Date = Date.init,
    activeEpisodeRowIDs: @escaping @Sendable () -> Set<Int64> = { [] },
    monotonic: PodcastCloudMonotonicSource = .process
  ) {
    self.database = database
    self.transport = PodcastCloudTransportStore(database: database)
    self.applier = applier
    self.keyringStore = keyringStore
    self.recordNameKeys = recordNameKeys
    self.now = now
    self.monotonic = monotonic
    self.activeEpisodeRowIDs = activeEpisodeRowIDs
  }

  /// Binds the engine. The engine takes this coordinator as its handler at construction, so the
  /// two are created in that order and joined here. The coordinator owns the engine; the engine
  /// holds this coordinator weakly (ADR 0018), so whoever created the coordinator keeps it alive.
  public func attach(_ engine: any PodcastCloudSyncing) {
    self.engine = engine
  }

  public var currentStatus: PodcastCloudSyncStatus { status }

  /// The opaque transport namespace for a fence. Deterministic, so the same fence always names the
  /// same outbox rows, and complete, so any change of container, environment, zone, user or epoch
  /// is a different namespace.
  public static func namespace(for fence: PodcastCloudAccountFence) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(fence)
  }

  // MARK: - Lifecycle

  public func enable(
    resolution: PodcastCloudInstallationResolution, fence: PodcastCloudAccountFence
  ) async throws {
    guard let engine else { throw PodcastCloudSyncCoordinatorError.notAttached }
    if phase != .idle {
      await engine.stop()
      resetSession()
    }
    let namespace = try Self.namespace(for: fence)
    self.resolution = resolution
    self.fence = fence
    self.namespace = namespace

    let stored = try await transport.state()
    if stored.namespace == namespace, stored.bootstrapComplete, fence.iCloudUserRecordID != nil {
      try await startConverging(engineState: stored.engineState)
      await resolveRecordNameKey()
      await publishLocalChanges()
      return
    }
    try await transport.activate(namespace: namespace)
    try await startBootstrap()
  }

  /// The screen's Try Again, and the retry path for a bootstrap that did not complete. Explicit
  /// fetches and sends are reserved for this, first enable, stale foreground recovery and the
  /// restore barrier.
  public func syncNow() async throws {
    guard let engine else { throw PodcastCloudSyncCoordinatorError.notAttached }
    switch phase {
    case .bootstrapping:
      await continueBootstrap()
    case .running:
      if quotaPaused {
        quotaPaused = false
        await setStatus(.upToDate)
        await outboxDidChange()
      }
      await retryHeldSends()
      try await fetchExplicitly(engine)
      try await engine.sendChanges()
    case .idle, .signedOut, .zoneLost:
      throw PodcastCloudSyncCoordinatorError.notEnabled
    }
  }

  /// Publishes the dirty log and sends now, rather than on the engine's own schedule. For the
  /// moments iOS may suspend the app before that schedule runs: a pause, or leaving the
  /// foreground. Does nothing before the barrier has passed, or while storage is full.
  public func sendPendingChanges() async throws {
    guard phase == .running, quotaPaused == false, let engine else { return }
    await publishLocalChanges()
    try await engine.sendChanges()
  }

  /// Foreground catch-up for a stale session: sends what is pending, then fetches,
  /// unless a fetch completed within `interval`. A failure is the caller's to log; it changes no
  /// status, because being offline is not a sync fault.
  public func catchUp(skippingFetchWithin interval: TimeInterval) async throws {
    guard phase == .running, let engine else { return }
    try await sendPendingChanges()
    if let lastSuccessfulFetch, now().timeIntervalSince(lastSuccessfulFetch) < interval { return }
    try await fetchExplicitly(engine)
  }

  /// A fetch that returns without throwing reached iCloud, even when it delivered no zone events:
  /// the engine reports a zone's fetch only when the database fetch found that zone changed. The
  /// engine returns only after its fetch events are handled, so a zone failure is already known.
  private func fetchExplicitly(_ engine: any PodcastCloudSyncing) async throws {
    zoneFetchFailed = false
    try await engine.fetchChanges()
    if phase == .running, zoneFetchFailed == false { lastSuccessfulFetch = now() }
  }

  /// Turning sync off fences and tears down; it never deletes cloud data, and local
  /// content and the outbox stay. Re-enabling repeats the barrier only if the namespace changed or
  /// the bootstrap never completed.
  public func disable() async {
    await engine?.stop()
    resetSession()
    status = .off
    recordNameKeys.set(nil)
  }

  /// Hands the running engine the outbox's current names. Call after committing a local mutation
  /// that enqueued work; the engine otherwise only learns of rows at construction.
  public func outboxDidChange() async {
    guard phase == .running, !quotaPaused, let engine, let namespace else { return }
    guard let work = try? await transport.pendingWork(namespace: namespace), !work.isEmpty else {
      return
    }
    await engine.schedule(work)
  }

  /// Stamps and enqueues whatever local edits the dirty log holds, then hands the engine the new
  /// work. The App calls this when the log changes; it is a no-op until the session is running
  /// with a record-name key, and the log simply waits until then.
  public func publishLocalChanges() async {
    guard phase == .running else { return }
    do {
      if try await drainLocalChanges() > 0 { await outboxDidChange() }
    } catch {
      drainFaulted = true
      await interrupt("the local change drain threw \(Self.describe(error))")
    }
  }

  /// Drains the dirty log in one transaction and returns how many records it enqueued.
  /// `markingAll` first registers existing follows and marks every local entity, so pre-sync
  /// history reaches the outbox.
  ///
  /// A failing entry stays in the log, so the drain stops when a pass clears nothing, not when the
  /// log is empty, and the failure reads as `interrupted` until a later drain publishes it.
  func drainLocalChanges(markingAll: Bool = false) async throws -> Int {
    guard let key = recordNameKeys.current else { return 0 }
    let now = now()
    let monotonic = monotonic
    let (published, failed) = try await database.writeAsync { db in
      if markingAll {
        _ = try PodcastCloudRegistryBackfill.run(in: db)
        try PodcastCloudDirtyLog.markAll(in: db)
      }
      var published = 0
      var failed = 0
      while try PodcastCloudDirtyLog.isEmpty(in: db) == false {
        let outcome = try PodcastCloudLocalReconciler.drain(
          in: db, recordNameKey: key, now: now, seedingUnaccepted: markingAll, monotonic: monotonic)
        published += outcome.published.count
        failed = outcome.failed
        if outcome.deferred || outcome.published.isEmpty && outcome.settled == 0 { break }
      }
      return (published, failed)
    }
    drainFaulted = failed > 0
    if failed > 0 { await interrupt("\(failed) local edit(s) did not publish") }
    return published
  }

  /// Explicit recovery, after the user chose to recreate the zone: the namespace forgets
  /// its zone, so the next bootstrap creates one, and the retained outbox is sent into it once the
  /// barrier has fetched. Never called automatically.
  public func recoverFromZoneLoss() async throws {
    guard let engine, let namespace, phase == .zoneLost else {
      throw PodcastCloudSyncCoordinatorError.notEnabled
    }
    await engine.stop()
    resetSession(keepingIdentity: true)
    try await transport.forgetZone(namespace: namespace)
    try await startBootstrap()
  }

  /// The listener's explicit clock repair: clears the quarantine, re-stamps the sends skipped
  /// while it stood, and publishes the local edits that waited in the dirty log. Never called
  /// automatically. A clock that is still far ahead is quarantined again by the next admission.
  public func repairClock() async throws {
    guard phase == .running else { throw PodcastCloudSyncCoordinatorError.notEnabled }
    await resolveRecordNameKey()
    guard let key = recordNameKeys.current else { throw PodcastCloudSyncCoordinatorError.notEnabled }
    _ = try await PodcastCloudClockRepair.repair(database: database, recordNameKey: key, now: now())
    if status == .clockRepairRequired { await setStatus(.upToDate) }
    await publishLocalChanges()
    await outboxDidChange()
  }

  /// The user's "delete iCloud data". Deletes the zone, then quarantines this namespace's outbox
  /// so none of it is sent into a zone recreated later, and turns sync off. Local content stays.
  public func deleteCloudData() async throws {
    guard let engine, let namespace, phase == .running || phase == .bootstrapping else {
      throw PodcastCloudSyncCoordinatorError.notEnabled
    }
    zoneDeletionSucceeded = false
    try await engine.deleteZone()
    guard zoneDeletionSucceeded else {
      await interrupt("the zone deletion was not confirmed")
      return
    }
    try await transport.forgetZone(namespace: namespace)
    try await transport.quarantine(namespace: namespace)
    await engine.stop()
    resetSession()
    status = .off
    recordNameKeys.set(nil)
  }

  // MARK: - Bootstrap

  func startBootstrap() async throws {
    guard let engine, let resolution, let fence else { return }
    let stored = try await transport.state()
    zoneIntent = stored.zoneEstablished ? .expectExisting : .create
    phase = .bootstrapping
    bootstrapFetchSucceeded = false
    inFlight = [:]
    try await engine.start(
      PodcastCloudActivation(
        resolution: resolution, fence: fence, stateSerialization: nil, automaticallySync: false,
        zone: zoneIntent))
    // The engine exists either way, so an account change has a listener; without a user record
    // there is nothing to fetch yet.
    guard fence.iCloudUserRecordID != nil else {
      phase = .signedOut
      await setStatus(.accountUnavailable)
      return
    }
    await setStatus(.bootstrapping)
    await continueBootstrap()
  }

  /// Runs the barrier as far as it will go. Every early return leaves it closed, which is the
  /// safe state: a failed or cancelled fetch keeps the barrier closed.
  func continueBootstrap() async {
    guard let engine, let namespace, phase == .bootstrapping else { return }
    do {
      if zoneIntent == .create, try await transport.state().zoneEstablished == false {
        try await engine.sendChanges()
        guard phase == .bootstrapping, try await transport.state().zoneEstablished else { return }
      }
      // The key comes before the fetch: projecting a fetched subscription, setting or episode
      // state means naming local entities in the account's keyed form.
      if let keyringStore {
        recordNameKeys.set(try await PodcastCloudKeyringBootstrap().resolveKey(using: keyringStore))
      }
      guard phase == .bootstrapping, self.namespace == namespace else { return }
      // Local history enters the outbox before any remote value arrives:
      // admission then merges each fetched record with it as a pending send. Projecting first
      // would overwrite local state that should have won, such as a finish from before sync.
      _ = try await drainLocalChanges(markingAll: true)
      bootstrapFetchSucceeded = false
      try await engine.fetchChanges()
      guard phase == .bootstrapping, bootstrapFetchSucceeded, self.namespace == namespace else {
        return
      }
      // Remote apply, system fields and fetch progress were committed as each event arrived, so
      // the persisted serialization is one this state has caught up with.
      let engineState = try await transport.state().engineState
      try await transport.completeBootstrap(namespace: namespace, engineState: engineState ?? Data())
      await engine.stop()
      try await startConverging(engineState: engineState)
    } catch {
      // Any step can land here, not only the network fetch. Domain and code only: a CloudKit
      // error's description can name records.
      let failure = error as NSError
      Self.log.error(
        "Podcast sync bootstrap failed: \(String(describing: type(of: error)), privacy: .public) \(failure.domain, privacy: .public) \(failure.code, privacy: .public)"
      )
      if phase == .bootstrapping { await setStatus(.waiting(until: nil)) }
    }
  }

  func startConverging(engineState: Data?) async throws {
    guard let engine, let resolution, let fence else { return }
    // Set before `start`: the engine asks for outstanding work while it is being constructed, and
    // that answer must come from a coordinator that already considers itself running.
    phase = .running
    inFlight = [:]
    // Before the engine exists: it asks for outstanding work while it is being constructed, and
    // a send held in an earlier session is offered once more in this one.
    await releaseHoldsForNewSession()
    try await engine.start(
      PodcastCloudActivation(
        resolution: resolution, fence: fence, stateSerialization: engineState,
        automaticallySync: true, zone: .expectExisting))
    switch status {
    case .interrupted where drainFaulted: break
    // A quarantined clock and a held record both outlive the session that found them, so a start
    // never reads as up to date over either.
    default:
      if await clockRequiresRepair() {
        await setStatus(.clockRepairRequired)
      } else {
        await setStatus(await hasHeldRecords() ? .needsAttention : .upToDate)
      }
    }
  }

  private func clockRequiresRepair() async -> Bool {
    let required = try? await database.readAsync { db in
      try PodcastCloudInstallationStore.clock(in: db)?.repairRequired ?? false
    }
    return required ?? false
  }

  /// A resumed session still needs the key for the resolver; failing to reach the keyring leaves
  /// it `nil`, which the resolver already treats as a skip, and the next enable tries again.
  func resolveRecordNameKey() async {
    guard let keyringStore, recordNameKeys.current == nil else { return }
    recordNameKeys.set(try? await PodcastCloudKeyringBootstrap().resolveKey(using: keyringStore))
  }

  func resetSession(keepingIdentity: Bool = false) {
    phase = .idle
    inFlight = [:]
    quotaPaused = false
    drainFaulted = false
    bootstrapFetchSucceeded = false
    zoneDeletionSucceeded = false
    recordCeiling = PodcastCloudBatchLimits.standard.maximumRecords
    if keepingIdentity == false {
      resolution = nil
      fence = nil
      namespace = nil
    }
  }

  /// A retryable failure. It never masks a state that needs the listener or the service to act:
  /// a held record, a lost zone, a clock repair, full storage or a signed-out account.
  func interrupt(_ reason: String) async {
    Self.log.error("Podcast sync interrupted: \(reason, privacy: .public)")
    switch status {
    case .off, .bootstrapping, .upToDate, .waiting, .interrupted:
      await setStatus(.interrupted)
    case .needsAttention, .zoneLost, .clockRepairRequired, .quotaExceeded, .accountUnavailable:
      break
    }
  }

  /// A fetch or send pass that completed cleanly clears an interruption, unless a local edit is
  /// still stuck in the dirty log.
  func clearInterruption() async {
    guard status == .interrupted, drainFaulted == false else { return }
    await setStatus(.upToDate)
  }

  /// An error's type, domain and code: enough to tell failures apart, and nothing that names a
  /// record or a show.
  public static func describe(_ error: any Error) -> String {
    let bridged = error as NSError
    return "\(type(of: error)) (\(bridged.domain) \(bridged.code))"
  }

  func setStatus(_ newStatus: PodcastCloudSyncStatus) async {
    status = newStatus
    guard let namespace else { return }
    try? await transport.setStatus(
      newStatus.token, retryAfter: newStatus.retryAfter, namespace: namespace)
  }
}
