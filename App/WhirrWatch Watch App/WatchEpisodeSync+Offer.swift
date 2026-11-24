import Foundation
import OSLog
import WatchConnectivity
import WatchPlayback
import WatchProtocol

/// The offer the phone sends and the ingress chain that applies it.
extension WatchEpisodeSync {
  /// Launch: remove what the replaced file transport left in the inbox, then apply any pending
  /// offer and reconcile the downloads. All of it is safe before the account is restored, and a
  /// no-op until a store exists.
  func prepareForLaunch() {
    guard !didPurgeInbox else { return }
    didPurgeInbox = true
    WatchReceivedEpisodeInbox.purge(
      olderThan: clock().addingTimeInterval(-Self.inboxRetention), directory: inboxDirectory)
    scheduleIngress()
    rssDownloads.scheduleReconcile()
  }

  /// Keeps the newest generation and applies it: a delivery that arrives before the account is
  /// restored is persisted, not lost.
  func receiveOffer(_ data: Data) {
    guard data.count <= WatchEpisodeSendOffer.maxWireBytes else {
      Self.note("offer_oversized")
      return
    }
    guard let offer = try? WatchWireCodec.decode(WatchEpisodeSendOffer.self, from: data) else {
      Self.note("offer_undecodable")
      return
    }
    // Offers carry the phone's whole desired set, so a later generation makes an earlier one moot,
    // and the two transports give no ordering guarantee.
    guard offer.generation >= storedOfferGeneration() else { return }
    WatchRSSDiagnostics.log("offer_received", ["generation": String(offer.generation)])
    guard persistOffer(data) else { return }
    scheduleIngress()
  }

  /// Applies the offer on disk. The file stays until the store has taken it, so no offer is dropped
  /// between its delivery and the account restore. Runs only inside `scheduleIngress`.
  private func applyPendingOffer() async {
    guard let store = receivedEpisodeStore else {
      WatchRSSDiagnostics.log("offer_apply", ["outcome": "no_store"])
      return
    }
    guard let data = try? Data(contentsOf: offerURL) else {
      WatchRSSDiagnostics.log("offer_apply", ["outcome": "no_offer"])
      return
    }
    guard let offer = try? WatchWireCodec.decode(WatchEpisodeSendOffer.self, from: data) else {
      // This build cannot read it, so no retry can; removing it lets a newer offer through.
      WatchRSSDiagnostics.log("offer_apply", ["outcome": "undecodable"])
      removeOffer()
      return
    }
    let outcome: WatchEpisodeOfferOutcome
    do {
      outcome = try await store.apply(offer)
    } catch {
      WatchRSSDiagnostics.log(
        "offer_apply",
        [
          "outcome": "failed", "generation": String(offer.generation),
          "type": String(describing: type(of: error)),
        ])
      Self.note("offer_apply_failed")
      return
    }
    switch outcome {
    case .ignored(let reason):
      WatchRSSDiagnostics.log(
        "offer_apply",
        ["outcome": "ignored", "generation": String(offer.generation), "reason": reason.rawValue])
    case .applied(let admitted, let declined, let dropped):
      WatchRSSDiagnostics.log(
        "offer_apply",
        [
          "outcome": "applied", "generation": String(offer.generation),
          "admitted": String(admitted.count), "declined": String(declined.count),
          "dropped": String(dropped.count),
        ])
    }
    // Applied and ignored are both final for this generation. A newer offer may have been saved
    // while the store applied this one; it stays for the next ingress.
    if storedOfferGeneration() == offer.generation { removeOffer() }
    await refreshReadyCopies()
    guard case .applied(_, _, let dropped) = outcome else { return }
    await retainJournalRows()
    if !dropped.isEmpty { onCopiesDropped(dropped) }
    scheduleInventory()
  }

  /// Applies the pending offer, then reconciles the Watch's downloads against it. Every caller goes
  /// through this one chain, so an offer apply and a reconcile never interleave.
  func scheduleIngress() {
    ingressGeneration &+= 1
    let generation = ingressGeneration
    let previous = ingressTask
    ingressTask = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      if !Task.isCancelled {
        // The store may already hold copies when the account is restored or the app relaunches.
        await self.refreshReadyCopies()
        await self.applyPendingOffer()
        self.rssDownloads.scheduleReconcile()
      }
      // A newer schedule owns the field now, so this one only clears its own.
      if self.ingressGeneration == generation { self.ingressTask = nil }
    }
  }

  /// A `WKURLSessionRefreshBackgroundTask` for the RSS session: the session is recreated so the
  /// system delivers the events that woke the app, and `completion` runs once they have drained.
  func attachRSSBackgroundEvents(_ completion: @escaping @Sendable () -> Void) {
    rssDownloads.handleBackgroundEvents(completion: completion)
  }
  private func storedOfferGeneration() -> UInt64 {
    guard let data = try? Data(contentsOf: offerURL),
      let offer = try? WatchWireCodec.decode(WatchEpisodeSendOffer.self, from: data)
    else { return 0 }
    return offer.generation
  }

  private func persistOffer(_ data: Data) -> Bool {
    do {
      try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
      try data.write(
        to: offerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      Self.note("offer_write_failed")
      return false
    }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var url = offerURL
    try? url.setResourceValues(values)
    return true
  }

  func removeOffer() {
    try? FileManager.default.removeItem(at: offerURL)
  }
}
