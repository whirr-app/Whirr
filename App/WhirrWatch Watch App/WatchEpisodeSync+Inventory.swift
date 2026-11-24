import Foundation
import OSLog
import WatchConnectivity
import WatchPlayback
import WatchProtocol

/// What the Watch holds, and the inventory that tells the phone.
extension WatchEpisodeSync {
  /// Coalesces changes into one inventory; a restoring or signed-out Watch has nothing to report
  /// yet, except the signed-out report itself.
  func scheduleInventory() {
    guard accountState != .unknown else {
      WatchRSSDiagnostics.log("inventory_scheduled", ["skipped": "account_unknown"])
      return
    }
    inventoryPending = true
    inventoryGeneration &+= 1
    let generation = inventoryGeneration
    WatchRSSDiagnostics.log(
      "inventory_scheduled",
      ["generation": String(generation), "coalesced": inventoryTask == nil ? "no" : "yes"])
    inventoryTask?.cancel()
    inventoryTask = Task { [weak self] in
      try? await Task.sleep(for: Self.inventoryDelay)
      guard !Task.isCancelled, let self else { return }
      let delivered = await self.sendInventory()
      // A schedule made while this sent is still owed; its own task reports it.
      guard self.inventoryGeneration == generation else { return }
      self.inventoryTask = nil
      if delivered { self.inventoryPending = false }
    }
  }

  /// Deletes this copy and keeps a tombstone at its revision for the phone to acknowledge.
  func removeCopy(_ selection: WatchNativeSelection) async {
    guard let store = receivedEpisodeStore else { return }
    do {
      _ = try await store.remove(selection)
    } catch {
      Self.note("remove_failed")
    }
    await refreshReadyCopies()
    await retainJournalRows()
    scheduleInventory()
    // The store no longer wants this entry, so its task is cancelled rather than left to finish.
    rssDownloads.scheduleReconcile()
  }

  /// Whether `selection` is a native-feed episode whose file this account holds ready. An
  /// Audiobookshelf title plays from its own downloads, so it is never "ready" here.
  func hasReadyCopy(_ selection: WatchSelection) -> Bool {
    guard let native = WatchNativeSelection(selection) else { return false }
    return readyCopies.contains(native)
  }

  /// Re-reads the ready entries and the journal's newest listen for each, together, so the On My
  /// Watch and Continue screens never read either store themselves. The store keeps entries in
  /// memory, so this costs no file access; the journal reads its in-memory rows.
  func refreshReadyCopies() async {
    guard let store = receivedEpisodeStore else {
      if !readyCopies.isEmpty { readyCopies = [] }
      if !receivedEpisodes.isEmpty { receivedEpisodes = [] }
      if !nativeListens.isEmpty { nativeListens = [:] }
      model?.publishEpisodes()
      return
    }
    let entries = await store.entries()
    let ready = entries.filter { $0.state == .ready }
    let readySelections = Set(ready.map(\.selection))
    var listens: [WatchNativeSelection: WatchNativeListen] = [:]
    if let journal = nativeJournal {
      for selection in readySelections {
        if let listen = await journal.latest(for: selection) { listens[selection] = listen }
      }
    }
    let visible = entries.filter { $0.state != .removed }
    if readySelections != readyCopies { readyCopies = readySelections }
    if visible != receivedEpisodes { receivedEpisodes = visible }
    if listens != nativeListens { nativeListens = listens }
    model?.publishEpisodes()
  }

  /// An older phone sends no setting, and the phone setting defaults to on.
  var removesPlayedCopies: Bool { model?.companion.snapshot?.removePlayedNativeEpisodes != false }

  /// Reports what the Watch holds. Returns whether the inventory was handed to WatchConnectivity,
  /// so a caller that owes the phone one knows whether it can stop.
  @discardableResult
  func sendInventory() async -> Bool {
    guard accountState != .unknown, canSend() else {
      let reason = accountState == .unknown ? "account_unknown" : "cannot_send"
      WatchRSSDiagnostics.log("inventory_not_sent", Self.transportFields(reason))
      return false
    }
    guard let installStore = resolvedInstallStore(),
      let installID = try? await installStore.installID(),
      let sequence = try? await installStore.nextInventorySequence()
    else {
      WatchRSSDiagnostics.log("inventory_not_sent", ["reason": "install_unavailable"])
      Self.note("inventory_unavailable")
      return false
    }
    let store: WatchReceivedEpisodeStore? = accountState == .signedIn ? receivedEpisodeStore : nil
    let entries: [WatchReceivedEpisode]
    let acknowledged: UInt64
    if let store {
      let stored = await store.entries()
      entries = isAppActive() ? stored : stored.map { Self.withoutProgress($0) }
      acknowledged = await store.appliedGeneration
    } else {
      entries = []
      acknowledged = 0
    }
    let budget = store == nil ? nil : context?.storageBudget
    // The Audiobookshelf half rides the same inventory, and only from a signed-in Watch.
    let abs = store == nil ? nil : await model?.absRequests.inventoryHalf(includingProgress: isAppActive())
    guard
      let inventory = try? WatchEpisodeInventoryPlan.make(
        installID: installID, sequence: sequence, acknowledgedGeneration: acknowledged,
        acceptsCopies: store != nil, entries: entries, abs: abs,
        totalBytes: budget?.totalBytes ?? Self.defaultBudgetBytes,
        usedBytes: budget?.usedBytes ?? 0, observedAt: clock())
    else {
      WatchRSSDiagnostics.log(
        "inventory_not_sent", ["reason": "plan_invalid", "sequence": String(sequence)])
      Self.note("inventory_invalid")
      return false
    }
    guard canSend() else {
      WatchRSSDiagnostics.log("inventory_not_sent", Self.transportFields("cannot_send"))
      return false
    }
    guard let data = try? WatchWireCodec.encode(inventory) else {
      WatchRSSDiagnostics.log(
        "inventory_not_sent", ["reason": "encode_failed", "sequence": String(sequence)])
      return false
    }
    send([WatchTransportKey.episodeInventory: data])
    WatchRSSDiagnostics.log(
      "inventory_sent",
      [
        "sequence": String(sequence), "entries": String(entries.count),
        "absEntries": String(inventory.absEntries?.count ?? 0),
        "acceptsCopies": store == nil ? "no" : "yes",
      ])
    return true
  }

  private static func withoutProgress(_ entry: WatchReceivedEpisode) -> WatchReceivedEpisode {
    var entry = entry
    entry.progress = nil
    return entry
  }
}
