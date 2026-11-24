import CoreSupport
import Foundation
import Observation
import Persistence
import PlayerCore
import SyncEngine

/// The playback coordinator and, together with `NavigationModel.PlayerPresentation`, the global
/// presentation state the shell's mini-player renders (see ARCHITECTURE.md). The only AppModel
/// type that sees both `PlaybackSyncing` (SyncEngine) and `PlaybackControlling` (PlayerCore). Maps
/// `PreparedPlayback` into PlayerCore's descriptors, forwards every PlayerCore progress event to
/// `PlaybackSyncing` (persist transaction and cadence state machine), and owns all player copy
/// (`PlaybackCopy`). `RootModel` constructs one instance shared across sections.
@MainActor
@Observable
public final class PlaybackModel: LogoutPreflighting {

  /// Coarse display phase, narrower than PlayerCore's `PlayerPhase` in one place: `.ready`
  /// (loaded, never yet played) folds into `.paused`. A start that plays issues `.play` right
  /// behind `.load`, so that gap needs no copy; a start asked not to play (a Look Back load, a
  /// continuation prepared after a finish) stays `.paused` once the load settles. `.stalled` is
  /// distinct from ordinary buffering because it has reached a terminal deadline. `.failed` splits
  /// into `.recoverableError` and `.unrecoverableError` so `retry()` (legal only from the former)
  /// and its copy stay distinct.
  public enum Phase: Sendable, Equatable {
    case idle
    case preparing
    case buffering
    case stalled
    case playing
    case paused
    case seeking
    case recoverableError
    case unrecoverableError
    case ended
  }

  @ObservationIgnored public var authorizePlaybackStart:
    (@MainActor (String, String?) async -> PlaybackStartAuthorization)?

  public private(set) var phase: Phase = .idle
  /// The item the shell has selected for presentation. During `start`, this changes immediately
  /// so the UI can transition to the requested item while session preparation is in flight.
  public private(set) var activeItemID: String?
  public private(set) var activeEpisodeID: String?
  /// The item actually handed to PlayerCore. Unlike `activeItemID`, this does not change until
  /// preparation succeeds and `.load` is sent, so stale player state can never be mistaken for
  /// the newly requested item.
  public private(set) var loadedItemID: String?
  public private(set) var loadedEpisodeID: String?
  /// Whether the item currently handed to PlayerCore depends on the remote server while playing.
  /// Stored separately from PlayerCore's state so SwiftUI surfaces observe the source kind without
  /// becoming dependents of the player's position ticks.
  public private(set) var isStreamingSource = false
  public private(set) var currentTime: Double = 0
  /// `currentTime` at list cadence: follows the playhead only once it is a minute away, and
  /// settles on it when playback is not running or a new identity loads. Rows draw progress no
  /// finer than a minute, so reading this keeps their bodies off the two-per-second tick.
  public private(set) var listPlayheadSeconds: Double = 0
  /// The user's restored playback speed, projected from PlayerCore so presentation surfaces can
  /// update their listening-time captions when the speed picker changes.
  public private(set) var playbackRate: Double = 1.0
  /// The retained "last played" item, independent of `activeItemID`; it stays set across `stop()`,
  /// an item ending, and a cold launch that never called `start`. Projects
  /// `PlaybackBookmarkStoring.observeBookmark()` as reported, including `nil` for a missing or
  /// soft-deleted target (see `DefaultPlaybackBookmarkStoring`'s tombstone decision). Only
  /// `logout()` resets it, matching `activeItemID`'s "never carried forward" contract.
  ///
  /// It stays set when the item is finished: it is the metadata and position source every player
  /// surface reads, and only `nowPlayingIdentity` decides presence. A finished bookmark is never
  /// presented (see `refreshNowPlayingIdentity()`).
  ///
  /// Republished only when something other than the position changes, so the players do not
  /// rebuild on every save. Its `positionSeconds` is therefore stale: read
  /// `displayedItemPositionSeconds` or `displayedPositionSeconds(itemID:episodeID:persisted:)`.
  public private(set) var displayedItem: PlaybackBookmark?
  /// The retained bookmark's saved position, or `0` when there is none. Changes on every save of
  /// the retained item, so only a leaf view that prints that item's position should read it.
  public private(set) var displayedItemPositionSeconds: Double = 0
  /// What another device reports playing, set by the phone's Watch glue and cleared at its
  /// expiry, so a view reading it re-renders when the indicator lapses.
  public internal(set) var companionDevicePlayback: CompanionDevicePlayback?
  @ObservationIgnored var companionExpiryTask: Task<Void, Never>?
  /// How the expiry waits; a seam so tests need no real time.
  @ObservationIgnored var companionExpiryWait: @MainActor (TimeInterval) async -> Void = { seconds in
    try? await Task.sleep(for: .seconds(seconds))
  }

