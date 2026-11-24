import Persistence
import SyncEngine

/// What the shared server-save presenter writes into on behalf of one surface. The presenter owns
/// the outcome switch, the generation fence around the await and the failure mapping; everything a
/// listener can see stays with the receiver that implements this.
///
/// The two implementations differ only where the show and the card already differed: the show
/// publishes per-episode maps, a current episode and a shared action-error channel; the card
/// publishes one episode and owns its error channel.
@MainActor
protocol NativeEpisodeServerSaveSink: AnyObject {
  /// Bumped by every teardown. Read when an operation begins and re-checked when its outcome lands,
  /// so an outcome that belongs to a cleared presentation is dropped.
  var serverSaveGeneration: Int { get }

  /// Opens this episode's mutation fence. A single save clears the removal fence; a remove leaves
  /// it for the first strictly newer snapshot to clear.
  func beginServerSaveMutation(for episodeID: String, clearingRemoval: Bool)
  func endServerSaveMutation(for episodeID: String)
  /// Feeds the outcome to the fence before any of it is presented, so a late snapshot cannot
  /// replace the result this outcome is about to publish.
  func recordServerSaveOutcome(
    _ outcome: NativeEpisodeServerSaveOutcome, for episodeID: String)

  func setServerSaveStatus(_ status: NativeEpisodeServerSaveStatus, for episodeID: String)
  func setServerSaveAttemptID(_ attemptID: Int64?, for episodeID: String)
  func raiseServerSaveBanner(_ message: String)
  func presentServerSaveChoice(_ choice: PendingServerSaveChoice)
  func reportServerSaveError(_ message: String?)

  /// A save that needed no destination choice resolved without a failure. The card clears its own
  /// action error here; the show leaves its channel alone because its episode actions share it.
  func serverSaveDidAcceptWithoutChoice()
}

/// Single-episode Save and Remove for one episode on one surface, shared by
/// `PodcastShowServerSaveModel` and `PodcastEpisodeCardModel`.
///
/// The receiver passes itself as the sink, so the presenter owns no presentation state and holds
/// no reference back to it. Every asynchronous result is applied only if the sink's generation
/// still holds the value captured when the work began.
@MainActor
final class NativeEpisodeServerSavePresenter {
  private let saving: any NativeEpisodeServerSaving
  private let resolving: any NativeEpisodeIDResolving
  private let librarySyncRequester: any LibrarySyncRequesting

  init(
    saving: any NativeEpisodeServerSaving,
    resolving: any NativeEpisodeIDResolving,
    librarySyncRequester: any LibrarySyncRequesting
  ) {
    self.saving = saving
    self.resolving = resolving
    self.librarySyncRequester = librarySyncRequester
  }

  func save(
    feedID: Int64,
    episodeID: String,
    choice: ServerPodcastSaveChoice?,
    sink: any NativeEpisodeServerSaveSink
  ) async {
    // `episodeID` is the feed identity key the summary carries, not the row id the coordinator
    // is keyed by. A key with no row is a pruned or never-stored episode, which is the one case
    // that must not reach the coordinator at all.
    guard
      let nativeEpisodeID = await resolving.nativeEpisodeID(
        feedId: feedID, identityKey: episodeID)
    else {
      applyFailure(
        episodeID: episodeID, category: .missingEpisode, phase: .save, attemptID: nil, sink: sink)
      return
    }
    let generation = sink.serverSaveGeneration
    sink.beginServerSaveMutation(for: episodeID, clearingRemoval: true)
    sink.setServerSaveStatus(.preparing, for: episodeID)
    let outcome = await saving.save(
      feedId: feedID, episodeId: nativeEpisodeID, choice: choice)
    // A create is durable whether or not this presentation survived, so the sync is requested
    // before the teardown guard below.
    if choice?.createsShow == true, outcome.wasAccepted {
      // Not awaited: a whole-library sync must not hold the save's own result back.
      let requester = librarySyncRequester
      Task { await requester.requestLibrarySync() }
    }
    // A teardown while the request was in flight owns the presentation now; the durable row keeps
    // the outcome for the next projection read.
    guard generation == sink.serverSaveGeneration else { return }
    sink.endServerSaveMutation(for: episodeID)
    apply(outcome, episodeID: episodeID, phase: .save, sink: sink)
  }

