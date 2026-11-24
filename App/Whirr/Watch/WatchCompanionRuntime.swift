import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine
import WatchProtocol

/// Account composition, lifecycle and recovery for the process-owned Watch bridge.
@MainActor
final class WatchCompanionRuntime {
  static let shared = WatchCompanionRuntime()
  /// The copies models this runtime pushes into. Owned per runtime, so a runtime a test builds
  /// never writes into the process's, and a test can observe what this runtime applies.
  let episodeCopies: WatchEpisodeCopiesModel
  let absCopies: ABSWatchCopiesModel
  /// The newest enriched snapshot, as published for the bound account; `unbind` clears it.
  var latestSnapshot: WatchCatalogueSnapshot?
  private weak var publisher: WatchCataloguePublisher?
  private weak var playback: PlaybackModel?
  var handoffEndpoint: WatchPhoneHandoffEndpoint?
  var handoffAsker: WatchPhoneHandoffAsker?
  var companionHandoff: CompanionPlaybackHandoff?
  /// The last Watch-takeover effect, so `unbind` can cancel a send that outlived its account.
  private var takeoverTask: Task<Void, Never>?
  /// When this phone last listened to a title, from its stored progress.
  var phoneLastListened: (@MainActor (_ itemID: String, _ episodeID: String?) -> Date?)?
  /// The Watch's latest playing report for the bound account, in memory only: the Watch
  /// republishes on every transition and a reader treats an old one as expired.
  private(set) var playingReport: WatchPlayingReport?
  private var phoneWasPlaying = false
  var pendingProgressInbox: WatchPendingProgressInbox?
  var pendingProgressGate: WatchPendingProgressStartGate?
  var authenticatedStamp: WatchAccountStamp?
  var accountEpoch = 0
  private var didActivate = false
  var artworkEndpoint: WatchPhoneArtworkEndpoint?
  var artworkSources: FollowedShowArtworkSources?
  var artworkSync: WatchArtworkSyncPublisher?
  private var artworkSyncObservers: [Task<Void, Never>] = []
  /// The device-owned episode sender. Composed from the stores, never from the account bind, and
  /// kept for the life of the process.
  var episodeSendPublisher: WatchEpisodeSendPublisher?
  var episodeInventoryInbox: WatchEpisodeInventoryInbox?
  /// The Watch's last download report, kept across this phone's relaunch. The inventory
  /// inbox saves each newer projection; the account boundary clears it with the copies.
  let downloadStatusRecord = WatchDownloadStatusRecord()
  /// The bound account's Audiobookshelf sender and inventory reader (ADR 0021). Unlike the RSS pair
  /// they follow the account graph, so both are nil while signed out.
  var absSendPublisher: ABSWatchSendPublisher?
  var absInventoryInbox: ABSWatchInventoryInbox?
  /// The Watch's last Audiobookshelf report, kept across this phone's relaunch.
  let absInventoryRecord = ABSWatchInventoryRecord()
  /// The native listen ingress. Device-owned like the sender: it names received copies, which
  /// belong to the Watch install rather than the bound account.
  var nativeProgressInbox: WatchNativeProgressInbox?
  /// Asks a Watch playing a received episode to pause before a phone start or resume.
  var nativeStartGate: WatchNativeStartGate?
  /// Lazy so the setup model can read the bridge's prerequisite state; the closure defers that
  /// reference until after both properties exist.
  private(set) lazy var setupModel = WatchPhoneSetupModel(
    sender: { data, key in await WatchPeerMessageSender.send(data, key: key) },
    installState: { [weak self] in self?.bridge.installState ?? .unknown })

