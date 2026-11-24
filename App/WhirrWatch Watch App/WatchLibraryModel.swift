import Foundation
import Observation
import WatchPlayback
import WatchProtocol

/// Published projection and stable view API for the Watch session's controllers.
@MainActor
@Observable
final class WatchLibraryModel {
  private(set) var account: WatchAccountRecord?
  private(set) var libraries: [WatchLibrary] = []
  private(set) var items: [WatchLibraryItem] = []
  private(set) var continued: [WatchContinueItem] = []
  private(set) var continueTitles: [WatchSelection: String] = [:]
  private(set) var downloadLabels: [String: String] = [:]
  private(set) var downloads: [WatchDownloadManifest] = []
  /// The native-RSS copies the Watch holds, and the Watch's own listen for each. Published from
  /// `WatchEpisodeSync` so the On My Watch and Continue screens read observable state.
  private(set) var receivedEpisodes: [WatchReceivedEpisode] = []
  private(set) var nativeListens: [WatchNativeSelection: WatchNativeListen] = [:]
  /// What holds the library while it restores, installs, signs out or starts a download.
  private(set) var busyHolder: WatchBusyHolder?
  var busy: Bool { busyHolder != nil }
  private(set) var message: String?
  private(set) var messageID = UUID()
  private(set) var selectedLibrary: String?
  private(set) var hasMore = false
  private(set) var libraryLoadFailure: WatchLibraryLoadFailure?
  private(set) var isRefreshingLibraries = false
  private(set) var currentSelection: WatchSelection?
  let companion: WatchCompanionStore
  /// Account-linked Watch state that must stay off the backup to the paired iPhone.
  let protectedStore: WatchProtectedFileStore
  @ObservationIgnored lazy var session = WatchSessionController(model: self)
  @ObservationIgnored lazy var catalogue = WatchCatalogueController(model: self, catalogueLoader: catalogueLoader)
  @ObservationIgnored lazy var playback = WatchPlaybackController(model: self)
  @ObservationIgnored lazy var offlineSync = WatchOfflineSyncController(model: self)
  @ObservationIgnored lazy var downloadsController = WatchDownloadController(model: self)
  @ObservationIgnored lazy var episodes = WatchEpisodeSync(model: self)
  /// The phone's Audiobookshelf requests (ADR 0021).
  @ObservationIgnored lazy var absRequests = WatchABSRequestDriver(model: self)
  /// The one owner of the outgoing application context: the playing report and the status report
  /// are written together so neither replaces the other.
  @ObservationIgnored lazy var applicationContext = WatchApplicationContextPublisher()
  private let catalogueLoader: (@Sendable (String, Int, Int) async throws -> WatchLibraryPage)?

  var audio: WatchAudioEngine { playback.audio }
  var setupReceiver: WatchSetupReceiver { session.setupReceiver }
  var browseClient: WatchLibraryClient? { session.context?.libraryClient }

  init(
    companion: WatchCompanionStore,
    protectedStore: WatchProtectedFileStore,
    catalogueLoader: (@Sendable (String, Int, Int) async throws -> WatchLibraryPage)? = nil
  ) {
    self.companion = companion
    self.protectedStore = protectedStore
    self.catalogueLoader = catalogueLoader
    _ = playback
  }

  func publishAccount(_ value: WatchAccountRecord?) { account = value }
  func setBusy(_ holder: WatchBusyHolder?) { busyHolder = holder }
  func setMessage(_ value: String?) {
    message = value
    messageID = UUID()
  }

  // Controllers publish per mutation; only the property that changed emits, as it did when the
  // model held the state directly.
  func publishCatalogue() {
    if libraries != catalogue.libraries { libraries = catalogue.libraries }
    if items != catalogue.items { items = catalogue.items }
    if continued != catalogue.continued { continued = catalogue.continued }
    if continueTitles != catalogue.continueTitles { continueTitles = catalogue.continueTitles }
    if selectedLibrary != catalogue.selectedLibrary { selectedLibrary = catalogue.selectedLibrary }
    if hasMore != catalogue.hasMore { hasMore = catalogue.hasMore }
    if libraryLoadFailure != catalogue.libraryLoadFailure { libraryLoadFailure = catalogue.libraryLoadFailure }
    if isRefreshingLibraries != catalogue.isRefreshingLibraries {
      isRefreshingLibraries = catalogue.isRefreshingLibraries
    }
  }

  func publishPlayback() {
    if currentSelection != playback.currentSelection { currentSelection = playback.currentSelection }
  }

  func publishDownload() {
    if downloadLabels != downloadsController.downloadLabels { downloadLabels = downloadsController.downloadLabels }
    if downloads != downloadsController.downloads { downloads = downloadsController.downloads }
  }

  func publishEpisodes() {
    if receivedEpisodes != episodes.receivedEpisodes { receivedEpisodes = episodes.receivedEpisodes }
    if nativeListens != episodes.nativeListens { nativeListens = episodes.nativeListens }
  }

