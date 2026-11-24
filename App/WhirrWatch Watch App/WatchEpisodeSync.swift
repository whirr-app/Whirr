import Foundation
import OSLog
import WatchConnectivity
import WatchPlayback
import WatchProtocol

/// The Watch's native-RSS episodes: offer admission, the Watch's own downloads, inventory and
/// native progress. `WatchLibraryModel` owns one for the life of the app; the account's stores
/// live in `WatchSessionContext`, so a signed-out Watch holds none and reports `acceptsCopies:
/// false` until the next sign-in re-offers the set.
///
/// Everything the phone sends is `transferUserInfo`, which WatchConnectivity queues and delivers
/// across relaunches. The audio does not cross that boundary: the Watch downloads the offer's
/// enclosure URL itself (ADR 0020 Decision 1).
@MainActor
final class WatchEpisodeSync {
  /// `unknown` while launch's account restore is still running: reporting then would tell the phone
  /// the Watch takes no copies before it has read the sign-in.
  enum AccountState: Equatable {
    case unknown
    case signedIn
    case signedOut
  }

  /// The app-wide install identity, the pending offer and the RSS download staging. Application
  /// Support, never Caches: an offer or a file the listener asked for must not be evicted while
  /// idle.
  ///
  /// watchOS is the only platform this app runs on, so every other build is the host regression
  /// harness: it gets a per-process temporary root rather than the Mac's own Application Support.
  nonisolated static var applicationSupportDirectory: URL {
    #if os(watchOS)
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    #else
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "watch-episode-sync-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    #endif
  }

  /// A day is long enough that a slow delivery is not thrown away, and short enough that a file a
  /// replaced build left behind is not held forever.
  static let inboxRetention: TimeInterval = 24 * 60 * 60
  /// Several changes in one apply (offers, commits, removals) become one inventory.
  static let inventoryDelay = Duration.seconds(1)
  static let defaultBudgetBytes: Int64 = 2_000_000_000

  private nonisolated static let logger = Logger(
    subsystem: "com.remoteconcern.whirr.watchkitapp", category: "episodeSync")

  weak var model: WatchLibraryModel?
  let applicationSupport: URL
  let clock: @MainActor () -> Date
  let canSend: @MainActor () -> Bool
  let send: @MainActor ([String: Any]) -> Void

  var accountState: AccountState = .unknown
  private var installStore: WatchEpisodeInstallStore?
  var ingressTask: Task<Void, Never>?
  var ingressGeneration = 0
  var inventoryTask: Task<Void, Never>?
  var inventoryGeneration = 0
  /// An inventory is owed to the phone: a change was recorded and the debounced send has not run.
  var inventoryPending = false
  var didPurgeInbox = false

  /// Called with the selections whose playable copy an applied offer dropped, so playback stops one
  /// that is playing; a re-admitted selection appears here too.
  var onCopiesDropped: @MainActor ([WatchNativeSelection]) -> Void = { _ in }

  /// Whether Whirr is on screen. A suspended app gets no progress callbacks while the system
  /// downloads, so a fraction sent from the background would sit on the phone unchanged until the
  /// download finished; the inventory reports no fraction then, and the phone shows a spinner.
  var isAppActive: @MainActor () -> Bool = { true }

  /// The copies that can play now, as the store has them. Read synchronously when a start asks the
  /// machine for `hasLocalCopy`, and refreshed after everything that changes the store.
  var readyCopies: Set<WatchNativeSelection> = []

  /// Every non-removed received entry, newest offer first, and the journal's newest listen for each
  /// ready selection. Refreshed beside `readyCopies` so a view never reads the store, and published
  /// through `WatchLibraryModel` for the On My Watch and Continue screens.
  var receivedEpisodes: [WatchReceivedEpisode] = []
  var nativeListens: [WatchNativeSelection: WatchNativeListen] = [:]

  init(
    model: WatchLibraryModel,
    applicationSupport: URL = WatchEpisodeSync.applicationSupportDirectory,
    clock: @escaping @MainActor () -> Date = Date.init,
    canSend: @escaping @MainActor () -> Bool = { WCSession.default.activationState == .activated },
    send: @escaping @MainActor ([String: Any]) -> Void = { _ = WCSession.default.transferUserInfo($0) }
  ) {
    self.model = model
    self.applicationSupport = applicationSupport
    self.clock = clock
    self.canSend = canSend
    self.send = send
  }