  private(set) lazy var bridge: WatchPhoneBridge = {
    let bridge = WatchPhoneBridge(onCommandCompletion: { [weak self] _, _ in self?.publisher?.refresh() })
    bridge.onWatchAvailabilityChange = { [weak self] installed in
      guard let self else { return }
      // A deleted Watch app takes its files with it: readiness must follow the install state, not
      // only a new status report, so the copies model hides what is no longer there.
      self.refreshWatchAvailability()
      if installed { publisher?.start() } else { publisher?.stopAndPublishSignedOut() }
      if installed { artworkSync?.watchBecameAvailable() }
      self.ensureEpisodeSend()
      if installed { self.episodeSendPublisher?.watchBecameAvailable() }
      if installed { self.absSendPublisher?.watchBecameAvailable() }
    }
    bridge.onWatchReachabilityChange = { [weak self] reachable in
      self?.setupModel.watchReachabilityChanged(isReachable: reachable)
    }
    bridge.artworkEndpoint = { [weak self] in self?.artworkEndpoint }
    bridge.artworkSync = { [weak self] in self?.artworkSync }
    bridge.episodeSend = { [weak self] in
      self?.ensureEpisodeSend()
      return self?.episodeSendPublisher
    }
    bridge.episodeInventoryInbox = { [weak self] in
      self?.ensureEpisodeSend()
      return self?.episodeInventoryInbox
    }
    bridge.nativeProgressInbox = { [weak self] in
      self?.ensureEpisodeSend()
      return self?.nativeProgressInbox
    }
    bridge.browseEndpoint = { [weak self] in self?.publisher?.browseEndpoint }
    bridge.handoffEndpoint = { [weak self] in self?.handoffEndpoint }
    bridge.authenticatedStamp = { [weak self] in self?.authenticatedStamp }
    bridge.storePlayingReport = { [weak self] in self?.storePlayingReport($0) }
    bridge.storeStatusReport = { [weak self] report in
      guard let self else { return }
      self.setupModel.acceptStatusReport(report)
      // A newly accepted report can change what the Watch can do, and the screen's waiting rows
      // read that through the copies model.
      self.publishWatchAppReadiness()
    }
    bridge.refreshCatalogue = { [weak self] in self?.publisher?.refresh() }
    bridge.pendingProgressInbox = { [weak self] in self?.pendingProgressInbox }
    return bridge
  }()

  /// Fresh copies models by default. They are optional parameters rather than defaults built in the
  /// signature because a default argument is evaluated outside the initialiser's MainActor
  /// isolation, so an isolated initialiser cannot be one.
  init(episodeCopies: WatchEpisodeCopiesModel? = nil, absCopies: ABSWatchCopiesModel? = nil) {
    let episodes = episodeCopies ?? WatchEpisodeCopiesModel()
    self.episodeCopies = episodes
    self.absCopies = absCopies ?? ABSWatchCopiesModel()
    // Weak, so the model's host does not keep the runtime alive.
    episodes.connect(
      WatchEpisodeCopiesModel.Host(
        isWatchAppInstalled: { [weak self] in self?.isWatchAppInstalled ?? false },
        refreshAvailability: { [weak self] in self?.refreshWatchAvailability() },
        refreshSend: { [weak self] in self?.refreshEpisodeSend() }))
  }

  func activate() {
    didActivate = true
    ensureEpisodeSend()
    bridge.activate()
  }

  /// Flushes the Watch context dedup timestamp to storage as the app leaves the foreground. The
  /// guard avoids constructing the lazy bridge in a process that never activated Watch support
  /// (the UI harness skips `activate()`).
  func persistContextTimestamp() {
    guard didActivate else { return }
    bridge.persistContextTimestamp()
  }