  func remove(
    episodeID: String,
    attemptID: Int64,
    sink: any NativeEpisodeServerSaveSink
  ) async {
    let generation = sink.serverSaveGeneration
    sink.beginServerSaveMutation(for: episodeID, clearingRemoval: false)
    sink.setServerSaveStatus(.removing, for: episodeID)
    let outcome = await saving.remove(attemptID: attemptID)
    guard generation == sink.serverSaveGeneration else { return }
    sink.endServerSaveMutation(for: episodeID)
    apply(outcome, episodeID: episodeID, phase: .remove, sink: sink)
  }

  private func apply(
    _ outcome: NativeEpisodeServerSaveOutcome,
    episodeID: String,
    phase: NativeEpisodeServerSavePhase,
    sink: any NativeEpisodeServerSaveSink
  ) {
    sink.recordServerSaveOutcome(outcome, for: episodeID)
    switch outcome {
    case .needsChoice(let attemptID, let prompt):
      sink.setServerSaveAttemptID(attemptID, for: episodeID)
      sink.setServerSaveStatus(.preparing, for: episodeID)
      sink.presentServerSaveChoice(
        PendingServerSaveChoice(episodeID: episodeID, attemptID: attemptID, prompt: prompt))
      sink.reportServerSaveError(nil)
    case .accepted(let attemptID, _):
      sink.setServerSaveAttemptID(attemptID, for: episodeID)
      sink.setServerSaveStatus(.requested, for: episodeID)
      sink.raiseServerSaveBanner(NativeEpisodeServerSaveCopy.requested)
      sink.serverSaveDidAcceptWithoutChoice()
    case .alreadyPresent(let attemptID, _):
      sink.setServerSaveAttemptID(attemptID, for: episodeID)
      sink.setServerSaveStatus(.saved, for: episodeID)
      sink.raiseServerSaveBanner(NativeEpisodeServerSaveCopy.saved)
      sink.serverSaveDidAcceptWithoutChoice()
    case .inProgress(let attemptID, let state, _):
      sink.setServerSaveAttemptID(attemptID, for: episodeID)
      let status = NativeEpisodeServerSaveStatus.status(for: state, category: .unknown)
      sink.setServerSaveStatus(status, for: episodeID)
      if status == .removed || status == .saved {
        sink.raiseServerSaveBanner(NativeEpisodeServerSaveCopy.text(for: status))
      }
    case .uncertain(let attemptID, _, let category):
      sink.setServerSaveAttemptID(attemptID, for: episodeID)
      // Preserve the phase-specific uncertainty in status presentation. It stays out of the
      // error channel: unknown is neither a success nor a failure.
      sink.setServerSaveStatus(.uncertain(category, phase: phase), for: episodeID)
      sink.reportServerSaveError(nil)
    case .failed(let attemptID, _, let category):
      applyFailure(
        episodeID: episodeID, category: category, phase: phase, attemptID: attemptID, sink: sink)
    }
  }

  private func applyFailure(
    episodeID: String,
    category: NativeEpisodeServerSaveErrorCategory,
    phase: NativeEpisodeServerSavePhase,
    attemptID: Int64?,
    sink: any NativeEpisodeServerSaveSink
  ) {
    sink.setServerSaveAttemptID(attemptID, for: episodeID)
    sink.setServerSaveStatus(.failed(category, phase: phase), for: episodeID)
    sink.reportServerSaveError(NativeEpisodeServerSaveCopy.disabledReason(for: category))
  }
}
