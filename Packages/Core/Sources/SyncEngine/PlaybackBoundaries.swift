import ABSApi
import Foundation

// MARK: - Playback session orchestration

/// The stream credential appears in `PlaybackSyncing`'s public boundary, so conformers need no
/// second import to spell it. ABSApi stays the owning module; SyncEngine re-exposes the same
/// opaque value.
public typealias PlaybackStreamAuthorization = ABSApi.PlaybackStreamAuthorization

/// The request-mint seam for a prepared playback resource. The provider carries no credential or
/// origin configuration: each origin owns its authorization and decides whether a URL may receive
/// headers.
public protocol PlaybackStreamAuthorizationProviding: Sendable {
  func httpHeaderFields(for url: URL) -> [String: String]
}

// ABSApi cannot depend on SyncEngine, so the conformance lives where the value is consumed. The
// credential's initialiser, storage and origin gate are untouched.
extension ABSApi.PlaybackStreamAuthorization: PlaybackStreamAuthorizationProviding {}

/// Non-secret device/app identification injected into every `/play` request's `deviceInfo`
/// (API-CONVENTIONS.md). `deviceId` is not a property: it is always the account's own persisted
/// client UUID, never caller-supplied. Foundation-only: an App-side adapter reads the values and
/// passes them in at construction.
public struct PlaybackDeviceMetadata: Sendable, Equatable {
  public var clientVersion: String?
  public var manufacturer: String?
  public var model: String?
  public var clientName: String?
  public var deviceName: String?

  public init(
    clientVersion: String? = nil,
    manufacturer: String? = nil,
    model: String? = nil,
    clientName: String? = nil,
    deviceName: String? = nil
  ) {
    self.clientVersion = clientVersion
    self.manufacturer = manufacturer
    self.model = model
    self.clientName = clientName
    self.deviceName = deviceName
  }
}

/// One playable track on the book's global timeline (ARCHITECTURE.md), mapped from ABSApi's
/// `PlaybackSessionAudioTrack`. Unlike the source type, every field is required: a track missing
/// `index`/`startOffset`/`duration` cannot be placed on the timeline, so
/// `PlaybackSessionCoordinator` drops it during mapping.
public struct PreparedPlaybackTrack: Sendable, Equatable {
  public let index: Int
  public let startOffset: Double
  public let duration: Double
  public let url: URL
  public let mimeType: String?
  public let title: String?

  public init(index: Int, startOffset: Double, duration: Double, url: URL, mimeType: String?, title: String?) {
    self.index = index
    self.startOffset = startOffset
    self.duration = duration
    self.url = url
    self.mimeType = mimeType
    self.title = title
  }
}

/// One chapter boundary, mapped from ABSApi's `PlaybackChapter`, which never escapes above this
/// module.
public struct PreparedPlaybackChapter: Sendable, Equatable {
  public let id: Int
  public let start: Double
  public let end: Double
  public let title: String?

  public init(id: Int, start: Double, end: Double, title: String?) {
    self.id = id
    self.start = start
    self.end = end
    self.title = title
  }
}

/// Distinguishes a live server-backed session, whose `PreparedPlaybackTrack.url` values are
/// authenticated stream endpoints, from a fully local session played from files the download
/// store already validated, whose URLs are credential-free app-container file URLs. Callers
/// branch on this rather than sniffing URL schemes.
public enum PreparedPlaybackSource: Sendable, Equatable {
  case streaming
  case local
}

/// The result of a successful `PlaybackSyncing.startSession` call: everything AppModel needs to
/// hand a book off to PlayerCore, in Foundation values only (ARCHITECTURE.md: App, AppModel and
/// PlayerCore may not import ABSApi, so this is the sole shape that crosses from SyncEngine up).
/// `startPosition` already reflects `ProgressMergePolicy`'s resolution of local unacknowledged
/// progress against the server's, so callers never re-run the merge. A local (`source == .local`)
/// preparation skips it: `startPosition` is this device's last known position.
public struct PreparedPlayback: Sendable, Equatable {
  public let itemID: String
  public let episodeID: String?
  public let startPosition: Double
  public let duration: Double?
  public let tracks: [PreparedPlaybackTrack]
  public let chapters: [PreparedPlaybackChapter]
  public let source: PreparedPlaybackSource
  /// The header fields every `.streaming` track URL may be fetched with. Each origin-specific
  /// provider applies its own URL gate. `nil` for a `.local` preparation, whose file URLs need no
  /// headers.
  public let streamAuthorization: (any PlaybackStreamAuthorizationProviding)?

