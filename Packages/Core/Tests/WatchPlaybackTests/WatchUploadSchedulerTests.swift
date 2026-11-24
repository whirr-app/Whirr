import Foundation
import Testing

@testable import WatchPlayback

/// When the Watch tries to upload, with or without the phone.
@Suite struct WatchUploadSchedulerTests {
  private let start = Date(timeIntervalSince1970: 1_000)

  @Test func aRequestStartsARunWhenNoneIsRunning() {
    var scheduler = WatchUploadScheduler()
    let r1 = scheduler.request()
    #expect(r1)
    #expect(scheduler.isRunning)
  }

  /// S13: a request during a run is remembered and runs once more, not dropped.
  @Test func requestsDuringARunCoalesceIntoOneMoreRun() {
    var scheduler = WatchUploadScheduler()
    let r2 = scheduler.request()
    #expect(r2)
    let r3 = scheduler.request()
    #expect(!r3)
    let r4 = scheduler.request()
    #expect(!r4)
    let r5 = scheduler.finish(.succeeded, pending: false, now: start)
    #expect(r5)
    #expect(scheduler.isRunning)
    let r6 = scheduler.finish(.succeeded, pending: false, now: start)
    #expect(!r6)
    #expect(!scheduler.isRunning)
  }

  /// Consecutive transport failures with rows pending back off 1, 5, then 15 minutes.
  @Test func transportFailuresBackOff() {
    var scheduler = WatchUploadScheduler()
    var delays: [TimeInterval] = []
    for _ in 0..<4 {
      let r7 = scheduler.request()
      #expect(r7)
      let r8 = scheduler.finish(.transportFailure, pending: true, now: start)
      #expect(!r8)
      delays.append(scheduler.retryAt.map { $0.timeIntervalSince(start) } ?? -1)
    }
    #expect(delays == [60, 300, 900, 900])
  }

  @Test func aRetryRunsOnlyOnceDue() {
    var scheduler = WatchUploadScheduler()
    _ = scheduler.request()
    _ = scheduler.finish(.transportFailure, pending: true, now: start)
    let r9 = scheduler.retryIfDue(now: start.addingTimeInterval(59))
    #expect(!r9)
    let r10 = scheduler.retryIfDue(now: start.addingTimeInterval(60))
    #expect(r10)
    #expect(scheduler.retryAt == nil)
    #expect(scheduler.isRunning)
    let r11 = scheduler.retryIfDue(now: start.addingTimeInterval(600))
    #expect(!r11)
  }

  @Test func successOrOtherFailuresClearTheRetry() {
    var scheduler = WatchUploadScheduler()
    _ = scheduler.request()
    _ = scheduler.finish(.transportFailure, pending: true, now: start)
    _ = scheduler.request()
    _ = scheduler.finish(.succeeded, pending: false, now: start)
    #expect(scheduler.retryAt == nil)
    _ = scheduler.request()
    _ = scheduler.finish(.transportFailure, pending: true, now: start)
    #expect(scheduler.retryAt == start.addingTimeInterval(60))
    _ = scheduler.request()
    _ = scheduler.finish(.failed, pending: true, now: start)
    #expect(scheduler.retryAt == nil)
  }

  @Test func nothingPendingSchedulesNoRetry() {
    var scheduler = WatchUploadScheduler()
    _ = scheduler.request()
    _ = scheduler.finish(.transportFailure, pending: false, now: start)
    #expect(scheduler.retryAt == nil)
  }

  @Test func aDueRetryDuringARunJoinsIt() {
    var scheduler = WatchUploadScheduler()
    _ = scheduler.request()
    _ = scheduler.finish(.transportFailure, pending: true, now: start)
    let r12 = scheduler.request()
    #expect(r12)
    let r13 = scheduler.retryIfDue(now: start.addingTimeInterval(60))
    #expect(!r13)
    let r14 = scheduler.finish(.succeeded, pending: false, now: start)
    #expect(r14)
  }

  /// Logout makes one attempt, or waits for the one already running, and nothing after it.
  @Test func logoutMakesOneBoundedAttempt() {
    var idle = WatchUploadScheduler()
    let r15 = idle.logout()
    #expect(r15 == .run(bound: WatchUploadScheduler.logoutBound))
    let r16 = idle.request()
    #expect(!r16)
    var busy = WatchUploadScheduler()
    _ = busy.request()
    let r17 = busy.logout()
    #expect(r17 == .awaitRunning(bound: WatchUploadScheduler.logoutBound))
    let r18 = busy.finish(.succeeded, pending: false, now: start)
    #expect(!r18)
    let r19 = busy.request()
    #expect(!r19)
    #expect(WatchUploadScheduler.logoutBound == .seconds(10))
  }

  /// Ten minutes of continuous play is a checkpoint; a pause restarts the count.
  @Test func tenMinutesOfContinuousPlayIsACheckpoint() {
    var scheduler = WatchUploadScheduler()
    let r20 = scheduler.checkpointDue(at: 0)
    #expect(!r20)
    scheduler.playing(at: 100)
    scheduler.playing(at: 300)
    let r21 = scheduler.checkpointDue(at: 699)
    #expect(!r21)
    let r22 = scheduler.checkpointDue(at: 700)
    #expect(r22)
    let r23 = scheduler.checkpointDue(at: 1_299)
    #expect(!r23)
    let r24 = scheduler.checkpointDue(at: 1_300)
    #expect(r24)
    scheduler.stopped()
    let r25 = scheduler.checkpointDue(at: 5_000)
    #expect(!r25)
    scheduler.playing(at: 5_000)
    let r26 = scheduler.checkpointDue(at: 5_599)
    #expect(!r26)
    let r27 = scheduler.checkpointDue(at: 5_600)
    #expect(r27)
  }

  @Test func aFailedLogoutReopensUploads() {
    var scheduler = WatchUploadScheduler()
    _ = scheduler.logout()
    _ = scheduler.finish(.failed, pending: true, now: .now)
    let whileClosed = scheduler.request()
    scheduler.reopen()
    let reopened = scheduler.request()
    #expect(whileClosed == false)
    #expect(reopened)
  }

  @Test func anAbandonedRunReleasesTheScheduler() {
    var scheduler = WatchUploadScheduler()
    let first = scheduler.request()
    let second = scheduler.request()
    scheduler.abandon()
    let afterAbandon = scheduler.request()
    #expect(first)
    #expect(second == false)
    #expect(afterAbandon)
  }

  /// A phone catalogue is not a reconnect: the phone republishes on every change and on its
  /// playhead while it plays, so a run per catalogue would read the server and report to the
  /// phone with nothing to send. One runs only while closed rows wait.
  @Test func aPeerCatalogueRequestsARunOnlyWhileRowsWait() {
    var scheduler = WatchUploadScheduler()
    let nothingPending = scheduler.requestForPeerContext(pending: false)
    #expect(nothingPending == false)
    #expect(scheduler.isRunning == false)
    let rowsWaiting = scheduler.requestForPeerContext(pending: true)
    #expect(rowsWaiting)
    #expect(scheduler.isRunning)
  }

  /// A transport failure's backoff is not cut short by the next catalogue; the retry
  /// timer owns the next attempt.
  @Test func aPeerCatalogueWaitsOutATransportBackoff() {
    var scheduler = WatchUploadScheduler()
    _ = scheduler.request()
    _ = scheduler.finish(.transportFailure, pending: true, now: start)
    #expect(scheduler.retryAt != nil)
    let duringBackoff = scheduler.requestForPeerContext(pending: true)
    #expect(duringBackoff == false)
    #expect(scheduler.isRunning == false)
  }
}
