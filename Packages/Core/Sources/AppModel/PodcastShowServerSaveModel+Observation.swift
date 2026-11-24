import Foundation
import Persistence
import SyncEngine

/// The owning show's lifecycle and the server-save projection: attaching to a show, the
/// subscription and account teardowns, and the status stream every row reads.
extension PodcastShowServerSaveModel {

  /// Connects the owning show and starts the observations. Called once, at the end of the show's
  /// initializer, so no observation runs without a host.
  func attach(host: any PodcastShowServerSaveHost) {
    self.host = host
    restartShowSaveObservation()
    startServerSaveLifecycleObservation()
  }

  /// The show's episode observation emitted. Statuses are re-read only when the ids changed.
  func episodesDidChange(_ episodes: [PodcastEpisodeSummary]) {
    guard episodes.map(\.id) != serverSaveProjectedEpisodeIDs else { return }
    observeServerSaveProjection(itemID: itemID, episodes: episodes)
  }

  /// The owning show moved to another item. Unlike `clearServerSavePresentation(for:)` this keeps
  /// the capability and `serverSavePresentationVersion`, and the lifecycle observations run on.
  func show(itemID: String) {
    batchServerSaveCancellation?.cancel()
    serverSavePresentationGeneration += 1
    batchServerSave = nil
    batchServerSaveCancellation = nil
    batchServerSaveResume = nil
    batchServerSavePendingEpisodeIDs.removeAll()
    batchServerSaveRequestedAttemptIDs.removeAll()
    batchServerSaveConfirmedAttemptIDs.removeAll()
    batchServerSaveTally = NativeEpisodeServerSaveBatchCopy.Tally()
    batchServerSaveAppliedEpisodeIDs.removeAll()
    serverSaveStatusTask?.cancel()
    serverSaveCredentialTask?.cancel()
    self.itemID = itemID
    serverSaveStatus = .none
    serverSaveFeedbackMessage = nil
    serverSaveBannerMessage = nil
    pendingServerSaveChoice = nil
    serverSaveStatuses.removeAll()
    serverSavePreflightPresence.removeAll()
    serverSaveAttemptIDs.removeAll()
    serverSaveFences.removeAll()
    serverSaveCredentialedFeed = false
    serverSaveCurrentEpisodeID = nil
    serverSaveProjectedEpisodeIDs = []
    restartShowSaveObservation()
  }

  func resetServerSavePresentationState() {
    batchServerSaveCancellation?.cancel()
    serverSavePresentationGeneration += 1
    serverSavePresentationVersion += 1
    pendingServerSaveChoice = nil
    serverSaveStatus = .none
    serverSaveFeedbackMessage = nil
    serverSaveBannerMessage = nil
    serverSaveStatuses.removeAll()
    serverSavePreflightPresence.removeAll()
    serverSaveAttemptIDs.removeAll()
    serverSaveFences.removeAll()
    serverSaveCurrentEpisodeID = nil
    serverSaveProjectedEpisodeIDs = []
    showSaveSupport.isArmed = false
    batchServerSave = nil
    batchServerSaveCancellation = nil
    batchServerSaveResume = nil
    batchServerSavePendingEpisodeIDs.removeAll()
    batchServerSaveRequestedAttemptIDs.removeAll()
    batchServerSaveConfirmedAttemptIDs.removeAll()
    batchServerSaveTally = NativeEpisodeServerSaveBatchCopy.Tally()
    batchServerSaveAppliedEpisodeIDs.removeAll()
  }