  /// "Now Playing" for the queue-availability policy: the active session's identity, or once
  /// nothing is active, the retained one the mini-player shows — but only while that bookmark is
  /// unfinished. Keying to `activeItemID` alone would withdraw Play Next/Add to Up Next when
  /// playback stopped, which is when a listener queues the next thing. A finished retained title
  /// has no presence: `nil` here is the "nothing playing" state the mini player and expanded player
  /// leave through and the queue menus fall back to Play for.
  ///
  /// Written only through `refreshNowPlayingIdentity()`, which drops no-change assignments.
  /// `displayedItem` republishes on every position change and this is read from recycled list rows'
  /// menus, so a computed property would make each reader a dependent of the playhead.
  public private(set) var nowPlayingIdentity: ListeningIdentity?

  /// Whether the user currently intends playback to be running (`PlayerState.isPlaybackIntended`).
  /// The play/pause affordances render this, not `phase`, which flaps through `buffering`/`seeking`
  /// around every play and seek on a real stream and glitches the icon. Reads through to the player
  /// so it cannot drift from the reducer's last accepted intent.
  ///
  /// Read via `PlaybackControlling.isPlaybackIntended`, never `state.isPlaybackIntended`: `state`
  /// carries the playhead and is republished on every engine tick, making a surface a dependent of
  /// the position.
  public var isPlaybackIntended: Bool { player.isPlaybackIntended }

  /// Item-scoped playback intent for player surfaces. A newly requested item must not inherit
  /// the previous loaded item's playing/paused control state while preparation is in flight.
  public func isPlaybackIntended(for itemID: String) -> Bool {
    activeItemID == itemID && loadedItemID == itemID
      && activeEpisodeID == loadedEpisodeID && player.isPlaybackIntended
  }

  /// Whether PlayerCore has exactly this item/episode loaded and active. Unlike
  /// `nowPlayingIdentity` this goes false on `stop()` instead of answering with the retained
  /// bookmark, so a paused session ("resume this one") differs from a remembered one ("prepare a
  /// new one").
  public func isLoaded(itemID: String, episodeID: String?) -> Bool {
    activeItemID == itemID && loadedItemID == itemID
      && activeEpisodeID == loadedEpisodeID && activeEpisodeID == episodeID
  }

  /// Episode-scoped intent, for per-episode affordances. `isPlaybackIntended(for:)` answers for the
  /// show, which every episode shares, so a podcast surface keyed to it would light up episode B
  /// while episode A is running.
  public func isPlaybackIntended(for itemID: String, episodeID: String?) -> Bool {
    isLoaded(itemID: itemID, episodeID: episodeID) && player.isPlaybackIntended
  }

  /// The speed a given title would play at: its own override, or the default it inherits.
  ///
  /// Every "time left" caption must use this, not `playbackRate`, the live rate of whatever is
  /// loaded (resetting to 1× when PlayerCore goes idle), which quotes a title at another title's
  /// speed. Synchronous (in-memory map), so a scrolling carousel never awaits per row.
  public func effectiveRate(for itemID: String?) -> Double {
    rateCoordinator?.effectiveRate(forItemID: itemID) ?? playbackRate
  }

  public func hasRateOverride(for itemID: String?) -> Bool {
    rateCoordinator?.hasOverride(forItemID: itemID) ?? false
  }
  /// Set only right after playback fails to prepare a session. A screen surfaces it once and
  /// dismisses it when the user acknowledges the reason; a fresh `start` also clears it.
  public private(set) var startFailure: PlaybackStartFailure?
  /// The reason on its own, for callers that only need to know a start did not take, such as the
  /// sheet and player bindings that must not raise a surface for a title that never began.
  public var startFailureMessage: String? { startFailure?.message }
  /// Set once by `logout()` and never cleared. A fresh `PlaybackModel` (next launch, after a
  /// fresh login) does not carry it forward.
  public private(set) var isQuiescedForLogout = false

