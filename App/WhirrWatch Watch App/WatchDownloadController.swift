import Foundation
import Observation
import WatchPlayback
import WatchProtocol

@MainActor
@Observable
final class WatchDownloadController {
  private unowned let model: WatchLibraryModel
  private var context: WatchSessionContext? { model.session.context }
  var downloadLabels: [String: String] = [:] { didSet { model.publishDownload() } }
  var downloads: [WatchDownloadManifest] = [] {
    didSet {
      model.publishDownload()
      scheduleInventoryIfChanged()
    }
  }
  @ObservationIgnored lazy var network = WatchNetworkStatus { [weak model] in
    Task { @MainActor [weak model] in await model?.downloadsController.networkChanged() }
  }
  private var account: WatchAccountRecord? { context?.account ?? model.account }
  private var authenticatedStamp: WatchAccountStamp? {
    context?.authenticatedStamp ?? (try? account?.authenticatedStamp())
  }
  private var busy: Bool { model.busy }
  private var message: String? {
    get { model.message }
    set { model.setMessage(newValue) }
  }
  private var sessionEpoch: Int { model.session.epoch }
  private var service: ABSWatchLibraryService? { context?.service }
  private var downloadStore: WatchDownloadStore? { context?.downloadStore }
  private var downloadManager: WatchDownloadManager? { context?.downloadManager }
  private var currentSelection: WatchSelection? { model.playback.currentSelection }
  @ObservationIgnored private let enqueuer = WatchABSEnqueuer()
  /// What the phone last could have heard about the groups; a change schedules an inventory.
  @ObservationIgnored private var reportedGroups: [String] = []

  init(model: WatchLibraryModel) { self.model = model }

  var groups: [WatchDownloadGroup] { WatchDownloadGroup.groups(from: downloads) }

  func presentation(for group: WatchDownloadGroup) -> WatchDownloadRowPresentation {
    WatchDownloadRowPresentation(group: group, manifests: downloads, labels: downloadLabels)
  }

  func play(group: WatchDownloadGroup) async {
    guard group.accountStamp == (try? model.account?.authenticatedStamp()) else { return }
    await model.playback.play(group.selection)
  }

  /// Acts on the rows that already exist before touching the network. A Wi-Fi-held group is
  /// already fully planned, so re-fetching the item detail first only risks replacing the retry
  /// with an unrelated failure message.
  func retry(group: WatchDownloadGroup) async {
    guard group.accountStamp == (try? model.account?.authenticatedStamp()) else { return }
    await readmit(group)
    if group.manifestIDs.count < group.expectedTrackCount {
      await download(
        group.selection, title: presentation(for: group).title, origin: group.origin,
        phoneRevision: group.phoneRevision)
    }
    await reloadDownloads()
    // A tap must never be silent: say so when the row could not be moved.
    if downloads.contains(where: {
      group.manifestIDs.contains($0.id) && $0.state == .queued && $0.failureReason == .waitingForWiFi
    }) {
      WatchDiagnostics.record(.downloadUnavailable)
      message = "Couldn’t start this download. Connect the Watch to Wi-Fi and try again."
    }
  }

  /// Re-admits every file of the group as an explicit request, which bypasses the Wi-Fi signal.
  /// The wrist's Retry and the phone's Try Again both come here; it sets no message.
  func readmit(_ group: WatchDownloadGroup) async {
    for id in group.manifestIDs {
      guard group.accountStamp == (try? model.account?.authenticatedStamp()) else { return }
      guard let manifest = downloads.first(where: { $0.id == id }) else { continue }
      switch manifest.state {
      case .failed:
        await retryDownload(id)
      case .paused:
        // `retry` only leaves `failed`; a paused row has to be resumed or the transition throws
        // and the tap does nothing at all.
        await downloadManager?.resume(id: id)
      case .queued:
        // A Wi-Fi-held row is still queued, so `retry` would reject that transition too. Ask the
        // manager to admit it as an explicit request, which bypasses the Wi-Fi signal.
        await downloadManager?.startDownload(id: id, userInitiated: true)
      case .downloading, .completed:
        continue
      }
    }
    await reloadDownloads()
  }

