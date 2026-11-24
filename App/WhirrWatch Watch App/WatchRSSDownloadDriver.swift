import Foundation
import WatchPlayback
import WatchProtocol

/// Drives the Watch's own downloads of offered RSS episodes (ADR 0020 Decision 1). The
/// received-episode store is the only source of truth: an offer, a launch, a wake and a finished
/// task all reconcile the system's tasks against `pendingDownloads()`, so exactly one task exists
/// per entry and nothing else decides what is downloading.
@MainActor
final class WatchRSSDownloadDriver {
  /// Two at a time. A Watch has one radio, and two concurrent downloads ran without either
  /// starving the other.
  static let maxConcurrentDownloads = 2

  let adapter: WatchRSSDownloadURLSessionAdapter
  private let storeProvider: @MainActor () -> WatchReceivedEpisodeStore?
  /// The signed-in account's store, read at each use: it changes with sign-in and sign-out.
  var store: WatchReceivedEpisodeStore? { storeProvider() }
  let networkPolicy: @MainActor () async -> WatchDownloadNetworkPolicy
  /// Repaints the Watch's own rows, which costs no wire traffic.
  let didProgress: @MainActor () async -> Void
  /// Tells the phone: inventory only, and only at a recorded step or an outcome.
  let didChange: @MainActor () async -> Void

