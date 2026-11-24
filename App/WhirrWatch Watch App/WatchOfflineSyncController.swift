import ABSApi
import Foundation
import Observation
import WatchConnectivity
import WatchPlayback
import WatchProtocol

@MainActor
@Observable
final class WatchOfflineSyncController {
  private unowned let model: WatchLibraryModel
  private var context: WatchSessionContext? { model.session.context }
  private var account: WatchAccountRecord? { context?.account ?? model.account }
  private var authenticatedStamp: WatchAccountStamp? {
    context?.authenticatedStamp ?? (try? account?.authenticatedStamp())
  }
  private var busy: Bool { model.busy }
  private var message: String? {
    get { model.message }
    set { model.setMessage(newValue) }
  }
  private var sessionEpoch: Int { model.session.epoch }
  private var activeRun: UUID?
  private var loggingOut: Bool { model.session.loggingOut }
  private var libraryClient: WatchLibraryClient? { context?.libraryClient }
  private var service: ABSWatchLibraryService? { context?.service }
  private var progressStore: WatchOfflineProgressStore? { context?.progressStore }
  private var offlineSessionID: UUID? { model.playback.offlineSessionID }
  private var reconciliationTask: Task<Void, Never>? {
    get { model.session.lifecycle.reconciliation }
    set { model.session.lifecycle.reconciliation = newValue }
  }
  /// When uploads run. A new account starts a fresh one, because logout closes it.
  private var scheduler = WatchUploadScheduler()
  private var retryTimer: Task<Void, Never>?

  init(model: WatchLibraryModel) { self.model = model }

  /// A fresh account session uploads afresh: the previous account's logout closed the scheduler.
  func resetForAccount() {
    retryTimer?.cancel()
    retryTimer = nil
    scheduler = WatchUploadScheduler()
    activeRun = nil
  }

  /// Logout failed and the account stays signed in.
  func logoutDidFail() { scheduler.reopen() }

  func peerDidReconnect() async {
    await reconcileOfflineProgress()
  }

  /// The phone sent a catalogue, which it does on every change. Uploads only when closed rows
  /// wait; the phone asks for the pending report before any start that needs it.
  func peerDidSendContext() async {
    guard !loggingOut else { return }
    guard scheduler.requestForPeerContext(pending: await hasPendingRows()) else { return }
    startRun()
    await reconciliationTask?.value
  }

  /// Requests an upload and waits for the run in progress, which includes any run this request
  /// added. Uploads never wait for the phone; the open row stays out of them.
  func reconcileOfflineProgress() async {
    guard !loggingOut else { return }
    if scheduler.request() { startRun() }
    await reconciliationTask?.value
  }

  /// Continuous play reached a checkpoint. `playing` says whether audio is playing now.
  func checkpointDue(playing: Bool) -> Bool {
    let uptime = ProcessInfo.processInfo.systemUptime
    guard playing else {
      scheduler.stopped()
      return false
    }
    scheduler.playing(at: uptime)
    return scheduler.checkpointDue(at: uptime)
  }

