import Foundation
import Persistence
import SyncEngine

/// Routes `PlaybackSyncing` between the account's ABS session coordinator and the device-owned RSS
/// one. Neither child knows the other exists (`PlaybackSessionCoordinator` speaks only to the
/// server, `RSSPlaybackCoordinator` only to the native tables). Lives here, not in the App target,
/// so `PlaybackModel`'s tests can exercise the composed graph.
///
/// Calls that name an item dispatch on that item's decoded source identity. Calls about the
/// session in progress go to whichever child started it: the ABS child before any start and after
/// every stop, and the announced item's origin after an announced start but before its session
/// opens. Lifecycle calls about the app rather than a session fan out to both.
///
/// A tick or stop reaching the wrong child is a silent no-op, so a misroute means a played RSS
/// episode whose position never persists.
public final class RoutingPlaybackSyncing: PlaybackSyncing, @unchecked Sendable {
  private enum Route {
    case abs
    case rss
  }

  private let absSyncing: any PlaybackSyncing
  private let rssSyncing: any PlaybackSyncing

  /// Which child owns the session in progress, `nil` when none does. Snapshot reads use a lock
  /// rather than the transition tail so cadence from the player's event loop never waits on a
  /// `startSession` still talking to the server. Ownership-changing calls use the tail below.
  private let lock = NSLock()
  private var activeRoute: Route?
  private var pendingRoute: Route?
  private let transitionLock = NSLock()
  private var transitionTail: Task<Void, Never>?

  public init(abs: any PlaybackSyncing, rss: any PlaybackSyncing) {
    self.absSyncing = abs
    self.rssSyncing = rss
  }

  // MARK: - Keyed by item identity

  /// A switch within one origin is closed by that coordinator as part of starting the
  /// replacement. A switch across origins is not (the outgoing coordinator never sees the new
  /// item), so it is stopped explicitly here. Otherwise starting an RSS episode over a playing
  /// ABS book would leave that book's session open on the server.
  public func startSession(itemID: String, episodeID: String?) async throws -> PreparedPlayback {
    try await serializeTransition { [self] in
      let route = Self.route(forItemID: itemID)
      if let outgoing = currentRoute(), outgoing != route {
        // Best effort, as in `PlaybackSessionCoordinator`: the durable local closure matters, and
        // a failed network attempt must not block the new item.
        try? await child(outgoing).stopSession()
        setCurrentRoute(nil)
      }
      let prepared = try await child(route).startSession(itemID: itemID, episodeID: episodeID)
      setCurrentRoute(route)
      // A thrown start leaves the announcement in place so its following `.idle` phase still
      // reaches the origin that failed.
      setPendingRoute(nil)
      return prepared
    }
  }