  internal let sync: any PlaybackSyncing
  internal let player: any PlaybackControlling
  internal let account: any AccountLifecycle
  internal let appLifecycle: any AppLifecycle
  internal let bookmarkStore: any PlaybackBookmarkStoring
  internal let nativePodcastSubscriptions: any NativePodcastSubscriptionsReading
  internal let listeningQueue: any ListeningQueueStoring
  /// The active smart list run, if any; consulted before Up Next (`PlaybackModel+SmartListRun.swift`).
  internal let continuation: any PlaybackContinuationSource
  internal let requestReachabilityProbe: @Sendable () -> Void
  @ObservationIgnored internal let downloadReading: (any DownloadReading)?
  /// Detected ad ranges (`PlaybackModel+SkipRanges.swift`); nil when ad skipping is not composed.
  @ObservationIgnored internal let skipRanges: (any PlaybackSkipRangeSource)?
  @ObservationIgnored internal var loadedSkipRequest: PlaybackSkipRangeRequest?
  /// The device's time-saved totals (`TimeSaved.swift`); nil when they are not composed.
  @ObservationIgnored internal let timeSaved: (any TimeSavedRecording)?
  /// The most recent skip of the loaded item, for the receipt; cleared by Undo and by a new load.
  public internal(set) var lastSkip: PlaybackSkipReceipt?
  /// Whether the loaded local file is being checked for ads, or why it waits; `.none` otherwise.
  public internal(set) var adAnalysisStatus: PlaybackAdAnalysisStatus = .none
  /// What the speed card says about Trim Silences for the loaded episode.
  public internal(set) var trimStatus: PlaybackTrimStatus = .off
  /// The loaded book's files and chapters, when it plays from a complete download; Look Back reads
  /// only this. Nil for an episode, a stream, or nothing loaded.
  public internal(set) var loadedLookBack: LookBackSource?
  /// Called when a sleep timer pauses an audiobook, the moment a listener has lost their place.
  /// The app's Look Back tip records it durably here rather than by observing state, because the
  /// app may not be foregrounded again before the system ends it.
  @ObservationIgnored public var onBookSleepTimerPause: (@MainActor () -> Void)?
  @ObservationIgnored internal let trim: PlaybackTrimDependencies?
  /// Whether the loaded item has had its trim plan adopted; false between loads.
  @ObservationIgnored internal var hasLoadedTrimTarget = false
  /// The loaded file, when it is one Trim Silences can cut.
  @ObservationIgnored internal var loadedTrimRequest: PlaybackSkipRangeRequest?
  /// The map PlayerCore holds for the loaded item.
  @ObservationIgnored internal var loadedTrimMap: PlayerTrimMap?
  @ObservationIgnored internal var trimSavedThisEpisode: Double = 0
  @ObservationIgnored internal var trimTask: Task<Void, Never>?
  @ObservationIgnored internal var trimObservationTasks: [Task<Void, Never>] = []
  /// The owner of per-title and default playback speed. Optional only so tests can construct this
  /// model without one; production always supplies it. Without it every title resolves to
  /// whatever PlayerCore already holds.
  internal let rateCoordinator: PlaybackRateCoordinator?
  internal var playbackGeneration = 0
  /// The model generation that installed the currently loaded PlayerCore item. Active and loaded
  /// identity can stay equal while a stalled same-item replacement awaits a fresh session; this
  /// token stops old events in that window being stamped as the new start.
  internal var loadedPlaybackGeneration: Int?
  /// The model generation whose downloaded copy has already replaced its streamed player item.
  /// Track auto-advance does not change this model generation, so it cannot accidentally turn a
  /// gapless next-track load into a whole-item swap.
  @ObservationIgnored internal var promotedGeneration: Int?
  /// A completed download observed during a scrub is retried when the seek settles. It is cleared
  /// with the loaded identity so a late phase transition can never promote a different item.
  @ObservationIgnored internal var deferredPromotion: (itemID: String, episodeID: String?, generation: Int)?
  /// Serializes each `start` through its final durable cleanup. A newer request takes the visible
  /// generation immediately but cannot enter SyncEngine until a displaced successful request has
  /// closed its now-unplayable session. Without this ordering, SyncEngine could see old-start,
  /// new-start, old-stop, and the old request's cleanup would close the new session.
  @ObservationIgnored internal var startOperationTail: Task<Void, Never>?
  internal var completedGeneration: Int?
  /// A detail-screen chapter/history jump that arrives after `start` has made the item active but
  /// before its session has finished preparing. `seek(itemID:toGlobalOffset:)` rejects that window
  /// (PlayerCore still holds the previous item), so dropping the target would resume at the
  /// server's position, not the tapped row. Generation-scoped so a late preparation for a
  /// displaced item cannot consume it.
  internal var pendingStartSeek: (itemID: String, episodeID: String?, generation: Int, offset: Double)?
  /// The loaded, paused title's next play must prepare a new session instead of taking the
  /// resumable fast path. Set when a timer expiry closes a local session, and when a peer device
  /// takes the title over (`CompanionPlaybackHandoff`): the phone's in-memory position is then
  /// stale, and only a start asks the peer and reads the server's position.
  internal var freshLocalSessionOnNextPlay: (itemID: String, episodeID: String?)?
  /// When this phone last heard a title itself: stamped by progress events that carry
  /// listening, never by a load, a seek or progress synced from elsewhere. Unobserved, as it moves
  /// with every tick and the Watch publication already follows those.
  @ObservationIgnored internal var lastListen: (itemID: String, episodeID: String?, at: Date)?
  /// The identity that failed to prepare. Requested failures clear the active identity for the
  /// alert, while queue-advance failures retain it for the player's recovery banner.
  internal var failedStartIdentity: (itemID: String, episodeID: String?)?
  /// The run intent of the failed start, so Retry of a failed list Play still begins the run.
  internal var failedStartRun: RunIntent?
  /// The Up Next extent of the failed start, so Retry of a failed chapter row replays that chapter
  /// and consumes its row instead of playing the book on from its saved position.
  internal var failedStartExtent: QueueStartExtent?

