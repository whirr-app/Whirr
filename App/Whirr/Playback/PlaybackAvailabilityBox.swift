import AppModel
import Observation
import SyncEngine

/// The process-lifetime hardware's late-bound view of account-scoped playback availability. The
/// playback model and connectivity model are both replaced at login/logout, while the system
/// integrations that consume this answer are registered only once. Keeping weak references here
/// prevents those integrations from retaining an obsolete account graph.
@MainActor
protocol PlaybackAvailabilityProviding: AnyObject {
  /// Why a remote stream cannot play, or `nil` when playback is fine.
  var unavailableReason: ServerUnreachableReason? { get }
  /// A terminal stall has ended the session; a stream still buffering against an unreachable
  /// server has not. The distinction decides which commands can still do something real.
  var isTerminalRemotePlaybackFailure: Bool { get }

  func setChangeHandler(_ handler: (@MainActor () -> Void)?)

  /// Starts the same explicit recovery action as the in-app Retry control. `false` means no
  /// account-scoped playback model is currently bound, or the shared availability rule is false.
  @discardableResult
  func recoverPlayback() -> Bool

  /// Offers a play-shaped remote command to the bound model's sleep-timer latch: after a
  /// timer-owned close, a bare `PlayerIntent` would resume audio with no session recording it.
  /// `true` means the model took the command and is opening a fresh local session; `false` (also
  /// when no model is bound) lets the caller send the intent as usual.
  @discardableResult
  func resumeThroughFreshLocalSessionIfLatched() -> Bool
}

extension PlaybackAvailabilityProviding {
  /// Offered so the command adapter can ask the question without naming the reason it will never
  /// display.
  /// A terminal RSS stall has no ABS outage reason, but it still needs the same explicit Retry
  /// path as an ABS stall. Keep that command-level state separate from user-facing copy.
  var remotePlaybackUnavailable: Bool {
    unavailableReason != nil || isTerminalRemotePlaybackFailure
  }
}

@MainActor
final class PlaybackAvailabilityBox: PlaybackAvailabilityProviding {
  weak var playback: PlaybackModel?
  weak var connectivityModel: ConnectivityModel?

  private var changeHandler: (@MainActor () -> Void)?
  private var bindingGeneration = 0

  func bind(playback: PlaybackModel, connectivityModel: ConnectivityModel?) {
    bindingGeneration += 1
    self.playback = playback
    self.connectivityModel = connectivityModel
    observeChanges(for: bindingGeneration)
  }

  func unbind() {
    bindingGeneration += 1
    playback = nil
    connectivityModel = nil
  }

  func setChangeHandler(_ handler: (@MainActor () -> Void)?) {
    changeHandler = handler
    guard handler != nil else {
      bindingGeneration += 1
      return
    }
    observeChanges(for: bindingGeneration)
  }

  var unavailableReason: ServerUnreachableReason? {
    guard let playback else { return nil }
    return PlaybackAvailability.unavailableReason(
      phase: playback.phase,
      isStreamingSource: playback.isStreamingSource,
      reachability: connectivityModel?.reachability ?? .unknown,
      itemID: playback.loadedItemID)
  }

  var isTerminalRemotePlaybackFailure: Bool {
    guard let playback else { return false }
    return playback.isStreamingSource && playback.phase == .stalled
  }

  @discardableResult
  func recoverPlayback() -> Bool {
    guard let playback, remotePlaybackUnavailable else { return false }
    return playback.retry()
  }

  @discardableResult
  func resumeThroughFreshLocalSessionIfLatched() -> Bool {
    playback?.resumeThroughFreshLocalSessionIfLatched() ?? false
  }

  private func observeChanges(for generation: Int) {
    guard changeHandler != nil, let playback else { return }
    withObservationTracking {
      _ = playback.phase
      _ = playback.isStreamingSource
      _ = self.connectivityModel?.reachability
    } onChange: { [weak self] in
      // `onChange` fires before the new value is applied, so the read that re-arms tracking has to
      // happen on a later turn or it would observe the value being replaced.
      Task { @MainActor [weak self] in
        guard let self, self.bindingGeneration == generation else { return }
        self.changeHandler?()
        self.observeChanges(for: generation)
      }
    }
  }
}
