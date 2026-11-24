import ABSApi
import Foundation
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// `RoutingPlaybackSyncing` joins the ABS session coordinator to the device-owned RSS one. Every
/// method it forwards to the wrong child is a silent no-op there rather than a visible failure (a
/// misrouted tick simply never persists), so these tests pin the routing call by call, in the
/// order the children saw them.
@Suite("RoutingPlaybackSyncing", .timeLimit(.minutes(1)))
struct RoutingPlaybackSyncingTests {
  // MARK: - Dispatch by item identity

  @Test func anABSItemStartsOnlyOnTheABSChild() async throws {
    let harness = Harness()

    _ = try await harness.sut.startSession(itemID: "li_book", episodeID: nil)

    #expect(harness.journal.calls == [.abs(.startSession(itemID: "li_book", episodeID: nil))])
  }

  @Test func anRSSItemStartsOnlyOnTheRSSChild() async throws {
    let harness = Harness()

    _ = try await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-a")

    #expect(harness.journal.calls == [.rss(.startSession(itemID: "rss:7", episodeID: "episode-a"))])
  }

  /// The reservation is enforced at sync ingest; an id that carries the prefix but does not decode
  /// is not an RSS item, and sending it to the RSS child would turn a bad id into a silent no-op
  /// instead of the failure every other unrecognised id already produces.
  @Test func aMalformedReservedIdentifierStaysOnTheABSChild() async throws {
    let harness = Harness()

    _ = try? await harness.sut.startSession(itemID: "rss:007", episodeID: "episode-a")

    #expect(
      harness.journal.calls == [.abs(.startSession(itemID: "rss:007", episodeID: "episode-a"))])
  }

  /// Promotion names its item, so it must follow that item's origin rather than the session in
  /// progress. It must leave ownership alone, since the promoted session stays where it was.
  @Test func promotionRoutesByItemIdentityAndLeavesOwnershipUnchanged() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "li_book", episodeID: nil)
    harness.journal.reset()

    _ = await harness.sut.promoteStreamingSessionToLocalDownload(
      itemID: "li_book", episodeID: nil, currentPosition: 30, streamedDuration: nil)
    _ = await harness.sut.promoteStreamingSessionToLocalDownload(
      itemID: "rss:7", episodeID: "episode-a", currentPosition: 60, streamedDuration: nil)
    try await harness.sut.stopSession()

    #expect(
      harness.journal.calls == [
        .abs(.promote(itemID: "li_book", episodeID: nil, currentPosition: 30)),
        .rss(.promote(itemID: "rss:7", episodeID: "episode-a", currentPosition: 60)),
        .abs(.stopSession),
      ])
  }

  @Test func ticksRouteByItemIdentityInBothDirections() async {
    let harness = Harness()

    await harness.sut.recordProgressTick(
      itemID: "li_book", episodeID: nil, currentTime: 30, listenedDelta: 5, isFinished: false,
      isSeek: false)
    await harness.sut.recordProgressTick(
      itemID: "rss:7", episodeID: "episode-a", currentTime: 60, listenedDelta: 10, isFinished: true,
      isSeek: true)
    // The sleep-timer close marker has to survive the hop, or an expiry would close the outgoing
    // session at the wrong position on whichever origin owns the item.
    await harness.sut.recordProgressTick(
      itemID: "li_book", episodeID: nil, currentTime: 90, listenedDelta: 3, isFinished: false,
      isSeek: false, sleepTimerExpired: true)

    #expect(
      harness.journal.calls == [
        .abs(
          .tick(
            itemID: "li_book", episodeID: nil, currentTime: 30, listenedDelta: 5, isFinished: false,
            isSeek: false, sleepTimerExpired: false)),
        .rss(
          .tick(
            itemID: "rss:7", episodeID: "episode-a", currentTime: 60, listenedDelta: 10,
            isFinished: true, isSeek: true, sleepTimerExpired: false)),
        .abs(
          .tick(
            itemID: "li_book", episodeID: nil, currentTime: 90, listenedDelta: 3, isFinished: false,
            isSeek: false, sleepTimerExpired: true)),
      ])
  }

  // MARK: - Switching origin

  /// The outgoing coordinator never sees the incoming item, so nothing else would ever tell it to
  /// close. Leaving that close out is what would strand an ABS session open on the server.
  @Test func switchingFromABSToRSSStopsTheOutgoingSessionFirst() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "li_book", episodeID: nil)
    harness.journal.reset()

    _ = try await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-a")

    #expect(
      harness.journal.calls == [
        .abs(.stopSession),
        .rss(.startSession(itemID: "rss:7", episodeID: "episode-a")),
      ])
  }

  @Test func switchingFromRSSToABSStopsTheOutgoingSessionFirst() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-a")
    harness.journal.reset()

    _ = try await harness.sut.startSession(itemID: "li_book", episodeID: nil)

    #expect(
      harness.journal.calls == [
        .rss(.stopSession),
        .abs(.startSession(itemID: "li_book", episodeID: nil)),
      ])
  }

  /// A same-origin switch is the coordinator's own business: it closes the displaced session as
  /// part of starting the replacement, so the router must not inject a second close.
  @Test func switchingWithinOneOriginInjectsNoStop() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "li_book", episodeID: nil)
    harness.journal.reset()

    _ = try await harness.sut.startSession(itemID: "li_other", episodeID: nil)

    #expect(harness.journal.calls == [.abs(.startSession(itemID: "li_other", episodeID: nil))])
  }

  // MARK: - The session in progress

  @Test func stopFollowsTheChildThatStarted() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-a")
    harness.journal.reset()

    try await harness.sut.stopSession()

    #expect(harness.journal.calls == [.rss(.stopSession)])
  }

  @Test func aFailedStopRetainsItsRouteForRetry() async throws {
    let harness = Harness(rssStopFailsOnce: true)
    _ = try await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-a")
    harness.journal.reset()

    await #expect(throws: RecordingStopError.self) {
      try await harness.sut.stopSession()
    }
    try await harness.sut.stopSession()

    #expect(harness.journal.calls == [.rss(.stopSession), .rss(.stopSession)])
  }

  /// The first call is held inside the RSS child after the router has accepted it but before it can
  /// publish RSS ownership. The stop task is launched on the same serial executor and signals
  /// synchronously before entering the router, so releasing the child cannot race ahead of the
  /// stop request itself.
  @Test
  @MainActor
  func stopAcceptedDuringRSSPreparationRunsAfterThatStartAndStopsRSS() async throws {
    let startGate = BlockingCall()
    let harness = Harness(rssStartGate: startGate)
    let starting = Task {
      try await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-a")
    }
    await startGate.waitUntilEntered()

    let stopWasRequested = TestCountRecorder(label: "stop request")
    let stopping = Task {
      stopWasRequested.record()
      try await harness.sut.stopSession()
    }
    await stopWasRequested.waitUntil(count: 1)
    await startGate.release()

    _ = try await starting.value
    try await stopping.value

    #expect(
      harness.journal.calls == [
        .rss(.startSession(itemID: "rss:7", episodeID: "episode-a")),
        .rss(.stopSession),
      ])
  }

  /// An account that has never played anything behaves as if there were no router: the ABS child
  /// stays the destination for every unkeyed call.
  @Test func unkeyedCallsBeforeAnyStartGoToTheABSChild() async throws {
    let harness = Harness()

    try await harness.sut.stopSession()
    await harness.sut.notifyPlaybackPhase(.playing)
    await harness.sut.notifyImmediateSyncTrigger(.paused)
    _ = try await harness.sut.renewStreamAuthorization()

    #expect(
      harness.journal.calls == [
        .abs(.stopSession), .abs(.phase(.playing)), .abs(.trigger(.paused)), .abs(.renew),
      ])
  }

  @Test func anAnnouncedRSSItemRoutesPhaseAwayFromAnActiveABSSession() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "li_book", episodeID: nil)
    harness.journal.reset()

    harness.sut.willStartPlayback(itemID: "rss:7")
    await harness.sut.notifyPlaybackPhase(.buffering)

    #expect(harness.journal.calls == [.rss(.phase(.buffering))])
  }

  @Test func anAnnouncedRSSItemRoutesImmediateTriggerAwayFromAnActiveABSSession() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "li_book", episodeID: nil)
    harness.journal.reset()

    harness.sut.willStartPlayback(itemID: "rss:7")
    await harness.sut.notifyImmediateSyncTrigger(.seekCompleted)

    #expect(harness.journal.calls == [.rss(.trigger(.seekCompleted))])
  }

  /// The announcement and the start name different origins: once a session is open,
  /// the route it opened on is the answer, and an announcement that never became a session must
  /// not go on overriding it. Announcing the item that did start could not tell the two apart.
  @Test func aSuccessfulStartClearsThePendingRoute() async throws {
    let harness = Harness()

    harness.sut.willStartPlayback(itemID: "rss:7")
    _ = try await harness.sut.startSession(itemID: "li_book", episodeID: nil)
    harness.journal.reset()
    await harness.sut.notifyPlaybackPhase(.playing)

    #expect(harness.journal.calls == [.abs(.phase(.playing))])
  }

  /// The failure path's own `.idle` has to reach the origin that failed, and nothing else can name
  /// it: the start never opened a session, so there is no active route to follow, and the ABS
  /// fallback would report a device-owned episode's collapse to the server coordinator.
  @Test func aFailedStartKeepsThePendingRouteForItsIdlePhase() async throws {
    let harness = Harness()

    harness.sut.willStartPlayback(itemID: "rss:7")
    _ = try? await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-throws")
    await harness.sut.notifyPlaybackPhase(.idle)

    #expect(
      harness.journal.calls == [
        .rss(.startSession(itemID: "rss:7", episodeID: "episode-throws")), .rss(.phase(.idle)),
      ])
  }

  @Test func stopReturnsTheRouterToTheABSChild() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-a")
    try await harness.sut.stopSession()
    harness.journal.reset()

    await harness.sut.notifyPlaybackPhase(.paused)

    #expect(harness.journal.calls == [.abs(.phase(.paused))])
  }

  /// An RSS episode's cadence must never reach the ABS coordinator: `.playing` there schedules the
  /// periodic outbox drain, which is ABS network work an enclosure stream has no business starting.
  @Test func cadenceNotificationsFollowAnRSSSession() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-a")
    harness.journal.reset()

    await harness.sut.notifyPlaybackPhase(.playing)
    await harness.sut.notifyImmediateSyncTrigger(.seekCompleted)

    #expect(harness.journal.calls == [.rss(.phase(.playing)), .rss(.trigger(.seekCompleted))])
  }

  @Test func renewalDuringAnRSSSessionNeverReachesTheServer() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-a")
    harness.journal.reset()

    let renewed = try await harness.sut.renewStreamAuthorization()

    #expect(renewed == nil)
    #expect(harness.journal.calls == [.rss(.renew)])
  }

  // MARK: - App lifecycle fan-out

  /// `PlaybackModel` blocks its first play intent on this call, so the gate must stay shut until
  /// both children have answered. ABS-first keeps the launch sequence identical run to run.
  @Test func recoveryFansOutToBothChildrenABSFirst() async {
    let harness = Harness()

    await harness.sut.recoverOpenSessions()

    #expect(harness.journal.calls == [.abs(.recoverOpenSessions), .rss(.recoverOpenSessions)])
  }

  /// Foreground/launch catch-up is lifecycle recovery rather than playback cadence. A native
  /// session can need its pending local rows drained while ABS remains the active source (and vice
  /// versa), so this trigger follows the same deterministic ABS-first fan-out as recovery.
  @Test func catchUpFansOutToBothChildrenABSFirstRegardlessOfTheActiveSource() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-a")
    harness.journal.reset()

    await harness.sut.notifyImmediateSyncTrigger(.catchUp)

    #expect(
      harness.journal.calls == [
        .abs(.trigger(.catchUp)),
        .rss(.trigger(.catchUp)),
      ])
  }

  @Test func backgroundingFansOutToBothChildren() async {
    let harness = Harness()

    await harness.sut.handleAppBackgrounded()

    #expect(harness.journal.calls == [.abs(.backgrounded), .rss(.backgrounded)])
  }

  @Test func logoutQuiescenceFansOutToBothChildren() async {
    let harness = Harness()

    await harness.sut.quiesceForLogout()

    #expect(harness.journal.calls == [.abs(.quiesceForLogout), .rss(.quiesceForLogout)])
  }

  /// Quiescence tears the account down, so nothing may keep pointing at the RSS child afterwards.
  @Test func logoutDuringAnRSSSessionReturnsTheRouterToTheABSChild() async throws {
    let harness = Harness()
    _ = try await harness.sut.startSession(itemID: "rss:7", episodeID: "episode-a")
    await harness.sut.quiesceForLogout()
    harness.journal.reset()

    try await harness.sut.stopSession()

    #expect(harness.journal.calls == [.abs(.stopSession)])
  }
}