  @ObservationIgnored internal var eventBridge: PlaybackEventBridge?

  @ObservationIgnored internal var recoveryTask: Task<Void, Never>?
  @ObservationIgnored internal var stalledRecoveryTask: Task<Void, Never>?
  @ObservationIgnored internal var bookmarkTask: Task<Void, Never>?
  @ObservationIgnored internal var nativeSubscriptionsTask: Task<Void, Never>?
  @ObservationIgnored internal var promotionObservationTask: Task<Void, Never>?
  @ObservationIgnored internal var skipRangeTask: Task<Void, Never>?
  @ObservationIgnored internal var skipRangeChangesTask: Task<Void, Never>?
  @ObservationIgnored internal var analysisStatusTask: Task<Void, Never>?
  @ObservationIgnored internal var analysisStatusChangesTask: Task<Void, Never>?
  internal var latestBookmark: PlaybackBookmark?
  internal var nativeSubscriptionsEnabled: Bool?

  /// Continuation decisions taken when nothing is presented have no surface to report to, so they
  /// are recorded here instead.
  static let log = CoreLogging.logger(category: "Playback")

  // MARK: - State mutation (the only code that may assign the observable state above)

  /// Changes the display phase and owns the buffering probe's episode boundaries. Repeated ticks
  /// in the same phase leave the existing task alone; every transition away from buffering
  /// cancels it before any later event can observe the old episode.
  internal func setPhase(_ nextPhase: Phase) {
    guard phase != nextPhase else { return }
    phase = nextPhase
    if nextPhase == .buffering, isStreamingSource {
      eventBridge?.armBufferingProbe(
        .init(modelGeneration: playbackGeneration, itemID: loadedItemID, episodeID: loadedEpisodeID))
    } else {
      eventBridge?.cancelBufferingProbe()
    }
    handlePromotionPhaseChange(nextPhase)
  }