  public init(
    itemID: String,
    episodeID: String?,
    startPosition: Double,
    duration: Double?,
    tracks: [PreparedPlaybackTrack],
    chapters: [PreparedPlaybackChapter],
    source: PreparedPlaybackSource = .streaming,
    streamAuthorization: (any PlaybackStreamAuthorizationProviding)? = nil
  ) {
    self.itemID = itemID
    self.episodeID = episodeID
    self.startPosition = startPosition
    self.duration = duration
    self.tracks = tracks
    self.chapters = chapters
    self.source = source
    self.streamAuthorization = streamAuthorization
  }

  /// Keeps value semantics without asking the existential to expose a credential or origin. The
  /// tracks are already equal here, so comparing each provider's headers at those URLs captures
  /// the observable authorisation behaviour.
  public static func == (lhs: PreparedPlayback, rhs: PreparedPlayback) -> Bool {
    lhs.itemID == rhs.itemID
      && lhs.episodeID == rhs.episodeID
      && lhs.startPosition == rhs.startPosition
      && lhs.duration == rhs.duration
      && lhs.tracks == rhs.tracks
      && lhs.chapters == rhs.chapters
      && lhs.source == rhs.source
      && streamAuthorizationsMatch(
        lhs.streamAuthorization, rhs.streamAuthorization, urls: lhs.tracks.map(\.url))
  }

  private static func streamAuthorizationsMatch(
    _ lhs: (any PlaybackStreamAuthorizationProviding)?,
    _ rhs: (any PlaybackStreamAuthorizationProviding)?,
    urls: [URL]
  ) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
      return true
    case (nil, _), (_, nil):
      return false
    case (let lhs?, let rhs?):
      return urls.allSatisfy { url in
        lhs.httpHeaderFields(for: url) == rhs.httpHeaderFields(for: url)
      }
    }
  }
}

/// Errors `PlaybackSyncing`'s production conformance (`PlaybackSessionCoordinator`) raises.
public enum PlaybackCoordinatorError: Error, Sendable, Equatable {
  /// No signed-in account.
  case notAuthenticated
  /// `itemID` does not resolve to a locally known item (Persistence has never seen it pulled).
  case unknownItem(String)
  /// `episodeID` does not resolve beneath the requested locally-known podcast item.
  case unknownPodcastEpisode(itemID: String, episodeID: String)
  /// `/play` returned `200` but no tracks survived `PreparedPlaybackTrack`'s stricter mapping.
  /// The just-opened server session is closed as compensation (durably, then best-effort over
  /// the network) before this is thrown.
  case unusableStream
  /// `/play` succeeded but the local session row could not be persisted (it must be before the
  /// session counts as active). The just-opened server session is closed as compensation,
  /// best-effort, before this is thrown.
  case persistenceFailed
  /// `quiesceForLogout` has already run on this coordinator, so no further playback work may
  /// start. A fresh coordinator (next launch, after a fresh login) does not carry this forward.
  case quiescedForLogout
  /// A download row for `itemID` moved to `.deleting` while this call was resolving the item's
  /// playback source (a concurrent purge or removal). Fails closed rather than falling back to a
  /// half-built local preparation or an equally stale streaming attempt.
  case localSourceUnavailable(itemID: String)
  /// `itemID` was a complete local download, but the integrity sweep found it no longer playable
  /// locally (a file went missing under a `completed` row) and the streaming fallback also
  /// failed, so the item cannot be played at all. Distinct from an ordinary streaming failure,
  /// so callers never conflate "not downloaded" with "downloaded and now unavailable everywhere".
  case unplayableOffline(itemID: String)
}

