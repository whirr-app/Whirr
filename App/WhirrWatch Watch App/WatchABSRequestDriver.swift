import Foundation
import OSLog
import WatchPlayback
import WatchProtocol

/// Applies the phone's Audiobookshelf requests (ADR 0021). Headless: it persists the
/// offer, reconciles it against the account's download groups through `WatchABSRequestLedger`, and
/// runs each step through the download controller's shared paths, so a phone request and a wrist
/// tap cannot diverge.
///
/// It reconciles when an offer arrives, when the account becomes ready, when the app activates and
/// when the network returns, never in a loop. One reconcile runs at a time; one asked for while it
/// runs follows it. The offer waits on disk until a signed-in session can take it, so a delivery
/// before the account is restored, or a launch too short to plan a book, loses nothing.
@MainActor
final class WatchABSRequestDriver {
  private nonisolated static let logger = Logger(
    subsystem: "com.remoteconcern.whirr.watchkitapp", category: "absRequests")

  private unowned let model: WatchLibraryModel
  private let applicationSupport: URL
  private var ledger: WatchABSRequestLedger?
  private var ledgerStamp: WatchAccountStamp?
  private var running: Task<Void, Never>?
  private var runAgain = false
  private var runAgainRetriesNetwork = false

  init(model: WatchLibraryModel, applicationSupport: URL = WatchEpisodeSync.applicationSupportDirectory) {
    self.model = model
    self.applicationSupport = applicationSupport
  }

  private var offerURL: URL { applicationSupport.appendingPathComponent("WatchABSOffer.json") }

  // MARK: Triggers

  /// Keeps the newest generation on disk and reconciles. Offers carry the phone's whole set, so a
  /// later generation makes an earlier one moot.
  func receiveOffer(_ data: Data) {
    guard data.count <= WatchABSSendOffer.maxWireBytes,
      let offer = try? WatchWireCodec.decode(WatchABSSendOffer.self, from: data)
    else {
      Self.note("abs_offer_unreadable")
      return
    }
    guard offer.generation >= pendingOfferGeneration() else { return }
    WatchRSSDiagnostics.log("abs_offer_received", ["generation": String(offer.generation)])
    guard persistOffer(data) else { return }
    scheduleReconcile()
  }

  func accountReady() { scheduleReconcile() }

  /// `retryingNetworkFailures` retries a request whose detail or plan failed for want of a
  /// network; every other failure waits for the phone's next revision.
  func scheduleReconcile(retryingNetworkFailures: Bool = false) {
    runAgainRetriesNetwork = runAgainRetriesNetwork || retryingNetworkFailures
    guard running == nil else {
      runAgain = true
      return
    }
    runAgain = true
    running = Task { [weak self] in
      guard let self else { return }
      while self.runAgain, !Task.isCancelled {
        let retries = self.runAgainRetriesNetwork
        self.runAgain = false
        self.runAgainRetriesNetwork = false
        await self.reconcile(retryingNetworkFailures: retries)
      }
      self.running = nil
    }
  }

  /// Waits for a reconcile in flight, so a background wake is released only after the phone's
  /// requests are enqueued or recorded.
  func settle() async {
    while let running { await running.value }
  }

  /// Sign-out forgets the pending offer with the account; the account's ledger file goes with its
  /// directory.
  func signOut() {
    running?.cancel()
    running = nil
    runAgain = false
    runAgainRetriesNetwork = false
    ledger = nil
    ledgerStamp = nil
    try? FileManager.default.removeItem(at: offerURL)
  }

  /// Call before the listener deletes a group on the wrist. A phone-sent group leaves a record, so
  /// the phone's repeated set does not download it again.
  func recordWristRemoval(of group: WatchDownloadGroup) {
    guard group.origin == .phone, model.session.context?.authenticatedStamp == group.accountStamp,
      loadLedger(for: group.accountStamp)
    else { return }
    ledger?.recordRemoval(of: group)
    saveLedger()
  }

