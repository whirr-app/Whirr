import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine
import WatchProtocol

/// Send to Watch for native-RSS episodes: composing the device-owned sender and its ingress, and
/// the account boundary and settings changes that clear or refresh it. The Audiobookshelf half is
/// in `WatchCompanionRuntime+ABSSend.swift`.
extension WatchCompanionRuntime {
  /// Composes the process-lifetime episode sender on first use. It needs only the stores, so a wake
  /// before the first unlock leaves it nil and the next Watch event (or `activate()`) tries again.
  func ensureEpisodeSend() {
    guard episodeSendPublisher == nil, let database = DatabaseHardware.sharedIfAvailable() else {
      return
    }
    let bridge = self.bridge
    let credentialStore: (any FeedCredentialStoring)? = try? KeychainFeedCredentialStore()
    let publisher = WatchEpisodeSendPublisher.production(
      database: database,
      credentialStore: credentialStore,
      sender: WatchEpisodeSendPublisher.Sender(
        isWatchInstalled: { bridge.isWatchInstalled },
        sendOffer: { bridge.sendEpisodeOffer($0) }))
    let episodes = RSSEpisodeStore(database: database)
    let copies = RSSWatchCopyStore(database: database)
    let inbox = WatchEpisodeInventoryInbox(
      copies: copies,
      record: downloadStatusRecord,
      episodeIDs: { feedId, identityKeys in
        (try? await episodes.fetchEpisodeIDs(feedId: feedId, identityKeys: identityKeys)) ?? [:]
      })
    inbox.onApplied = { [weak publisher] _ in publisher?.refresh() }
    inbox.onABSInventory = { [weak self] inventory, now in
      _ = await self?.absInventoryInbox?.receive(inventory, now: now)
    }
    inbox.onStatuses = { [weak self] statuses in
      self?.episodeCopies.applyDownloadStatuses(statuses)
    }
    episodeInventoryInbox = inbox
    restoreDownloadStatuses(from: copies)
    let state = RSSEpisodeStateStore(database: database)
    nativeProgressInbox = WatchNativeProgressInbox(
      activeInstallID: {
        guard let set = try? await copies.setState() else { return nil }
        return set.watchInstallID
      },
      episodeIDs: { feedId, identityKeys in
        (try? await episodes.fetchEpisodeIDs(feedId: feedId, identityKeys: Array(identityKeys))) ?? [:]
      },
      apply: { episodeId, position, finished, listenedAt, duration, now in
        try? await state.applyPeerListen(
          episodeId: episodeId, position: position, finished: finished, listenedAt: listenedAt,
          duration: duration, now: now)
      },
      isPlayingHere: { episodeId in
        PodcastCloudSyncComposition.activePlaybackTracker.activeEpisodeRowIDs.contains(episodeId)
      },
      removeFromWatch: { [weak self] episodeId in
        guard let self else { return }
        await self.removePlayedCopyFromWatch(episodeId: episodeId)
      })
    episodeSendPublisher = publisher
    publisher.refresh()
  }

  /// Restores the Watch's last download report into the copies model. The Watch cannot be woken to
  /// resend it, so without this the rows fall back to "Waiting for your Watch" after this phone
  /// relaunches. A report is valid only for the install whose copy set the store still holds; the
  /// model's own revision check drops a status for a superseded copy.
  func restoreDownloadStatuses(from copies: RSSWatchCopyStore) {
    let record = downloadStatusRecord
    Task { @MainActor in
      guard let set = try? await copies.setState(), let watchInstallID = set.watchInstallID,
        let saved = record.load(watchInstallID: watchInstallID)
      else { return }
      self.episodeCopies.applyDownloadStatuses(saved)
    }
  }

  /// The confirmed phone account boundary. Every row goes, and the bumped
  /// generation makes the next empty offer tell the Watch to drop the previous account's copies.
  func clearEpisodeSendForAccountChange() async {
    // The rows the saved report describes are gone, and a re-request starts again at revision 1, so
    // neither the record nor the model's projection may outlive the account.
    downloadStatusRecord.clear()
    episodeCopies.applyDownloadStatuses([:])
    // The account's Audiobookshelf rows cascade with it, and the schema forgets the inventory's
    // account in the same transaction; only the saved report is left to drop.
    absInventoryRecord.clear()
    if let publisher = episodeSendPublisher {
      await publisher.clearForAccountChange()
    } else if let database = DatabaseHardware.sharedIfAvailable() {
      try? await RSSWatchCopyStore(database: database).clearForAccountChange()
    }
  }

  /// The phone's On Apple Watch screen calls this after a request or removal, so
  /// the offer reflects the new desired set without waiting for an unrelated trigger.
  func refreshEpisodeSend() {
    episodeSendPublisher?.refresh()
    absSendPublisher?.refresh()
  }

  /// A played episode leaves the Watch once the phone records it finished, unless the listener
  /// turned that off in Settings. This is the native progress inbox's removal after a finished
  /// Watch listen; with the setting off the copy stays until it is removed by hand.
  func removePlayedCopyFromWatch(episodeId: Int64) async {
    guard WatchEpisodeSendPreferences.removesPlayedEpisodes() else { return }
    guard let database = DatabaseHardware.sharedIfAvailable() else { return }
    _ = try? await RSSWatchCopyStore(database: database)
      .removeFromWatch(episodeId: episodeId, now: Date())
    refreshEpisodeSend()
  }
}