  /// The wrist's Delete. A phone-sent download removed here stays removed until the phone sends it
  /// again.
  func delete(group: WatchDownloadGroup) async {
    guard group.accountStamp == (try? model.account?.authenticatedStamp()) else { return }
    model.absRequests.recordWristRemoval(of: group)
    await remove(group)
  }

  /// Deletes every file of the group, stopping its playback first. A removal the phone asked for
  /// comes here directly, leaving no record of a removal on the wrist.
  func remove(_ group: WatchDownloadGroup) async {
    guard group.accountStamp == (try? model.account?.authenticatedStamp()) else { return }
    for id in group.manifestIDs {
      guard group.accountStamp == (try? model.account?.authenticatedStamp()) else { return }
      await deleteDownload(id)
    }
  }

  func reset() {
    downloads = []
    downloadLabels = [:]
  }

  func reloadDownloads() async {
    let token = sessionEpoch
    let manifests = await downloadStore?.allManifests() ?? []
    guard token == sessionEpoch else { return }
    downloads = manifests
  }

  /// Re-admits rows parked by the Wi-Fi policy. `networkChanged` only fires on a path change, so
  /// a row held while the path was already settled would otherwise wait forever.
  private func driveHeldTransfers() async {
    guard network.isWiFiAvailable else { return }
    for manifest in downloads where manifest.state == .queued && manifest.failureReason == .waitingForWiFi {
      await downloadManager?.startDownload(id: manifest.id)
    }
  }

  /// Called when the Downloads screen appears, so a stale hold clears without a path change.
  func refreshDownloads() async {
    await reloadDownloads()
    await driveHeldTransfers()
    await reloadDownloads()
  }

  func deleteDownload(_ id: UUID) async {
    if let manifest = downloads.first(where: { $0.id == id }), manifest.selection == currentSelection {
      await model.playback.stopPlayback()
    }
    await downloadManager?.delete(id: id)
    downloadLabels.removeValue(forKey: id.uuidString)
    persistDownloadLabels()
    await reloadDownloads()
  }

  /// The wrist's Download. A file the store already holds is skipped, so a tap on a title the phone
  /// is already sending adds nothing and reports no failure.
  func download(
    _ selection: WatchSelection, title: String? = nil, origin: WatchABSOrigin = .watch,
    phoneRevision: UInt64? = nil
  ) async {
    guard !busy, service != nil, account != nil, downloadManager != nil, case .audiobookshelf = selection else {
      return
    }
    model.setBusy(.downloading)
    defer { model.setBusy(nil) }
    let request = WatchABSEnqueueRequest(
      selection: selection, title: title ?? model.catalogue.title(for: selection), origin: origin,
      phoneRevision: phoneRevision)
    do {
      _ = try await enqueue(request)
      message = nil
    } catch {
      // A superseded or cancelled request is not the listener's failure.
      guard let outcome = WatchABSRequestOutcome(error) else { return }
      WatchDiagnostics.record(.downloadUnavailable)
      message =
        outcome == .declined(.storageFull)
        ? "Not enough space on Watch. Remove a download and retry."
        : "Couldn’t download this title. Try again."
    }
  }

  /// The shared detail, plan, admission and enqueue step. Leaves `busy` and `message`
  /// to the caller, so the phone's driver touches neither.
  @discardableResult
  func enqueue(_ request: WatchABSEnqueueRequest) async throws -> [UUID] {
    guard let service, let account, let downloadStore, let downloadManager else {
      throw WatchLibraryError.notAuthenticated
    }
    let token = sessionEpoch
    let context = WatchABSEnqueueContext(
      service: service, account: account, store: downloadStore, manager: downloadManager,
      budget: self.context?.storageBudget)
    do {
      let ids = try await enqueuer.enqueue(
        request, in: context, isCurrent: { [weak model] in model?.session.epoch == token },
        label: { [weak self] id, title in self?.setLabel(title, for: id) })
      await reloadDownloads()
      return ids
    } catch {
      await reloadDownloads()
      throw error
    }
  }