  /// Adds the authenticated stamp and drops a stale rate. Every other snapshot field must be
  /// carried across, since the snapshot has no copy method.
  nonisolated static func enriched(
    _ snapshot: WatchCatalogueSnapshot, authenticatedStamp: WatchAccountStamp?
  ) -> WatchCatalogueSnapshot {
    (try? WatchCatalogueSnapshot(
      accountStamp: snapshot.accountStamp,
      generatedAt: snapshot.generatedAt, items: snapshot.items,
      playbackState: snapshot.accountStamp == nil ? .idle : snapshot.playbackState,
      authenticatedAccountStamp: snapshot.accountStamp == nil ? nil : authenticatedStamp,
      playbackRate: snapshot.playbackState.phoneHasSession ? snapshot.playbackRate : nil,
      skipBackwardSeconds: snapshot.skipBackwardSeconds, skipForwardSeconds: snapshot.skipForwardSeconds,
      playbackRatePresets: snapshot.playbackRatePresets,
      followedPodcastsEnabled: snapshot.followedPodcastsEnabled,
      removePlayedNativeEpisodes: snapshot.removePlayedNativeEpisodes)) ?? snapshot
  }

  func bind(
    actions: CompanionPlaybackActions, dependencies: AppDependencies, playback: PlaybackModel,
    identity: AccountIdentity, accountRecord: AccountRecord? = nil,
    artwork: (any ArtworkServing)? = nil,
    audioActivationWasRefused: @escaping WatchCataloguePublisher.AudioActivationRefusal
  ) -> WatchCataloguePublisher? {
    unbind(publishSignedOut: false)
    let hashes = CompanionCatalogueBuilder.identityHashes(for: identity)
    guard let stamp = try? WatchAccountStamp(accountIdentityHash: hashes.account, serverIdentityHash: hashes.server)
    else { return nil }
    self.playback = playback
    if let accountRecord { setupModel.bind(account: accountRecord, reading: dependencies.serverAccountReading) }
    publishWatchAppReadiness()
    authenticatedStamp = accountRecord.flatMap(Self.authenticatedStamp)
    if let accountId = accountRecord?.id, let authenticatedStamp {
      bindABSSend(accountId: accountId, stamp: authenticatedStamp, dependencies: dependencies)
    }
    bridge.bind(actions, accountStamp: stamp, currentSelection: Self.selectionReader(playback))
    let library = bindHandoff(actions: actions, dependencies: dependencies, playback: playback)
    bindProgressGates(library: library, playback: playback)
    let epoch = accountEpoch
    let publisher = makeCataloguePublisher(
      epoch: epoch, stamp: stamp, actions: actions, playback: playback, dependencies: dependencies,
      audioActivationWasRefused: audioActivationWasRefused)
    self.publisher = publisher
    if let artwork {
      bindArtwork(epoch: epoch, stamp: stamp, artwork: artwork, dependencies: dependencies)
    }
    // The episode sender is device-owned and outlives this graph. It reads no phone download, so
    // binding only asks it to catch up with the store.
    episodeSendPublisher?.refresh()
    bridge.replayReceivedPlayingReport()
    bridge.replayReceivedStatusReport()
    if bridge.isWatchInstalled { publisher.start() }
    return publisher
  }

  func unbind(publishSignedOut: Bool = true) {
    unbindABSSend()
    setupModel.unbind()
    publishWatchAppReadiness()
    takeoverTask?.cancel()
    takeoverTask = nil
    playback?.authorizePlaybackStart = nil
    handoffEndpoint?.reset()
    handoffEndpoint = nil
    handoffAsker = nil
    nativeStartGate = nil
    companionHandoff = nil
    phoneLastListened = nil
    playingReport = nil
    playback?.setCompanionDevicePlayback(nil)
    phoneWasPlaying = false
    pendingProgressGate = nil
    pendingProgressInbox = nil
    playback = nil
    authenticatedStamp = nil
    artworkEndpoint = nil
    artworkSources = nil
    for observer in artworkSyncObservers { observer.cancel() }
    artworkSyncObservers = []
    artworkSync?.stop()
    artworkSync = nil
    if let publisher {
      if publishSignedOut { publisher.stopAndPublishSignedOut() } else { publisher.stop() }
    } else if publishSignedOut, let signedOut = try? WatchCatalogueSnapshot(accountStamp: nil, items: []) {
      bridge.publish(signedOut)
    }
    publisher = nil
    accountEpoch &+= 1
    bridge.unbind()
    latestSnapshot = nil
  }

