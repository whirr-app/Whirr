import Foundation
import WatchConnectivity
import WatchKit
import WatchPlayback
import WatchProtocol

@MainActor
final class WatchBackgroundDelegate: NSObject, WKApplicationDelegate, WCSessionDelegate {
  let session = WCSession.default
  let store = WatchCompanionStore(store: .production)
  lazy var library = WatchLibraryModel(companion: store, protectedStore: .production)
  /// One disk cache for covers: rows read it, and the sync receiver writes pushed covers to it.
  private let artworkCache = WatchArtworkStore.makeCache()
  lazy var artwork: WatchArtworkStore = {
    let artwork = WatchArtworkStore(cache: artworkCache)
    artwork.syncedManifest = { [weak self] in self?.artworkSync.manifest }
    return artwork
  }()
  lazy var artworkSync: WatchArtworkSyncReceiver = {
    let receiver = WatchArtworkSyncReceiver(
      cache: artworkCache,
      phoneStamp: { [weak self] in self?.store.snapshot?.accountStamp },
      canSend: { [weak self] in self?.session.activationState == .activated },
      send: { [weak self] wantList in self?.send(wantList) })
    receiver.onManifest = { [weak self] manifest in self?.artwork.learnSyncedRevisions(from: manifest) }
    receiver.onCovers = { [weak self] keys in self?.artwork.syncedCoversArrived(keys) }
    return receiver
  }()
  /// Native-RSS ingress. `WatchLibraryModel` owns one for the life of the app.
  var episodes: WatchEpisodeSync { library.episodes }

  var pendingRefreshTasks: [ObjectIdentifier: WKWatchConnectivityRefreshBackgroundTask] = [:]
  var urlTasks: [ObjectIdentifier: WKURLSessionRefreshBackgroundTask] = [:]
  var refreshExpiration: Task<Void, Never>?
  /// The grace a wake that delivered nothing waits before releasing. It is the only reason a wake
  /// waits less than the twenty-second fallback.
  var refreshGrace: Task<Void, Never>?
  var wake = WatchRefreshWake()
  var settlingRefreshTasks = false
  var holdingOutsideWake = false
  var outsideWakeNeedsAnotherPass = false
  private var observesContentPending = false
  static let refreshGracePeriod = Duration.seconds(5)

  override init() {
    super.init()
    WatchRSSDiagnostics.log("launch")
    session.delegate = self
    session.addObserver(self, forKeyPath: "hasContentPending", options: [.initial, .new], context: nil)
    observesContentPending = true
    session.activate()
    // Files an earlier launch received but did not finish ingesting.
    artworkSync.process()
    // An offer or an audio file may have arrived before the account was restored; both are applied
    // once it is, and both no-op until then.
    episodes.isAppActive = { WKApplication.shared().applicationState == .active }
    episodes.prepareForLaunch()
  }

  private func send(_ wantList: WatchArtworkWantList) {
    guard session.activationState == .activated, let data = try? WatchWireCodec.encode(wantList) else { return }
    session.transferUserInfo([WatchArtworkSyncTransport.wantList: data])
  }

