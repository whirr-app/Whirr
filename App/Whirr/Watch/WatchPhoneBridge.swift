import AppModel
import Foundation
import Persistence
import WatchConnectivity
import WatchProtocol

/// The process-lifetime WCSession ingress and router for every phone-side Watch endpoint.
///
/// `WCSessionDelegate` callbacks are nonisolated because WatchConnectivity may deliver them while
/// no scene or SwiftUI composition exists. The callback only extracts the bounded payload and hops
/// to this MainActor object, whose weak account binding is replaced at every account boundary.
@MainActor
final class WatchPhoneBridge: NSObject, WCSessionDelegate {
  nonisolated static let payloadKey = WatchTransportKey.payload
  /// Persisted only so `WatchCatalogueTransport`'s context dedup survives process death.
  private nonisolated static let contextTimestampKey = "watch.context.timestamp"

  typealias ReplyHandler = ([String: Any]) -> Void
  typealias CurrentSelection = @MainActor () -> CompanionSelection?
  typealias Completion =
    @MainActor (
      WatchCommand, CompanionPlaybackActionResult
    ) -> Void

  private let commandEndpoint: WatchPhoneCommandEndpoint
  private let bootstrap: @MainActor () -> Void
  private let isDatabaseAvailable: @MainActor () -> Bool
  var didBootstrap = false
  /// Reports received before the store could open. The Watch marks a report sent and never repeats
  /// it, so a drop loses that listen; the phone holds a few in memory until it can apply them, and
  /// a process exit before then still loses them.
  var heldNativeProgress: [Data] = []
  static let heldNativeProgressLimit = 8
  /// Prevents a second drain from interleaving with one already awaiting the inbox.
  var isDeliveringHeldNativeProgress = false
  var session: WCSession?
  private lazy var catalogueTransport = WatchCatalogueTransport(
    lastTimestamp: UserDefaults.standard.object(forKey: Self.contextTimestampKey) as? Date,
    isReady: { [weak self] in self?.isWatchInstalled == true },
    persistTimestamp: { UserDefaults.standard.set($0, forKey: Self.contextTimestampKey) },
    send: { [weak self] data in
      guard let session = self?.session else { return }
      try session.updateApplicationContext([WatchTransportKey.payload: data])
    })
  var onWatchAvailabilityChange: @MainActor (Bool) -> Void = { _ in }
  /// Every reachability report, so a visible setup screen can check the Watch the moment it can
  /// answer again.
  var onWatchReachabilityChange: @MainActor (Bool) -> Void = { _ in }

  /// Separates "no Watch paired" from "Watch paired without the Whirr app" so setup can tell the
  /// two apart. `isWatchInstalled` is the single flag the catalogue publisher gates on.
  var installState: WatchInstallState {
    guard let session, session.activationState == .activated else { return .unknown }
    guard session.isPaired else { return .unpaired }
    return session.isWatchAppInstalled ? .ready : .appNotInstalled
  }

  var isWatchInstalled: Bool { installState == .ready }

  /// Runtime supplies account composition and recovery hooks, not wire handlers.
  var artworkEndpoint: @MainActor () -> WatchPhoneArtworkEndpoint? = { nil }
  var artworkSync: @MainActor () -> WatchArtworkSyncPublisher? = { nil }
  var browseEndpoint: @MainActor () -> WatchPhoneBrowseEndpoint? = { nil }
  var handoffEndpoint: @MainActor () -> WatchPhoneHandoffEndpoint? = { nil }
  /// The process-lifetime episode sender and its inventory ingress. Both are device-owned, so they
  /// are composed from the database rather than the account graph.
  var episodeSend: @MainActor () -> WatchEpisodeSendPublisher? = { nil }
  var episodeInventoryInbox: @MainActor () -> WatchEpisodeInventoryInbox? = { nil }
  /// The native listen ingress, device-owned like the episode sender: a report is about a received
  /// copy, not about the bound account.
  var nativeProgressInbox: @MainActor () -> WatchNativeProgressInbox? = { nil }
  var authenticatedStamp: @MainActor () -> WatchAccountStamp? = { nil }
  /// Receives the Watch's latest playing report once it has passed the account check.
  var storePlayingReport: @MainActor (WatchPlayingReport) -> Void = { _ in }
  /// Receives the Watch's latest status report once it has passed the account check.
  var storeStatusReport: @MainActor (WatchStatusReport) -> Void = { _ in }
  var refreshCatalogue: @MainActor () -> Void = {}
  var pendingProgressInbox: @MainActor () -> WatchPendingProgressInbox? = { nil }