  /// Row covers for the whole library go to the Watch while the phone app runs; the Watch asks
  /// for what it lacks.
  func startArtworkSync(
    stamp: WatchAccountStamp, load: @escaping @MainActor (WatchArtworkRequest) async -> Data?,
    library: any LibraryReading, shows: any NativePodcastShowsReading
  ) {
    let bridge = bridge
    let sync = WatchArtworkSyncPublisher(
      accountStamp: stamp, authenticatedStamp: authenticatedStamp, load: load,
      sender: WatchArtworkSyncPublisher.Sender(
        isReady: { bridge.isWatchInstalled },
        transfer: { url, kind in bridge.transferArtworkFile(url, kind: kind) },
        outstanding: { bridge.outstandingArtworkFiles }))
    artworkSync = sync
    artworkSyncObservers = [
      Task { [weak sync] in
        for await items in library.observeBrowseList(category: nil) {
          guard !Task.isCancelled else { break }
          sync?.update(library: items)
        }
      },
      Task { [weak sync] in
        for await snapshot in shows.observeShows() {
          guard !Task.isCancelled else { break }
          sync?.update(followedShows: snapshot.shows)
        }
      },
    ]
  }

  /// Keeps the copies model's readiness in step with the transport's install state and the setup
  /// model's record: the screen draws "Open Whirr on your Watch" or "Update Whirr on your Watch"
  /// from it, and reports "Whirr isn't on your Watch" while the app is gone. The
  /// session's own `sessionWatchStateDidChange` reaches this through the bridge's callback; a
  /// screen that is about to draw calls it too, so an answer read before activation cannot outlive
  /// it.
  func refreshWatchAvailability() {
    publishWatchAppReadiness()
  }

  private func publishWatchAppReadiness() {
    setupModel.refreshInstallState()
    episodeCopies.applyReadiness(setupModel.watchAppReadiness)
    absCopies.applyReadiness(setupModel.absReadiness)
  }

  /// Keeps the newest report for the bound account. Reports can arrive out of order.
  func storePlayingReport(_ report: WatchPlayingReport) {
    guard report.accountStamp == authenticatedStamp else { return }
    if let held = playingReport, held.observedAt > report.observedAt { return }
    playingReport = report
    playback?.setCompanionDevicePlayback(Self.companionPlayback(report))
    noteTakeover(report)
  }

  /// The Watch asks the phone to pause only when the phone is playing, so a handoff from a paused
  /// phone is seen here, in the report the Watch publishes when it plays or pauses the title. A
  /// Watch command's own aftermath (Continue on iPhone) is not a takeover.
  private func noteTakeover(_ report: WatchPlayingReport) {
    guard !bridge.commandScope.isRecent, let playback, let companionHandoff,
      let taken = Self.takenOverSelection(
        report, loaded: Self.selectionReader(playback)(), phoneLastListened: phoneLastListened)
    else { return }
    runTakeover {
      await companionHandoff.peerTookOver(itemID: taken.itemID, episodeID: taken.episodeID)
    }
  }

  /// Owns the takeover as one task so `unbind` can cancel it with the rest of the account graph.
  func runTakeover(_ operation: @escaping @MainActor () async -> Void) {
    takeoverTask = Task { @MainActor in await operation() }
  }

  var takeoverTaskForTesting: Task<Void, Never>? { takeoverTask }

  /// The phone's loaded title, when the report names it and the Watch was on it after the phone
  /// last listened. Playing or paused: a Watch paused further on still holds the newer position.
  static func takenOverSelection(
    _ report: WatchPlayingReport, loaded: CompanionSelection?,
    phoneLastListened: (@MainActor (_ itemID: String, _ episodeID: String?) -> Date?)?
  ) -> CompanionSelection? {
    guard let loaded, let named = report.selection,
      WatchPhoneHandoffAsker.wireSelection(loaded) == named,
      report.observedAt > (phoneLastListened?(loaded.itemID, loaded.episodeID) ?? .distantPast)
    else { return nil }
    return loaded
  }