  // MARK: Inventory

  /// The Audiobookshelf half of the inventory, for the signed-in account. Progress is left out
  /// while the app is not on screen: a suspended app gets no progress callbacks, so a fraction sent
  /// then would sit on the phone unchanged.
  func inventoryHalf(includingProgress: Bool) async -> WatchABSInventoryHalf? {
    guard let context = model.session.context else { return nil }
    let stamp = context.authenticatedStamp
    let groups = await accountGroups(context)
    guard model.session.context?.authenticatedStamp == stamp, loadLedger(for: stamp), let ledger else { return nil }
    var entries = ledger.inventoryEntries(groups: groups)
    if !includingProgress { entries = entries.map(Self.withoutProgress) }
    return WatchABSInventoryHalf(
      accountStamp: stamp, acknowledgedGeneration: ledger.acknowledgedGeneration, entries: entries)
  }

  // MARK: Reconcile

  private func reconcile(retryingNetworkFailures: Bool) async {
    guard let context = model.session.context else { return }
    let epoch = model.session.epoch
    let stamp = context.authenticatedStamp
    guard let installID = await model.episodes.currentInstallID(), isCurrent(epoch),
      loadLedger(for: stamp)
    else { return }
    acceptPendingOffer(installID: installID, stamp: stamp)
    let groups = await accountGroups(context)
    guard isCurrent(epoch),
      let plan = ledger?.reconcile(groups: groups, retryNetworkFailures: retryingNetworkFailures),
      let generation = plan.generation
    else { return }
    saveLedger()
    let held = Dictionary(groups.map { ($0.selection, $0) }) { first, _ in first }
    for action in plan.actions {
      guard isCurrent(epoch), !Task.isCancelled, await perform(action, held: held) else { return }
    }
    guard isCurrent(epoch), !Task.isCancelled else { return }
    ledger?.markApplied(generation: generation)
    saveLedger()
    WatchRSSDiagnostics.log(
      "abs_reconcile", ["generation": String(generation), "actions": String(plan.actions.count)])
    model.episodes.scheduleInventory()
  }

  /// Runs one step. `false` stops the reconcile without acknowledging: the session changed under
  /// it, and the next reconcile starts from the store again.
  private func perform(_ action: WatchABSRequestAction, held: [WatchSelection: WatchDownloadGroup]) async -> Bool {
    let downloads = model.downloadsController
    switch action {
    case .remove(let selection):
      if let group = held[selection.watchSelection] { await downloads.remove(group) }
      return true
    case .adopt(let selection, let revision):
      do { try await downloads.adopt(selection.watchSelection, revision: revision) } catch {
        Self.note("abs_adopt_failed")
      }
      return true
    case .retry(let entry):
      guard let group = held[entry.selection.watchSelection] else { return true }
      await downloads.readmit(group)
      guard group.manifestIDs.count < group.expectedTrackCount else { return true }
      return await fetch(entry)
    case .fetch(let entry):
      return await fetch(entry)
    }
  }

  private func fetch(_ entry: WatchABSOfferEntry) async -> Bool {
    let request = WatchABSEnqueueRequest(
      selection: entry.selection.watchSelection, title: entry.title, origin: .phone, phoneRevision: entry.revision)
    do {
      try await model.downloadsController.enqueue(request)
      ledger?.clearOutcome(for: entry.selection)
      return true
    } catch {
      guard let outcome = WatchABSRequestOutcome(error) else { return false }
      ledger?.record(outcome, for: entry.selection, revision: entry.revision)
      saveLedger()
      WatchRSSDiagnostics.log("abs_request_refused", ["revision": String(entry.revision)])
      return true
    }
  }