  func activate() {
    guard session == nil, WCSession.isSupported() else { return }
    let session = WCSession.default
    self.session = session
    session.delegate = self
    session.activate()
  }

  func publish(_ snapshot: WatchCatalogueSnapshot) {
    catalogueTransport.enqueue(snapshot)
  }

  /// The one place the context dedup timestamp reaches `UserDefaults`. Called when the app leaves
  /// the foreground; see `WatchCatalogueTransport.persistLastTimestamp`.
  func persistContextTimestamp() {
    catalogueTransport.persistLastTimestamp()
  }

  init(
    deduplicator: WatchCommandDeduplicator = WatchCommandDeduplicator(),
    bootstrap: @escaping @MainActor () -> Void = {
      AppRuntime.shared.start()
      PlaybackHardware.shared.noteHeadlessEntry()
    },
    isDatabaseAvailable: @escaping @MainActor () -> Bool = { DatabaseHardware.sharedIfAvailable() != nil },
    onCommandCompletion: @escaping Completion = { _, _ in },
    startReplyBound: Duration = .seconds(6)
  ) {
    self.commandEndpoint = WatchPhoneCommandEndpoint(
      deduplicator: deduplicator, onCommandCompletion: onCommandCompletion,
      startReplyBound: startReplyBound)
    self.bootstrap = bootstrap
    self.isDatabaseAvailable = isDatabaseAvailable
    super.init()
  }

  /// Marks playback the Watch caused, so the runtime never asks it to pause for its own command.
  var commandScope: WatchCommandScope { commandEndpoint.commandScope }
  var isBound: Bool { commandEndpoint.isBound }
  var isBusy: Bool { commandEndpoint.isBusy }
  var hasBootstrapped: Bool { didBootstrap }

  func bind(
    _ handler: any CompanionPlaybackActionHandling,
    accountStamp: WatchAccountStamp,
    currentSelection: @escaping CurrentSelection
  ) {
    commandEndpoint.bind(handler, accountStamp: accountStamp, currentSelection: currentSelection)
  }

  func unbind() { commandEndpoint.unbind() }

  /// Testable and App-owned entry point for the two WatchConnectivity receive callbacks.
  /// The reply carries the real outcome of the command, bounded by the endpoint's start reply bound.
  nonisolated func receive(
    message: [String: Any], replyHandler: @escaping ReplyHandler
  ) {
    if message[WatchHandoffRequest.transportKey] is Data {
      routeHandoff(message, replyHandler: replyHandler)
      return
    }
    // An application context carries whichever reports the Watch had; one update may hold both,
    // so both are routed rather than the first key winning.
    if let playing = message[WatchPlayingReport.transportKey] as? Data,
      message[WatchStatusReport.transportKey] is Data
    {
      deliver(playingReport: playing, statusReport: message[WatchStatusReport.transportKey] as? Data)
      return
    }
    if let report = message[WatchPlayingReport.transportKey] as? Data {
      deliver(playingReport: report)
      return
    }
    if let report = message[WatchStatusReport.transportKey] as? Data {
      deliver(statusReport: report)
      return
    }
    if message[WatchTransportKey.artworkRequest] is Data {
      routeArtwork(message, replyHandler: replyHandler)
      return
    }
    if message[WatchTransportKey.browseRequest] is Data {
      routeBrowse(message, replyHandler: replyHandler)
      return
    }
    guard let data = message[Self.payloadKey] as? Data else {
      // A malformed payload has no command id. An empty reply lets the Watch classify it as
      // malformed rather than wait and treat delivery as an ambiguous timeout.
      replyHandler([:])
      return
    }
    admitCommand(data, replyHandler: replyHandler)
  }

  private nonisolated func routeHandoff(
    _ message: [String: Any], replyHandler: @escaping ReplyHandler
  ) {
    route(
      message, key: WatchHandoffRequest.transportKey, limit: WatchHandoffRequest.maxWireBytes,
      replyHandler: replyHandler
    ) { bridge, data, reply in
      guard let endpoint = bridge.handoffEndpoint() else {
        reply([:])
        return
      }
      await endpoint.admit(data: data, replyHandler: reply)
    }
  }

