import ABSApi
import Foundation
import SyncEngine
import Testing

/// `PlaybackSyncing`'s fake: every call is recorded (in order) and stubbable, so `PlaybackModel`
/// tests can assert what SyncEngine was asked to do without a real `PlaybackSessionCoordinator`
/// (the real conformance lives in `Sources/SyncEngine/PlaybackSessionCoordinator.swift`).
/// Start, promotion, stop, recovery and progress ticks can each be held open on demand (a
/// `TestGate`) so tests can exercise in-flight ordering and cancellation without a sleep.
public final class FakePlaybackSyncing: PlaybackSyncing, @unchecked Sendable {
  private struct ActiveSession: Sendable {
    let itemID: String
    let episodeID: String?
    let prepared: PreparedPlayback
  }

  public struct ProgressIdentityCall: Sendable, Equatable {
    public let itemID: String
    public let episodeID: String?

    public init(itemID: String, episodeID: String?) {
      self.itemID = itemID
      self.episodeID = episodeID
    }
  }

  /// Every argument of one `recordProgressTick`, which `RecordedCall` and `progressIdentityCalls`
  /// each carry only part of.
  public struct ProgressTick: Sendable, Equatable {
    public let itemID: String
    public let episodeID: String?
    public let currentTime: Double
    public let listenedDelta: Double
    public let isFinished: Bool
    public let isSeek: Bool
    public let sleepTimerExpired: Bool

    public init(
      itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
      isFinished: Bool, isSeek: Bool, sleepTimerExpired: Bool = false
    ) {
      self.itemID = itemID
      self.episodeID = episodeID
      self.currentTime = currentTime
      self.listenedDelta = listenedDelta
      self.isFinished = isFinished
      self.isSeek = isSeek
      self.sleepTimerExpired = sleepTimerExpired
    }
  }

  public enum RecordedCall: Sendable, Equatable {
    case startSession(itemID: String, episodeID: String?)
    case promoteStreamingSessionToLocalDownload(
      itemID: String, episodeID: String?, currentPosition: Double, streamedDuration: Double?)
    case stopSession
    case notifyPlaybackPhase(PlaybackCadencePhase)
    case notifyImmediateSyncTrigger(PlaybackImmediateSyncTrigger)
    case handleAppBackgrounded
    case recoverOpenSessions
    case quiesceForLogout
    case recordProgressTick(
      itemID: String, currentTime: Double, listenedDelta: Double, isFinished: Bool, isSeek: Bool)
    case sleepTimerExpiry(itemID: String, episodeID: String?)
  }

  public struct UnstubbedResult: Error, Sendable {}

  public let recorder = CallRecorder<RecordedCall>(label: "FakePlaybackSyncing calls")
  public var calls: [RecordedCall] { recorder.calls }
  private let willStartPlaybackItemIDsBox = Locked<[String]>([])
  public var willStartPlaybackItemIDs: [String] { willStartPlaybackItemIDsBox.value }
  private let progressIdentityCallsBox = Locked<[ProgressIdentityCall]>([])
  public var progressIdentityCalls: [ProgressIdentityCall] { progressIdentityCallsBox.value }
  private let progressTicksBox = Locked<[ProgressTick]>([])
  /// Every `recordProgressTick`, with all of its arguments, in order.
  public var progressTicks: [ProgressTick] { progressTicksBox.value }

  private func record(_ call: RecordedCall) {
    recorder.record(call)
  }

  /// Test-only: suspends, bounded, until the recorded call list satisfies `predicate`.
  @discardableResult
  public func waitForCalls(
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation,
    satisfying predicate: @escaping @Sendable ([RecordedCall]) -> Bool
  ) async -> TestWaitOutcome {
    await recorder.waitUntil(timeout: timeout, sourceLocation: sourceLocation, predicate)
  }

  public var notifyPlaybackPhaseCalls: [PlaybackCadencePhase] {
    calls.compactMap {
      if case .notifyPlaybackPhase(let phase) = $0 { return phase }
      return nil
    }
  }

  public init() {}

