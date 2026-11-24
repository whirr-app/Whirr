import Foundation
import Persistence
import PlayerCore
import SyncEngine

/// Payload-free reasons safe to return across the companion command boundary.
public enum CompanionPlaybackActionRejection: Sendable, Equatable {
  case accountUnavailable
  case invalidSelection
  case preparationFailed
  case cancelled
  case noActivePlayback
  case invalidPosition
  case invalidRate
  case staleRequest
}

/// Result of a command sent to the account-scoped phone player.
///
/// `.accepted` means the request passed account and input checks and preparation handed a matching
/// item to PlayerCore. It does not mean audio started: `isLoaded` is a preparation fact, not
/// evidence that the OS activated audio or PlayerCore reached `.playing`.
public enum CompanionPlaybackActionResult: Sendable, Equatable {
  case accepted
  case rejected(CompanionPlaybackActionRejection)
}

/// The account-scoped phone command boundary used by a companion transport.
///
/// Class-bound ownership mirrors `VoicePlaybackActionHandling`: composition retains one handler
/// for the current account and replaces it on logout/login. The protocol names only
/// AppModel values and has no dependency on the companion wire module.
@MainActor
public protocol CompanionPlaybackActionHandling: AnyObject {
  func start(
    source: PodcastSourceIdentity, episodeID: String?
  ) async -> CompanionPlaybackActionResult
  func start(_ selection: CompanionSelection) async -> CompanionPlaybackActionResult
  func pause() -> CompanionPlaybackActionResult
  func resume() -> CompanionPlaybackActionResult
  func seek(toGlobalOffset offset: Double) -> CompanionPlaybackActionResult
  func skip(by seconds: Double) -> CompanionPlaybackActionResult
  func setRate(_ rate: Double) -> CompanionPlaybackActionResult
}

/// Headless companion control over the existing account-scoped playback graph.
///
/// Preparation is serialized by `PlaybackModel.start`, which owns the dual-origin
/// `RoutingPlaybackSyncing` path. This adds only the account, cancellation and stale-result checks
/// a process-lifetime transport handler needs; it creates no source router and leaves the engine
/// alone.
@MainActor
public final class CompanionPlaybackActions: CompanionPlaybackActionHandling {
  private let playback: PlaybackModel
  private let player: any PlaybackControlling
  private let account: any AccountLifecycle
  private var requestGeneration = 0

  public init(
    playback: PlaybackModel,
    player: any PlaybackControlling,
    account: any AccountLifecycle
  ) {
    self.playback = playback
    self.player = player
    self.account = account
  }

  /// Starts the exact source/episode target through `PlaybackModel`'s existing ABS/RSS route.
  ///
  /// The matching loaded identity is required before returning `.accepted`; a failed or cancelled
  /// preparation leaves no accepted command. The result still makes no claim that audio started.
  public func start(
    source: PodcastSourceIdentity, episodeID: String?
  ) async -> CompanionPlaybackActionResult {
    await start(source: source, episodeID: episodeID, chapter: nil)
  }

  /// `start(source:episodeID:)` for an Up Next row, whose chapter starts at its own position and
  /// consumes its own row.
  public func start(
    source: PodcastSourceIdentity, episodeID: String?, chapter: ListeningQueueRowChapter?
  ) async -> CompanionPlaybackActionResult {
    guard accountOwnsPlayback else { return .rejected(.accountUnavailable) }
    let selection = CompanionSelection(source: source, episodeID: episodeID)
    guard Self.isValid(selection) else { return .rejected(.invalidSelection) }
    guard Task.isCancelled == false else { return .rejected(.cancelled) }

    requestGeneration &+= 1
    let generation = requestGeneration
    if let chapter,
      let identity = ListeningIdentity.resolving(itemID: selection.itemID, episodeID: selection.episodeID)
    {
      await playback.start(identity: identity, queuedChapter: chapter)
    } else {
      await playback.start(itemID: selection.itemID, episodeID: selection.episodeID)
    }

    guard Task.isCancelled == false else { return .rejected(.cancelled) }
    guard accountOwnsPlayback else { return .rejected(.accountUnavailable) }
    guard generation == requestGeneration else { return .rejected(.staleRequest) }
    guard playback.startFailure == nil,
      playback.isLoaded(itemID: selection.itemID, episodeID: selection.episodeID)
    else {
      return .rejected(.preparationFailed)
    }
    return .accepted
  }

  public func start(_ selection: CompanionSelection) async -> CompanionPlaybackActionResult {
    await start(source: selection.source, episodeID: selection.episodeID)
  }

  /// Sends an explicit pause rather than a toggle, so repeating a delayed command cannot resume
  /// audio. A loaded identity is the only state this facade needs to control.
  public func pause() -> CompanionPlaybackActionResult {
    guard accountOwnsPlayback else { return .rejected(.accountUnavailable) }
    guard hasLoadedPlayback else { return .rejected(.noActivePlayback) }
    player.send(.pause)
    return .accepted
  }