  /// WatchConnectivity deletes the file when this returns, so it is moved synchronously. Episode
  /// audio no longer arrives this way (ADR 0020): the Watch downloads the enclosure itself, so
  /// every remaining file belongs to the artwork pipeline.
  nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
    WatchArtworkSyncReceiver.accept(file)
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.artworkSync.process()
      self.refreshContentReceived(.file)
    }
  }

  /// Offers arrive as user info in every build. WatchConnectivity hands the refresh task over
  /// before it delivers this callback, so the delivery is what ends a wake's hold.
  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    let offer = userInfo[WatchTransportKey.episodeSendOffer] as? Data
    let absOffer = userInfo[WatchTransportKey.absSendOffer] as? Data
    let content = WatchRefreshWake.content(in: userInfo)
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let offer { self.episodes.receiveOffer(offer) }
      if let absOffer { self.library.absRequests.receiveOffer(absOffer) }
      self.refreshContentReceived(content)
    }
  }

  isolated deinit {
    refreshExpiration?.cancel()
    refreshGrace?.cancel()
    if observesContentPending {
      session.removeObserver(self, forKeyPath: "hasContentPending")
    }
  }

  func consumeCurrentContext() {
    guard session.activationState == .activated else { return }
    store.consumeReceivedApplicationContext(session.receivedApplicationContext)
    drainRefreshTasksIfReady()
  }

  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    guard activationState == .activated else { return }
    let reachable = session.isReachable
    let context = session.receivedApplicationContext
    let payload = context[WatchTransportKey.payload] as? Data
    let malformed = !context.isEmpty && payload == nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      // The store may have been built before activation finished, when it read the phone as
      // unreachable; no reachability callback follows if the state never flips.
      self.store.reachabilityChanged(reachable)
      self.store.receiveLivePayload(payload, malformed: malformed)
      self.artworkSync.process()
      // A Watch that changed while the phone was away reports as soon as it can send; a restoring
      // account stays silent until `accountReady`.
      self.episodes.scheduleIngress()
      self.episodes.scheduleInventory()
      await self.library.peerDidReconnect()
      self.drainRefreshTasksIfReady()
    }
  }

  nonisolated func session(
    _ session: WCSession,
    didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    let payload = applicationContext[WatchTransportKey.payload] as? Data
    let malformed = !applicationContext.isEmpty && payload == nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.store.receiveLivePayload(payload, malformed: malformed)
      self.artworkSync.process()
      await self.library.peerDidSendContext()
      self.refreshContentReceived(.applicationContext)
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    let reachable = session.isReachable
    Task { @MainActor [weak self] in
      guard let self else { return }
      // Both directions: losing the phone must disable remote transport.
      self.store.reachabilityChanged(reachable)
      guard reachable else { return }
      await library.initialize()
      await library.peerDidReconnect()
    }
  }

  nonisolated func session(
    _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
  ) {
    let setupKeys = [WatchTransportKey.setupHello, WatchTransportKey.setupStatus, WatchTransportKey.setupCredentials]
    if let key = setupKeys.first(where: { message[$0] != nil }) {
      answerSetup(message[key] as? Data, key: key, replyHandler: replyHandler)
      return
    }
    if let query = message[WatchPendingProgressQuery.transportKey] as? Data {
      answerPendingProgress(query, replyHandler: replyHandler)
      return
    }
    if let payload = message[WatchTransportKey.nativePauseRequest] as? Data {
      answerNativePause(payload, replyHandler: replyHandler)
      return
    }
    answerHandoff(message[WatchHandoffRequest.transportKey] as? Data, replyHandler: replyHandler)
  }

  /// Answers a setup message. Every path calls `replyHandler` exactly once.
  private nonisolated func answerSetup(
    _ payload: Data?, key: String, replyHandler: @escaping ([String: Any]) -> Void
  ) {
    guard let payload, payload.count <= WatchSetupCredentials.maxWireBytes else {
      replyHandler([:])
      return
    }
    Task { @MainActor [weak self] in
      guard let self else {
        replyHandler([:])
        return
      }
      await self.library.initialize()
      if let reply = await self.library.setupReceiver.receive(payload, key: key) {
        replyHandler([key: reply])
      } else {
        replyHandler([:])
      }
      self.refreshContentReceived(.message)
    }
  }

  /// Answers a pending-progress query. Every path calls `replyHandler` exactly once.
  private nonisolated func answerPendingProgress(
    _ query: Data, replyHandler: @escaping ([String: Any]) -> Void
  ) {
    guard query.count <= WatchPendingProgressQuery.maxWireBytes else {
      replyHandler([:])
      return
    }
    Task { @MainActor [weak self] in
      guard let self else {
        replyHandler([:])
        return
      }
      await self.library.initialize()
      if let report = await self.library.offlineSync.answerPendingProgressQuery(query) {
        replyHandler([WatchPendingProgressQuery.transportKey: report])
      } else {
        replyHandler([:])
      }
      self.refreshContentReceived(.message)
    }
  }

  /// Answers the phone's pause request for a native-RSS episode. Every path calls `replyHandler`
  /// exactly once.
  private nonisolated func answerNativePause(
    _ payload: Data, replyHandler: @escaping ([String: Any]) -> Void
  ) {
    guard payload.count <= WatchNativePauseRequest.maxWireBytes else {
      replyHandler([:])
      return
    }
    Task { @MainActor [weak self] in
      guard let self else {
        replyHandler([:])
        return
      }
      await self.library.initialize()
      if let reply = await self.library.playback.answerNativePause(payload) {
        replyHandler([WatchTransportKey.nativePauseRequest: reply])
      } else {
        replyHandler([:])
      }
      self.refreshContentReceived(.message)
    }
  }

  /// Answers the phone's handoff request. The reply precedes `requestUpload()`, because the phone
  /// is waiting to start; an unanswerable request still replies once, with an empty payload.
  private nonisolated func answerHandoff(
    _ payload: Data?, replyHandler: @escaping ([String: Any]) -> Void
  ) {
    guard let payload, payload.count <= WatchHandoffRequest.maxWireBytes else {
      replyHandler([:])
      return
    }
    Task { @MainActor [weak self] in
      guard let self else {
        replyHandler([:])
        return
      }
      await self.library.initialize()
      guard let reply = await self.library.playback.answerHandoff(payload) else {
        replyHandler([:])
        self.refreshContentReceived(.message)
        return
      }
      // Reply first: the phone is waiting to start. The upload follows the reply.
      replyHandler([WatchHandoffRequest.transportKey: reply])
      self.library.playback.requestUpload()
      self.refreshContentReceived(.message)
    }
  }

  nonisolated override func observeValue(
    forKeyPath keyPath: String?,
    of object: Any?,
    change: [NSKeyValueChangeKey: Any]?,
    context: UnsafeMutableRawPointer?
  ) {
    guard keyPath == "hasContentPending" else { return }
    Task { @MainActor [weak self] in
      self?.drainRefreshTasksIfReady()
    }
  }

}