  private nonisolated func routeArtwork(
    _ message: [String: Any], replyHandler: @escaping ReplyHandler
  ) {
    route(
      message, key: WatchTransportKey.artworkRequest, limit: WatchArtworkRequest.maxWireBytes,
      replyHandler: replyHandler
    ) { bridge, data, reply in
      guard let endpoint = bridge.artworkEndpoint() else {
        reply([:])
        return
      }
      await endpoint.receive(data, replyHandler: reply)
    }
  }

  private nonisolated func routeBrowse(
    _ message: [String: Any], replyHandler: @escaping ReplyHandler
  ) {
    route(
      message, key: WatchTransportKey.browseRequest, limit: WatchBrowseLimits.maxWireBytes,
      replyHandler: replyHandler
    ) { bridge, data, reply in
      guard let endpoint = bridge.browseEndpoint() else {
        reply([:])
        return
      }
      await endpoint.receive(data, replyHandler: reply)
    }
  }

  /// A playing report carries no reply. A report over its wire bound is dropped, and a Watch that
  /// cannot be reached republishes on its next transition.
  private nonisolated func deliver(playingReport report: Data) {
    guard report.count <= WatchPlayingReport.maxWireBytes else { return }
    Task { @MainActor [weak self] in self?.receivePlayingReport(report) }
  }

  private nonisolated func deliver(statusReport report: Data) {
    guard report.count <= WatchStatusReport.maxWireBytes else { return }
    Task { @MainActor [weak self] in self?.receiveStatusReport(report) }
  }

