import Persistence
import PlayerCore
import SyncEngine

/// Why a voice playback request could not be performed. These cases are
/// payload-free: an App Intents adapter can give Siri a useful generic response without ever
/// carrying an audiobook title, podcast title, author, position, or server identity across the
/// action boundary.
public enum VoicePlaybackActionUnavailabilityReason: Sendable, Equatable {
  case accountUnavailable
  case noBookmark
  case noActivePlayback
  case noChapters
  case startFailed
  /// The named item cannot be started: a widget row's token is unknown, stale, from another
  /// account, or names a selection the account cannot play.
  case itemUnavailable
  /// Extend was asked for with no countdown running. PlayerCore extends a countdown only.
  case noSleepTimer
}

/// The complete result visible to platform voice adapters. Playback content stays inside the
/// account-scoped Core graph; only success or a finite, non-sensitive unavailability reason leaves
/// it.
public enum VoicePlaybackActionResult: Sendable, Equatable {
  case performed
  case unavailable(VoicePlaybackActionUnavailabilityReason)
}

/// The AppModel boundary exposed to Siri/App Intents. Class-bound so the App target can retain one
/// account-scoped handler and atomically replace it with the rest of its composition on
/// login/logout.
@MainActor
public protocol VoicePlaybackActionHandling: AnyObject {
  func resumeLastPlayed() async -> VoicePlaybackActionResult
  func pausePlayback() -> VoicePlaybackActionResult
  func skip(by seconds: Double) async -> VoicePlaybackActionResult
  func setSleepTimer(_ duration: SleepTimerDuration) -> VoicePlaybackActionResult
  func play(selection: CompanionSelection) async -> VoicePlaybackActionResult
  func extendSleepTimer(by seconds: Double) -> VoicePlaybackActionResult
}

/// Privacy-safe voice playback orchestration over the same `PlaybackModel` and PlayerCore
/// controller used by the in-app player.
///
/// Cold resume/skip reads a fresh local bookmark snapshot rather than waiting for
/// `PlaybackModel.displayedItem`'s observation task. Persistence resolves it against the account
/// row and a live local item/episode, so a stale projection from an earlier composition is never
/// treated as owned by the current account.
@MainActor
public final class VoicePlaybackActions: VoicePlaybackActionHandling {
  private let playback: PlaybackModel
  private let player: any PlaybackControlling
  private let account: any AccountLifecycle
  private let bookmarkStore: any PlaybackBookmarkStoring
  /// Starts a named selection with the account and RSS-scope checks the Watch already relies on.
  /// Built here, per account, so a widget's play works whether or not a Watch is paired.
  private let selectionStarter: CompanionPlaybackActions

  public init(
    playback: PlaybackModel,
    player: any PlaybackControlling,
    account: any AccountLifecycle,
    bookmarkStore: any PlaybackBookmarkStoring
  ) {
    self.playback = playback
    self.player = player
    self.account = account
    self.bookmarkStore = bookmarkStore
    self.selectionStarter = CompanionPlaybackActions(
      playback: playback, player: player, account: account)
  }

  public func resumeLastPlayed() async -> VoicePlaybackActionResult {
    guard accountOwnsPlayback else { return .unavailable(.accountUnavailable) }

    if let active = activeIdentity {
      await playback.start(itemID: active.itemID, episodeID: active.episodeID)
      guard accountOwnsPlayback else { return .unavailable(.accountUnavailable) }
      guard playback.isLoaded(itemID: active.itemID, episodeID: active.episodeID) else {
        return .unavailable(.startFailed)
      }
      return .performed
    }

    // An in-flight in-app start has selected an identity but has not loaded it yet. Starting a
    // second session here would race that work; there is no active player for the voice request to
    // control yet.
    guard playback.activeItemID == nil else { return .unavailable(.noActivePlayback) }
    guard let bookmark = await ownedBookmark() else {
      return accountOwnsPlayback
        ? .unavailable(.noBookmark)
        : .unavailable(.accountUnavailable)
    }

    await playback.start(itemID: bookmark.serverItemId, episodeID: bookmark.episodeID)
    guard accountOwnsPlayback else { return .unavailable(.accountUnavailable) }
    guard playback.isLoaded(itemID: bookmark.serverItemId, episodeID: bookmark.episodeID) else {
      return .unavailable(.startFailed)
    }
    // `start` has already loaded the position resolved by `PlaybackSessionCoordinator`, which
    // merges this device's saved progress with the `/play` response. Seeking back to the bookmark
    // snapshot fetched before that merge could regress a newer server position.
    return .performed
  }