  /// The one place the loaded identity and source kind move. The rate coordinator must be told:
  /// whether a speed change is heard depends on which title PlayerCore holds, and three of four
  /// callers are stop/end/logout paths where forgetting would aim a later mutation at a title no
  /// longer playing. Clearing here also cancels a pending probe before a replacement inherits it.
  ///
  /// `isStreaming` has no default: a default gives un-updated callers a silently wrong answer (the
  /// failure mode `NowPlayingItemInfoProviding` records), and a stream claiming to be local can
  /// never raise an offline affordance.
  internal func setLoaded(
    itemID: String?, episodeID: String?, isStreaming: Bool, generation: Int? = nil
  ) {
    eventBridge?.cancelBufferingProbe()
    loadedItemID = itemID
    loadedEpisodeID = episodeID
    loadedPlaybackGeneration = itemID == nil ? nil : generation
    let nextIsStreamingSource = itemID != nil && isStreaming
    if isStreamingSource != nextIsStreamingSource {
      isStreamingSource = nextIsStreamingSource
    }
    updatePromotionObservation(
      itemID: itemID, episodeID: episodeID, isStreaming: nextIsStreamingSource)
    resetSkipRanges(isUnload: itemID == nil)
    resetTrim()
    if loadedLookBack != nil { loadedLookBack = nil }
    timeSaved?.flush()
    rateCoordinator?.itemDidLoad(itemID)
  }

  /// The one place `activeItemID`/`activeEpisodeID` move together, so `nowPlayingIdentity` cannot
  /// be left behind by a path that forgot to update it.
  internal func setActive(itemID: String?, episodeID: String?) {
    activeItemID = itemID
    activeEpisodeID = episodeID
    refreshNowPlayingIdentity()
  }

  internal func refreshNowPlayingIdentity() {
    let next: ListeningIdentity? =
      if let activeItemID {
        ListeningIdentity.resolving(itemID: activeItemID, episodeID: activeEpisodeID)
      } else if let displayedItem, displayedItem.isFinished == false {
        ListeningIdentity.resolving(itemID: displayedItem.serverItemId, episodeID: displayedItem.episodeID)
      } else {
        nil
      }
    guard next != nowPlayingIdentity else { return }
    nowPlayingIdentity = next
  }

  /// The only path that assigns `startFailure`. Callers in the session and queue extensions cannot
  /// reach the setter directly, so failure presentation has one owner.
  internal func setStartFailure(_ failure: PlaybackStartFailure?) {
    startFailure = failure
  }

  /// The only path that assigns `displayedItem` and its position. Each property is written only
  /// when its own value changes, so a save moves the position without republishing the bookmark.
  internal func setDisplayedItem(_ item: PlaybackBookmark?) {
    let position = item?.positionSeconds ?? 0
    if displayedItemPositionSeconds != position {
      displayedItemPositionSeconds = position
    }
    if Self.bookmarkDiffersBeyondPosition(displayedItem, item) {
      displayedItem = item
    }
  }

  private static func bookmarkDiffersBeyondPosition(
    _ lhs: PlaybackBookmark?, _ rhs: PlaybackBookmark?
  ) -> Bool {
    guard let lhs, let rhs else { return (lhs == nil) != (rhs == nil) }
    return lhs.serverItemId != rhs.serverItemId || lhs.episodeID != rhs.episodeID
      || lhs.episodeTitle != rhs.episodeTitle || lhs.showTitle != rhs.showTitle
      || lhs.title != rhs.title || lhs.author != rhs.author
      || lhs.durationSeconds != rhs.durationSeconds || lhs.isFinished != rhs.isFinished
  }

  /// The position a screen prints for an item or episode: the live playhead while PlayerCore has
  /// that identity loaded, the retained bookmark's position while it is merely retained, and
  /// `persisted` otherwise.
  ///
  /// Call it from the leaf view that prints the position, not a list's parent body: a row for any
  /// other identity reads neither, so ticks and saves do not rebuild it.
  public func displayedPositionSeconds(
    itemID: String, episodeID: String?, persisted: Double
  ) -> Double {
    if loadedItemID == itemID, loadedEpisodeID == episodeID {
      return currentTime
    }
    if let displayedItem, displayedItem.serverItemId == itemID,
      displayedItem.episodeID == episodeID
    {
      return displayedItemPositionSeconds
    }
    return persisted
  }

