import Persistence

/// The narrow playback dependency the reader's finish needs: stop a book's audio when it is the
/// title on the player, and prepare whatever continues it once the finished progress has landed.
///
/// `ReaderModel` has no other playback dependency, and the reader is presented above the player,
/// so the composition that owns `PlaybackModel` supplies this rather than the reader reaching into
/// the shared playback graph.
@MainActor
public protocol ReaderPlaybackInterlock {
  /// Stops the active title when it is this book's audio, returning the `PlaybackModel` generation
  /// captured once the stop has fully returned. `nil` means nothing was playing.
  func stopIfActive(itemID: String) async -> Int?

  /// Prepares the next smart-list or Up Next continuation paused, or leaves presence to clear when
  /// there is none. Only call this with a generation `stopIfActive` returned, and only once the
  /// finish has landed.
  func prepareContinuation(after itemID: String, generation: Int) async
}

/// The reader's default: no playback to disturb, for previews, tests and harnesses.
public struct NoOpReaderPlaybackInterlock: ReaderPlaybackInterlock {
  public init() {}
  public func stopIfActive(itemID: String) async -> Int? { nil }
  public func prepareContinuation(after itemID: String, generation: Int) async {}
}

/// The production reader interlock. A dual-format book's audio is the active title only when the
/// book itself is loaded (`activeEpisodeID == nil`); a podcast episode row is a different identity
/// and is left alone.
public struct PlaybackReaderInterlock: ReaderPlaybackInterlock {
  private let playback: PlaybackModel

  public init(playback: PlaybackModel) {
    self.playback = playback
  }

  public func stopIfActive(itemID: String) async -> Int? {
    guard playback.activeItemID == itemID, playback.activeEpisodeID == nil else { return nil }
    await playback.stop()
    return playback.playbackGeneration
  }

  public func prepareContinuation(after itemID: String, generation: Int) async {
    guard let identity = ListeningIdentity.resolving(itemID: itemID) else { return }
    await playback.prepareContinuationPaused(
      after: identity, clearing: .everyRow, generation: generation)
  }
}
