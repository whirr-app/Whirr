import Foundation
import Persistence

extension PlaybackModel {

  /// What completing a title should do after asking the active smart-list run for its next
  /// episode. `.noRun` and `.drained` leave completion to Up Next; `.advanced` and `.stopped` end
  /// it here.
  internal enum ListAdvanceOutcome: Sendable, Equatable {
    /// No run is active; Up Next goes on.
    case noRun
    /// The run was drained and ended here; Up Next goes on.
    case drained
    /// The run's next episode was handed to `start`.
    case advanced
    /// The generation was displaced, or the run could not be read. Up Next is never consulted.
    case stopped
  }

  /// The run step of completion, between the finished identity's own queue row and Up Next's peek.
  /// `playAfterStart` is false when the continuation is only prepared, never played.
  /// `reportsFailure` is false for a preparation taken before presence exists: a read failure has
  /// no surface to appear on there, so it is only logged.
  internal static func driveListAdvance(
    model: @escaping @MainActor () -> PlaybackModel?,
    continuation: any PlaybackContinuationSource,
    generation: Int,
    finished identity: ListeningIdentity,
    playAfterStart: Bool = true,
    reportsFailure: Bool = true
  ) async -> ListAdvanceOutcome {
    guard let run = await continuation.currentRun() else { return .noRun }
    guard model()?.ownsGeneration(generation) == true else { return .stopped }
    let candidate: SmartListCandidate?
    do {
      candidate = try await continuation.nextEpisode(after: run, excluding: identity)
    } catch {
      guard model()?.ownsGeneration(generation) == true else { return .stopped }
      if reportsFailure {
        model()?.applyListAdvanceFailure(generation: generation, identity: identity)
      } else {
        log.error(
          "List continuation could not be read: \(String(describing: type(of: error)), privacy: .public)"
        )
      }
      return .stopped
    }
    guard model()?.ownsGeneration(generation) == true else { return .stopped }
    guard let candidate else {
      await continuation.endRun(reason: .listExhausted)
      return model()?.ownsGeneration(generation) == true ? .drained : .stopped
    }
    await model()?.start(
      itemID: candidate.itemID, episodeID: candidate.episodeID, fromStart: false,
      origin: .listAdvance, forceFreshSession: false, expectedGeneration: generation,
      playAfterStart: playAfterStart)
    return .advanced
  }

  private func applyListAdvanceFailure(generation: Int, identity: ListeningIdentity) {
    guard ownsGeneration(generation) else { return }
    setQueueAdvanceFailure(identity: identity, origin: .listAdvance)
  }

  /// Runs before a start does anything durable. A `.requested` start without a run intent ends the
  /// run unless it is the run's anchor episode; automatic starts and a list's own `.begin` never
  /// end it.
  internal func endRunForStartIfNeeded(
    itemID: String, episodeID: String?, origin: PlaybackStartFailure.Origin, run: RunIntent?
  ) async {
    guard origin == .requested, run == nil else { return }
    await continuation.endRunUnlessAnchored(itemID: itemID, episodeID: episodeID)
  }

  /// Runs once a start succeeded. Only a generation this model still owns may write, which also
  /// keeps the write behind logout quiescence.
  internal func recordRunStart(
    itemID: String, episodeID: String?, origin: PlaybackStartFailure.Origin, run: RunIntent?,
    generation: Int
  ) async {
    guard ownsGeneration(generation), let episodeID else { return }
    switch (run, origin) {
    case (.begin(let listID)?, _):
      await continuation.recordListStart(itemID: itemID, episodeID: episodeID, listID: listID)
    case (nil, .listAdvance):
      await continuation.recordListStart(itemID: itemID, episodeID: episodeID, listID: nil)
    case (nil, .requested), (nil, .queueAdvance):
      break
    }
  }
}