  /// `displayedPositionSeconds` for a list row, progress bar or remaining-time caption: the loaded
  /// identity resolves to `listPlayheadSeconds`, so the reader re-runs about once a minute while
  /// playing rather than on every tick. Use `displayedPositionSeconds` only where a position is
  /// printed to the second (the players).
  public func listPositionSeconds(
    itemID: String, episodeID: String?, persisted: Double
  ) -> Double {
    if loadedItemID == itemID, loadedEpisodeID == episodeID {
      return listPlayheadSeconds
    }
    return displayedPositionSeconds(itemID: itemID, episodeID: episodeID, persisted: persisted)
  }

  /// Projects the retained marker through the native-subscriptions visibility gate. The raw
  /// bookmark remains cached while RSS is disabled so turning the feature back on can restore the
  /// mini-player without starting playback or waiting for a database write. ABS markers remain
  /// visible regardless of the native preference.
  internal func refreshDisplayedBookmarkProjection() {
    guard let nativeSubscriptionsEnabled else { return }
    let nextDisplayedItem: PlaybackBookmark? =
      if nativeSubscriptionsEnabled == false, let latestBookmark,
        PodcastSourceIdentity(itemId: latestBookmark.serverItemId)?.rssFeedId != nil
      {
        nil
      } else {
        latestBookmark
      }
    setDisplayedItem(nextDisplayedItem)
    refreshNowPlayingIdentity()
  }

  /// True while an RSS episode owns the active playback request, including preparation and
  /// buffering before PlayerCore has installed it. A retained bookmark alone is not active.
  public var isActiveNativePodcastPlayback: Bool {
    guard
      let itemID = activeItemID,
      activeEpisodeID != nil
    else { return false }
    if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil { return true }
    return false
  }

  /// Latches the terminal logout state. One-way by construction: there is no un-quiesce.
  internal func markQuiescedForLogout() {
    isQuiescedForLogout = true
  }

  /// Mirrors the equality guard the display path already applied, so a rate tick that changes
  /// nothing still cannot invalidate `playbackRate` observers.
  internal func setPlaybackRate(_ rate: Double) {
    guard playbackRate != rate else { return }
    playbackRate = rate
  }

  /// How far the playhead runs ahead of `listPlayheadSeconds` before list surfaces move.
  internal static let listPlayheadGranularity: Double = 60

  /// `currentTime` is unguarded: position ticks are expected to invalidate on every event.
  /// `listPlayheadSeconds` is guarded; see its declaration.
  internal func setCurrentTime(_ time: Double, settlesListPlayhead: Bool = false) {
    currentTime = time
    let settles =
      settlesListPlayhead || phase != .playing
      || abs(time - listPlayheadSeconds) >= Self.listPlayheadGranularity
    if settles, listPlayheadSeconds != time {
      listPlayheadSeconds = time
    }
  }

