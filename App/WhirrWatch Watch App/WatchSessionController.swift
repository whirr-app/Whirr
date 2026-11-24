import ABSApi
import Foundation
import Observation
import WatchPlayback
import WatchProtocol

@MainActor
@Observable
final class WatchSessionController {
  private unowned let model: WatchLibraryModel
  private(set) var context: WatchSessionContext?
  let lifecycle = WatchSessionLifecycle()
  private(set) var epoch = 0
  private(set) var loggingOut = false
  /// The saved account has been restored, or there was none to restore.
  private(set) var initialized = false
  private var accountStore: WatchAccountStore?
  @ObservationIgnored lazy var setupReceiver = WatchSetupReceiver(
    store: model.protectedStore,
    currentAccount: { [weak model] in try? model?.account?.authenticatedStamp() },
    install: { [weak model] credentials in
      guard let model else { throw WatchLibraryError.notAuthenticated }
      try await model.session.installSetupCredentials(credentials)
    },
    isInstalled: { [weak model] stamp in await model?.session.hasInstalledSetup(stamp) ?? false },
    health: { [weak model] in model?.catalogue.lastLinkHealth })
  private var account: WatchAccountRecord? {
    get { model.account }
    set { model.publishAccount(newValue) }
  }
  private var busy: Bool { model.busy }
  private var message: String? {
    get { model.message }
    set { model.setMessage(newValue) }
  }
  private var sessionEpoch: Int { epoch }
  private var libraryClient: WatchLibraryClient? { model.session.context?.libraryClient }
  private var coordinator: WatchPlaybackSessionCoordinator? { model.session.context?.coordinator }
  private var downloadManager: WatchDownloadManager? { model.session.context?.downloadManager }
  private var audio: WatchAudioEngine { model.playback.audio }
  private var retainedPosition: Double {
    get { model.playback.retainedPosition }
    set { model.playback.retainedPosition = newValue }
  }
  private var retainedSelection: WatchSelection? {
    get { model.playback.retainedSelection }
    set { model.playback.retainedSelection = newValue }
  }
  private var network: WatchNetworkStatus { model.downloadsController.network }
  private var initializationTask: Task<Void, Never>? {
    get { model.session.lifecycle.initialization }
    set { model.session.lifecycle.initialization = newValue }
  }
  private var reconciliationTask: Task<Void, Never>? {
    get { model.session.lifecycle.reconciliation }
    set { model.session.lifecycle.reconciliation = newValue }
  }
  private var selectedLibrary: String? {
    get { model.catalogue.selectedLibrary }
    set { model.catalogue.selectedLibrary = newValue }
  }

  init(model: WatchLibraryModel) { self.model = model }

  func initialize() async {
    guard !initialized else { return }
    if let initializationTask { return await initializationTask.value }
    let token = epoch
    let task = Task { [model] in await model.session.restoreSavedAccount() }
    initializationTask = task
    await task.value
    if token == epoch { initializationTask = nil }
  }

  func restoreSavedAccount() async {
    model.setBusy(.restoring)
    defer { model.setBusy(nil) }
    WatchRSSDiagnostics.log("restore_start")
    do {
      let store = try WatchAccountStore.production(protectedStore: model.protectedStore)
      accountStore = store
      if let saved = try await store.load() {
        // The non-secret record and the Keychain pair are separate stores that can survive
        // independently. Configuring from a record whose tokens are gone publishes an account that
        // renders a library and then fails every request, so stay signed out and name the repair.
        let stamp = try saved.authenticatedStamp()
        switch await setupPresence(stamp) {
        case .installed: break
        case .unreadable:
          // Protected storage before first unlock: not a lost sign-in. Stay uninitialized so the
          // next caller retries once the Watch is unlocked.
          WatchRSSDiagnostics.log("restore_end", ["branch": "unreadable"])
          throw WatchLibraryError.storageFailure
        case .absent:
          WatchRSSDiagnostics.log("restore_end", ["branch": "absent"])
          message = "Your Watch sign-in is no longer valid. Reconnect using your iPhone."
          WatchRSSDiagnostics.log("restore_message", ["text": message ?? ""])
          initialized = true
          model.episodes.accountSignedOut()
          return
        }
        try await configure(saved)
        WatchRSSDiagnostics.log("restore_end", ["branch": "configured"])
        // Background delivery must not wait for a network profile request before attaching
        // the persisted account's download session and handoff endpoint.
        let client = libraryClient
        let token = sessionEpoch
        lifecycle.restore = Task { [weak model] in
          guard let model, token == model.session.epoch, !Task.isCancelled else { return }
          _ = try? await client?.restore()
          guard token == model.session.epoch, !Task.isCancelled else { return }
          await model.catalogue.refresh()
        }
      } else {
        // Nothing to restore: the Watch is signed out, not still restoring.
        WatchRSSDiagnostics.log("restore_end", ["branch": "no_record"])
        model.episodes.accountSignedOut()
      }
      initialized = true
    } catch {
      WatchRSSDiagnostics.log(
        "restore_end",
        [
          "branch": "error", "type": String(describing: type(of: error)),
          "error": String(describing: error),
        ])
      message = "Watch setup could not be restored. Reconnect using your iPhone."
      WatchRSSDiagnostics.log("restore_message", ["text": message ?? ""])
    }
  }