  /// Whether `selection` is a native-feed episode whose file this account holds ready. Reads the
  /// published list, so a view that asks from `body` re-renders when a copy arrives or goes.
  func hasReadyEpisodeCopy(_ selection: WatchSelection) -> Bool {
    guard let native = WatchNativeSelection(selection) else { return false }
    return receivedEpisodes.contains { $0.selection == native && $0.state == .ready }
  }

  /// The ready selections as the Now Playing projection wants them.
  var readyEpisodeSelections: Set<WatchSelection> {
    Set(receivedEpisodes.filter { $0.state == .ready }.map(\.selection.selection))
  }

  /// In-progress copies Continue may show: a ready file whose journal row has a listen and no
  /// finish. A copy never played stays in On My Watch only.
  var nativeContinueItems: [WatchNativeContinueItem] {
    receivedEpisodes.compactMap { entry in
      guard entry.state == .ready, let listen = nativeListens[entry.selection],
        let duration = entry.duration ?? listen.duration
      else { return nil }
      return WatchNativeContinueItem(
        selection: entry.selection.selection, title: entry.title, showTitle: entry.showTitle,
        progressSeconds: listen.position, durationSeconds: duration, isFinished: listen.isFinished)
    }
  }

  /// Removes a received copy the listener asked to delete, stopping its playback first.
  func removeEpisodeCopy(_ selection: WatchSelection) async {
    guard let native = WatchNativeSelection(selection) else { return }
    await playback.removeNativeCopy(native)
  }

  /// Stops playback here before a phone start of `selection`; returns the position to hand over when
  /// the Watch was playing that native episode.
  func stopForPhoneStart(of selection: WatchSelection) async -> Double? {
    await playback.stopForPhoneStart(of: selection)
  }

  /// Re-reads the copies and the Watch's listens for the screens that show them. Called when one of
  /// those screens opens, because a pause or stop updates the journal behind the player.
  func refreshReceivedEpisodes() async {
    await episodes.refreshReadyCopies()
  }

  /// Catches up on whatever a background wake could not finish: the pending offer and the Watch's
  /// downloads (ingress reconciles them), then the inventory the phone reads as status.
  func resumeEpisodeSync() {
    episodes.scheduleIngress()
    episodes.scheduleInventory()
    absRequests.scheduleReconcile(retryingNetworkFailures: true)
  }

  /// Hands over a held inventory and any unfinished download commit before the app is suspended.
  func suspendEpisodeSync() async {
    await episodes.settleForSuspension()
  }

  func homeProjection(scope: WatchHomeProjection.Scope) -> WatchHomeProjection {
    catalogue.homeProjection(scope: scope)
  }

  var downloadGroups: [WatchDownloadGroup] { downloadsController.groups }

  func downloadPresentation(for group: WatchDownloadGroup) -> WatchDownloadRowPresentation {
    downloadsController.presentation(for: group)
  }

  func retry(group: WatchDownloadGroup) async { await downloadsController.retry(group: group) }

  func delete(group: WatchDownloadGroup) async { await downloadsController.delete(group: group) }

  func play(group: WatchDownloadGroup) async { await downloadsController.play(group: group) }

  func initialize() async { await session.initialize() }

  /// Publishes the Watch's own link status for the phone. The publisher throttles an unchanged
  /// report, so every lifecycle and library trigger may call this.
  func publishStatusReport() {
    applicationContext.publishStatus(
      accountStamp: try? account?.authenticatedStamp(), health: catalogue.lastLinkHealth,
      checkedAt: catalogue.lastServerContactAt)
  }

  func refresh() async { await catalogue.refresh() }

  func refreshContinueListening() async { await catalogue.refreshContinueListening() }

  func selectLibrary(_ id: String) async { await catalogue.selectLibrary(id) }

  func loadMore() async { await catalogue.loadMore() }

  @discardableResult
  func play(_ selection: WatchSelection) async -> Bool {
    await playback.play(selection)
  }

  func continueOnPhone() async { await playback.continueOnPhone() }

  func resume() async { await playback.resume() }

  func pause() async { await playback.pause() }

  func seek(to position: Double) async { await playback.seek(to: position) }

  func skip(by delta: Double) { playback.skip(by: delta) }

  func setRate(_ rate: Double) async { await playback.setRate(rate) }

  func stopPlayback(finished: Bool = false) async { await playback.stopPlayback(finished: finished) }

  func reloadDownloads() async { await downloadsController.reloadDownloads() }

  func refreshDownloads() async { await downloadsController.refreshDownloads() }

  func deleteDownload(_ id: UUID) async { await downloadsController.deleteDownload(id) }

  func download(_ selection: WatchSelection, title: String? = nil) async {
    await downloadsController.download(selection, title: title)
  }

  func retryDownload(_ id: UUID) async { await downloadsController.retryDownload(id) }

  func resumeBackgroundSession(identifier: String, completion: @escaping @Sendable () -> Void) async {
    await downloadsController.resumeBackgroundSession(identifier: identifier, completion: completion)
  }

  func peerDidReconnect() async { await offlineSync.peerDidReconnect() }

  func peerDidSendContext() async { await offlineSync.peerDidSendContext() }

  func logout() async { await session.logout() }

  func downloadName(_ manifest: WatchDownloadManifest) -> String { downloadsController.downloadName(manifest) }
}
