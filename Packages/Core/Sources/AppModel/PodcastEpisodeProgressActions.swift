import CoreSupport
import Persistence

/// Coordinates episode progress intents with the live playback session.
///
/// The Podcasts tab uses `ItemActionsModel` for its durable progress writes, but those writes need
/// the same playback interlocks as the show screen's episode intents. Book surfaces use it too, with
/// no episode ID, so every swipe, menu and multi-select disturbs the live session in the same order.
@MainActor
public struct PodcastEpisodeProgressActions {
  private static let log = CoreLogging.logger(category: "ItemProgressActions")

  private let actions: ItemActionsModel
  private let playback: PlaybackModel

  public init(actions: ItemActionsModel, playback: PlaybackModel) {
    self.actions = actions
    self.playback = playback
  }

  /// Stops first so a progress tick from the live session cannot overwrite the completed state.
  /// When the finished title was the one playing, the next continuation is then prepared paused:
  /// playback does not resume, but the player keeps its next row instead of the finished title.
  @discardableResult
  public func markAsFinished(
    itemID: String, episodeID: String?, duration: Double?
  ) async -> ItemActionResult {
    let finished = await finish(itemID: itemID, episodeID: episodeID, duration: duration)
    if let identity = finished.identity, let generation = finished.stoppedGeneration {
      await playback.prepareContinuationPaused(
        after: identity, clearing: .everyRow, generation: generation)
    }
    return finished.result
  }

  /// One target's finish, without the continuation step.
  ///
  /// A multi-select batch runs this for every target and prepares one continuation after the loop:
  /// preparing per target could start a row a later target in the same batch is about to finish.
  @discardableResult
  func finish(
    itemID: String, episodeID: String?, duration: Double?
  ) async -> FinishedTarget {
    let identity = ListeningIdentity.resolving(itemID: itemID, episodeID: episodeID)
    var generation: Int?
    if isActive(itemID: itemID, episodeID: episodeID) {
      await playback.stop()
      generation = playback.playbackGeneration
    }
    let result = await actions.markAsFinished(
      itemID: itemID, episodeID: episodeID, duration: duration)
    guard result == .succeeded else {
      return FinishedTarget(result: result, identity: nil, stoppedGeneration: nil)
    }
    return FinishedTarget(result: result, identity: identity, stoppedGeneration: generation)
  }

  /// The single continuation step a batch runs once every target has finished.
  ///
  /// `alsoFinished` are the identities it finished: their Up Next rows go before the preparation
  /// peeks, so a row the listener just marked finished cannot be started as the next thing to play.
  func prepareContinuation(
    after finished: ListeningIdentity, generation: Int, alsoFinished: [ListeningIdentity]
  ) async {
    for identity in alsoFinished where identity != finished {
      do {
        try await playback.listeningQueue.remove(identity: identity)
      } catch {
        // Without the removal the peek could select a title this batch finished. Nothing is
        // presented before the start, so there is no surface to report it on; log and leave it.
        Self.log.error(
          "A batch-finish continuation could not clear a finished title's row: \(String(describing: type(of: error)), privacy: .public)"
        )
        return
      }
    }
    await playback.prepareContinuationPaused(
      after: finished, clearing: .everyRow, generation: generation)
  }

  /// Persists first, then moves the live playhead so the screen and player agree on the reset.
  @discardableResult
  public func resetProgress(
    itemID: String, episodeID: String?, category: ItemMediaCategory = .audiobook
  ) async -> ItemActionResult {
    let result = await actions.resetProgress(
      itemID: itemID, episodeID: episodeID, category: category)
    if isActive(itemID: itemID, episodeID: episodeID) {
      playback.seek(itemID: itemID, toGlobalOffset: 0)
    }
    return result
  }

  private func isActive(itemID: String, episodeID: String?) -> Bool {
    playback.activeItemID == itemID && playback.activeEpisodeID == episodeID
  }

  struct FinishedTarget {
    let result: ItemActionResult
    /// The identity the write finished, `nil` when the write failed.
    let identity: ListeningIdentity?
    /// The generation captured right after this finish stopped the active title. Non-nil only when
    /// the write landed and the title was the one playing.
    let stoppedGeneration: Int?
  }
}