/// A Foundation-only boundary AppModel drives to start, switch, or stop live playback sessions
/// (ARCHITECTURE.md: SyncEngine alone may call `/play`, `/sync`, or `/close`). AppModel maps the
/// returned `PreparedPlayback` into PlayerCore descriptors itself, as it may import both while
/// those two may not import each other.
///
/// There is no "switch" entry point: `startSession` while a different item is locally active is a
/// switch (the former session is frozen and its close attempted before `/play`), and calling it
/// for the active item is an idempotent resume with no repeated `/play`. Session requests are
/// serialised by device, not actor reentrancy (ARCHITECTURE.md), so concurrent start/stop calls
/// apply in one order.
public protocol PlaybackSyncing: Sendable {
  /// Starts, resumes (same item already active), or switches to (different item active) a live
  /// session for `itemID`/`episodeID`. Persisted locally the instant `/play` returns `200`, before
  /// further preparation, so a crash right after still leaves a recoverable session id.
  func startSession(itemID: String, episodeID: String?) async throws -> PreparedPlayback

  /// Best-effort promotion of the currently streaming session to a fully downloaded local copy.
  /// Returns the freshly opened local preparation only when promoted, `nil` when it declines (the
  /// caller keeps streaming).
  ///
  /// No protocol default, as with `recordProgressTick`: a defaulted no-op would let a decorator
  /// that forgot to forward it compile and silently withdraw the feature.
  func promoteStreamingSessionToLocalDownload(
    itemID: String, episodeID: String?, currentPosition: Double, streamedDuration: Double?
  ) async -> PreparedPlayback?

  /// Re-mints the credentials the active streamed session's track URLs use, forcing one run of the
  /// account's single-flight refresh, for the caller to re-stamp its resources with. `nil` when
  /// there is nothing to renew: no active session, or a local one whose file URLs carry no Bearer.
  ///
  /// AVFoundation checks a stream's credential, not this package's transport, so an expired one
  /// gives a 401 nothing here can see. A definitive rejection throws rather than returning a
  /// stale header, which latches the transport and raises recovery.
  func renewStreamAuthorization() async throws -> PlaybackStreamAuthorization?

  /// Stops the locally active session, if any: freezes its final position and durably persists
  /// `closePending` before any network close (API-CONVENTIONS.md rule 9). A failed network attempt
  /// is not an error; the outbox row left behind is drained later.
  func stopSession() async throws

  /// Reports PlayerCore's current coarse phase for the active session, driving the cadence state
  /// machine. The caller maps PlayerCore's richer `PlayerPhase` onto this narrower vocabulary,
  /// as SyncEngine may not import PlayerCore.
  func notifyPlaybackPhase(_ phase: PlaybackCadencePhase) async

  /// Announces the item whose start is about to be requested, before any phase notification for
  /// it. Single-origin conformers no-op; a routing conformance uses it to send pre-`startSession`
  /// cadence to the incoming origin. No default, so decorators cannot silently swallow it.
  func willStartPlayback(itemID: String)

  /// A one-shot request for an immediate drain outside the periodic cadence (pause, seek
  /// completion, backgrounding, item switch, session close; API-CONVENTIONS rule 7). Coincident
  /// triggers coalesce into a single drain.
  func notifyImmediateSyncTrigger(_ trigger: PlaybackImmediateSyncTrigger) async

  /// SyncEngine's sole `AppLifecycle` subscriber routes a `.background` transition here. While
  /// playing, requests one immediate sync (like `notifyImmediateSyncTrigger(.backgrounded)`) and
  /// leaves the session open with the cadence running. Every other phase closes the active
  /// session as `stopSession` does, marking `closePending` before any network attempt. It assumes
  /// no execution time, so a caller needing the close to survive scene suspension wraps the call.
  func handleAppBackgrounded() async

  /// Fresh-process recovery. Reconciles the locally persisted active session against
  /// `GET /api/session/{id}`, closing it locally if the server says it is gone, and
  /// best-effort-queries `/api/sessions/open` for this installation's device id to close a
  /// post-`/play` orphan that never reached local persistence. Never touches another device's
  /// session. Composition calls this once, before accepting any play intent; it shares the
  /// device-keyed chain with `startSession`/`stopSession`, so a following `/play` sees what it
  /// closed.
  func recoverOpenSessions() async