// MARK: - Harness

private struct Harness {
  let journal = CallJournal()
  let sut: RoutingPlaybackSyncing

  init(rssStartGate: BlockingCall? = nil, rssStopFailsOnce: Bool = false) {
    sut = RoutingPlaybackSyncing(
      abs: RecordingChild(origin: .abs, journal: journal),
      rss: RecordingChild(
        origin: .rss, journal: journal, startGate: rssStartGate,
        stopFailuresRemaining: rssStopFailsOnce ? 1 : 0))
  }
}

/// One journal shared by both children, because the assertions that matter are about ordering
/// across them: that the outgoing session is stopped before the incoming one starts, and that
/// recovery reaches both.
private final class CallJournal: @unchecked Sendable {
  enum Origin: Equatable, Sendable {
    case abs
    case rss
  }

  enum Method: Equatable, Sendable {
    case startSession(itemID: String, episodeID: String?)
    case stopSession
    case renew
    case phase(PlaybackCadencePhase)
    case trigger(PlaybackImmediateSyncTrigger)
    case backgrounded
    case recoverOpenSessions
    case quiesceForLogout
    case tick(
      itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
      isFinished: Bool, isSeek: Bool, sleepTimerExpired: Bool)
    case promote(itemID: String, episodeID: String?, currentPosition: Double)
  }