  private let startSessionResultBox = Locked<Result<PreparedPlayback, Error>?>(nil)
  private let promotionResultBox = Locked<PreparedPlayback?>(nil)
  private let resumeInPlaceBox = Locked(false)
  private let activeSessionBox = Locked<ActiveSession?>(nil)
  private let stopSessionErrorBox = Locked<Error?>(nil)
  private let renewedAuthorizationBox = Locked<PlaybackStreamAuthorization?>(nil)

  public let startSessionGate = TestGate<Result<PreparedPlayback, Error>>(
    label: "FakePlaybackSyncing.startSession", ignoresCancellation: true)
  public let promotionGate = TestGate<PreparedPlayback?>(
    label: "FakePlaybackSyncing.promoteStreamingSessionToLocalDownload",
    ignoresCancellation: true)
  public let stopSessionGate = TestGate<Void>(
    label: "FakePlaybackSyncing.stopSession", ignoresCancellation: true)
  public let recoverOpenSessionsGate = TestGate<Void>(label: "FakePlaybackSyncing.recoverOpenSessions")
  public let recordProgressTickGate = TestGate<Void>(label: "FakePlaybackSyncing.recordProgressTick")

  public func stubStartSession(_ result: Result<PreparedPlayback, Error>) {
    startSessionResultBox.value = result
  }

  /// Test-only: what `renewStreamAuthorization()` answers. `nil` is the default and means nothing
  /// is renewable.
  public func stubRenewStreamAuthorization(_ authorization: PlaybackStreamAuthorization?) {
    renewedAuthorizationBox.value = authorization
  }

  /// Test-only: scripts the best-effort promotion result. `nil` is the normal default and means
  /// the coordinator declined, so callers continue streaming.
  public func stubPromoteStreamingSessionToLocalDownload(_ result: PreparedPlayback?) {
    promotionResultBox.value = result
  }

  /// Test-only: parks promotion after recording the call so a test can advance the player's live
  /// position before the coordinator returns the local preparation.
  public func holdPromotion() { promotionGate.hold() }

  /// Test-only: resumes every currently parked promotion with the stubbed result.
  public func releasePromotion() { promotionGate.release(promotionResultBox.value) }

  /// Test-only: number of promotion calls currently held by `holdPromotion()`.
  public var parkedPromotionCount: Int { promotionGate.parkedCount }

  /// Test-only: makes a repeated start of the locally active identity return the preparation that
  /// opened that session, just as the production coordinator's in-place resume path does.
  public func stubResumeInPlace(_ enabled: Bool = true) {
    resumeInPlaceBox.value = enabled
  }

  public func stubStopSession(throwing error: Error?) {
    stopSessionErrorBox.value = error
  }

  /// Test-only: parks `stopSession` calls until `releaseStopSession` is called, so a newer intent
  /// can be issued while a recovery close is still in flight.
  public func holdStopSession() { stopSessionGate.hold() }

  /// Test-only: resumes every currently parked `stopSession` call.
  public func releaseStopSession() { stopSessionGate.release() }

  /// Test-only: makes the next (and every subsequent, until released) `startSession` call park
  /// instead of returning immediately.
  public func holdStartSession() { startSessionGate.hold() }

  /// Test-only: resumes every currently-parked `startSession` call with `result`.
  public func releaseStartSession(with result: Result<PreparedPlayback, Error>) {
    startSessionGate.release(result)
  }

  /// Test-only: resumes only the oldest parked `startSession` call and keeps the hold in place.
  /// This makes overlapping-call tests deterministic when the older and newer requests must
  /// complete with different results.
  public func releaseNextStartSession(with result: Result<PreparedPlayback, Error>) {
    startSessionGate.releaseNext(result)
  }

  /// Test-only: makes the next (and every subsequent, until released) `recoverOpenSessions` call
  /// park instead of returning immediately. Lets a test prove launch recovery runs before a
  /// caller-issued play intent, rather than merely being called at some point.
  public func holdRecoverOpenSessions() { recoverOpenSessionsGate.hold() }

  /// Test-only: resumes every currently-parked `recoverOpenSessions` call.
  public func releaseRecoverOpenSessions() { recoverOpenSessionsGate.release() }