  /// Moves the offer on disk into the ledger. The file goes once the ledger holds the outcome, so an
  /// offer for another account or install, or an older one, is not applied again.
  private func acceptPendingOffer(installID: String, stamp: WatchAccountStamp) {
    guard let data = try? Data(contentsOf: offerURL) else { return }
    guard let offer = try? WatchWireCodec.decode(WatchABSSendOffer.self, from: data), var ledger else {
      try? FileManager.default.removeItem(at: offerURL)
      return
    }
    let acceptance = ledger.accept(offer, installID: installID, accountStamp: stamp)
    switch acceptance {
    case .accepted:
      self.ledger = ledger
      guard saveLedger() else { return }
    case .ignored(let reason):
      WatchRSSDiagnostics.log(
        "abs_offer_ignored", ["generation": String(offer.generation), "reason": reason.rawValue])
    }
    // A newer offer may have been saved meanwhile; it stays for the next reconcile.
    if pendingOfferGeneration() == offer.generation { try? FileManager.default.removeItem(at: offerURL) }
  }

  private func accountGroups(_ context: WatchSessionContext) async -> [WatchDownloadGroup] {
    let manifests = await context.downloadStore.allManifests()
    return WatchDownloadGroup.groups(from: manifests).filter { $0.accountStamp == context.authenticatedStamp }
  }

  private func isCurrent(_ epoch: Int) -> Bool { model.session.epoch == epoch && model.session.context != nil }

  // MARK: Storage

  private func ledgerFile(_ stamp: WatchAccountStamp) -> WatchABSRequestLedgerFile {
    let url = applicationSupport.appendingPathComponent("WatchAccounts", isDirectory: true)
      .appendingPathComponent(stamp.accountIdentityHash, isDirectory: true)
      .appendingPathComponent("ABSRequests", isDirectory: true)
      .appendingPathComponent("ledger.json")
    return WatchABSRequestLedgerFile(fileURL: url, accountStamp: stamp)
  }

  /// `false` only while the file cannot be read yet, as before first unlock. A corrupt file or one
  /// another account wrote starts afresh: the phone repeats its set until an inventory
  /// acknowledges it.
  private func loadLedger(for stamp: WatchAccountStamp) -> Bool {
    if ledgerStamp == stamp, ledger != nil { return true }
    do {
      ledger = try ledgerFile(stamp).load() ?? WatchABSRequestLedger()
    } catch .unavailable {
      return false
    } catch {
      Self.note("abs_ledger_reset")
      ledger = WatchABSRequestLedger()
    }
    ledgerStamp = stamp
    return true
  }

  @discardableResult
  private func saveLedger() -> Bool {
    guard let ledger, let ledgerStamp else { return false }
    do {
      try ledgerFile(ledgerStamp).save(ledger)
      return true
    } catch {
      Self.note("abs_ledger_write_failed")
      return false
    }
  }

  private func pendingOfferGeneration() -> UInt64 {
    guard let data = try? Data(contentsOf: offerURL),
      let offer = try? WatchWireCodec.decode(WatchABSSendOffer.self, from: data)
    else { return 0 }
    return offer.generation
  }

  private func persistOffer(_ data: Data) -> Bool {
    do {
      try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
      try data.write(to: offerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      Self.note("abs_offer_write_failed")
      return false
    }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var url = offerURL
    try? url.setResourceValues(values)
    return true
  }

  private static func withoutProgress(_ entry: WatchABSInventoryEntry) -> WatchABSInventoryEntry {
    guard entry.progress != nil else { return entry }
    return
      (try? WatchABSInventoryEntry(
        selection: entry.selection, revision: entry.revision, origin: entry.origin, state: entry.state,
        trackCount: entry.trackCount, completedTracks: entry.completedTracks, declineReason: entry.declineReason,
        failureReason: entry.failureReason, progress: nil, committedBytes: entry.committedBytes)) ?? entry
  }

  /// Only fixed event names enter system logs; no listener data can pass through this API.
  private nonisolated static func note(_ event: String) {
    logger.notice("\(event, privacy: .public)")
  }
}
