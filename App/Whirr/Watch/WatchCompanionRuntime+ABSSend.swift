import AppModel
import Foundation
import Persistence
import WatchProtocol

/// The account-bound Audiobookshelf half of Send to Watch (ADR 0021). The RSS half is
/// device-owned and outlives the account; this one is composed with the account graph and stopped
/// with it, so every offer carries the account's stamp and every row belongs to the account.
extension WatchCompanionRuntime {
  func bindABSSend(accountId: Int64, stamp: WatchAccountStamp, dependencies: AppDependencies) {
    unbindABSSend()
    guard let database = DatabaseHardware.sharedIfAvailable() else { return }
    let store = ABSWatchCopyStore(database: database, accountId: accountId)
    let resolver = ABSWatchTitleResolver(library: dependencies.library, podcasts: dependencies.podcastReading)
    let bridge = self.bridge
    let library = dependencies.library
    let publisher = ABSWatchSendPublisher(
      store: store, stamp: stamp,
      progress: { library.currentAudioProgress(itemId: $0.itemId, episodeId: $0.episodeId) },
      sender: ABSWatchSendPublisher.Sender(
        isWatchInstalled: { bridge.isWatchInstalled }, sendOffer: { bridge.sendABSOffer($0) }),
      removesFinished: { WatchEpisodeSendPreferences.removesPlayedEpisodes() })
    let record = absInventoryRecord
    let model = absCopies
    let inbox = ABSWatchInventoryInbox(store: store, stamp: stamp, resolver: resolver, record: record)
    inbox.onAccountMatch = { model.applyInventoryMatch($0) }
    inbox.onApplied = { [weak publisher] snapshot in
      model.applyInventory(snapshot)
      publisher?.refresh()
    }
    absSendPublisher = publisher
    absInventoryInbox = inbox
    model.bind(store: store, resolver: resolver) { [weak publisher] in publisher?.refresh() }
    restoreABSInventory(store: store, stamp: stamp, resolver: resolver, publisher: publisher)
    publisher.refresh()
  }

  func unbindABSSend() {
    absSendPublisher?.stop()
    absSendPublisher = nil
    absInventoryInbox = nil
    absCopies.unbind()
  }

  /// Restores the Watch's last report for this install and account, so Watch-origin rows and
  /// percentages survive this phone's relaunch. The record is read again after the titles resolve:
  /// an inventory applied meanwhile has replaced it, and is already showing.
  private func restoreABSInventory(
    store: ABSWatchCopyStore, stamp: WatchAccountStamp, resolver: ABSWatchTitleResolver,
    publisher: ABSWatchSendPublisher
  ) {
    let record = absInventoryRecord
    let hash = stamp.accountIdentityHash
    Task { @MainActor [weak self] in
      guard let installID = try? await store.setState().watchInstallID,
        let saved = record.load(watchInstallID: installID, accountIdentityHash: hash)
      else { return }
      let titled = await saved.titled(by: resolver)
      guard let self, self.absSendPublisher === publisher,
        record.load(watchInstallID: installID, accountIdentityHash: hash) == saved
      else { return }
      self.absCopies.applyInventory(titled)
    }
  }
}
