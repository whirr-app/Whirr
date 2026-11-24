import Persistence
import PlayerCore

/// What the car asked to play.
public enum CarPlaySelection: Sendable, Hashable {
  case resumeLastPlayed
  /// The row to play, with the chapter an Up Next chapter row carries.
  case play(ListeningIdentity, chapter: ListeningQueueRowChapter? = nil)
}

/// How one tap ends. Every tap gets exactly one of these, which is what lets the template call
/// its completion handler exactly once.
public enum CarPlaySelectionOutcome: Sendable, Equatable {
  /// The selection was handed to the player: show Now Playing. Audio may still fail to start;
  /// `CarPlaySelectionOperations.lateFailure(in:)` reports that.
  case started
  case failed(CarPlayPlaybackRejection)
  /// A newer selection, from the car or another surface, replaced this one. Show nothing: the
  /// newer action owns the screen.
  case superseded
  /// The scene went away or the account changed before the selection finished.
  case cancelled
}

/// A start the car reported as accepted that then produced no audio.
public enum CarPlayLateFailure: Sendable, Equatable {
  case failed(isRecoverable: Bool)
  case stalled
}

/// Turns row taps into finite outcomes.
///
/// One selection is in flight at a time. A repeated tap on it joins it; a different selection
/// supersedes it. Superseding or cancelling ends only the car's wait: the start is left to
/// `PlaybackModel`, which serializes competing starts, so the car never cancels playback another
/// surface asked for.
@MainActor
public final class CarPlaySelectionOperations {
  private struct Pending {
    let id: Int
    let selection: CarPlaySelection
    var waiters: [CheckedContinuation<CarPlaySelectionOutcome, Never>] = []
  }

  private var pending: Pending?
  private var lastID = 0
  /// The accepted selection whose audio has not yet been seen to play.
  private var awaitingAudio: CarPlaySelection?

  public init() {}

  public var isPending: Bool { pending != nil }

  /// Performs `selection` unless it is already pending, and returns when it finishes, is
  /// superseded or is cancelled, whichever comes first.
  public func select(
    _ selection: CarPlaySelection,
    perform: @escaping @MainActor () async -> CarPlayPlaybackResult
  ) async -> CarPlaySelectionOutcome {
    if pending?.selection != selection {
      end(with: .superseded)
      lastID += 1
      let id = lastID
      pending = Pending(id: id, selection: selection)
      awaitingAudio = nil
      Task { [weak self] in
        let result = await perform()
        self?.finish(id, result)
      }
    }
    return await withCheckedContinuation { pending?.waiters.append($0) }
  }

  /// Ends every wait as cancelled: the scene disconnected or the account graph was replaced.
  public func cancelAll() {
    end(with: .cancelled)
    awaitingAudio = nil
  }

  /// Called with each player state after a `.started` outcome. Returns a failure at most once
  /// per accepted selection, and never for a title the car did not start.
  public func lateFailure(in state: PlayerState) -> CarPlayLateFailure? {
    guard let awaitingAudio else { return nil }
    if case .play(let identity, _) = awaitingAudio, let item = state.item,
      item.id != identity.itemID || item.episodeID != identity.episodeID
    {
      // Another surface loaded something else; its failures are not the car's to report.
      self.awaitingAudio = nil
      return nil
    }
    switch state.phase {
    case .playing:
      self.awaitingAudio = nil
      return nil
    case .failed(let failure):
      self.awaitingAudio = nil
      return .failed(isRecoverable: failure.isRecoverable)
    case .stalled:
      self.awaitingAudio = nil
      return .stalled
    case .idle, .preparing, .buffering, .ready, .paused, .seeking, .ended:
      return nil
    }
  }

  private func finish(_ id: Int, _ result: CarPlayPlaybackResult) {
    // A superseded or cancelled selection has already answered its waiters.
    guard let pending, pending.id == id else { return }
    switch result {
    case .accepted:
      awaitingAudio = pending.selection
      end(with: .started)
    case .rejected(.cancelled):
      // The playback model dropped this start for a newer one from another surface.
      end(with: .superseded)
    case .rejected(let rejection):
      end(with: .failed(rejection))
    }
  }

  private func end(with outcome: CarPlaySelectionOutcome) {
    guard let ended = pending else { return }
    pending = nil
    for waiter in ended.waiters { waiter.resume(returning: outcome) }
  }
}