  enum Call: Equatable, Sendable {
    case abs(Method)
    case rss(Method)
  }

  private let lock = NSLock()
  private var recorded: [Call] = []

  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func record(_ origin: Origin, _ method: Method) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(origin == .abs ? .abs(method) : .rss(method))
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    recorded = []
  }
}

// Kept: both children share one `CallJournal` so the tests can assert ordering across them,
// which two separate FakePlaybackSyncing recorders cannot express.
/// Answers every `PlaybackSyncing` requirement by recording it. `startSession` returns a minimal
/// preparation rather than throwing so a routing test never has to distinguish "went to the wrong
/// child" from "the right child refused".
private final class RecordingChild: PlaybackSyncing, @unchecked Sendable {
  private let origin: CallJournal.Origin
  private let journal: CallJournal
  private let startGate: BlockingCall?
  private let stopFailureLock = NSLock()
  private var stopFailuresRemaining: Int

  init(
    origin: CallJournal.Origin, journal: CallJournal, startGate: BlockingCall? = nil,
    stopFailuresRemaining: Int = 0
  ) {
    self.origin = origin
    self.journal = journal
    self.startGate = startGate
    self.stopFailuresRemaining = stopFailuresRemaining
  }

  func startSession(itemID: String, episodeID: String?) async throws -> PreparedPlayback {
    journal.record(origin, .startSession(itemID: itemID, episodeID: episodeID))
    await startGate?.enter()
    // Keyed on the episode rather than the item so either child can be made to refuse, which is
    // what lets a failure test name an origin the ABS fallback would not have reached anyway.
    if episodeID == "episode-throws" { throw RecordingStartError() }
    return PreparedPlayback(
      itemID: itemID,
      episodeID: episodeID,
      startPosition: 0,
      duration: 60,
      tracks: [
        PreparedPlaybackTrack(
          index: 0, startOffset: 0, duration: 60,
          url: URL(string: "https://example.test/audio.mp3")!, mimeType: "audio/mpeg",
          title: itemID)
      ],
      chapters: [],
      source: .streaming,
      streamAuthorization: nil)
  }

