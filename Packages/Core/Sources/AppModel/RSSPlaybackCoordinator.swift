import Foundation
import Persistence
import PodcastFeeds
import SyncEngine

/// Failures while preparing a device-owned RSS episode for direct enclosure streaming.
public enum RSSPlaybackCoordinatorError: Error, Equatable, Sendable {
  case notAnRSSItem(itemID: String)
  /// An RSS item was named without an episode. Distinct from `unknownEpisode`: nothing was asked
  /// for, so there is no id to report, and inventing a placeholder one would misreport the bug.
  case missingEpisodeID(itemID: String)
  case unknownEpisode(itemID: String, episodeID: String)
  case durationUnavailable(itemID: String, episodeID: String)
  case unplayableEnclosure(itemID: String, episodeID: String)
}

/// Process-local bridge from RSS playback to storage eviction. Playback owns the write side;
/// eviction reads a synchronous snapshot immediately before its transactional candidate query.
/// The durable queue exclusion remains database-backed and independent of this active marker.
public final class RSSActivePlaybackTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var episodeRowID: Int64?

  public init() {}

  public var activeEpisodeRowIDs: Set<Int64> {
    lock.withLock { episodeRowID.map { Set([$0]) } ?? [] }
  }

  fileprivate func setActiveEpisodeRowID(_ value: Int64?) {
    lock.withLock { episodeRowID = value }
  }
}

/// Told when a pause or close has made an RSS episode's final position durable. Pausing lets iOS
/// suspend the app within seconds, so cloud sync sends then instead of on its own schedule.
/// Must return at once: the playback bridge awaits its triggers in order.
public protocol PodcastPlaybackSettleObserving: Sendable {
  func playbackPositionSettled()
}