  public func recordProgressTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool, sleepTimerExpired: Bool
  ) async {
    await child(Self.route(forItemID: itemID)).recordProgressTick(
      itemID: itemID, episodeID: episodeID, currentTime: currentTime, listenedDelta: listenedDelta,
      isFinished: isFinished, isSeek: isSeek, sleepTimerExpired: sleepTimerExpired)
  }

  /// Routes on the item's identity like a tick, not on the session in progress. It never changes
  /// which child owns the session.
  public func promoteStreamingSessionToLocalDownload(
    itemID: String, episodeID: String?, currentPosition: Double, streamedDuration: Double?
  ) async -> PreparedPlayback? {
    await child(Self.route(forItemID: itemID)).promoteStreamingSessionToLocalDownload(
      itemID: itemID, episodeID: episodeID, currentPosition: currentPosition,
      streamedDuration: streamedDuration)
  }

  // MARK: - The session in progress

  public func stopSession() async throws {
    try await serializeTransition { [self] in
      let route = currentRoute() ?? .abs
      try await child(route).stopSession()
      // A thrown close leaves the route set, so an explicit retry targets the same child
      // instead of being redirected to ABS.
      setCurrentRoute(nil)
    }
  }

  /// Only an ABS stream carries a credential; the RSS child answers `nil` because an enclosure is
  /// a foreign origin this app never authenticates to. Routing by the session in progress avoids
  /// asking the server to re-mint a credential nothing is using, since a refusal there latches
  /// the transport and raises the recovery sheet.
  public func renewStreamAuthorization() async throws -> PlaybackStreamAuthorization? {
    try await child(currentRoute() ?? .abs).renewStreamAuthorization()
  }

  /// Cadence notifications follow the session in progress, or the announced session when none is
  /// active yet. Fanning them out would let an RSS episode's `.playing` phase start the ABS
  /// periodic drain schedule for a session that does not exist.
  public func notifyPlaybackPhase(_ phase: PlaybackCadencePhase) async {
    await child(cadenceRoute()).notifyPlaybackPhase(phase)
  }

  public func notifyImmediateSyncTrigger(_ trigger: PlaybackImmediateSyncTrigger) async {
    // Catch-up is lifecycle recovery, not a property of the session in progress. Either child can
    // own stranded durable rows while the other is active, so fan out as `recoverOpenSessions`
    // does. Playback-shaped triggers stay source-routed, or ABS network cadence would start for
    // an RSS session.
    if trigger == .catchUp {
      await absSyncing.notifyImmediateSyncTrigger(trigger)
      await rssSyncing.notifyImmediateSyncTrigger(trigger)
      return
    }
    await child(cadenceRoute()).notifyImmediateSyncTrigger(trigger)
  }

  public func willStartPlayback(itemID: String) {
    setPendingRoute(Self.route(forItemID: itemID))
  }

  // MARK: - App lifecycle

  /// Backgrounding belongs to the app, not a session, and each child decides what it means: ABS
  /// closes or drains depending on its cadence phase, RSS does nothing because every accepted
  /// tick is already durable.
  public func handleAppBackgrounded() async {
    await absSyncing.handleAppBackgrounded()
    await rssSyncing.handleAppBackgrounded()
  }

  /// `PlaybackModel` blocks its first play intent on this call, so it must not return until both
  /// children have answered. Sequential and ABS-first (RSS returns immediately) keeps the launch
  /// sequence the same on every run.
  public func recoverOpenSessions() async {
    await absSyncing.recoverOpenSessions()
    await rssSyncing.recoverOpenSessions()
  }

  /// Both children must refuse new work before the account's data is removed, so neither can
  /// write into a database about to be torn down.
  public func quiesceForLogout() async {
    try? await serializeTransition { [self] in
      setCurrentRoute(nil)
      setPendingRoute(nil)
      await absSyncing.quiesceForLogout()
      await rssSyncing.quiesceForLogout()
    }
  }

  // MARK: - Routing

  /// Only an id that provably decodes to `.rss` is diverted. A malformed id carrying the reserved
  /// prefix stays on the ABS path, as in `ItemActionsModel`. The reservation is enforced at sync
  /// ingest, so an unrecognised id here fails where every other unrecognised id already fails.
  private static func route(forItemID itemID: String) -> Route {
    if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil { return .rss }
    return .abs
  }

  private func child(_ route: Route) -> any PlaybackSyncing {
    switch route {
    case .abs: absSyncing
    case .rss: rssSyncing
    }
  }

  private func currentRoute() -> Route? {
    lock.withLock { activeRoute }
  }

  private func setPendingRoute(_ route: Route?) {
    lock.withLock { pendingRoute = route }
  }

  private func cadenceRoute() -> Route {
    lock.withLock { pendingRoute ?? activeRoute ?? .abs }
  }

  private func setCurrentRoute(_ route: Route?) {
    lock.withLock { activeRoute = route }
  }

  /// Orders only calls that can change session ownership, so start/stop/logout cannot observe
  /// and then act on different route generations. Cadence stays lock-snapshot based and never
  /// waits behind preparation or network work.
  private func serializeTransition<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let task: Task<Result<T, any Error>, Never> = transitionLock.withLock {
      let previous = transitionTail
      let task = Task<Result<T, any Error>, Never> {
        await previous?.value
        do {
          return .success(try await operation())
        } catch {
          return .failure(error)
        }
      }
      transitionTail = Task { _ = await task.value }
      return task
    }
    return try await withTaskCancellationHandler {
      try await task.value.get()
    } onCancel: {
      task.cancel()
    }
  }
}
