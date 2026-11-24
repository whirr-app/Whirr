import Foundation
import Observation
import Persistence
import SyncEngine

/// The card's server save: single-episode Save and Remove, the destination choice, the
/// subscription and account lifecycle, the status projection, and the sink the presenter writes
/// its outcomes to.
extension PodcastEpisodeCardModel {

  public func saveEpisodeToServer() async {
    guard let feedID = nativeFeedID else { return }
    await serverSavePresenter.save(
      feedID: feedID, episodeID: episodeID, choice: nil, sink: self)
  }

  public func removeEpisodeFromServer() async {
    guard let feedID = nativeFeedID else {
      await removeServerShowEpisodeFromServer()
      return
    }
    guard
      let nativeEpisodeID = await nativeEpisodeIDResolving.nativeEpisodeID(
        feedId: feedID, identityKey: episodeID)
    else {
      actionErrorMessage = NativeEpisodeServerSaveCopy.disabledReason(.missingEpisode)
      return
    }
    let snapshot = await nativeEpisodeServerSaveStatusReading.status(
      feedId: feedID, episodeId: nativeEpisodeID)
    guard snapshot.status.isRemovable,
      snapshot.preflightPresence == .absentBeforeRequest,
      let attemptID = snapshot.attemptID
    else {
      applyServerSaveSnapshot(snapshot)
      actionErrorMessage = NativeEpisodeServerSaveCopy.disabledReason(.unavailable)
      return
    }
    await serverSavePresenter.remove(
      episodeID: episodeID, attemptID: attemptID, sink: self)
  }