  /// Clears only in-memory presentation. It never transitions, deletes, or reconciles a durable
  /// attempt and never calls the server coordinator.
  public func clearServerSavePresentation(
    for trigger: NativeEpisodeServerSaveLifecycleTrigger
  ) {
    serverSaveStatusTask?.cancel()
    serverSaveStatusTask = nil
    resetServerSavePresentationState()
    serverPodcastMutationCapability = .none
    if trigger.invalidatesCapability {
      let capabilityReading = serverPodcastMutationCapabilityReading
      Task { await capabilityReading.invalidate() }
    }
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
            // Turning the feature back on re-reads capability and statuses; the teardown left
            // both empty on purpose.
            self.observeServerSaveProjection(
              itemID: self.itemID, episodes: self.host?.serverSaveEpisodes ?? [])
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

  /// The status used by the show-row menu. Unknown episodes are the untouched state, which lets a
  /// capability-enabled native feed show Save before a status observation has completed.
  public func serverSaveStatus(for episodeID: String) -> NativeEpisodeServerSaveStatus {
    serverSaveStatuses[episodeID] ?? .none
  }

  public var isCredentialedNativeFeed: Bool { serverSaveCredentialedFeed }

  public var serverMutationCapability: ServerPodcastMutationCapability {
    serverPodcastMutationCapability
  }

  func observeServerSaveProjection(itemID: String, episodes: [PodcastEpisodeSummary]) {
    serverSaveStatusTask?.cancel()
    serverSaveProjectedEpisodeIDs = episodes.map(\.id)
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else {
      if let serverItemID = PodcastSourceIdentity(itemId: itemID)?.absItemId {
        observeServerItemSaveProjection(itemID: itemID, serverItemID: serverItemID)
      }
      return
    }
    let reader = nativeEpisodeServerSaveStatusReading
    let resolver = nativeEpisodeIDResolving
    let capabilityReader = serverPodcastMutationCapabilityReading
    let recovering = nativeEpisodeServerSaveRecovering
    serverSaveStatusTask = Task { [weak self] in
      let capability = await capabilityReader.capability()
      let episodeIDs = await resolver.nativeEpisodeIDs(
        feedId: feedID, identityKeys: episodes.map(\.id))
      let rowIDs = episodes.compactMap { episodeIDs[$0.id] }
      let statusStream = reader.observeStatuses(feedId: feedID, episodeIds: rowIDs)
      var didRecover = false

      for await snapshots in statusStream {
        guard Task.isCancelled == false, let self, itemID == self.itemID else { return }
        if self.serverPodcastMutationCapability != capability {
          self.serverPodcastMutationCapability = capability
        }
        self.applyServerSaveSnapshots(
          snapshots, episodes: episodes, resolvedEpisodeIDs: episodeIDs)

        // Rows this feed left unsettled are recovered after the initial aggregate emission. A
        // second bounded pull sees the recovery transitions even for a compatibility reader whose
        // observation stream emits only once.
        if didRecover == false {
          didRecover = true
          let recovered = await recovering.recoverPendingAttempts(feedId: feedID)
          guard Task.isCancelled == false, itemID == self.itemID else { return }
          guard recovered.isEmpty == false else { continue }
          let refreshed = await reader.statuses(feedId: feedID, episodeIds: rowIDs)
          guard Task.isCancelled == false, itemID == self.itemID else { return }
          self.applyServerSaveSnapshots(
            refreshed, episodes: episodes, resolvedEpisodeIDs: episodeIDs)
        }
      }
    }

    serverSaveCredentialTask?.cancel()
    let feedManaging = nativeFeedManaging
    serverSaveCredentialTask = Task { [weak self] in
      let read = try? await feedManaging.hasCredential(feedId: feedID)
      guard let self, itemID == self.itemID else { return }
      self.serverSaveCredentialedFeed = read ?? false
      self.applyShowSaveCredentialRead(read)
    }
  }

  /// The server show's projection: statuses arrive keyed by server episode id, which is what a
  /// server show's `PodcastEpisodeSummary.id` already is, so no resolution step is needed. Only
  /// Remove can come of it (a server show has nothing of its own to save), and the availability
  /// rule keeps that to confirmed, Whirr-created copies.
  private func observeServerItemSaveProjection(itemID: String, serverItemID: String) {
    let reader = nativeEpisodeServerSaveStatusReading
    let capabilityReader = serverPodcastMutationCapabilityReading
    serverSaveStatusTask = Task { [weak self] in
      let capability = await capabilityReader.capability()
      for await snapshots in reader.observeServerItemStatuses(serverItemId: serverItemID) {
        guard Task.isCancelled == false, let self, itemID == self.itemID else { return }
        if self.serverPodcastMutationCapability != capability {
          self.serverPodcastMutationCapability = capability
        }
        self.applyServerSaveSnapshots(snapshots.map { ($0.key, $0.value) })
      }
    }
  }

  /// Summary ids are feed identity keys; the projection is keyed by the `rssEpisode` row id, so
  /// the whole list is resolved in one read and its statuses fetched in one more. A per-episode
  /// status read would cost one query per row (600 for a large feed) on every list emission.
  private static func serverSaveSnapshots(
    episodes: [PodcastEpisodeSummary],
    resolvedEpisodeIDs: [String: Int64],
    statuses: [Int64: NativeEpisodeServerSaveStatusSnapshot]
  ) -> [(String, NativeEpisodeServerSaveStatusSnapshot)] {
    var snapshots: [(String, NativeEpisodeServerSaveStatusSnapshot)] = []
    for episode in episodes {
      guard let episodeID = resolvedEpisodeIDs[episode.id] else { continue }
      snapshots.append(
        (episode.id, statuses[episodeID] ?? NativeEpisodeServerSaveStatusSnapshot(status: .none)))
    }
    return snapshots
  }

  private func applyServerSaveSnapshots(
    _ statuses: [Int64: NativeEpisodeServerSaveStatusSnapshot],
    episodes: [PodcastEpisodeSummary],
    resolvedEpisodeIDs: [String: Int64]
  ) {
    applyServerSaveSnapshots(
      Self.serverSaveSnapshots(
        episodes: episodes, resolvedEpisodeIDs: resolvedEpisodeIDs, statuses: statuses))
  }

  private func applyServerSaveSnapshots(
    _ snapshots: [(String, NativeEpisodeServerSaveStatusSnapshot)]
  ) {
    for (episodeID, snapshot) in snapshots {
      guard serverSaveFences[episodeID, default: .init()].accept(snapshot) else { continue }
      // The confirmation the listener was left waiting for after Requested: it lands from the
      // durable stream, not from an action, so it is the one stream change that earns a banner.
      if serverSaveStatuses[episodeID] == .requested, snapshot.status == .saved {
        if let attemptID = snapshot.attemptID,
          batchServerSaveRequestedAttemptIDs.contains(attemptID)
        {
          batchServerSaveConfirmedAttemptIDs.insert(attemptID)
          if batchServerSaveConfirmedAttemptIDs == batchServerSaveRequestedAttemptIDs {
            serverSaveBannerMessage = NativeEpisodeServerSaveBatchCopy.allConfirmed(
              count: batchServerSaveRequestedAttemptIDs.count)
            batchServerSaveRequestedAttemptIDs.removeAll()
            batchServerSaveConfirmedAttemptIDs.removeAll()
          }
        } else {
          serverSaveBannerMessage = NativeEpisodeServerSaveCopy.saved
        }
      }
      // Every attempt-table write re-emits the whole map, and these three maps are read by every
      // visible row. A write is an observable mutation whether or not the value moved, so a row
      // whose snapshot is unchanged must leave them untouched or each write of a batch rebuilds
      // the list for nothing.
      if serverSaveStatuses[episodeID] != snapshot.status {
        serverSaveStatuses[episodeID] = snapshot.status
      }
      if (serverSavePreflightPresence[episodeID] ?? nil) != snapshot.preflightPresence {
        serverSavePreflightPresence[episodeID] = snapshot.preflightPresence
      }
      if (serverSaveAttemptIDs[episodeID] ?? nil) != snapshot.attemptID {
        serverSaveAttemptIDs[episodeID] = snapshot.attemptID
      }
      if serverSaveCurrentEpisodeID == episodeID {
        if serverSaveStatus != snapshot.status { serverSaveStatus = snapshot.status }
        let feedback =
          snapshot.status == .none ? nil : NativeEpisodeServerSaveCopy.text(for: snapshot.status)
        if serverSaveFeedbackMessage != feedback { serverSaveFeedbackMessage = feedback }
      }
    }
  }

  public func serverSavePreflightPresence(for episodeID: String)
    -> NativeEpisodeServerSavePreflightPresence?
  {
    serverSavePreflightPresence[episodeID] ?? nil
  }

  public func serverSaveAttemptID(for episodeID: String) -> Int64? {
    serverSaveAttemptIDs[episodeID] ?? nil
  }
}