  func installSetupCredentials(_ credentials: WatchSetupCredentials) async throws {
    guard !busy, !loggingOut, let store = accountStore else { throw WatchLibraryError.staleRequest }
    guard let serverURL = URL(string: credentials.serverURL) else { throw WatchLibraryError.invalidServer }
    let record = try WatchAccountRecord(
      serverURL: serverURL, userID: credentials.userID,
      username: credentials.username, defaultLibraryID: credentials.defaultLibraryID)
    guard try record.authenticatedStamp() == credentials.accountStamp else {
      throw WatchLibraryError.accountMismatch
    }
    model.setBusy(.installing)
    defer { model.setBusy(nil) }
    if let saved = try await store.load(), try saved.authenticatedStamp() != credentials.accountStamp {
      throw WatchLibraryError.accountMismatch
    }
    loggingOut = true
    epoch &+= 1
    let reconciliation = lifecycle.reconciliation
    lifecycle.cancelAll()
    model.catalogue.invalidatePaging()
    model.catalogue.forgetLinkHealth()
    defer { loggingOut = false }
    await reconciliation?.value
    reconciliationTask = nil
    await model.playback.stopPlayback()
    await downloadManager?.stop()
    await coordinator?.cancel()
    if let libraryClient {
      do { try await libraryClient.logout() } catch {
        // Remote logout can fail after successful local invalidation. A local tombstone must
        // still block replacement so an old refresh can never overwrite the new pair.
        if try await store.load() != nil { throw WatchLibraryError.storageFailure }
      }
    }
    context = nil
    account = nil
    selectedLibrary = nil
    try await store.install(
      record,
      tokens: TokenPair(
        accessToken: credentials.accessToken, refreshToken: credentials.refreshToken,
        accessExpiry: credentials.accessExpiry))
    try await configure(record)
    message = nil
    model.publishStatusReport()
    let token = sessionEpoch
    let client = libraryClient
    lifecycle.install = Task { [weak model] in
      guard let model, token == model.session.epoch, !Task.isCancelled else { return }
      _ = try? await client?.restore()
      guard token == model.session.epoch, !Task.isCancelled else { return }
      await model.catalogue.refresh()
    }
  }

  enum SetupPresence { case installed, absent, unreadable }

  func hasInstalledSetup(_ stamp: WatchAccountStamp) async -> Bool {
    await setupPresence(stamp) == .installed
  }

  /// Tells a missing installation from storage that cannot be read yet: before first unlock the
  /// record and the Keychain pair both fail to read, and that is not a sign-out.
  func setupPresence(_ stamp: WatchAccountStamp) async -> SetupPresence {
    guard let accountStore else { return .absent }
    let saved: WatchAccountRecord?
    do { saved = try await accountStore.load() } catch { return .unreadable }
    guard let saved, let actual = try? saved.authenticatedStamp(), actual == stamp,
      let tokenAccount = try? saved.tokenAccount()
    else { return .absent }
    let tokens: TokenPair?
    do { tokens = try accountStore.tokenStore.load(for: tokenAccount) } catch { return .unreadable }
    guard let tokens, !tokens.accessToken.isEmpty, !(tokens.refreshToken ?? "").isEmpty else { return .absent }
    return .installed
  }