  public init(
    sync: any PlaybackSyncing, player: any PlaybackControlling, account: any AccountLifecycle,
    appLifecycle: any AppLifecycle, bookmarkStore: any PlaybackBookmarkStoring = NoOpPlaybackBookmarkStoring(),
    nativePodcastSubscriptions: any NativePodcastSubscriptionsReading =
      NoOpNativePodcastSubscriptionsReading(),
    listeningQueue: any ListeningQueueStoring = NoOpListeningQueueStore(),
    rateCoordinator: PlaybackRateCoordinator? = nil,
    requestReachabilityProbe: @escaping @Sendable () -> Void = {},
    bufferingClock: any PlaybackBufferingClock = SystemPlaybackBufferingClock(),
    downloadReading: (any DownloadReading)? = nil,
    skipRanges: (any PlaybackSkipRangeSource)? = nil,
    timeSaved: (any TimeSavedRecording)? = nil,
    trim: PlaybackTrimDependencies? = nil,
    continuation: any PlaybackContinuationSource = NoOpPlaybackContinuationSource()
  ) {
    self.sync = sync
    self.player = player
    self.account = account
    self.appLifecycle = appLifecycle
    self.bookmarkStore = bookmarkStore
    self.nativePodcastSubscriptions = nativePodcastSubscriptions
    self.listeningQueue = listeningQueue
    self.continuation = continuation
    self.rateCoordinator = rateCoordinator
    self.requestReachabilityProbe = requestReachabilityProbe
    self.downloadReading = downloadReading
    self.skipRanges = skipRanges
    self.timeSaved = timeSaved
    self.trim = trim
    let rate = player.state.rate
    if playbackRate != rate {
      playbackRate = rate
    }

    // Launch recovery must finish before any play intent is accepted. Kicked off once, up front,
    // so `start` can await it rather than every call site remembering to.
    recoveryTask = Task { await sync.recoverOpenSessions() }

    let bridge = PlaybackEventBridge(
      events: player.progressEvents,
      sync: sync,
      bufferingClock: bufferingClock,
      ingest: { [weak self] event in self?.ingest(progressEvent: event) },
      isCurrent: { [weak self] envelope in self?.isCurrent(envelope) == true },
      onLocalTimerExpiry: { [weak self] envelope in self?.handleLocalTimerExpiry(envelope) },
      onCompletion: { [weak self, sync, listeningQueue, continuation] envelope, shouldAdvance in
        await Self.driveCompletion(
          model: { [weak self] in self }, sync: sync, listeningQueue: listeningQueue,
          continuation: continuation, envelope: envelope, shouldAdvance: shouldAdvance)
      },
      onSegmentEnd: { [weak self, listeningQueue] envelope in
        await Self.driveSegmentAdvance(
          model: { [weak self] in self }, listeningQueue: listeningQueue, envelope: envelope)
      },
      onBufferingProbeElapsed: { [weak self] token in self?.handleBufferingProbeElapsed(token) })
    eventBridge = bridge
    bridge.start()

    // The retained-item projection runs in its own task: a screen reading `displayedItem` must not
    // wait behind this model's other I/O, and the DB observation must never be awaited inline
    // inside `apply(displayEvent:)`.
    let bookmarks = bookmarkStore.observeBookmark()
    bookmarkTask = Task { [weak self] in
      for await bookmark in bookmarks {
        guard Task.isCancelled == false, let self else { return }
        self.latestBookmark = bookmark
        self.refreshDisplayedBookmarkProjection()
        await self.reconcileQueueWithRetainedIdentityIfNeeded(bookmark)
      }
    }

    let nativeSubscriptions = nativePodcastSubscriptions.observeEnabled()
    nativeSubscriptionsTask = Task { [weak self] in
      for await enabled in nativeSubscriptions {
        guard Task.isCancelled == false, let self else { return }
        self.nativeSubscriptionsEnabled = enabled
        self.refreshDisplayedBookmarkProjection()
      }
    }
  }

  deinit {
    recoveryTask?.cancel()
    stalledRecoveryTask?.cancel()
    bookmarkTask?.cancel()
    nativeSubscriptionsTask?.cancel()
    promotionObservationTask?.cancel()
    skipRangeTask?.cancel()
    skipRangeChangesTask?.cancel()
    analysisStatusTask?.cancel()
    analysisStatusChangesTask?.cancel()
    trimTask?.cancel()
    for task in trimObservationTasks { task.cancel() }
    startOperationTail?.cancel()
  }

  /// In-flight preparation for a retained-item skip tap. Repeated taps coalesce into one
  /// preparation and one seek: further taps for the same not-yet-active item trigger no second
  /// `start`, each folds its offset into `pendingRetainedSkipOffset`, and only the original
  /// preparation applies the total, once, when `start` resolves.
  ///
  /// A tap as preparation finishes is not a race: these mutate only on `@MainActor` and nothing
  /// between `start` resolving and the seek (`performRetainedSkipPreparation`) awaits, so a tap
  /// sees the task in flight (and joins) or cleared (and starts afresh).
  @ObservationIgnored internal var retainedSkipPreparationTask: Task<Void, Never>?
  internal var retainedSkipPreparationItemID: String?
  internal var retainedSkipPreparationEpisodeID: String?
  internal var pendingRetainedSkipOffset: Double = 0

  // MARK: - Queue reconciliation (start and row removal are not one transaction)

  /// Whether this process has already settled the crash window below. Set by the first
  /// reconciliation and by any `start`, since a start this process made consumes its own row.
  internal var hasReconciledRetainedIdentity = false
}