  /// The indicator's value. A report that is not playing, or names no title, clears it.
  static func companionPlayback(_ report: WatchPlayingReport) -> CompanionDevicePlayback? {
    guard report.playing, let selection = report.selection else { return nil }
    return CompanionDevicePlayback(
      itemID: selection.itemID, episodeID: selection.episodeID, observedAt: report.observedAt)
  }

  /// The phone resuming a paused loaded title while the Watch plays asks the Watch
  /// to pause. Seen as the published phone state turning to playing; a start has already asked
  /// (the asker's repeat window), and a Watch command's own playback never asks back.
  func noteResume(_ snapshot: WatchCatalogueSnapshot) {
    let playing = snapshot.accountStamp != nil && snapshot.playbackState == .playing
    defer { phoneWasPlaying = playing }
    guard playing, !phoneWasPlaying, !bridge.commandScope.isRecent, let playback else { return }
    let loaded = Self.selectionReader(playback)()
    handoffAsker?.askOnResume(selection: loaded.flatMap { WatchPhoneHandoffAsker.wireSelection($0) })
    nativeStartGate?.askOnResume()
  }

  /// A phone start is a live choice and is never denied. It brings the Watch's pending progress,
  /// and asks a playing Watch to pause; the Watch's reply position, being its latest, wins
  /// over the pending-progress position. A start the Watch itself sent asks nothing back.
  func authorizePhoneStart(itemID: String, episodeID: String?) async -> PlaybackStartAuthorization {
    // The Watch paused where it handed over, which is the newest listen to this title.
    if let handed = bridge.commandScope.handedPosition(itemID: itemID, episodeID: episodeID) {
      return .allowed(position: handed)
    }
    let epoch = accountEpoch
    let peerAsk: Task<Double?, Never>? =
      bridge.commandScope.isExecuting
      ? nil
      : handoffAsker.map { asker in
        Task { @MainActor in await asker.positionForStart(itemID: itemID, episodeID: episodeID) }
      }
    let nativeAsk: Task<Double?, Never>? =
      bridge.commandScope.isExecuting
      ? nil
      : nativeStartGate.map { gate in
        Task { @MainActor in await gate.positionForStart(itemID: itemID, episodeID: episodeID) }
      }
    let watchPosition = await pendingProgressGate?.position(itemID: itemID, episodeID: episodeID)
    let peerPosition = await peerAsk?.value
    let nativePosition = await nativeAsk?.value
    guard epoch == accountEpoch else { return .denied(message: "The account changed. Try playback again.") }
    return .allowed(position: nativePosition ?? peerPosition ?? watchPosition)
  }

  private static func authenticatedStamp(_ record: AccountRecord) -> WatchAccountStamp? {
    guard let url = URL(string: record.serverBaseURL),
      let server = try? TokenAccount.normalizedServerIdentity(from: url)
    else { return nil }
    return try? WatchAccountStamp.authenticated(serverIdentity: server, userID: record.serverUserId)
  }

  static func selectionReader(_ playback: PlaybackModel) -> WatchPhoneBridge.CurrentSelection {
    { [weak playback] in
      guard let playback, let itemID = playback.loadedItemID,
        playback.isLoaded(itemID: itemID, episodeID: playback.loadedEpisodeID),
        let source = PodcastSourceIdentity(itemId: itemID)
      else { return nil }
      return CompanionSelection(source: source, episodeID: playback.loadedEpisodeID)
    }
  }

  // MARK: - Phone UI accessors

  /// Whether the Watch app is installed, for the screens that offer a Watch action. The bridge's
  /// one `WCSession` owns the answer; this is only its reader.
  var isWatchAppInstalled: Bool { bridge.isWatchInstalled }

  /// What the Watch's last status report said it can do, for the On Apple Watch rows a probe has
  /// just re-confirmed.
  var watchAppReadiness: WatchAppReadiness { setupModel.watchAppReadiness }
}