  public func startSession(itemID: String, episodeID: String?) async throws -> PreparedPlayback {
    record(.startSession(itemID: itemID, episodeID: episodeID))
    if resumeInPlaceBox.value,
      let activeSession = activeSessionBox.value,
      activeSession.itemID == itemID,
      activeSession.episodeID == episodeID
    {
      return activeSession.prepared
    }
    let stubbed = startSessionResultBox
    let result = await startSessionGate.pass {
      stubbed.value ?? .failure(UnstubbedResult())
    }
    let prepared = try result.get()
    if resumeInPlaceBox.value {
      activeSessionBox.value = ActiveSession(itemID: itemID, episodeID: episodeID, prepared: prepared)
    }
    return prepared
  }

  public func promoteStreamingSessionToLocalDownload(
    itemID: String, episodeID: String?, currentPosition: Double, streamedDuration: Double?
  ) async -> PreparedPlayback? {
    record(
      .promoteStreamingSessionToLocalDownload(
        itemID: itemID, episodeID: episodeID, currentPosition: currentPosition,
        streamedDuration: streamedDuration))
    let stubbed = promotionResultBox
    return await promotionGate.pass { stubbed.value }
  }

  public func stopSession() async throws {
    record(.stopSession)
    await stopSessionGate.pass()
    if resumeInPlaceBox.value {
      activeSessionBox.value = nil
    }
    if let error = stopSessionErrorBox.value { throw error }
  }

  /// Nothing to renew unless a test supplies an authorization with `stubRenewStreamAuthorization`:
  /// no fake can mint a real `PlaybackStreamAuthorization` (its initializer is private to ABSApi by
  /// design).
  public func renewStreamAuthorization() async throws -> PlaybackStreamAuthorization? {
    renewedAuthorizationBox.value
  }

  public func notifyPlaybackPhase(_ phase: PlaybackCadencePhase) async {
    record(.notifyPlaybackPhase(phase))
  }

  public func willStartPlayback(itemID: String) {
    // Keep the announcement separate: `calls` is exact-order asserted by established suites, and
    // the announcement has no session semantics for this single-origin fake.
    willStartPlaybackItemIDsBox.withValue { $0.append(itemID) }
  }

  public func notifyImmediateSyncTrigger(_ trigger: PlaybackImmediateSyncTrigger) async {
    record(.notifyImmediateSyncTrigger(trigger))
  }

  public func handleAppBackgrounded() async {
    record(.handleAppBackgrounded)
  }

  public func recoverOpenSessions() async {
    record(.recoverOpenSessions)
    await recoverOpenSessionsGate.pass()
  }

  public func quiesceForLogout() async {
    record(.quiesceForLogout)
  }

  /// Test-only: makes the next (and every subsequent, until released) `recordProgressTick` call
  /// park instead of returning immediately. Lets a test prove a slow persistence/sync tick never
  /// delays the caller's own display-state updates. The call is still recorded before parking, so
  /// `waitForCalls` can observe the in-flight tick.
  public func holdRecordProgressTicks() { recordProgressTickGate.hold() }

  /// Test-only: resumes every currently-parked `recordProgressTick` call.
  public func releaseRecordProgressTicks() { recordProgressTickGate.release() }

  /// `RecordedCall.recordProgressTick` carries no `episodeID`. The full identity of every tick is
  /// recorded separately in `progressIdentityCalls`, which podcast coverage asserts against.
  public func recordProgressTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool, sleepTimerExpired: Bool = false
  ) async {
    progressIdentityCallsBox.withValue {
      $0.append(ProgressIdentityCall(itemID: itemID, episodeID: episodeID))
    }
    progressTicksBox.withValue {
      $0.append(
        ProgressTick(
          itemID: itemID, episodeID: episodeID, currentTime: currentTime,
          listenedDelta: listenedDelta, isFinished: isFinished, isSeek: isSeek,
          sleepTimerExpired: sleepTimerExpired))
    }
    record(
      .recordProgressTick(
        itemID: itemID, currentTime: currentTime, listenedDelta: listenedDelta, isFinished: isFinished,
        isSeek: isSeek))
    if sleepTimerExpired {
      record(.sleepTimerExpiry(itemID: itemID, episodeID: episodeID))
    }
    await recordProgressTickGate.pass()
  }
}