  func willStartPlayback(itemID: String) {
    _ = itemID
  }

  /// Always `nil`: these tests pin which child was asked, not what a promotion produced.
  func promoteStreamingSessionToLocalDownload(
    itemID: String, episodeID: String?, currentPosition: Double, streamedDuration: Double?
  ) async -> PreparedPlayback? {
    journal.record(
      origin,
      .promote(itemID: itemID, episodeID: episodeID, currentPosition: currentPosition))
    return nil
  }

  func stopSession() async throws {
    journal.record(origin, .stopSession)
    let shouldFail = stopFailureLock.withLock {
      guard stopFailuresRemaining > 0 else { return false }
      stopFailuresRemaining -= 1
      return true
    }
    if shouldFail { throw RecordingStopError() }
  }

  /// Always `nil`: what these tests pin is which child was asked, and a real authorization can only
  /// be minted through a token store this suite has no reason to build.
  func renewStreamAuthorization() async throws -> PlaybackStreamAuthorization? {
    journal.record(origin, .renew)
    return nil
  }

  func notifyPlaybackPhase(_ phase: PlaybackCadencePhase) async {
    journal.record(origin, .phase(phase))
  }

  func notifyImmediateSyncTrigger(_ trigger: PlaybackImmediateSyncTrigger) async {
    journal.record(origin, .trigger(trigger))
  }

  func handleAppBackgrounded() async {
    journal.record(origin, .backgrounded)
  }

  func recoverOpenSessions() async {
    journal.record(origin, .recoverOpenSessions)
  }

  func quiesceForLogout() async {
    journal.record(origin, .quiesceForLogout)
  }

  func recordProgressTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool, sleepTimerExpired: Bool
  ) async {
    journal.record(
      origin,
      .tick(
        itemID: itemID, episodeID: episodeID, currentTime: currentTime,
        listenedDelta: listenedDelta, isFinished: isFinished, isSeek: isSeek,
        sleepTimerExpired: sleepTimerExpired))
  }
}

private struct RecordingStartError: Error {}
private struct RecordingStopError: Error {}

private actor BlockingCall {
  // A held call runs to completion regardless of cancellation.
  private nonisolated let gate = TestGate<Void>(
    label: "BlockingCall enter", ignoresCancellation: true)

  init() { gate.hold() }

  func enter() async {
    await gate.pass()
  }

  func waitUntilEntered() async {
    await gate.waitUntilParked()
  }

  func release() {
    gate.release()
  }
}