  /// The server episode's Remove: the projection keyed by server episode id is the only index
  /// there is, so the attempt is whatever it last reported for this card.
  private func removeServerShowEpisodeFromServer() async {
    guard serverItemID != nil else { return }
    guard serverSaveStatus.isRemovable,
      serverSavePreflightPresence == .absentBeforeRequest,
      let attemptID = serverSaveFence.latestAttemptID
    else {
      actionErrorMessage = NativeEpisodeServerSaveCopy.disabledReason(.unavailable)
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
    pendingServerSaveChoice = nil
    await serverSavePresenter.save(
      feedID: feedID, episodeID: pending.episodeID, choice: choice, sink: self)
  }

  /// Clears only in-memory presentation, when the account, native-subscription feature, or card
  /// lifecycle invalidates it. Never transitions, deletes, or reconciles a durable attempt:
  /// preparing/creatingShow sent nothing, but requestingDownload and every later state may
  /// already represent a server operation.
  public func clearServerSavePresentation(
    for trigger: NativeEpisodeServerSaveLifecycleTrigger = .accountUnavailable
  ) {
    serverSaveStatusTask?.cancel()
    serverSaveStatusTask = nil
    serverSavePresentationGeneration += 1
    serverSavePresentationVersion += 1
    pendingServerSaveChoice = nil
    serverSaveStatus = .none
    serverSaveFeedbackMessage = nil
    serverSaveBannerMessage = nil
    serverSavePreflightPresence = nil
    serverSaveFence = NativeEpisodeServerSaveAttemptFence()
    serverPodcastMutationCapability = .none
    if trigger.invalidatesCapability {
      let capabilityReading = serverPodcastMutationCapabilityReading
      Task { await capabilityReading.invalidate() }
    }
  }

  /// Dismisses in-memory feedback. Cancelling a pending destination choice also drops the status,
  /// because nothing has been sent at that point; a status that survived a send is left for the
  /// durable projection to re-supply.
  public func dismissServerSaveFeedback() {
    let hadPendingChoice = pendingServerSaveChoice != nil
    pendingServerSaveChoice = nil
    if hadPendingChoice {
      serverSaveStatus = .none
    }
    serverSaveFeedbackMessage = nil
    actionErrorMessage = nil
  }

  func startServerSaveLifecycleObservation() {
    if serverSaveLifecycleTask == nil {
      let reading = nativePodcastSubscriptionsReading
      serverSaveLifecycleTask = Task { [weak self] in
        var edge = NativeEpisodeServerSaveLifecycleEdges.SubscriptionsEdge()
        for await enabled in reading.observeEnabled() {
          guard Task.isCancelled == false, let self else { return }
          switch edge.next(enabled) {
          case .clear(let trigger):
            self.clearServerSavePresentation(for: trigger)
          case .reenabled:
            // Turning the feature back on re-reads capability and status; the teardown left both
            // empty. Awaited, so no later value is read until the refresh finishes.
            await self.refreshServerSaveProjection()
          case nil:
            break
          }
        }
      }
    }
    guard serverSaveAccountIdentityTask == nil else { return }
    let reading = accountIdentityReading
    serverSaveAccountIdentityTask = Task { [weak self] in
      var edge = NativeEpisodeServerSaveLifecycleEdges.AccountEdge()
      for await identity in reading.observeAccountIdentity() {
        guard Task.isCancelled == false, let self else { return }
        if let trigger = edge.next(identity) {
          self.clearServerSavePresentation(for: trigger)
        }
      }
    }
  }

  func refreshServerSaveProjection() async {
    guard let feedID = nativeFeedID else {
      if let serverItemID {
        await refreshServerItemSaveProjection(serverItemID: serverItemID)
      }
      return
    }
    let capability = await serverPodcastMutationCapabilityReading.capability()
    guard Task.isCancelled == false else { return }
    serverPodcastMutationCapability = capability

    let feedManaging = nativeFeedManaging
    let credentialed = (try? await feedManaging.hasCredential(feedId: feedID)) ?? false
    guard Task.isCancelled == false else { return }
    serverSaveCredentialedFeed = credentialed

    // Capability and credential are facts about the account and the feed; only the status needs
    // the row id behind this card's identity key, and a key with no row simply has no status.
    guard
      let nativeEpisodeID = await nativeEpisodeIDResolving.nativeEpisodeID(
        feedId: feedID, identityKey: episodeID),
      Task.isCancelled == false
    else { return }
    guard serverSaveStatusTask == nil else { return }
    let reader = nativeEpisodeServerSaveStatusReading
    let statusStream = reader.observeStatuses(feedId: feedID, episodeIds: [nativeEpisodeID])
    serverSaveStatusTask = Task { [weak self] in
      for await statuses in statusStream {
        guard Task.isCancelled == false, let self else { return }
        guard self.nativeFeedID == feedID else { return }
        self.applyServerSaveSnapshot(
          statuses[nativeEpisodeID] ?? NativeEpisodeServerSaveStatusSnapshot(status: .none))
      }
    }
  }

  /// The server episode's projection, keyed by the server episode id this card already is.
  /// Only Remove can come of it; the availability rule keeps that to confirmed, Whirr-created
  /// copies.
  private func refreshServerItemSaveProjection(serverItemID: String) async {
    let capability = await serverPodcastMutationCapabilityReading.capability()
    guard Task.isCancelled == false else { return }
    serverPodcastMutationCapability = capability
    guard serverSaveStatusTask == nil else { return }
    let episodeID = self.episodeID
    let statusStream = nativeEpisodeServerSaveStatusReading.observeServerItemStatuses(
      serverItemId: serverItemID)
    serverSaveStatusTask = Task { [weak self] in
      for await statuses in statusStream {
        guard Task.isCancelled == false, let self else { return }
        guard self.serverItemID == serverItemID else { return }
        self.applyServerSaveSnapshot(
          statuses[episodeID] ?? NativeEpisodeServerSaveStatusSnapshot(status: .none))
      }
    }
  }

  private func applyServerSaveSnapshot(_ snapshot: NativeEpisodeServerSaveStatusSnapshot) {
    guard serverSaveFence.accept(snapshot) else { return }
    // The confirmation the listener was left waiting for after Requested lands from the durable
    // stream, not from an action, so it is the one stream change that earns a banner.
    if serverSaveStatus == .requested, snapshot.status == .saved {
      serverSaveBannerMessage = NativeEpisodeServerSaveCopy.saved
    }
    // The stream re-emits on every attempt-table write; an unchanged value is not a mutation the
    // card's view should be asked to redraw for.
    if serverSaveStatus != snapshot.status { serverSaveStatus = snapshot.status }
    if serverSavePreflightPresence != snapshot.preflightPresence {
      serverSavePreflightPresence = snapshot.preflightPresence
    }
    let feedback =
      snapshot.status == .none ? nil : NativeEpisodeServerSaveCopy.text(for: snapshot.status)
    if serverSaveFeedbackMessage != feedback { serverSaveFeedbackMessage = feedback }
  }
}

extension PodcastEpisodeCardModel: NativeEpisodeServerSaveSink {
  var serverSaveGeneration: Int { serverSavePresentationGeneration }

  func beginServerSaveMutation(for episodeID: String, clearingRemoval: Bool) {
    serverSaveFence.beginMutation(clearingRemoval: clearingRemoval)
  }

  func endServerSaveMutation(for episodeID: String) {
    serverSaveFence.endMutation()
  }

  func recordServerSaveOutcome(
    _ outcome: NativeEpisodeServerSaveOutcome, for episodeID: String
  ) {
    serverSaveFence.record(outcome)
  }

  func setServerSaveStatus(_ status: NativeEpisodeServerSaveStatus, for episodeID: String) {
    serverSaveStatus = status
    serverSaveFeedbackMessage = NativeEpisodeServerSaveCopy.text(for: status)
  }

  func setServerSaveAttemptID(_ attemptID: Int64?, for episodeID: String) {
    // The card publishes no attempt map; its fence's high-water mark is what Remove reads.
  }

  func raiseServerSaveBanner(_ message: String) {
    serverSaveBannerMessage = message
  }

  func presentServerSaveChoice(_ choice: PendingServerSaveChoice) {
    pendingServerSaveChoice = choice
  }

  func reportServerSaveError(_ message: String?) {
    actionErrorMessage = message
  }

  func serverSaveDidAcceptWithoutChoice() {
    actionErrorMessage = nil
  }
}
