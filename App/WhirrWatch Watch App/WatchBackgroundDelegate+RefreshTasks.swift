import Foundation
import WatchConnectivity
import WatchKit
import WatchPlayback
import WatchProtocol

/// WatchKit's background tasks: intake, the settle that must finish before release, and the bounded
/// fallbacks that release a wake the system cannot drain.
extension WatchBackgroundDelegate {
  func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
    for task in backgroundTasks {
      if let transferTask = task as? WKURLSessionRefreshBackgroundTask {
        let identifier = ObjectIdentifier(transferTask)
        // The Audiobookshelf identifier carries the account hash, so only the session's kind is
        // logged, never the string.
        let isRSS = transferTask.sessionIdentifier == WatchRSSDownloadURLSessionAdapter.sessionIdentifier
        WatchRSSDiagnostics.log(
          "bg_task_received", ["kind": "url_session", "session": isRSS ? "rss" : "other"])
        urlTasks[identifier] = transferTask
        transferTask.expirationHandler = { [weak self] in
          Task { @MainActor [weak self] in self?.completeURLTask(identifier, reason: "expired") }
        }
        if isRSS {
          // The account's store is what a finished file commits into, so the session is recreated
          // after the restore rather than before it. The task is also held past the commit and the
          // inventory it schedules: the phone only learns the copy is ready from that send.
          let completion: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
              guard let self else { return }
              await self.episodes.settleForSuspension()
              self.completeURLTask(identifier, reason: "settled")
            }
          }
          Task { @MainActor [weak self] in
            guard let self else { return }
            await self.library.initialize()
            self.episodes.attachRSSBackgroundEvents(completion)
          }
          continue
        }
        Task { [weak self] in
          guard let self else { return }
          await self.library.resumeBackgroundSession(identifier: transferTask.sessionIdentifier) { [weak self] in
            Task { @MainActor [weak self] in self?.completeURLTask(identifier, reason: "settled") }
          }
        }
        continue
      }
      guard let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask else {
        WatchRSSDiagnostics.log("bg_task_received", ["kind": "other"])
        task.setTaskCompletedWithSnapshot(false)
        continue
      }
      WatchRSSDiagnostics.log("bg_task_received", ["kind": "wc_refresh"])
      let identifier = ObjectIdentifier(connectivityTask)
      // The first connectivity task opens the wake; a delivery the previous wake left behind must
      // not count for this one.
      if pendingRefreshTasks.isEmpty { wake.reset() }
      pendingRefreshTasks[identifier] = connectivityTask
      connectivityTask.expirationHandler = { [weak self] in
        Task { @MainActor [weak self] in
          self?.completeRefreshTask(identifier)
        }
      }
    }
    guard !pendingRefreshTasks.isEmpty else { return }
    session.activate()
    scheduleRefreshExpirationIfNeeded()
    startRefreshGraceIfNeeded()
    // A wake may be the first time this process has seen the account, and the phone sends an offer
    // as user info, which cannot be applied without the account's store. The WatchKit task
    // therefore waits for the restore too; the expiration above bounds it. After the first
    // restore this is a no-op.
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.library.initialize()
      self.drainRefreshTasksIfReady()
    }
  }

  private func completeURLTask(_ identifier: ObjectIdentifier, reason: String) {
    let task = urlTasks.removeValue(forKey: identifier)
    WatchRSSDiagnostics.log(
      "bg_task_complete", ["kind": "url", "reason": reason, "found": task == nil ? "no" : "yes"])
    guard let task else { return }
    task.expirationHandler = nil
    task.setTaskCompletedWithSnapshot(false)
  }

  func drainRefreshTasksIfReady() {
    guard !pendingRefreshTasks.isEmpty else { return }
    // Releasing on `hasContentPending` alone is what suspended the app with an offer still queued:
    // WatchConnectivity hands over the refresh task before it delivers the user info. The wake
    // therefore waits for its content, or for the grace that says it carried none.
    guard
      wake.decision(
        activated: session.activationState == .activated,
        hasContentPending: session.hasContentPending,
        settling: settlingRefreshTasks) == .release
    else { return }
    // The content being drained is not the work: the offer is only applied, and its download task
    // only resumed, once ingress and the driver's reconcile have run. Releasing the tasks here lets
    // watchOS suspend the app before the URLSession task exists, so it waits for that chain.
    completeRefreshTasksAfterSettling()
  }

  /// Runs the ingress chain and the inventory flush the offer needs, then releases the held tasks.
  /// The system's expiration handler and the bounded fallback below stay the ceiling on how long a
  /// step that hangs can hold them.
  private func completeRefreshTasksAfterSettling() {
    guard !settlingRefreshTasks else { return }
    settlingRefreshTasks = true
    Task { [weak self] in
      guard let self else { return }
      await self.library.initialize()
      var settledDeliveries = self.wake.deliveries
      await self.episodes.settleAndAwaitTransferStart()
      // A delivery during the settle has forwarded content whose ingress, apply and inventory have
      // not run yet, so it settles again instead of releasing on the first pass's result.
      while !self.pendingRefreshTasks.isEmpty,
        self.wake.deliveries != settledDeliveries,
        !self.session.hasContentPending
      {
        settledDeliveries = self.wake.deliveries
        await self.episodes.settleForSuspension()
      }
      // A background refresh may be the only run this process gets; tell the phone what the Watch
      // knows before the system suspends it. The publisher throttles an unchanged report.
      self.library.publishStatusReport()
      self.settlingRefreshTasks = false
      // Completing through `drainRefreshTasksIfReady` would start another settle; this one has
      // already run, so the rule decides directly whether it may release.
      if self.wake.decision(
        activated: self.session.activationState == .activated,
        hasContentPending: self.session.hasContentPending,
        settling: false) == .release
      {
        self.completeHeldRefreshTasks("settled")
      }
    }
  }

  /// Removes and completes every held connectivity task. Removal is the guard: an expiration that
  /// fires mid-flight finds nothing and completes nothing twice.
  private func completeHeldRefreshTasks(_ reason: String) {
    let tasks = pendingRefreshTasks.values
    WatchRSSDiagnostics.log(
      "bg_task_complete", ["kind": "wc", "reason": reason, "count": String(tasks.count)])
    pendingRefreshTasks.removeAll()
    refreshExpiration?.cancel()
    refreshExpiration = nil
    resetRefreshWake()
    for task in tasks {
      task.expirationHandler = nil
      task.setTaskCompletedWithSnapshot(false)
    }
  }

  private func completeRefreshTask(_ identifier: ObjectIdentifier) {
    let task = pendingRefreshTasks.removeValue(forKey: identifier)
    WatchRSSDiagnostics.log(
      "bg_task_complete", ["kind": "wc", "reason": "expired", "found": task == nil ? "no" : "yes"])
    guard let task else { return }
    task.expirationHandler = nil
    task.setTaskCompletedWithSnapshot(false)
    if pendingRefreshTasks.isEmpty {
      refreshExpiration?.cancel()
      refreshExpiration = nil
      resetRefreshWake()
    }
  }

  /// The content that woke this task, forwarded. Marked after the forward so `receiveOffer` has
  /// enqueued its ingress before the drain may release the task.
  func refreshContentReceived(_ content: WatchRefreshWake.Content) {
    wake.contentDelivered()
    WatchRSSDiagnostics.log("wc_content_received", content.diagnosticFields)
    if pendingRefreshTasks.isEmpty, case .userInfo = content,
      WKApplication.shared().applicationState != .active
    {
      holdForOfferOutsideWake()
    } else {
      drainRefreshTasksIfReady()
    }
  }

  /// An offer can arrive in the seconds after Whirr leaves the screen, before watchOS suspends it,
  /// with no WatchKit task to hold. On device the offer was applied and its download resumed, but
  /// the inventory's debounce was still waiting when the app was suspended, so the phone never
  /// heard. An expiring activity keeps the process up for the same settle a background wake runs.
  private func holdForOfferOutsideWake() {
    guard !holdingOutsideWake else {
      outsideWakeNeedsAnotherPass = true
      return
    }
    holdingOutsideWake = true
    WatchRSSDiagnostics.log("outside_wake_hold", ["outcome": "start"])
    ProcessInfo.processInfo.performExpiringActivity(withReason: "Accept a Watch episode offer") {
      [weak self] expired in
      guard !expired else {
        WatchRSSDiagnostics.log("outside_wake_hold", ["outcome": "expired"])
        return
      }
      let done = DispatchSemaphore(value: 0)
      Task { @MainActor [weak self] in
        await self?.settleOutsideWake()
        done.signal()
      }
      _ = done.wait(timeout: .now() + .seconds(25))
    }
  }

  private func settleOutsideWake() async {
    repeat {
      outsideWakeNeedsAnotherPass = false
      await episodes.settleAndAwaitTransferStart()
    } while outsideWakeNeedsAnotherPass
    holdingOutsideWake = false
    WatchRSSDiagnostics.log("outside_wake_hold", ["outcome": "settled"])
  }

  /// The quiet grace: long enough for content WatchConnectivity delivers just after the refresh
  /// task, short enough that a wake which genuinely carried nothing does not wait for the bounded
  /// fallback. It re-runs the drain when it fires.
  private func startRefreshGraceIfNeeded() {
    guard refreshGrace == nil, !pendingRefreshTasks.isEmpty else { return }
    refreshGrace = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.refreshGracePeriod)
      guard !Task.isCancelled, let self else { return }
      self.refreshGrace = nil
      self.wake.graceDidElapse()
      WatchRSSDiagnostics.log("wc_grace_elapsed", ["held": String(self.pendingRefreshTasks.count)])
      self.drainRefreshTasksIfReady()
    }
  }

  private func resetRefreshWake() {
    refreshGrace?.cancel()
    refreshGrace = nil
    wake.reset()
  }

  private func scheduleRefreshExpirationIfNeeded() {
    guard refreshExpiration == nil else { return }
    refreshExpiration = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(20))
      guard !Task.isCancelled, let self, !self.pendingRefreshTasks.isEmpty else { return }
      self.refreshExpiration = nil
      // The bounded fallback explicitly ends the task when the system cannot activate or drain
      // its content. No Watch playback or retry is attempted.
      self.completeHeldRefreshTasks("expired")
    }
  }
}