  private var tasks: [WatchRSSDownloadKey: URLSessionDownloadTask] = [:]
  /// The last fraction written to the store. `didWriteData` fires many times a second and every
  /// store write persists a JSON file, so writes are kept to about one percent.
  private var lastStoredProgress: [WatchRSSDownloadKey: Double] = [:]
  private var lastReportedProgress: [WatchRSSDownloadKey: Double] = [:]
  private var reconcileTask: Task<Void, Never>?
  private var needsReconcile = false
  private var reconcileGeneration = 0
  /// Durable work a delegate callback started (a commit and the change it reports) that has not
  /// finished. A WatchKit task released while this is not zero lets watchOS suspend the app before
  /// the file is committed and the inventory is handed to WatchConnectivity.
  private var unsettledCallbacks = 0
  private var settleWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    rootURL: URL,
    networkPolicy: @escaping @MainActor () async -> WatchDownloadNetworkPolicy,
    store: @escaping @MainActor () -> WatchReceivedEpisodeStore?,
    didProgress: @escaping @MainActor () async -> Void,
    didChange: @escaping @MainActor () async -> Void
  ) {
    self.networkPolicy = networkPolicy
    storeProvider = store
    self.didProgress = didProgress
    self.didChange = didChange
    self.adapter = WatchRSSDownloadURLSessionAdapter(rootURL: rootURL)
    adapter.events = self
  }

  /// Asks for a reconcile, coalescing bursts into one. Reconcile awaits the store, so a second
  /// request that arrives while one runs is not lost.
  func scheduleReconcile() {
    guard reconcileTask == nil else {
      needsReconcile = true
      return
    }
    reconcileGeneration &+= 1
    let generation = reconcileGeneration
    reconcileTask = Task { [weak self] in
      guard let self else { return }
      repeat {
        self.needsReconcile = false
        await self.reconcile()
      } while self.needsReconcile && !Task.isCancelled
      // A stop or a newer reconcile owns the field now, so this one only clears its own.
      if self.reconcileGeneration == generation {
        self.reconcileTask = nil
        self.notifyIfSettled()
      }
    }
  }

  /// Recreates the session so the system delivers the events that woke the app; the WatchKit task
  /// is released once they have drained.
  func handleBackgroundEvents(completion: @escaping @Sendable () -> Void) {
    adapter.handleBackgroundEvents(completion: completion)
    scheduleReconcile()
  }

  /// Sign-out: nothing may commit into the next account, and no queued task may outlive the one
  /// that admitted it.
  func stop() async {
    WatchRSSDiagnostics.log("driver_stop", ["tasks": String(tasks.count)])
    reconcileGeneration &+= 1
    reconcileTask?.cancel()
    reconcileTask = nil
    needsReconcile = false
    tasks.removeAll()
    lastStoredProgress.removeAll()
    lastReportedProgress.removeAll()
    notifyIfSettled()
    await adapter.cancelAllTasks()
  }

  // MARK: Suspension

  /// Waits until no delegate callback is still committing and no reconcile is running or pending.
  /// It loops, so work the work it just waited for started is included. A background wake releases
  /// its WatchKit task only after this returns, and that task's expiration handler bounds a step
  /// that hangs.
  func settle() async {
    while !isSettled {
      await withCheckedContinuation { continuation in
        settleWaiters.append(continuation)
      }
    }
  }

  /// Waits, at most `limit`, until every running task has received its first bytes. A task resumed
  /// while the app is in the background starts at the system's discretion; on device one resumed
  /// in a background wake that was released at once received nothing until Whirr was next opened,
  /// two minutes later. Holding the wake until bytes arrive keeps Whirr running while it starts.
  func awaitTransferStart(within limit: Duration) async {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    var waited = false
    while tasks.values.contains(where: { $0.state == .running && $0.countOfBytesReceived == 0 }) {
      guard clock.now < deadline, !Task.isCancelled else {
        WatchRSSDiagnostics.log("transfer_start_wait", ["outcome": "timeout"])
        return
      }
      waited = true
      try? await Task.sleep(for: .milliseconds(500))
    }
    if waited { WatchRSSDiagnostics.log("transfer_start_wait", ["outcome": "started"]) }
  }

  /// Marks one delegate callback's durable work as running; every path pairs it with `endCallback()`.
  func beginCallback() {
    unsettledCallbacks += 1
  }

  func endCallback() {
    unsettledCallbacks -= 1
    notifyIfSettled()
  }

  private var isSettled: Bool { unsettledCallbacks == 0 && reconcileTask == nil }

  private func notifyIfSettled() {
    guard isSettled else { return }
    let waiters = settleWaiters
    settleWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  // MARK: Reconciliation

  func reconcile() async {
    guard !Task.isCancelled, let store else {
      WatchRSSDiagnostics.log(
        "reconcile", ["skipped": Task.isCancelled ? "cancelled" : "no_store"])
      return
    }
    // Room may have freed since the last pass (a finished, failed or removed copy, a shrunk
    // estimate, or an audiobook deleted), so a storage decline gets its turn before the queue is read.
    let readmitted = await store.readmitDeclined()
    if readmitted.isEmpty == false {
      WatchRSSDiagnostics.log("reconcile_readmit", ["count": String(readmitted.count)])
    }
    let pending = await store.pendingDownloads()
    guard !Task.isCancelled else { return }
    let wanted = Set(pending.map { WatchRSSDownloadKey($0) })
    let systemTasks = await adapter.allTasks()
    WatchRSSDiagnostics.log(
      "reconcile", ["pending": String(pending.count), "systemTasks": String(systemTasks.count)])
    let adoptedCount = adoptSystemTasks(systemTasks, pending: pending, wanted: wanted)
    var changed = readmitted.isEmpty == false
    // `adoptedCount` is fixed before the policy await, so a callback that lands during it cannot
    // change the budget this pass starts from.
    let policy = await networkPolicy()
    guard
      await startNewTasks(
        pending, store: store, policy: policy, startingAt: adoptedCount, changed: &changed)
    else { return }
    if changed { await didChange() }
  }

  /// Keeps the system's tasks whose entries are still wanted and distinct, cancels the rest, and
  /// makes the adopted set the driver's own. Returns how many tasks it adopted.
  private func adoptSystemTasks(
    _ systemTasks: [URLSessionTask], pending: [WatchReceivedEpisode], wanted: Set<WatchRSSDownloadKey>
  ) -> Int {
    let live = liveTasks(systemTasks, wanted: wanted)
    var adopted: [WatchRSSDownloadKey: URLSessionDownloadTask] = [:]
    for entry in pending {
      let key = WatchRSSDownloadKey(entry)
      guard let task = live[key] else { continue }
      adopted[key] = task
      WatchRSSDiagnostics.log("reconcile_adopt", key, taskIdentifier: task.taskIdentifier)
    }
    for key in Array(tasks.keys) where adopted[key]?.taskIdentifier != tasks[key]?.taskIdentifier {
      lastStoredProgress[key] = nil
      lastReportedProgress[key] = nil
    }
    tasks = adopted
    return adopted.count
  }

  /// The system's tasks by key. A duplicate, or a task whose entry is no longer wanted, is
  /// cancelled here and left out.
  private func liveTasks(
    _ systemTasks: [URLSessionTask], wanted: Set<WatchRSSDownloadKey>
  ) -> [WatchRSSDownloadKey: URLSessionDownloadTask] {
    var live: [WatchRSSDownloadKey: URLSessionDownloadTask] = [:]
    for task in systemTasks {
      let decoded = WatchRSSDownloadURLSessionAdapter.key(from: task.taskDescription)
      guard let key = decoded, wanted.contains(key), let download = task as? URLSessionDownloadTask
      else {
        // Removed, declined, superseded by a higher revision, or not this build's task at all.
        WatchRSSDiagnostics.log(
          "reconcile_cancel",
          [
            "taskIdentifier": String(task.taskIdentifier), "why": "not_wanted",
            "decoded": decoded == nil ? "no" : "yes",
          ])
        task.cancel()
        continue
      }
      guard live[key] == nil else {
        WatchRSSDiagnostics.log(
          "reconcile_cancel", key, taskIdentifier: task.taskIdentifier, ["why": "duplicate"])
        task.cancel()
        continue
      }
      live[key] = download
    }
    return live
  }

  /// Starts a task for each wanted entry up to the concurrency limit. Returns false when the
  /// reconcile was cancelled, which the caller must treat as the end of the pass.
  private func startNewTasks(
    _ pending: [WatchReceivedEpisode], store: WatchReceivedEpisodeStore,
    policy: WatchDownloadNetworkPolicy, startingAt adoptedCount: Int, changed: inout Bool
  ) async -> Bool {
    var active = adoptedCount
    for entry in pending where active < Self.maxConcurrentDownloads {
      guard !Task.isCancelled else { return false }
      let key = WatchRSSDownloadKey(entry)
      guard tasks[key] == nil else { continue }
      guard let url = entry.enclosureURL else {
        await fail(entry, .invalidResponse, store: store)
        changed = true
        continue
      }
      // A row a dead process left `downloading` would otherwise show that process's percentage.
      if entry.state == .downloading, entry.progress != nil {
        await store.markDownloading(
          selection: entry.selection, revision: entry.revision, progress: nil)
        changed = true
      }
      // No `countOfBytesClientExpectsToReceive`: setting none kept a 94 MB
      // download at about 2 MB/s with Whirr in the background; this driver with the hint crawled
      // at about 50 KB/s once Whirr left the screen.
      let task = adapter.downloadTask(with: request(for: url))
      task.taskDescription = WatchRSSDownloadURLSessionAdapter.taskDescription(for: key)
      tasks[key] = task
      lastStoredProgress[key] = nil
      lastReportedProgress[key] = nil
      WatchRSSDiagnostics.log(
        "reconcile_new_task", key, taskIdentifier: task.taskIdentifier, ["policy": policy.rawValue])
      task.resume()
      active += 1
    }
    return true
  }

  private func request(for url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    // No per-request `allowsCellularAccess`. With Whirr in the background the Watch reaches the
    // network through the paired iPhone, and a Wi-Fi-only request there crawled where a
    // permissive one ran at full speed. The Watch-cellular case of the Wi-Fi-only setting is not
    // settled yet.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    // No header of any kind: an enclosure is public, and the Watch holds no feed credential.
    return request
  }

  // MARK: Callbacks

  func rssDidWrite(
    _ token: WatchRSSCallbackToken, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) async {
    // The store, not the in-memory task map, decides whether this callback is ours: a task the
    // system inherited across a relaunch can report before the launch reconcile has adopted it.
    guard let store, await pendingEntry(for: token, store: store) != nil else { return }
    guard totalBytesWritten <= WatchEpisodeSendLimits.maxEpisodeBytes else {
      await abandon(token, reason: .tooLarge, store: store)
      return
    }
    let fraction =
      totalBytesExpectedToWrite > 0
      ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil
    let stored = lastStoredProgress[token.key]
    // The response's own length, which replaces the offer's estimate in the budget.
    let responseBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
    var wroteProgress = false
    var resized = false
    if let fraction, stored.map({ fraction < $0 || fraction - $0 >= 0.01 }) ?? true {
      lastStoredProgress[token.key] = fraction
      resized = await store.markDownloading(
        selection: token.key.selection, revision: token.key.revision, progress: fraction,
        responseBytes: responseBytes)
      wroteProgress = true
    } else if fraction == nil, stored == nil {
      lastStoredProgress[token.key] = 0
      resized = await store.markDownloading(
        selection: token.key.selection, revision: token.key.revision, progress: nil)
      wroteProgress = true
    }
    if wroteProgress { await didProgress() }
    // A smaller reservation may make room for an episode declined for storage.
    if resized { scheduleReconcile() }
    // The phone hears about a download at most once per tenth.
    let reported = lastReportedProgress[token.key]
    let report =
      fraction.map { WatchEnclosureProgressStep.shouldReport(lastReported: reported, current: $0) }
      ?? (reported == nil)
    guard report else { return }
    lastReportedProgress[token.key] = fraction ?? 0
    await didChange()
  }

  func rssTaskIsWaitingForConnectivity(_ token: WatchRSSCallbackToken) async {
    guard let store, await pendingEntry(for: token, store: store) != nil else { return }
    await store.markWaitingForNetwork(
      selection: token.key.selection, revision: token.key.revision)
    await didChange()
  }

  // MARK: Shared with the completion handlers

  func pendingEntry(
    for token: WatchRSSCallbackToken, store: WatchReceivedEpisodeStore
  ) async -> WatchReceivedEpisode? {
    guard let entry = await store.entry(for: token.key.selection),
      entry.revision == token.key.revision, entry.isAwaitingDownload
    else { return nil }
    return entry
  }

  /// Drops this task's bookkeeping. A task the driver cancelled on purpose produces a failure
  /// callback that finds nothing to settle and reports no failure.
  func release(_ token: WatchRSSCallbackToken) {
    if tasks[token.key]?.taskIdentifier == token.taskIdentifier {
      tasks.removeValue(forKey: token.key)
    }
    lastStoredProgress[token.key] = nil
    lastReportedProgress[token.key] = nil
  }

  func fail(
    _ entry: WatchReceivedEpisode, _ reason: WatchEpisodeInventoryEntry.FailureReason,
    store: WatchReceivedEpisodeStore
  ) async {
    WatchRSSDiagnostics.log(
      "entry_fail", WatchRSSDownloadKey(entry), ["reason": reason.rawValue])
    await store.markFailed(
      selection: entry.selection, revision: entry.revision, reason: reason)
    await didChange()
  }

  /// The transfer outgrew the 1 GiB cap (ADR 0020 Decision 2), so it is cancelled and reported
  /// rather than downloaded to the end and refused.
  private func abandon(
    _ token: WatchRSSCallbackToken, reason: WatchEpisodeInventoryEntry.FailureReason,
    store: WatchReceivedEpisodeStore
  ) async {
    WatchRSSDiagnostics.log(
      "entry_abandon", token.key, taskIdentifier: token.taskIdentifier, ["reason": reason.rawValue])
    tasks[token.key]?.cancel()
    release(token)
    guard let entry = await pendingEntry(for: token, store: store) else { return }
    await fail(entry, reason, store: store)
    scheduleReconcile()
  }
}

extension WatchRSSDownloadDriver: WatchRSSDownloadURLSessionEvents {}