  /// The Watch's own RSS downloads. One driver for the app's life; the store it writes into comes
  /// from the current session, so a sign-out cancels its tasks rather than retargeting them.
  private(set) lazy var rssDownloads = WatchRSSDownloadDriver(
    rootURL: applicationSupport.appendingPathComponent("RSSDownloads", isDirectory: true),
    networkPolicy: { [weak self] in
      guard let store = self?.context?.downloadStore else { return .wifiOnly }
      return await store.networkPolicy
    },
    store: { [weak self] in self?.receivedEpisodeStore },
    didProgress: { [weak self] in
      guard let self else { return }
      await self.refreshReadyCopies()
    },
    didChange: { [weak self] in
      guard let self else { return }
      await self.episodeStoreChanged()
    })

  var context: WatchSessionContext? { model?.session.context }
  var receivedEpisodeStore: WatchReceivedEpisodeStore? { context?.receivedEpisodes }
  var nativeJournal: WatchNativeProgressJournal? { context?.nativeJournal }
  var inboxDirectory: URL {
    WatchReceivedEpisodeInbox.directory(applicationSupport: applicationSupport)
  }
  var offerURL: URL { applicationSupport.appendingPathComponent("WatchEpisodeOffer.json") }
  private var installURL: URL { applicationSupport.appendingPathComponent("WatchEpisodeInstall.json") }

  // MARK: Account readiness

  /// The session published a context, so the account can take copies again.
  func accountReady() {
    accountState = .signedIn
    WatchRSSDiagnostics.log(
      "episodes_account_ready", ["store": receivedEpisodeStore == nil ? "no" : "yes"])
    // The feature sits out this session when its storage cannot open; ABS still runs.
    if receivedEpisodeStore == nil { Self.note("received_episodes_unavailable") }
    scheduleIngress()
    scheduleInventory()
    rssDownloads.scheduleReconcile()
  }

  /// Launch's restore concluded with no usable account. Copies cannot play, and the phone parks the
  /// set as "Waiting for your Watch" until an inventory after sign-in says otherwise.
  func accountSignedOut() {
    accountState = .signedOut
    WatchRSSDiagnostics.log("episodes_account_signed_out")
    scheduleInventory()
    // A signed-out Watch must not keep downloading an earlier account's offers.
    Task { [weak self] in
      guard let self else { return }
      await self.rssDownloads.stop()
    }
  }

  // MARK: Suspension

  /// How long a background run stays up for a new download's first bytes. Inside the WatchKit
  /// task's own expiry and the delegate's twenty-second fallback.
  static let transferStartHold = Duration.seconds(10)

  /// `settleForSuspension`, then held until a download resumed in the background has started, then
  /// settled again so the phone learns it is downloading before watchOS suspends the app.
  func settleAndAwaitTransferStart() async {
    await settleForSuspension()
    await rssDownloads.awaitTransferStart(within: Self.transferStartHold)
    await settleForSuspension()
  }

  /// Hands over everything a sleep would otherwise lose: the ingress chain, the Watch's own
  /// downloads, and an inventory a debounce still holds. A background wake releases its WatchKit
  /// task only after this returns, so the offer's download task exists and the phone has the
  /// outcome before watchOS suspends the app. Whatever this sends is queued `transferUserInfo`,
  /// which WatchConnectivity delivers across the suspension.
  func settleForSuspension() async {
    WatchRSSDiagnostics.log("settle_start", ["inventoryPending": inventoryPending ? "yes" : "no"])
    // Each schedule awaits the one before it, so awaiting the newest runs the whole chain.
    while let ingress = ingressTask {
      await ingress.value
    }
    await rssDownloads.settle()
    await model?.absRequests.settle()
    guard inventoryPending else {
      WatchRSSDiagnostics.log("settle_end", ["inventory": "none"])
      return
    }
    inventoryTask?.cancel()
    inventoryTask = nil
    // A send that cannot go out now leaves the inventory owed, for the next wake or launch.
    let generation = inventoryGeneration
    let sent = await sendInventory()
    if sent, inventoryGeneration == generation { inventoryPending = false }
    WatchRSSDiagnostics.log("settle_end", ["inventory": sent ? "sent" : "owed"])
  }

