import Foundation
import Persistence
import SyncEngine

/// The show's server-save actions: single-episode Save and Remove, Save Show's destination
/// choice, the banners, and the sink the presenter writes its outcomes to.
extension PodcastShowServerSaveModel {

  /// Whether the save action accepts this episode now: the show's `.saveToServer` selection
  /// predicate.
  func acceptsSave(_ episode: PodcastEpisodeSummary) -> Bool {
    NativeEpisodeServerSaveStatus.saveAvailability(
      capability: serverMutationCapability,
      isNativeFeed: isNativeFeed,
      isCredentialedFeed: isCredentialedNativeFeed,
      status: serverSaveStatus(for: episode.id)) == .enabled
  }

  /// The visible episodes among `episodeIDs` that the save action accepts.
  func saveTargets(episodeIDs: Set<String>) -> [PodcastEpisodeSummary] {
    (host?.serverSaveVisibleEpisodes ?? []).filter {
      acceptsSave($0) && episodeIDs.contains($0.id)
    }
  }

  func updateActionError(_ message: String?) {
    host?.reportServerSaveActionError(message)
  }

  public func saveEpisodeToServer(episodeID: String) async {
    guard let feedID = nativeFeedID else { return }
    await serverSavePresenter.save(
      feedID: feedID, episodeID: episodeID, choice: nil, sink: self)
  }

  public func removeEpisodeFromServer(episodeID: String) async {
    guard let feedID = nativeFeedID else {
      await removeServerShowEpisodeFromServer(episodeID: episodeID)
      return
    }
    guard
      let nativeEpisodeID = await nativeEpisodeIDResolving.nativeEpisodeID(
        feedId: feedID, identityKey: episodeID)
    else {
      updateActionError(NativeEpisodeServerSaveCopy.disabledReason(.missingEpisode))
      return
    }
    let snapshot = await nativeEpisodeServerSaveStatusReading.status(
      feedId: feedID, episodeId: nativeEpisodeID)
    guard snapshot.status.isRemovable,
      snapshot.preflightPresence == .absentBeforeRequest,
      let attemptID = snapshot.attemptID
    else {
      serverSaveStatus = snapshot.status
      serverSaveStatuses[episodeID] = snapshot.status
      serverSavePreflightPresence[episodeID] = snapshot.preflightPresence
      serverSaveAttemptIDs[episodeID] = snapshot.attemptID
      updateActionError(NativeEpisodeServerSaveCopy.disabledReason(.unavailable))
      return
    }
    await serverSavePresenter.remove(
      episodeID: episodeID, attemptID: attemptID, sink: self)
  }

  /// The server show's Remove: the attempt is whichever confirmed, Whirr-created row the
  /// projection reported for this server episode id. There is no pull read to fall back on (the
  /// stream is the only index by server episode), so an episode the projection never named is
  /// unavailable.
  private func removeServerShowEpisodeFromServer(episodeID: String) async {
    guard serverItemID != nil else { return }
    guard let status = serverSaveStatuses[episodeID], status.isRemovable,
      serverSavePreflightPresence[episodeID] == .absentBeforeRequest,
      let attemptID = serverSaveAttemptIDs[episodeID] ?? nil
    else {
      updateActionError(NativeEpisodeServerSaveCopy.disabledReason(.unavailable))
      return
    }
    await serverSavePresenter.remove(
      episodeID: episodeID, attemptID: attemptID, sink: self)
  }

  public func dismissServerSaveBanner() {
    serverSaveBannerMessage = nil
  }

  public func chooseSaveDestination(_ choice: ServerPodcastSaveChoice) async {
    guard let pending = pendingServerSaveChoice, let feedID = nativeFeedID else { return }
    if let batchID = pending.batchID, batchID == batchServerSave?.id,
      let resume = batchServerSaveResume,
      let session = batchServerSave,
      let cancellation = batchServerSaveCancellation
    {
      pendingServerSaveChoice = nil
      batchServerSaveResume = nil
      batchServerSaveTally = resume.tally
      batchServerSave?.setPhase(.running)
      await runBatchServerSave(
        generation: serverSavePresentationGeneration,
        sessionID: session.id,
        itemID: itemID,
        request: NativeEpisodeServerSaveBatchRequest(
          feedId: feedID, episodeIds: resume.rowIDs, choice: choice),
        rowToEpisodeID: resume.rowToEpisodeID,
        cancellation: cancellation)
      return
    }
    pendingServerSaveChoice = nil
    await serverSavePresenter.save(
      feedID: feedID, episodeID: pending.episodeID, choice: choice, sink: self)
  }

  public func dismissServerSaveFeedback() {
    let pending = pendingServerSaveChoice
    if let pending, let batchID = pending.batchID, batchID == batchServerSave?.id {
      clearBatchServerSaveAfterDismissal(episodeID: pending.episodeID)
    }
    pendingServerSaveChoice = nil
    if pending?.batchID == nil, let cancelledEpisodeID = pending?.episodeID {
      serverSaveStatuses[cancelledEpisodeID] = nil
      serverSavePreflightPresence[cancelledEpisodeID] = nil
      serverSaveAttemptIDs[cancelledEpisodeID] = nil
      if serverSaveCurrentEpisodeID == cancelledEpisodeID {
        serverSaveStatus = .none
      }
    }
    serverSaveFeedbackMessage = nil
    updateActionError(nil)
  }

  private func serverSaveCurrent(episodeID: String, status: NativeEpisodeServerSaveStatus) {
    serverSaveCurrentEpisodeID = episodeID
    serverSaveStatus = status
    serverSaveFeedbackMessage = NativeEpisodeServerSaveCopy.text(for: status)
    serverSaveStatuses[episodeID] = status
  }
}

extension PodcastShowServerSaveModel: NativeEpisodeServerSaveSink {
  var serverSaveGeneration: Int { serverSavePresentationGeneration }

  func beginServerSaveMutation(for episodeID: String, clearingRemoval: Bool) {
    serverSaveFences[episodeID, default: .init()].beginMutation(clearingRemoval: clearingRemoval)
  }

  func endServerSaveMutation(for episodeID: String) {
    serverSaveFences[episodeID]?.endMutation()
  }

  func recordServerSaveOutcome(
    _ outcome: NativeEpisodeServerSaveOutcome, for episodeID: String
  ) {
    serverSaveFences[episodeID, default: .init()].record(outcome)
  }

  func setServerSaveStatus(_ status: NativeEpisodeServerSaveStatus, for episodeID: String) {
    serverSaveCurrent(episodeID: episodeID, status: status)
  }

  func setServerSaveAttemptID(_ attemptID: Int64?, for episodeID: String) {
    serverSaveAttemptIDs[episodeID] = attemptID
  }

  func raiseServerSaveBanner(_ message: String) {
    serverSaveBannerMessage = message
  }

  func presentServerSaveChoice(_ choice: PendingServerSaveChoice) {
    pendingServerSaveChoice = choice
  }

  func reportServerSaveError(_ message: String?) {
    updateActionError(message)
  }

  func serverSaveDidAcceptWithoutChoice() {
    // The show's action-error channel is shared with every other episode action, so a resolved
    // save says nothing about it.
  }
}