  /// Logout preflight. Stops accepting new playback work (`startSession` throws
  /// `PlaybackCoordinatorError.quiescedForLogout` from then on), persists the active session's
  /// final state, and makes one best-effort close attempt before destructive account removal.
  /// Always returns normally: a failed close leaves the durable local closure, and removal
  /// proceeds with nothing retrying it afterwards.
  func quiesceForLogout() async

  /// The thin progress-tick entry point `AppModel`'s `PlaybackModel` forwards each PlayerCore
  /// progress event to, as Foundation-only values. Persists atomically through
  /// `PlaybackSessionStore.recordTick` against the locally active session for the full
  /// `itemID`/`episodeID` identity. A tick for any other item or episode, or with no active
  /// session, is a silent no-op (a stale tick from a displaced item must never write into its
  /// successor's session). `isSeek` and a change in `isFinished` start a fresh outbox-coalescing
  /// segment, which never crosses those boundaries; an ordinary tick joins the open one.
  ///
  /// `episodeID` is required, with no item-only overload or defaulted forwarding: a decorator once
  /// inherited a default that discarded it, so no podcast tick persisted, `globalPosition` never
  /// left its seed, and `/close` reset the server's episode progress to 0. Book playback passes
  /// `nil`.
  ///
  /// `sleepTimerExpired` is PlayerCore's structural marker for a timer-owned pause. When true, the
  /// coordinator closes an active local session on this serialised chain after persisting the
  /// tick; finished events leave closure to the existing completion path.
  func recordProgressTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool, sleepTimerExpired: Bool
  ) async
}

extension PlaybackSyncing {
  /// An ordinary tick has no timer-owned close marker.
  public func recordProgressTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool
  ) async {
    await recordProgressTick(
      itemID: itemID, episodeID: episodeID, currentTime: currentTime, listenedDelta: listenedDelta,
      isFinished: isFinished, isSeek: isSeek, sleepTimerExpired: false)
  }
}

/// The coarse playback phases the cadence state machine distinguishes. Narrower than PlayerCore's
/// `PlayerPhase`, which SyncEngine may not import, and limited to what cadence policy branches
/// on: `.playing` drives the periodic 15/60 s schedule (API-CONVENTIONS rule 7) and every other
/// phase stops it. `.paused` also requests one immediate drain; `.buffering`/`.stopped`/`.idle`
/// request none.
public enum PlaybackCadencePhase: Sendable, Equatable {
  case playing
  case paused
  case buffering
  case stopped
  case idle
}

/// One-shot cadence triggers that are not themselves phase changes (API-CONVENTIONS rule 7):
/// pause after its final tick, completed seek, backgrounding, item switch, and session close each
/// request exactly one immediate drain.
public enum PlaybackImmediateSyncTrigger: Sendable, Equatable {
  case paused
  case seekCompleted
  case backgrounded
  case itemSwitching
  case closing
  /// A lifecycle catch-up (launch, foreground, explicit refresh). Nothing playback-shaped
  /// happened, but stranded outbox rows (a sessionless progress PATCH after a session died, a
  /// retry-waiting sync with no cadence left to wake it) need a send opportunity.
  case catchUp
}

/// A single pending, cancellable deadline the cadence state machine schedules drains against
/// (API-CONVENTIONS rule 7). Tests inject a fake that advances virtual time; production uses
/// `SystemPlaybackCadenceScheduler`. `reschedule` cancels the previous deadline, so at most one is
/// pending and callers track no cancellation tokens.
public protocol PlaybackCadenceScheduling: Sendable {
  /// Cancels any pending deadline and schedules `action` to run once, after `interval` elapses.
  func reschedule(after interval: TimeInterval, action: @escaping @Sendable () async -> Void) async
  /// Cancels any pending deadline without scheduling a new one.
  func cancelPending() async
}