  /// Makes the selection's files the phone's, at `revision`.
  func adopt(_ selection: WatchSelection, revision: UInt64) async throws {
    guard let downloadStore else { throw WatchLibraryError.notAuthenticated }
    try await downloadStore.adopt(selection: selection, revision: revision)
    await downloadManager?.refresh()
  }

  private func setLabel(_ title: String?, for id: UUID) {
    if let title {
      downloadLabels[id.uuidString] = String(title.prefix(160))
    } else {
      downloadLabels.removeValue(forKey: id.uuidString)
    }
    persistDownloadLabels()
  }

  /// The inventory's Audiobookshelf half reads the groups, so a change in what it would say
  /// schedules one. Progress counts only by the tenth, as for RSS episodes: each inventory is a
  /// `transferUserInfo` to the phone.
  private func scheduleInventoryIfChanged() {
    let summary = groups.map { group in
      let tenth = group.progress.map { Int(($0 * 10).rounded(.down)) } ?? -1
      return "\(group.id)|\(group.state)|\(group.completedTrackCount)|\(group.phoneRevision ?? 0)|\(tenth)"
    }
    guard summary != reportedGroups else { return }
    reportedGroups = summary
    model.episodes.scheduleInventory()
  }

  func retryDownload(_ id: UUID) async {
    await downloadManager?.retry(id: id)
    await reloadDownloads()
  }

  func networkChanged() async {
    guard network.isWiFiAvailable else { return }
    model.absRequests.scheduleReconcile(retryingNetworkFailures: true)
    await driveHeldTransfers()
    await reloadDownloads()
    await model.offlineSync.reconcileOfflineProgress()
  }

  func resumeBackgroundSession(identifier: String, completion: @escaping @Sendable () -> Void) async {
    await model.session.initialize()
    guard let downloadManager, downloadManager.sessionIdentifier == identifier else {
      completion()
      return
    }
    downloadManager.handleBackgroundEvents(completionHandler: completion)
  }

  func downloadName(_ manifest: WatchDownloadManifest) -> String {
    downloadLabels[manifest.id.uuidString] ?? "Downloaded title"
  }

  // MARK: Labels

  static let labelsKeyPrefix = "watch.download.labels."
  /// False while the account's saved labels exist but could not be read (before first unlock).
  /// A write then would replace every saved title with the few known in memory.
  @ObservationIgnored private var labelsSettled = true

  private static func labelsKey(_ stamp: WatchAccountStamp) -> String {
    labelsKeyPrefix + stamp.accountIdentityHash
  }

  private func readLabels(_ stamp: WatchAccountStamp) -> WatchProtectedRead<[String: String]> {
    model.protectedStore.read(key: Self.labelsKey(stamp)) {
      try JSONDecoder().decode([String: String].self, from: $0)
    }
  }

  func restoreLabels(for stamp: WatchAccountStamp) {
    let read = readLabels(stamp)
    labelsSettled = read.isSettled
    downloadLabels = read.value ?? [:]
  }

  func persistDownloadLabels() {
    guard let stamp = authenticatedStamp else { return }
    if !labelsSettled {
      let read = readLabels(stamp)
      guard read.isSettled else { return }
      labelsSettled = true
      // Titles learned while the file was unreadable win over the saved ones.
      downloadLabels = (read.value ?? [:]).merging(downloadLabels) { _, memory in memory }
    }
    guard let data = try? JSONEncoder().encode(downloadLabels) else { return }
    do { try model.protectedStore.save(data, key: Self.labelsKey(stamp)) } catch {
      WatchDiagnostics.record(.protectedStateWriteFailed)
    }
  }

  /// Sign-out removes every account's labels, whether or not a session was configured.
  func clearAllLabels() {
    try? model.protectedStore.clear(keysWithPrefix: Self.labelsKeyPrefix)
    labelsSettled = true
  }
}