  /// One application-context update may carry both reports, so both are delivered from one hop to
  /// the main actor, in the order the Watch wrote them.
  private nonisolated func deliver(playingReport playing: Data, statusReport status: Data?) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.receivePlayingReport(playing)
      if let status { self.receiveStatusReport(status) }
    }
  }

  /// Commands have their own arrival path: no wire size bound beyond the message itself, and the
  /// headless graph must be bootstrapped before admission can run.
  private nonisolated func admitCommand(_ data: Data, replyHandler: @escaping ReplyHandler) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.ensureBootstrapped()
      await self.commandEndpoint.admit(data: data, replyHandler: replyHandler)
    }
  }

  /// One ingress discipline for the request/reply endpoints: extract the bounded payload, hop to
  /// the MainActor, bootstrap the headless graph once, and answer an empty reply when this process
  /// has no endpoint to answer with. Admission, deduplication and account fences stay in the
  /// endpoint.
  private nonisolated func route(
    _ message: [String: Any], key: String, limit: Int,
    replyHandler: @escaping ReplyHandler,
    endpoint: @escaping @MainActor (WatchPhoneBridge, Data, @escaping ReplyHandler) async -> Void
  ) {
    guard let data = message[key] as? Data, data.count <= limit else {
      replyHandler([:])
      return
    }
    Task { @MainActor [weak self] in
      guard let self else {
        replyHandler([:])
        return
      }
      self.ensureBootstrapped()
      await endpoint(self, data, replyHandler)
    }
  }

  /// Queues a cover-sync file for the Watch. WatchConnectivity sends it in the background and
  /// reports completion through `session(_:didFinish:error:)`.
  func transferArtworkFile(_ url: URL, kind: String) -> WatchArtworkTransferHandle? {
    guard let session, isWatchInstalled else { return nil }
    let transfer = session.transferFile(url, metadata: [WatchArtworkSyncTransport.fileKind: kind])
    return WatchArtworkTransferHandle(cancel: { transfer.cancel() })
  }

  /// Only the artwork outbox's own files, so a stray transfer in the outbox directory is the only
  /// kind it can adopt or prune.
  var outstandingArtworkFiles: Set<URL> {
    guard let session, session.activationState == .activated else { return [] }
    return Set(
      session.outstandingFileTransfers
        .filter { $0.file.metadata?[WatchArtworkSyncTransport.fileKind] != nil }
        .map(\.file.fileURL))
  }

  /// Queues an encoded offer. It has its own user-info key, so it never queues behind a cover
  /// file; user info survives suspension and is delivered in order.
  func sendEpisodeOffer(_ data: Data) -> Bool {
    guard let session, isWatchInstalled else { return false }
    session.transferUserInfo([WatchTransportKey.episodeSendOffer: data])
    return true
  }

  /// Queues an encoded Audiobookshelf offer under its own key, so the Watch reads it apart from the
  /// RSS offer and never as one (ADR 0021).
  func sendABSOffer(_ data: Data) -> Bool {
    guard let session, isWatchInstalled else { return false }
    session.transferUserInfo([WatchTransportKey.absSendOffer: data])
    return true
  }

  /// A want list that arrives before the account is bound, or before first unlock, is dropped;
  /// the Watch asks again.
  nonisolated func receive(userInfo: [String: Any]) {
    if let report = userInfo[WatchPendingProgressReport.transportKey] as? Data {
      guard report.count <= WatchPendingProgressReport.maxWireBytes else { return }
      Task { @MainActor [weak self] in self?.receivePendingProgress(report) }
      return
    }
    if let inventory = userInfo[WatchEpisodeInventory.transportKey] as? Data {
      // The Watch re-sends after every change, so a payload with no composed inbox (or one that
      // arrives before the store opens) is dropped rather than queued.
      guard inventory.count <= WatchEpisodeInventory.maxWireBytes else { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.ensureBootstrapped()
        guard self.didBootstrap else { return }
        await self.episodeInventoryInbox()?.receive(inventory, now: Date())
      }
      return
    }
    if let progress = userInfo[WatchNativeProgressReport.transportKey] as? Data {
      guard progress.count <= WatchNativeProgressReport.maxWireBytes else { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.holdNativeProgress(progress)
        await self.deliverHeldNativeProgress()
      }
      return
    }
    guard let data = userInfo[WatchArtworkSyncTransport.wantList] as? Data,
      data.count <= WatchArtworkWantList.maxWireBytes
    else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.ensureBootstrapped()
      guard let wantList = try? WatchWireCodec.decode(WatchArtworkWantList.self, from: data) else { return }
      self.artworkSync()?.receive(wantList)
    }
  }

  /// A report that arrives before the store can open, or before an account is bound, is dropped
  /// rather than queued: the Watch resends on its next change and answers a query at start.
  func receivePendingProgress(_ data: Data) {
    ensureBootstrapped()
    guard didBootstrap, let inbox = pendingProgressInbox(),
      let report = try? WatchWireCodec.decode(WatchPendingProgressReport.self, from: data)
    else { return }
    inbox.receive(report)
  }

  // MARK: WCSessionDelegate

  nonisolated func session(
    _: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
  ) {
    receive(message: message, replyHandler: replyHandler)
  }

  nonisolated func session(_: WCSession, didReceiveMessage message: [String: Any]) {
    receive(message: message, replyHandler: { _ in })
  }

  nonisolated func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    receive(userInfo: userInfo)
  }

  nonisolated func session(_: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
    let url = fileTransfer.file.fileURL
    Task { @MainActor [weak self] in
      if let publisher = self?.artworkSync() {
        publisher.transferFinished(url)
      } else if url.deletingLastPathComponent().standardizedFileURL
        == WatchArtworkSyncPublisher.defaultOutbox.standardizedFileURL
      {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  nonisolated func session(
    _: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?
  ) {
    Task { @MainActor [weak self] in self?.watchAvailabilityChanged() }
  }

  nonisolated func sessionWatchStateDidChange(_: WCSession) {
    Task { @MainActor [weak self] in self?.watchAvailabilityChanged() }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    let reachable = session.isReachable
    Task { @MainActor [weak self] in self?.watchReachabilityChanged(isReachable: reachable) }
  }

  func watchReachabilityChanged(isReachable: Bool) {
    onWatchReachabilityChange(isReachable)
    catalogueTransport.flush()
    if isReachable { refreshCatalogue() }
  }

  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    receive(message: applicationContext, replyHandler: { _ in })
  }

  nonisolated func sessionDidBecomeInactive(_: WCSession) {}

  nonisolated func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
  }

  private func watchAvailabilityChanged() {
    onWatchAvailabilityChange(isWatchInstalled)
    catalogueTransport.flush()
  }

  /// The store cannot open while its files are still protected (a wake before the first unlock
  /// since boot), so there is no graph to compose. Such a wake stays unbootstrapped, every
  /// endpoint answers through its unbound failure path, and the next message tries again.
  func ensureBootstrapped() {
    guard didBootstrap == false, isDatabaseAvailable() else { return }
    didBootstrap = true
    bootstrap()
    Task { @MainActor [weak self] in await self?.deliverHeldNativeProgress() }
  }

}