  /// A download changed the store: republish the rows the screens read and tell the phone.
  private func episodeStoreChanged() async {
    await refreshReadyCopies()
    scheduleInventory()
  }

  // MARK: Native progress and sign-out

  /// Sends the closed rows the phone has not heard. A row is marked reported only after the send is
  /// handed to WatchConnectivity, which delivers queued transfers across relaunches.
  func reportNativeProgress(excludingOpenRows openIDs: Set<UUID>) async {
    guard canSend(), let journal = nativeJournal else { return }
    guard let entries = try? await journal.pendingReport(excluding: openIDs), !entries.isEmpty else {
      return
    }
    guard let installStore = resolvedInstallStore(),
      let installID = try? await installStore.installID(),
      let sequence = try? await installStore.nextProgressSequence(),
      let report = try? WatchNativeProgressReport(
        watchInstallID: installID, sequence: sequence, entries: entries),
      let data = try? WatchWireCodec.encode(report)
    else {
      Self.note("progress_report_failed")
      return
    }
    guard canSend() else { return }
    send([WatchTransportKey.nativeProgressReport: data])
    do {
      try await journal.markReported(entries)
    } catch {
      Self.note("progress_mark_failed")
    }
    // The rows just moved: republish the listens the On My Watch and Continue screens read.
    await refreshReadyCopies()
  }

  /// Sign-out clears the copies this account fenced, after one last progress report so a finished
  /// Watch listen still reaches the phone (ADR 0019 decision 5). The phone re-sends after
  /// sign-in.
  func signOut() async {
    WatchRSSDiagnostics.log("episodes_sign_out")
    inventoryTask?.cancel()
    inventoryTask = nil
    inventoryPending = false
    ingressTask?.cancel()
    ingressTask = nil
    await reportNativeProgress(excludingOpenRows: [])
    // The queued tasks belong to the account that admitted them.
    await rssDownloads.stop()
    if let store = receivedEpisodeStore { try? await store.removeAll() }
    if let journal = nativeJournal { try? await journal.removeAll() }
    readyCopies = []
    receivedEpisodes = []
    nativeListens = [:]
    model?.publishEpisodes()
    WatchReceivedEpisodeInbox.removeAll(directory: inboxDirectory)
    removeOffer()
    accountState = .signedOut
    await sendInventory()
  }

  /// The install identity received copies are fenced by. `nil` when the app-wide store cannot be
  /// opened, which leaves the feature out of this session rather than failing it.
  func currentInstallID() async -> String? {
    guard let store = resolvedInstallStore() else { return nil }
    return try? await store.installID()
  }

  // MARK: Storage helpers

  /// Drops journal rows whose copy is gone, except an unreported finish the phone still needs.
  func retainJournalRows() async {
    guard let store = receivedEpisodeStore, let journal = nativeJournal else { return }
    let entries = await store.entries()
    let kept = Set(entries.filter { $0.state != .removed }.map(\.selection))
    do {
      try await journal.retainOnly(kept)
    } catch {
      Self.note("journal_retain_failed")
    }
  }

  func resolvedInstallStore() -> WatchEpisodeInstallStore? {
    if let installStore { return installStore }
    do {
      let store = try WatchEpisodeInstallStore(fileURL: installURL)
      installStore = store
      return store
    } catch {
      Self.note("install_identity_unavailable")
      return nil
    }
  }

  /// What an inventory's send depends on, so a line says why it did not go. `isReachable` is read
  /// on the Watch only: the host harness has no paired device.
  static func transportFields(_ reason: String) -> [String: String] {
    var fields = [
      "reason": reason, "activationState": activationName(WCSession.default.activationState),
    ]
    #if os(watchOS)
      fields["isReachable"] = WCSession.default.isReachable ? "yes" : "no"
    #endif
    return fields
  }

  private static func activationName(_ state: WCSessionActivationState) -> String {
    switch state {
    case .notActivated: return "not_activated"
    case .activated: return "activated"
    #if os(watchOS)
      case .inactive: return "inactive"
    #endif
    @unknown default: return "unknown"
    }
  }

  /// Only fixed event names enter system logs; no listener data can pass through this API.
  nonisolated static func note(_ event: String) {
    logger.notice("\(event, privacy: .public)")
  }
}