  /// The account's durable stores, opened together so `configure` is three phases: stores, service
  /// graph, publication.
  private struct AccountStores {
    let downloads: WatchDownloadStore
    let progress: WatchOfflineProgressStore
    let budget: WatchStorageBudget
    let received: (store: WatchReceivedEpisodeStore?, journal: WatchNativeProgressJournal?)
  }

  func configure(
    _ record: WatchAccountRecord, client: WatchLibraryClient? = nil, service: ABSWatchLibraryService? = nil
  ) async throws {
    guard let store = accountStore, let server = record.server else { throw WatchLibraryError.notAuthenticated }
    let service = service ?? ABSWatchLibraryService(server: server, tokenStore: store.tokenStore)
    let libraryClient = client ?? WatchLibraryClient(accountStore: store, service: service)
    let stamp = try record.authenticatedStamp()
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WatchAccounts", isDirectory: true).appendingPathComponent(
        stamp.accountIdentityHash, isDirectory: true)
    let stores = try await makeStores(root: root, stamp: stamp)
    let coordinator = WatchPlaybackSessionCoordinator(account: record, service: service, audio: audio)
    let manager = try makeDownloadManager(
      record: record, root: root, stamp: stamp, service: service, store: stores.downloads)
    publishContext(
      record: record, stamp: stamp, libraryClient: libraryClient, service: service,
      coordinator: coordinator, stores: stores, manager: manager)
    manager.onDownloadsChange = { [weak model] in model?.downloadsController.downloads = $0 }
    model.downloadsController.downloads = manager.downloads
    await manager.start()
    await model.downloadsController.reloadDownloads()
    // The manager is running, so the phone's pending requests can be planned and enqueued.
    model.absRequests.accountReady()
  }

  private func makeStores(root: URL, stamp: WatchAccountStamp) async throws -> AccountStores {
    let budget = WatchStorageBudget()
    let downloads = try WatchDownloadStore(
      rootURL: root.appendingPathComponent("Downloads"), accountStamp: stamp, storageBudget: budget)
    let progress = try WatchOfflineProgressStore(
      rootURL: root.appendingPathComponent("Progress"), accountStamp: stamp)
    let received = await receivedEpisodeStores(root: root, stamp: stamp, budget: budget)
    return AccountStores(downloads: downloads, progress: progress, budget: budget, received: received)
  }

  /// The providers capture the service and the token account, and nothing else.
  private func makeDownloadManager(
    record: WatchAccountRecord, root: URL, stamp: WatchAccountStamp,
    service: ABSWatchLibraryService, store: WatchDownloadStore
  ) throws -> WatchDownloadManager {
    let signal = network
    let tokenAccount = try record.tokenAccount()
    return WatchDownloadManager(
      store: store, accountStamp: stamp,
      requestProvider: { manifest in
        guard case .audiobookshelf(let itemID, _) = manifest.selection,
          let bytes = manifest.expectedBytes, bytes > 0, bytes <= Int64(Int.max)
        else {
          throw WatchLibraryError.libraryUnavailable
        }
        return try await service.audioDownload(
          account: tokenAccount, itemID: itemID, fileID: manifest.fileID,
          mimeType: manifest.expectedMIMEType, expectedSize: Int(bytes)
        ).makeURLRequest()
      },
      renewalProvider: { manifest in
        guard case .audiobookshelf(let itemID, _) = manifest.selection,
          let bytes = manifest.expectedBytes, bytes > 0, bytes <= Int64(Int.max)
        else { throw WatchLibraryError.libraryUnavailable }
        return try await service.renewAudioDownload(
          account: tokenAccount, itemID: itemID, fileID: manifest.fileID,
          mimeType: manifest.expectedMIMEType, expectedSize: Int(bytes)
        ).makeURLRequest()
      }, rootURL: root.appendingPathComponent("Transfers"),
      sessionIdentifier: "com.remoteconcern.whirr.watch-downloads.\(stamp.accountIdentityHash)",
      isWiFiAvailable: { signal.isWiFiAvailable })
  }

  /// Publishes the graph to observers, then the account it belongs to, then the stores a pending
  /// offer needs.
  private func publishContext(
    record: WatchAccountRecord, stamp: WatchAccountStamp, libraryClient: WatchLibraryClient,
    service: ABSWatchLibraryService, coordinator: WatchPlaybackSessionCoordinator,
    stores: AccountStores, manager: WatchDownloadManager
  ) {
    // The service graph is reachable before the account is published, so nothing observing
    // `account` can find `browseClient` or the controllers' services missing.
    model.offlineSync.resetForAccount()
    context = WatchSessionContext(
      account: record, authenticatedStamp: stamp, epoch: epoch, libraryClient: libraryClient,
      service: service, coordinator: coordinator, downloadStore: stores.downloads,
      progressStore: stores.progress, downloadManager: manager, storageBudget: stores.budget,
      receivedEpisodes: stores.received.store, nativeJournal: stores.received.journal)
    account = record
    // The stores are published, so a pending offer can be admitted and the phone told what the
    // Watch holds. ABS never waits on this: a store that could not open leaves it out.
    model.episodes.accountReady()
    model.downloadsController.restoreLabels(for: stamp)
    if let bookmark = model.playback.savedBookmark(), bookmark.accountStamp == stamp {
      retainedPosition = bookmark.position
      retainedSelection = bookmark.selection
    }
  }

  /// Publishes an already built service graph without the account store. `configure` needs the
  /// Keychain and a production service; the host regressions drive the controllers through this.
  func adopt(_ context: WatchSessionContext) {
    model.offlineSync.resetForAccount()
    self.context = context
    account = context.account
  }

  /// Opens the account's native-RSS stores. Each is optional: a failed open (before first unlock, a
  /// write failure) must leave the Audiobookshelf session working with the feature out for now.
  private func receivedEpisodeStores(
    root: URL, stamp: WatchAccountStamp, budget: WatchStorageBudget
  ) async -> (store: WatchReceivedEpisodeStore?, journal: WatchNativeProgressJournal?) {
    guard let installID = await model.episodes.currentInstallID() else { return (nil, nil) }
    let directory = root.appendingPathComponent("ReceivedEpisodes", isDirectory: true)
    let store = try? WatchReceivedEpisodeStore(
      rootURL: directory, accountStamp: stamp, installID: installID, budget: budget)
    let journal = try? WatchNativeProgressJournal(
      fileURL: directory.appendingPathComponent("native-progress.json"), accountStamp: stamp)
    return (store, journal)
  }

  /// Removes the departing account's downloads. Its `Progress` directory stays: listening the
  /// bounded logout upload could not deliver is uploaded when the same account signs in again.
  /// Received RSS copies go too: they are a re-sendable cache fenced by this account.
  private func removeLocalDownloads(_ stamp: WatchAccountStamp) {
    let hash = stamp.accountIdentityHash
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WatchAccounts", isDirectory: true).appendingPathComponent(hash, isDirectory: true)
    for directory in ["Downloads", "Transfers", "ReceivedEpisodes", "ABSRequests"] {
      try? FileManager.default.removeItem(at: root.appendingPathComponent(directory, isDirectory: true))
    }
  }

  func logout() async {
    guard !busy else { return }
    model.setBusy(.signingOut)
    defer { model.setBusy(nil) }
    // Stop first so the last listen is a closed row, then one bounded upload, then clear.
    await model.playback.stopPlayback()
    await model.offlineSync.uploadBeforeLogout()
    loggingOut = true
    epoch &+= 1
    lifecycle.cancelAll()
    model.catalogue.invalidatePaging()
    reconciliationTask = nil
    defer { loggingOut = false }
    do {
      let departing = context?.authenticatedStamp
      await downloadManager?.stop()
      await coordinator?.cancel()
      do { try await libraryClient?.logout() } catch {
        guard let accountStore, try await accountStore.load() == nil else { throw error }
      }
      // One last native progress report, then the copies this account fenced. Only a
      // confirmed sign-out reaches here, so a failed logout keeps them.
      await model.episodes.signOut()
      model.absRequests.signOut()
      // Only this explicit, confirmed flow removes downloads.
      if let departing { removeLocalDownloads(departing) }
      setupReceiver.reset()
      model.playback.resetHandoff()
      model.playback.forgetListening()
      model.playback.clearBookmark()
      model.downloadsController.clearAllLabels()
      model.companion.clearCache()
      retainedSelection = nil
      retainedPosition = 0
      context = nil
      account = nil
      model.catalogue.reset()
      model.downloadsController.reset()
      message = nil
      // A signed-out report replaces the last one without clearing the phone's record.
      model.publishStatusReport()
    } catch {
      model.offlineSync.logoutDidFail()
      message = "Couldn’t disconnect. Please try again."
    }
  }
}
