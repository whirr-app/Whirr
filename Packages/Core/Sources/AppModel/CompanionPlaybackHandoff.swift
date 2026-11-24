import Foundation
import Persistence

/// What the phone had loaded when a peer asked it to pause. `selection` is whatever is loaded,
/// including a native feed episode, which the wire cannot name: the caller decides what to tell
/// the peer.
public struct CompanionPlaybackPeerState: Sendable, Equatable {
  public let selection: CompanionSelection
  public let positionSeconds: Double
  /// Whether audio was intended at the moment of observation, before any pause.
  public let wasPlaying: Bool

  public init(selection: CompanionSelection, positionSeconds: Double, wasPlaying: Bool) {
    self.selection = selection
    self.positionSeconds = positionSeconds
    self.wasPlaying = wasPlaying
  }
}

/// The phone's half of a peer handoff: pause whatever is loaded, keep it loaded, and say where it
/// was. The title stays loaded so a later resume on the phone still works; the account session is
/// closed afterwards, so the phone's last word on the title is said before the peer listens.
@MainActor
public final class CompanionPlaybackHandoff {
  private let playback: PlaybackModel
  private let actions: any CompanionPlaybackActionHandling

  public init(
    playback: PlaybackModel,
    actions: any CompanionPlaybackActionHandling
  ) {
    self.playback = playback
    self.actions = actions
  }

  /// The loaded title and its in-memory position without changing playback; `nil` when nothing is
  /// loaded, the account is quiescing, or the position is unusable.
  public func peerState() -> CompanionPlaybackPeerState? {
    guard !playback.isQuiescedForLogout, let itemID = playback.loadedItemID,
      playback.isLoaded(itemID: itemID, episodeID: playback.loadedEpisodeID),
      let source = PodcastSourceIdentity(itemId: itemID)
    else { return nil }
    let position = playback.player.state.globalPosition
    guard position.isFinite, position >= 0 else { return nil }
    return CompanionPlaybackPeerState(
      selection: CompanionSelection(source: source, episodeID: playback.loadedEpisodeID),
      positionSeconds: position, wasPlaying: playback.isPlaybackIntended)
  }

  /// Pauses the loaded title and keeps it loaded. The returned state is read before the pause so
  /// `wasPlaying` reflects what the user was doing when the peer asked.
  public func pauseForPeer() -> CompanionPlaybackPeerState? {
    guard let state = peerState() else { return nil }
    guard actions.pause() == .accepted else { return nil }
    latchFreshStart(state.selection)
    return state
  }

  /// The peer reports the title this phone has loaded and paused, and has been on it since the
  /// phone last listened. The peer only asks a playing phone to pause, so this is how a handoff
  /// from a paused phone is seen. Closes the session now, so a later close cannot overwrite what
  /// the peer uploads, and makes the next phone play a start. `false` when the phone is playing,
  /// has another title loaded, or already knows.
  @discardableResult
  public func peerTookOver(itemID: String, episodeID: String?) async -> Bool {
    guard !playback.isQuiescedForLogout, !playback.isPlaybackIntended,
      !playback.nextPlayStartsFresh(itemID: itemID, episodeID: episodeID),
      let state = peerState(), state.selection.itemID == itemID, state.selection.episodeID == episodeID
    else { return false }
    latchFreshStart(state.selection)
    await flushProgress()
    return true
  }

  /// The phone's position for the title is stale once the peer has it, so the next phone play must
  /// be a start: it asks the peer, which waits for a playing one's position, and opens a new session
  /// whose server position carries what the peer uploaded.
  private func latchFreshStart(_ selection: CompanionSelection) {
    playback.freshLocalSessionOnNextPlay = (itemID: selection.itemID, episodeID: selection.episodeID)
  }

  /// Drains the in-memory progress and closes the account session, as backgrounding a paused
  /// title does. A session left open would close later with this pause position and overwrite the
  /// progress the peer has uploaded since; a resume on the phone opens a new one.
  public func flushProgress() async {
    guard !playback.isQuiescedForLogout, !Task.isCancelled else { return }
    await playback.sync.notifyImmediateSyncTrigger(.paused)
    guard !playback.isQuiescedForLogout, !Task.isCancelled, !playback.isPlaybackIntended else { return }
    try? await playback.sync.stopSession()
  }
}