  /// One upload before logout clears the account, bounded, and nothing after it.
  func uploadBeforeLogout() async {
    retryTimer?.cancel()
    retryTimer = nil
    let bound: Duration
    switch scheduler.logout() {
    case .run(let limit):
      bound = limit
      startRun()
    case .awaitRunning(let limit):
      bound = limit
    }
    guard let task = reconciliationTask else { return }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await task.value }
      group.addTask { try? await Task.sleep(for: bound) }
      await group.next()
      group.cancelAll()
    }
  }

  private func startRun() {
    let token = sessionEpoch
    // The scheduler admits one run at a time, so a task still held here is not a run of its own;
    // cancel it rather than leave it unowned, out of reach of logout's `cancelAll`.
    reconciliationTask?.cancel()
    let run = UUID()
    activeRun = run
    reconciliationTask = Task<Void, Never> { [weak self] in
      var again = true
      while again {
        guard let self else { return }
        // A run that stops reporting must release the scheduler it still holds, or nothing
        // uploads again; a scheduler replaced for a new account is not this run's to touch.
        guard token == self.sessionEpoch else { return self.abandon(run) }
        let outcome = await self.performOfflineReconciliation()
        guard token == self.sessionEpoch else { return self.abandon(run) }
        let pending = await self.hasPendingRows()
        again = self.scheduler.finish(outcome, pending: pending, now: .now)
      }
      guard let self, token == self.sessionEpoch else { return }
      self.reconciliationTask = nil
      self.scheduleRetry()
      // Whether or not the upload reached the server, the phone learns what is still pending.
      await self.publishPendingProgress()
    }
  }

  private func abandon(_ run: UUID) {
    guard activeRun == run else { return }
    activeRun = nil
    scheduler.abandon()
  }

  /// A transport failure retries while the app runs, after the scheduler's delay.
  private func scheduleRetry() {
    retryTimer?.cancel()
    guard let retryAt = scheduler.retryAt else { return }
    let token = sessionEpoch
    retryTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(0, retryAt.timeIntervalSinceNow)))
      guard let self, !Task.isCancelled, token == self.sessionEpoch, !self.loggingOut else { return }
      if self.scheduler.retryIfDue(now: .now) { self.startRun() }
    }
  }

  /// Uploads only when closed Audiobookshelf rows wait. A native-feed listen asks for this after it
  /// reports to the phone: rows written before it must not starve, but a native pause alone is no
  /// reason to read the server.
  func reconcileIfPending() async {
    guard !loggingOut, await hasPendingRows() else { return }
    await reconcileOfflineProgress()
  }

  private func hasPendingRows() async -> Bool {
    let open = offlineSessionID
    return await progressStore?.allSessions().contains { $0.id != open } ?? false
  }

  // MARK: Pending progress report

  private static let reportSequenceKey = "watch.pendingProgress.sequence"

  /// The Watch's current pending progress and downloaded titles, under a sequence the phone uses
  /// to discard reports that arrive out of order.
  func pendingProgressReport() async -> WatchPendingProgressReport? {
    guard let stamp = authenticatedStamp, let progressStore else { return nil }
    let defaults = UserDefaults.standard
    let sequence = UInt64(clamping: max(0, defaults.integer(forKey: Self.reportSequenceKey))) &+ 1
    defaults.set(Int(clamping: sequence), forKey: Self.reportSequenceKey)
    let downloaded = model.downloads.filter { $0.accountStamp == stamp && $0.isPlayable }.map(\.selection)
    return try? WatchPendingProgressReport(
      accountStamp: stamp, sequence: sequence, sessions: await progressStore.allSessions(), downloaded: downloaded)
  }

  /// Queues only the latest report: older outstanding report transfers are cancelled first, and
  /// the application context is left to the playing report that owns it.
  func publishPendingProgress() async {
    let session = WCSession.default
    guard !loggingOut, session.activationState == .activated, let report = await pendingProgressReport(),
      let data = try? WatchWireCodec.encode(report)
    else { return }
    for transfer in session.outstandingUserInfoTransfers
    where transfer.userInfo[WatchPendingProgressReport.transportKey] != nil {
      transfer.cancel()
    }
    session.transferUserInfo([WatchPendingProgressReport.transportKey: data])
  }

  /// The phone asks before starting a title the Watch reported: try to upload, then answer with
  /// what is still pending. A query for another account gets no answer.
  func answerPendingProgressQuery(_ data: Data) async -> Data? {
    guard let query = try? WatchWireCodec.decode(WatchPendingProgressQuery.self, from: data),
      query.accountStamp == authenticatedStamp
    else { return nil }
    await reconcileOfflineProgress()
    guard query.accountStamp == authenticatedStamp, let report = await pendingProgressReport() else { return nil }
    return try? WatchWireCodec.encode(report)
  }

  func performOfflineReconciliation() async -> WatchUploadScheduler.Outcome {
    guard !loggingOut, !Task.isCancelled, let service, let account, let progressStore else { return .failed }
    let token = sessionEpoch
    do {
      let snapshot = try await service.progress(account: account.tokenAccount())
      guard token == sessionEpoch, !loggingOut, !Task.isCancelled else { return .failed }
      let sessions = await progressStore.allSessions()
      // The row being written now is not settled yet; it uploads once it closes.
      let open = Set([offlineSessionID].compactMap { $0 })
      let plan = WatchOfflineReconciliationPlan(local: sessions, remote: snapshot.progress, open: open)
      Self.recordDiagnostics(for: plan, sessions: sessions)
      var eligible = await progressStore.apply(plan)
      var uploaded = false
      // Every eligible row goes in this run, a batch at a time. A row is offered once, so one the
      // server does not acknowledge waits for a later run instead of repeating in this one.
      while true {
        guard token == sessionEpoch, !loggingOut, !Task.isCancelled else { return .failed }
        let batch = try await progressStore.pendingUploadBatch(eligibleIDs: eligible)
        guard !batch.isEmpty else { break }
        guard token == sessionEpoch, !loggingOut, !Task.isCancelled else {
          try await progressStore.releaseUploadBatch()
          return .failed
        }
        eligible.subtract(batch.compactMap { UUID(uuidString: $0.id) })
        let result = try await service.syncLocalSessions(account: account.tokenAccount(), sessions: batch)
        // The server has the batch whatever happened here meanwhile, so the store (this account's
        // own) always hears it: a row released instead would be sent again under the same UUID.
        try await progressStore.acknowledge(result)
        uploaded = true
        guard token == sessionEpoch, !Task.isCancelled else { return .failed }
      }
      guard uploaded else { return .succeeded }
      let refreshed = try? await libraryClient?.serverProgress()
      guard token == sessionEpoch, !loggingOut else { return .succeeded }
      if let refreshed { await model.catalogue.adopt(refreshed) }
      return .succeeded
    } catch {
      try? await progressStore.releaseUploadBatch()
      return Self.isTransportFailure(error) ? .transportFailure : .failed
    }
  }

  /// Failures that a later attempt can get past without anything else changing.
  private static func isTransportFailure(_ error: any Error) -> Bool {
    switch error as? APIError {
    case .transport, .rateLimited, .serverFailure: true
    default: error is URLError
    }
  }

  /// One payload-free event per title whose position the rule chose without asking.
  private static func recordDiagnostics(
    for plan: WatchOfflineReconciliationPlan, sessions: [WatchOfflineProgressSession]
  ) {
    var reported: Set<WatchSelection> = []
    for decision in plan.decisions {
      guard let selection = sessions.first(where: { $0.id == decision.sessionID })?.selection,
        reported.insert(selection).inserted
      else { continue }
      let event: WatchDiagnostics.Event? =
        switch decision.reason {
        case .watchNewer: .offlineWatchNewer
        case .sharedNewer: .offlineSharedNewer
        case .tieFurther: .offlineTieFurther
        case .futureClockTie: .offlineFutureClock
        case .nearZeroShared: .offlineNearZeroKept
        case .converged, .watchInvalid, .sharedInvalid, .sharedMissing, .noSharedTimestamp: nil
        }
      if let event { WatchDiagnostics.record(event) }
    }
  }
}