/// `PlaybackSyncing` for device-owned RSS episodes. This coordinator only reads and writes the
/// native RSS tables: an enclosure is a foreign-origin stream, so this type has no ABS session,
/// outbox, or HTTP dependency by construction.
public actor RSSPlaybackCoordinator: PlaybackSyncing {
  private let episodeStore: RSSEpisodeStore
  private let stateStore: RSSEpisodeStateStore
  private let durationResolver: RSSEpisodeDurationResolver
  private let chapterResolver: RSSEpisodeChapterResolver?
  private let fileStore: RSSFileStore?
  private let activePlaybackTracker: RSSActivePlaybackTracker?
  private let feedStore: RSSFeedStore
  private let credentialStore: any PodcastFeedCredentialStoring
  private let downloadPreferences: any DownloadPreferences
  private let requestFinishedDownloadDeletion: @Sendable (String, String?) async -> Void
  private let requestPodcastAutoDownloadReap: @Sendable () async -> Void
  private let settleObserver: (any PodcastPlaybackSettleObserving)?
  private let now: @Sendable () -> Date

  private struct ActiveIdentity: Sendable, Equatable {
    let itemID: String
    let episodeID: String
    let episodeRowID: Int64
    var capturedSequence: Int64
    /// The finished flag of the last tick this identity durably wrote, or `nil` before any tick
    /// has landed. Only a witnessed not-finished to finished transition may delete a download, so
    /// the first tick of a stream that already reports finished is not a fresh completion.
    var lastPersistedFinished: Bool?
    /// The timeline length playback was prepared against. A promotion compares the local file to
    /// this rather than to the feed, because the stream actually playing may be a different cut.
    let preparedDuration: Double
  }

  private var activeIdentity: ActiveIdentity?
  private var isQuiescedForLogout = false
  private var sessionGeneration: UInt64 = 0
  /// Same save rule as the account-owned coordinator: ticks while playing are held, one durable
  /// write per interval or at a boundary. Every `rssEpisodeState` observer (show page, Home,
  /// mini-player) re-runs on each write, so saving per tick would rebuild them at the tick rate.
  private var progressThrottle: ProgressPersistThrottle
  /// Starts as not playing, so a tick that arrives without a phase (a teardown's final tick, a
  /// test) saves at once rather than being held.
  private var cadencePhase: PlaybackCadencePhase = .idle

  public init(
    episodeStore: RSSEpisodeStore,
    stateStore: RSSEpisodeStateStore,
    durationResolver: RSSEpisodeDurationResolver,
    chapterResolver: RSSEpisodeChapterResolver? = nil,
    fileStore: RSSFileStore? = nil,
    activePlaybackTracker: RSSActivePlaybackTracker? = nil,
    feedStore: RSSFeedStore,
    credentialStore: any PodcastFeedCredentialStoring,
    downloadPreferences: any DownloadPreferences = NoOpDownloadPreferences(),
    requestFinishedDownloadDeletion: @escaping @Sendable (String, String?) async -> Void = {
      _, _ in
    },
    requestPodcastAutoDownloadReap: @escaping @Sendable () async -> Void = {},
    settleObserver: (any PodcastPlaybackSettleObserving)? = nil,
    progressPersistInterval: TimeInterval = PlaybackSessionCoordinator.progressPersistInterval,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.episodeStore = episodeStore
    self.stateStore = stateStore
    self.durationResolver = durationResolver
    self.chapterResolver = chapterResolver
    self.fileStore = fileStore
    self.activePlaybackTracker = activePlaybackTracker
    self.feedStore = feedStore
    self.credentialStore = credentialStore
    self.downloadPreferences = downloadPreferences
    self.requestFinishedDownloadDeletion = requestFinishedDownloadDeletion
    self.requestPodcastAutoDownloadReap = requestPodcastAutoDownloadReap
    self.settleObserver = settleObserver
    self.progressThrottle = ProgressPersistThrottle(interval: progressPersistInterval)
    self.now = now
  }

  // MARK: - PlaybackSyncing

  public func startSession(itemID: String, episodeID: String?) async throws -> PreparedPlayback {
    // A replacement can win the race with a stop that never reached its close, so the outgoing
    // stream's held tick is saved here while its identity is still installed.
    await flushPendingProgress()
    progressThrottle.reset()
    sessionGeneration &+= 1
    let generation = sessionGeneration
    do {
      return try await prepare(itemID: itemID, episodeID: episodeID, generation: generation)
    } catch {
      // Preparation owns the marker from the first suspending step onward, so a failed start
      // (CancellationError included) retires both the identity and its eviction exclusion. A
      // superseded generation must leave its replacement's marker alone.
      if sessionGeneration == generation {
        activeIdentity = nil
        activePlaybackTracker?.setActiveEpisodeRowID(nil)
      }
      throw error
    }
  }

  public func stopSession() async throws {
    // There is no session or outbox to close; only the held tick needs saving before the identity
    // it belongs to is cleared.
    await flushPendingProgress()
    progressThrottle.reset()
    sessionGeneration &+= 1
    activeIdentity = nil
    activePlaybackTracker?.setActiveEpisodeRowID(nil)
  }

  /// Always `nil`. A feed credential is a stored, static field, not a minted token that can
  /// expire, so there is nothing to re-mint. An enclosure off the feed's own origin is never sent
  /// one (`FeedCredentialOrigin`). `PlaybackSyncing` requires every member at each conformance.
  public func renewStreamAuthorization() async throws -> PlaybackStreamAuthorization? { nil }

  /// The active stream's completed download, prepared to continue at `currentPosition`. There is no
  /// session to re-open: the active identity, its tick sequence and the eviction marker carry over
  /// unchanged. Anything only the local file provides depends on this swap, since a stream and its
  /// download can differ (dynamic ad insertion serves each request its own ads).
  public func promoteStreamingSessionToLocalDownload(
    itemID: String, episodeID: String?, currentPosition: Double, streamedDuration: Double?
  ) async -> PreparedPlayback? {
    let generation = sessionGeneration
    guard isQuiescedForLogout == false, let fileStore, let active = activeIdentity,
      active.itemID == itemID, active.episodeID == episodeID,
      let localURL = try? fileStore.validatedLocalURL(episodeId: active.episodeRowID),
      let episode = try? await episodeStore.fetchEpisode(episodeId: active.episodeRowID),
      let duration = try? await durationResolver.resolve(
        episodeId: active.episodeRowID, localFileURL: localURL)
    else { return nil }

    // The swap moves the playhead to the same offset in a different file, so both timelines must
    // agree. Checked before chapters so a declined swap never pays for a parse. The reference is
    // the length the player observed on the stream: the feed's declaration is often shorter than
    // a stream with inserted ads, and the download carries the same ads. The observed timeline
    // only grows, so a feed that over-declares stays the reference, which errs toward declining.
    guard
      PlaybackSessionCoordinator.promotionTimelinesAgree(
        localDuration: duration, referenceDuration: streamedDuration ?? active.preparedDuration,
        position: currentPosition),
      let chapters = try? await embeddedChapters(
        episodeRowID: active.episodeRowID, localURL: localURL, duration: duration),
      isQuiescedForLogout == false, sessionGeneration == generation,
      activeIdentity?.episodeRowID == active.episodeRowID
    else { return nil }
    return PreparedPlayback(
      itemID: itemID,
      episodeID: active.episodeID,
      startPosition: currentPosition,
      duration: duration,
      tracks: [
        PreparedPlaybackTrack(
          index: 0,
          startOffset: 0,
          duration: duration,
          url: localURL,
          mimeType: episode.enclosureType,
          title: episode.title)
      ],
      chapters: chapters,
      source: .local,
      streamAuthorization: nil)
  }

  public func notifyPlaybackPhase(_ phase: PlaybackCadencePhase) async {
    // The bridge sends a phase change before the tick that carries it, so the held tick is saved
    // as the listen leaves playing, and every tick until it resumes saves at once.
    cadencePhase = phase
    if phase != .playing { await flushPendingProgress() }
  }

  public nonisolated func willStartPlayback(itemID _: String) {
    // RSS owns one origin, so there is no route to prepare.
  }

  public func notifyImmediateSyncTrigger(_ trigger: PlaybackImmediateSyncTrigger) async {
    // No RSS network cadence to drive. A pause or close follows its final tick, which the
    // throttle may still hold; once that is saved, cloud sync must send before iOS suspends.
    switch trigger {
    case .paused, .closing:
      await flushPendingProgress()
      settleObserver?.playbackPositionSettled()
    case .backgrounded, .itemSwitching:
      await flushPendingProgress()
    case .seekCompleted, .catchUp: break
    }
  }

  public func handleAppBackgrounded() async {
    // Backgrounding is not an interruption for an RSS stream, so playback continues; the held tick
    // is saved because iOS may suspend or end the app from here on.
    await flushPendingProgress()
  }

  public func recoverOpenSessions() async {
    // No sessions to recover; the next start reads the local state row, which a crash leaves at
    // most one save interval behind. Must complete immediately: PlaybackModel's recovery gate
    // waits on it.
  }

  public func quiesceForLogout() async {
    await flushPendingProgress()
    progressThrottle.reset()
    isQuiescedForLogout = true
    sessionGeneration &+= 1
    activeIdentity = nil
    activePlaybackTracker?.setActiveEpisodeRowID(nil)
  }

  public func recordProgressTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool, sleepTimerExpired _: Bool
  ) async {
    // The close marker exists so a sleep-timer expiry closes the ABS server session at the right
    // position. A native RSS episode has no server session to close, so the flag is inert here.
    await recordTick(
      itemID: itemID, episodeID: episodeID, currentTime: currentTime,
      listenedDelta: listenedDelta, isFinished: isFinished, isSeek: isSeek)
  }

  // MARK: - Preparation

  private func prepare(
    itemID: String, episodeID: String?, generation: UInt64
  ) async throws -> PreparedPlayback {
    guard isQuiescedForLogout == false else {
      // Reuse the shared error so PlaybackModel's logout seam handles either coordinator alike.
      throw PlaybackCoordinatorError.quiescedForLogout
    }
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else {
      throw RSSPlaybackCoordinatorError.notAnRSSItem(itemID: itemID)
    }
    guard let episodeID else {
      throw RSSPlaybackCoordinatorError.missingEpisodeID(itemID: itemID)
    }
    guard
      let episode = try await episodeStore.fetchEpisode(feedId: feedID, identityKey: episodeID),
      let episodeRowID = episode.id
    else {
      throw RSSPlaybackCoordinatorError.unknownEpisode(itemID: itemID, episodeID: episodeID)
    }
    try Task.checkCancellation()
    try requireCurrentSessionGeneration(generation)

    // A completed file is the source of truth for local playback. Resolve it before the duration
    // loader so a downloaded episode never probes its remote enclosure. A malformed enclosure is
    // only fatal when streaming is the remaining option. The marker precedes this integrity read
    // and the suspending duration/state reads, so a concurrent eviction cannot remove the file
    // between validation and the playback request.
    activePlaybackTracker?.setActiveEpisodeRowID(episodeRowID)
    var localURL: URL?
    if let fileStore {
      localURL = try? fileStore.validatedLocalURL(episodeId: episodeRowID)
      if localURL == nil {
        // Streaming continues either way; this only corrects a row still claiming a file.
        try? fileStore.demoteCompletedDownloadIfFileInvalid(episodeId: episodeRowID)
      }
    }
    let enclosureURL = URL(string: episode.enclosureURL)
    guard let playbackURL = localURL ?? enclosureURL else {
      throw RSSPlaybackCoordinatorError.unplayableEnclosure(itemID: itemID, episodeID: episodeID)
    }
    guard
      let duration = try await durationResolver.resolve(
        episodeId: episodeRowID, localFileURL: localURL)
    else {
      throw RSSPlaybackCoordinatorError.durationUnavailable(
        itemID: itemID, episodeID: episodeID)
    }
    try Task.checkCancellation()
    try requireCurrentSessionGeneration(generation)

    let chapters = try await embeddedChapters(
      episodeRowID: episodeRowID, localURL: localURL, duration: duration)
    try Task.checkCancellation()
    try requireCurrentSessionGeneration(generation)

    let state = try await stateStore.fetchState(episodeId: episodeRowID)
    try Task.checkCancellation()
    try requireCurrentSessionGeneration(generation)
    // There is one local RSS writer and no server observation to merge against, so the stored
    // position is the complete resume policy. Restart-on-finished remains a UI decision.
    let startPosition = state?.position ?? 0
    let source: PreparedPlaybackSource = localURL == nil ? .streaming : .local
    let streamAuthorization = await makeStreamAuthorization(feedID: feedID, source: source)
    let prepared = PreparedPlayback(
      itemID: itemID,
      episodeID: episodeID,
      startPosition: startPosition,
      duration: duration,
      tracks: [
        PreparedPlaybackTrack(
          index: 0,
          startOffset: 0,
          duration: duration,
          url: playbackURL,
          mimeType: episode.enclosureType,
          title: episode.title)
      ],
      chapters: chapters,
      source: source,
      streamAuthorization: streamAuthorization)

    guard isQuiescedForLogout == false else {
      throw PlaybackCoordinatorError.quiescedForLogout
    }
    try Task.checkCancellation()
    try requireCurrentSessionGeneration(generation)
    // A different RSS identity simply replaces this local marker; there is no server session to
    // close first. The same identity is an idempotent resume but still returns this fresh read.
    activeIdentity = ActiveIdentity(
      itemID: itemID, episodeID: episodeID, episodeRowID: episodeRowID,
      capturedSequence: state?.localSequence ?? 0, lastPersistedFinished: nil,
      preparedDuration: duration)
    return prepared
  }

  /// Only a local file is read: a stream's chapters would need a network fetch this coordinator
  /// has no policy for. Ranges are fitted to the timeline actually being played, because the file
  /// is a separate fetch from the one the chapter table was authored against.
  private func embeddedChapters(
    episodeRowID: Int64, localURL: URL?, duration: Double
  ) async throws -> [PreparedPlaybackChapter] {
    guard let chapterResolver, let localURL else { return [] }
    let found = try await chapterResolver.resolve(episodeId: episodeRowID, localFileURL: localURL)
    return found.filter { $0.start < duration }.enumerated().map { index, chapter in
      PreparedPlaybackChapter(
        id: index, start: chapter.start, end: min(chapter.end, duration), title: chapter.title)
    }
  }

  private func requireCurrentSessionGeneration(_ generation: UInt64) throws {
    guard sessionGeneration == generation else { throw CancellationError() }
  }

  private func makeStreamAuthorization(
    feedID: Int64, source: PreparedPlaybackSource
  ) async -> (any PlaybackStreamAuthorizationProviding)? {
    guard source == .streaming else { return nil }

    guard let feed = try? await feedStore.fetchFeed(feedId: feedID) else { return nil }
    guard let credential = try? credentialStore.load(forFeedID: feedID) else { return nil }

    guard let feedURL = URL(string: feed.feedURL) else { return nil }
    return RSSPlaybackStreamAuthorization(credential: credential, feedURL: feedURL)
  }

  // MARK: - Progress

  private func recordTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta _: Double,
    isFinished: Bool, isSeek: Bool
  ) async {
    guard let activeIdentity, let episodeID,
      activeIdentity.itemID == itemID, activeIdentity.episodeID == episodeID
    else { return }

    // A native RSS row has no listened-delta semantics; only the latest position and finished
    // flag are persisted, so the throttle's merged delta is ignored.
    let decision = progressThrottle.record(
      ProgressPersistThrottle.Tick(
        itemID: itemID, episodeID: episodeID, currentTime: currentTime, listenedDelta: 0,
        isFinished: isFinished),
      isSeek: isSeek, isPlaying: cadencePhase == .playing, now: now())
    for write in decision.writes {
      await persist(write.tick, for: activeIdentity)
    }
  }

  /// Saves the held tick, if any, against the identity it was recorded for.
  private func flushPendingProgress() async {
    guard let activeIdentity, let held = progressThrottle.takePending(now: now()),
      held.itemID == activeIdentity.itemID, held.episodeID == activeIdentity.episodeID
    else { return }
    await persist(held, for: activeIdentity)
  }

  private func persist(_ tick: ProgressPersistThrottle.Tick, for identity: ActiveIdentity) async {
    // The identity is re-read for its sequence: an earlier write in the same decision has already
    // advanced it.
    let current = activeIdentity?.episodeRowID == identity.episodeRowID ? activeIdentity : nil
    guard let current, let episodeID = tick.episodeID else { return }
    let itemID = tick.itemID
    let isFinished = tick.isFinished
    do {
      let outcome = try await stateStore.recordTick(
        episodeId: current.episodeRowID,
        position: tick.currentTime,
        finished: isFinished,
        capturedSequence: current.capturedSequence,
        now: now())
      switch outcome {
      case .applied(let localSequence):
        let previousFinished = current.lastPersistedFinished
        updateCapturedSequence(localSequence, finished: isFinished, for: current)
        // Finished is durable, so post-persistence cleanup runs as in the account-owned tick.
        // Only a transition this stream itself wrote as not-finished first qualifies.
        if isFinished, previousFinished == false, downloadPreferences.deleteWhenFinished {
          await requestFinishedDownloadDeletion(itemID, episodeID)
        }
        // Reaps on every transition into finished, including a stream's first tick
        // (`previousFinished == nil`): reaping with nothing to reap is a no-op, while missing the
        // one finish would leave auto-downloads uncollected.
        if isFinished, previousFinished != true {
          await requestPodcastAutoDownloadReap()
        }
      case .suppressedNearZeroReset:
        // The guard did not change the row, so retain the sequence held by this identity.
        break
      }
    } catch let error as RSSEpisodeStateStoreError {
      if case .staleLocalSequence(_, let durable) = error {
        // Adopt the durable sequence so an externally advanced row cannot wedge every later tick.
        // Finished memory is left alone: nothing landed, so the next tick that does lands witnesses
        // the transition.
        updateCapturedSequence(durable, finished: nil, for: current)
      }
      // `episodeNotFound` and every other state-store error are best-effort drops at this seam.
    } catch {
      // A local session write is best effort, matching the shared playback boundary contract.
    }
  }

  /// `finished` is the flag the tick durably wrote, or `nil` when no write landed.
  private func updateCapturedSequence(
    _ sequence: Int64, finished: Bool?, for identity: ActiveIdentity
  ) {
    guard
      activeIdentity?.itemID == identity.itemID,
      activeIdentity?.episodeID == identity.episodeID,
      activeIdentity?.episodeRowID == identity.episodeRowID
    else { return }
    activeIdentity?.capturedSequence = sequence
    if let finished {
      activeIdentity?.lastPersistedFinished = finished
    }
  }

}