  /// Sends an explicit play rather than a toggle, so repeating resume is idempotent.
  public func resume() -> CompanionPlaybackActionResult {
    guard accountOwnsPlayback else { return .rejected(.accountUnavailable) }
    guard hasLoadedPlayback else { return .rejected(.noActivePlayback) }
    if !playback.resumeThroughFreshLocalSessionIfLatched() { player.send(.play) }
    return .accepted
  }

  /// Applies a finite, non-negative absolute position to the currently loaded item.
  public func seek(toGlobalOffset offset: Double) -> CompanionPlaybackActionResult {
    guard accountOwnsPlayback else { return .rejected(.accountUnavailable) }
    guard offset.isFinite, offset >= 0 else { return .rejected(.invalidPosition) }
    guard let itemID = playback.loadedItemID, hasLoadedPlayback else {
      return .rejected(.noActivePlayback)
    }
    playback.seek(
      itemID: itemID, toGlobalOffset: offset)
    return .accepted
  }

  /// Resolves relative movement against the live phone player, never a cached Watch position.
  public func skip(by seconds: Double) -> CompanionPlaybackActionResult {
    guard accountOwnsPlayback else { return .rejected(.accountUnavailable) }
    guard seconds.isFinite, seconds != 0, abs(seconds) <= 300 else {
      return .rejected(.invalidPosition)
    }
    guard hasLoadedPlayback else { return .rejected(.noActivePlayback) }
    let state = player.state
    guard state.globalPosition.isFinite else { return .rejected(.invalidPosition) }
    // Unclamped and sent as the relative intent: clamping here made the Watch card the one surface
    // that could not finish an item by skipping, and PlayerCore owns the end-of-item rule for
    // every other surface already.
    player.send(.skip(by: seconds))
    return .accepted
  }

  /// Validates against the existing PlayerCore rate policy before sending the intent. When the
  /// title-rate coordinator is present, it routes the change like the player's own menu: a Focus
  /// session adjustment while a Focus governs the title, otherwise the durable per-title override;
  /// otherwise this boundary still applies the same normalized value directly to PlayerCore.
  public func setRate(_ rate: Double) -> CompanionPlaybackActionResult {
    guard accountOwnsPlayback else { return .rejected(.accountUnavailable) }
    guard let normalized = PlaybackRateResolution.normalizedRate(rate) else {
      return .rejected(.invalidRate)
    }
    guard let itemID = playback.loadedItemID, hasLoadedPlayback else {
      return .rejected(.noActivePlayback)
    }
    if let rateCoordinator = playback.rateCoordinator {
      rateCoordinator.adjustRate(normalized, itemID: itemID)
    } else {
      player.send(.setRate(normalized))
    }
    return .accepted
  }

  private var accountOwnsPlayback: Bool {
    account.isAuthenticated && playback.isQuiescedForLogout == false
  }

  private var hasLoadedPlayback: Bool {
    guard let itemID = playback.loadedItemID else { return false }
    return playback.isLoaded(itemID: itemID, episodeID: playback.loadedEpisodeID)
  }

  private static func isValid(_ selection: CompanionSelection) -> Bool {
    guard selection.itemID.isEmpty == false else { return false }
    if let episodeID = selection.episodeID, episodeID.isEmpty { return false }
    switch selection.source.source {
    case .abs:
      return true
    case .rss:
      // RSS preparation is episode-scoped. Refuse before PlaybackModel can announce a malformed
      // native request to the router, keeping this boundary's rejection deterministic.
      return selection.episodeID != nil
    }
  }
}

extension PlaybackModel {
  /// When this phone last listened to the loaded title, which the Watch weighs against its
  /// own last listen to choose what Now Playing shows. Nil until the phone has played it here.
  public var companionLastListenedAt: Date? {
    guard !isQuiescedForLogout, let listen = lastListen, let loadedItemID,
      listen.itemID == loadedItemID, listen.episodeID == loadedEpisodeID,
      activeItemID == loadedItemID, activeEpisodeID == loadedEpisodeID
    else { return nil }
    return listen.at
  }

  /// A single matching live sample; retained metadata must never borrow another item's chapters.
  public var companionPlaybackProgress:
    (
      selection: CompanionSelection, position: Double, duration: Double, chapter: PlaybackChapter?
    )?
  {
    guard !isQuiescedForLogout, let item = player.state.item,
      loadedItemID == item.id, loadedEpisodeID == item.episodeID,
      activeItemID == item.id, activeEpisodeID == item.episodeID,
      let source = PodcastSourceIdentity(itemId: item.id)
    else { return nil }
    let position = player.state.globalPosition
    let duration = item.timeline.totalDuration
    guard position.isFinite, duration.isFinite, duration > 0 else { return nil }
    let current = item.chapters.currentChapter(at: position)
    let chapter = current.flatMap { current -> PlaybackChapter? in
      guard current.end <= duration else { return nil }
      let index = item.chapters.chapters.firstIndex(of: current) ?? 0
      return PlaybackChapter(title: "Chapter \(index + 1)", start: current.start, end: current.end)
    }
    return (.init(source: source, episodeID: item.episodeID), min(max(0, position), duration), duration, chapter)
  }
}