  public func pausePlayback() -> VoicePlaybackActionResult {
    guard accountOwnsPlayback else { return .unavailable(.accountUnavailable) }
    guard activeIdentity != nil else { return .unavailable(.noActivePlayback) }
    // Voice pause must be idempotent. `.toggle` could start playback when Siri handles a delayed
    // request after the player has already paused.
    player.send(.pause)
    return .performed
  }

  public func skip(by seconds: Double) async -> VoicePlaybackActionResult {
    guard accountOwnsPlayback else { return .unavailable(.accountUnavailable) }
    let finiteSeconds = seconds.isFinite ? seconds : 0

    if let active = activeIdentity {
      await playback.skip(itemID: active.itemID, episodeID: active.episodeID, by: finiteSeconds)
      guard accountOwnsPlayback else { return .unavailable(.accountUnavailable) }
      return .performed
    }

    guard playback.activeItemID == nil else { return .unavailable(.noActivePlayback) }
    guard let bookmark = await ownedBookmark() else {
      return accountOwnsPlayback
        ? .unavailable(.noBookmark)
        : .unavailable(.accountUnavailable)
    }

    await playback.start(itemID: bookmark.serverItemId, episodeID: bookmark.episodeID)
    guard accountOwnsPlayback else { return .unavailable(.accountUnavailable) }
    guard playback.isLoaded(itemID: bookmark.serverItemId, episodeID: bookmark.episodeID) else {
      return .unavailable(.startFailed)
    }
    // As with cold resume, use the position PlayerCore just loaded from the coordinator's merge,
    // not the older bookmark snapshot that was needed only to identify what to start.
    playback.seek(
      itemID: bookmark.serverItemId,
      toGlobalOffset: Self.normalizedPosition(player.state.globalPosition + finiteSeconds))
    return .performed
  }

  public func setSleepTimer(_ duration: SleepTimerDuration) -> VoicePlaybackActionResult {
    guard accountOwnsPlayback else { return .unavailable(.accountUnavailable) }
    guard activeIdentity != nil else { return .unavailable(.noActivePlayback) }
    if duration == .endOfChapter, player.quickActions.item?.hasChapters != true {
      // PlayerCore otherwise falls back to the end of the whole item, which would make a spoken
      // “end of chapter” confirmation materially untrue.
      return .unavailable(.noChapters)
    }
    player.send(.setSleepTimer(duration))
    return .performed
  }

  public func play(selection: CompanionSelection) async -> VoicePlaybackActionResult {
    guard accountOwnsPlayback else { return .unavailable(.accountUnavailable) }
    switch await selectionStarter.start(selection) {
    case .accepted:
      return .performed
    case .rejected(.accountUnavailable):
      return .unavailable(.accountUnavailable)
    case .rejected(.invalidSelection):
      return .unavailable(.itemUnavailable)
    case .rejected(.preparationFailed), .rejected(.cancelled), .rejected(.staleRequest),
      .rejected(.noActivePlayback), .rejected(.invalidPosition), .rejected(.invalidRate):
      // Only the first three can come from a start; none of them means the item is wrong.
      return .unavailable(.startFailed)
    }
  }

  public func extendSleepTimer(by seconds: Double) -> VoicePlaybackActionResult {
    guard accountOwnsPlayback else { return .unavailable(.accountUnavailable) }
    guard activeIdentity != nil else { return .unavailable(.noActivePlayback) }
    // PlayerCore silently ignores an extension of anything but a countdown, and of a non-positive
    // or non-finite amount; refusing here keeps a confirmation from claiming a change that did not
    // happen. No intent sends a non-positive amount.
    guard seconds.isFinite, seconds > 0,
      case .countdown = player.state.sleepTimer.mode
    else { return .unavailable(.noSleepTimer) }
    player.send(.extendSleepTimer(by: seconds))
    return .performed
  }

  private var accountOwnsPlayback: Bool {
    account.isAuthenticated && playback.isQuiescedForLogout == false
  }

  private var activeIdentity: (itemID: String, episodeID: String?)? {
    guard let itemID = playback.activeItemID,
      playback.isLoaded(itemID: itemID, episodeID: playback.activeEpisodeID)
    else { return nil }
    return (itemID, playback.activeEpisodeID)
  }

  /// Re-checks account ownership after the suspension as well as before it. Logout can begin while
  /// the database read is queued; a bookmark fetched by that now-obsolete request must never start
  /// playback afterward.
  private func ownedBookmark() async -> PlaybackBookmark? {
    guard accountOwnsPlayback else { return nil }
    let bookmark = await bookmarkStore.fetchBookmark()
    guard accountOwnsPlayback else { return nil }
    return bookmark
  }

  private static func normalizedPosition(_ position: Double) -> Double {
    guard position.isFinite else { return 0 }
    return max(0, position)
  }
}
