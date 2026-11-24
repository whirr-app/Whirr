import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Shared construction/assertion plumbing for `DownloadCoordinator` tests: a real `ABSClient`
/// over `FakeHTTPClient`, an in-memory `AppDatabase` with one seeded account/library/book item,
/// a real `DownloadStore`/`DownloadFileStore` pair (over a real temp directory, since
/// `DownloadFileStore` performs actual file I/O), and fakes for every other boundary.
final class DownloadCoordinatorHarness: @unchecked Sendable {
  static let itemID = "item_book_fixture"
  static let podcastItemID = "item_podcast_fixture"

  let http: FakeHTTPClient
  let client: ABSClient
  let server: ABSServerConfig
  let account: TokenAccount
  let database: AppDatabase
  let downloadStore: DownloadStore
  let downloadFileStore: DownloadFileStore
  let rssDownloadStore: RSSDownloadStore
  let rssFileStore: RSSFileStore
  let feedCredentialStore: InMemoryFeedCredentialStore
  let backgroundTransferring: DownloadSchedulingBackgroundTransferring
  let downloadPreferences: FakeDownloadPreferences
  let networkConditions: FakeNetworkConditions
  let diagnostics: FakeDiagnosticsRecording
  let freeSpaceReporting: FakeFreeSpaceReporting
  /// The coordinators' clock. It never moves on its own, so a retry deadline is reached only when
  /// a test advances it.
  let clock: Locked<Date>
  let coordinator: DownloadCoordinator
  let accountId: Int64
  let libraryRowId: Int64
  let itemRowId: Int64
  let podcastItemRowId: Int64

  private let tempRoot: URL

  /// `fileMover` defaults to a real same-volume move. The reactive low-disk test injects a mover
  /// that throws an `ENOSPC`-shaped error (see `DownloadPurgeAndLowDiskTests.swift`), because the
  /// `PersistenceTests` fake is not reachable from this test target.
  init(
    fileMover: DownloadFileMoving = POSIXDownloadFileMover(), startSubscriptions: Bool = true
  ) async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://downloads.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID),
      userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    http = FakeHTTPClient()
    client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    self.server = server
    self.account = account

    let localDatabase = try AppDatabase.inMemory()
    let savedAccount = try await localDatabase.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture", serverVersion: "2.35.1")
      try record.insert(db)
      return record
    }
    let localAccountId = try #require(savedAccount.id)

    let localLibraryRowId = try await localDatabase.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: localDatabase)
    let localItemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: localAccountId, libraryId: localLibraryRowId, serverItemId: Self.itemID,
          mediaKind: "book", title: "Title", sortTitle: "title")
      ).id)
    let localPodcastItemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: localAccountId, libraryId: localLibraryRowId, serverItemId: Self.podcastItemID,
          mediaKind: "podcast", title: "Podcast Title", sortTitle: "podcast title")
      ).id)

    database = localDatabase
    accountId = localAccountId
    libraryRowId = localLibraryRowId
    itemRowId = localItemRowId
    podcastItemRowId = localPodcastItemRowId

    downloadStore = try DownloadStore(database: database)
    tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "DownloadCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
    downloadFileStore = try DownloadFileStore(
      rootURL: tempRoot, fileAttributes: InertFileAttributes(), downloadStore: downloadStore,
      fileMover: fileMover)
    rssDownloadStore = try RSSDownloadStore(database: database)
    rssFileStore = try RSSFileStore(
      rootURL: tempRoot, fileAttributes: InertFileAttributes(), downloadStore: rssDownloadStore,
      fileMover: fileMover)
    feedCredentialStore = InMemoryFeedCredentialStore()

    backgroundTransferring = DownloadSchedulingBackgroundTransferring()
    downloadPreferences = FakeDownloadPreferences()
    networkConditions = FakeNetworkConditions()
    diagnostics = FakeDiagnosticsRecording()
    freeSpaceReporting = FakeFreeSpaceReporting()
    let clock = Locked(Date(timeIntervalSince1970: 1_790_000_000))
    self.clock = clock

    if startSubscriptions {
      coordinator = DownloadCoordinator.make(
        client: client, database: database, downloadStore: downloadStore,
        downloadFileStore: downloadFileStore, backgroundTransferring: backgroundTransferring,
        downloadPreferences: downloadPreferences, networkConditions: networkConditions,
        diagnostics: diagnostics, freeSpaceReporting: freeSpaceReporting,
        rssDownloadStore: rssDownloadStore, rssFileStore: rssFileStore,
        feedCredentialStore: feedCredentialStore, now: { [clock] in clock.value })
    } else {
      coordinator = DownloadCoordinator(
        client: client, database: database, downloadStore: downloadStore,
        downloadFileStore: downloadFileStore, backgroundTransferring: backgroundTransferring,
        downloadPreferences: downloadPreferences, networkConditions: networkConditions,
        diagnostics: diagnostics, freeSpaceReporting: freeSpaceReporting,
        rssDownloadStore: rssDownloadStore, rssFileStore: rssFileStore,
        feedCredentialStore: feedCredentialStore, now: { [clock] in clock.value })
    }
  }

  deinit {
    try? FileManager.default.removeItem(at: tempRoot)
  }

  /// A second coordinator sharing every boundary except its own `DownloadStore`, simulating a
  /// relaunch. Constructing a fresh `DownloadStore` over the same database performs the
  /// `.downloading` -> `.interrupted` bulk reconciliation (not the coordinator's job).
  func makeCoordinator(downloadStore: DownloadStore) -> DownloadCoordinator {
    DownloadCoordinator.make(
      client: client, database: database, downloadStore: downloadStore,
      downloadFileStore: downloadFileStore, backgroundTransferring: backgroundTransferring,
      downloadPreferences: downloadPreferences, networkConditions: networkConditions,
      diagnostics: diagnostics, freeSpaceReporting: freeSpaceReporting,
      rssDownloadStore: rssDownloadStore, rssFileStore: rssFileStore,
      feedCredentialStore: feedCredentialStore, now: { [clock] in clock.value })
  }

  /// A relaunched process's coordinator with no event subscription, so a test delivers events
  /// itself through `handleTransferEvent` and controls their order against `reconcileAfterLaunch`.
  /// Construct fresh stores over `database` first: that is what performs each store's launch
  /// `.downloading` -> `.interrupted` rewrite.
  func makeUnsubscribedCoordinator(
    downloadStore: DownloadStore, rssDownloadStore: RSSDownloadStore
  ) -> DownloadCoordinator {
    DownloadCoordinator(
      client: client, database: database, downloadStore: downloadStore,
      downloadFileStore: downloadFileStore, backgroundTransferring: backgroundTransferring,
      downloadPreferences: downloadPreferences, networkConditions: networkConditions,
      diagnostics: diagnostics, freeSpaceReporting: freeSpaceReporting,
      rssDownloadStore: rssDownloadStore, rssFileStore: rssFileStore,
      feedCredentialStore: feedCredentialStore, now: { [clock] in clock.value })
  }

  // MARK: - Item-detail fixtures

  func seedItem(serverItemId: String, mediaKind: String = "book") async throws -> Int64 {
    let itemDAO = ItemDAO(database: database)
    let record = try await itemDAO.upsertAsync(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: serverItemId, mediaKind: mediaKind,
        title: serverItemId, sortTitle: serverItemId))
    return try #require(record.id)
  }

  func seedPodcastEpisode(
    episodeID: String,
    storedAudioIno: String? = "episode-file-ino",
    expectedSize: Int? = 1_024,
    mimeType: String? = "audio/mpeg",
    duration: Double? = 60
  ) async throws -> PodcastEpisodeRecord {
    try await PodcastEpisodeDAO(database: database).upsertAsync(
      PodcastEpisodeRecord(
        accountId: accountId,
        itemId: podcastItemRowId,
        serverEpisodeId: episodeID,
        title: episodeID,
        storedAudioIno: storedAudioIno,
        storedAudioExpectedSize: expectedSize,
        storedAudioMimeType: mimeType,
        storedAudioDurationSeconds: duration,
        lastSeenGeneration: 1))
  }

  func enqueueBookItemDetail(
    itemID: String = DownloadCoordinatorHarness.itemID,
    audioFiles: [(index: Int, ino: Int, size: Int, mimeType: String, duration: Double)],
    libraryFiles: [[String: Any]] = []
  ) {
    let object: [String: Any] = [
      "libraryFiles": libraryFiles,
      "id": itemID,
      "libraryId": "lib-1",
      "mediaType": "book",
      "media": [
        "metadata": ["title": "Test Book"],
        "duration": audioFiles.reduce(0.0) { $0 + $1.duration },
        // `ino` is serialised as a string, as a real Audiobookshelf server sends it, though
        // callers pass an `Int` for readability. Planning/scheduling tests thus see the real
        // wire shape.
        "audioFiles": audioFiles.map { file -> [String: Any] in
          [
            "index": file.index, "ino": String(file.ino), "duration": file.duration, "mimeType": file.mimeType,
            "metadata": ["size": file.size],
          ]
        },
        "tracks": [[String: Any]](),
        "chapters": [[String: Any]](),
      ] as [String: Any],
    ]
    http.enqueue(Self.jsonResponse(object: object))
  }

  func enqueuePodcastItemDetail(itemID: String = DownloadCoordinatorHarness.podcastItemID) {
    let object: [String: Any] = [
      "id": itemID, "libraryId": "lib-1", "mediaType": "podcast",
      "media": ["metadata": ["title": "Test Podcast"], "episodes": [[String: Any]]()],
    ]
    http.enqueue(Self.jsonResponse(object: object))
  }

  func enqueueRefreshResponse(accessToken: String, refreshToken: String) {
    let body = try! JSONSerialization.data(
      withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]])
    http.enqueue(HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body))
  }

  static func jsonResponse(object: Any) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }

  // MARK: - Download-store convenience

  func fetchDownloads(itemId: Int64) throws -> [DownloadRecord] {
    try downloadStore.fetchDownloads(itemId: itemId)
  }

  func makeTempFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x42, count: bytes).write(to: url)
    return url
  }

  func makeSparseTempFile(bytes: Int64) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(bytes - 1))
    try handle.write(contentsOf: Data([0x42]))
    return url
  }

  /// The default enclosure is on a different host from the feed, the ordinary podcast shape (feed
  /// from one origin, media from a CDN). A test about feed credentials passes `enclosureURL` to
  /// choose which side of that line it wants.
  func seedRSSDownload(
    feedID: Int64 = 41, episodeKey: String = "rss-episode", bytes: Int64? = 50,
    enclosureURL: URL = URL(string: "https://media.example.test/episode.mp3")!
  ) async throws -> RSSDownloadRecord {
    let feeds = RSSFeedStore(database: database)
    let actualFeedID = try await feeds.subscribe(
      feedURL: URL(string: "https://feeds.example.test/\(feedID)")!, title: "Feed \(feedID)",
      author: "Author", synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let episodeStore = RSSEpisodeStore(database: database)
    _ = try await episodeStore.applyRefresh(
      feedId: actualFeedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: episodeKey, title: "Episode",
          enclosureURL: enclosureURL,
          enclosureType: "audio/mpeg", declaredBytes: bytes)
      ])
    let episode = try #require(
      await episodeStore.fetchEpisode(feedId: actualFeedID, identityKey: episodeKey))
    return try await rssDownloadStore.claimOrCreateAsync(episodeId: try #require(episode.id))
  }

}

// Kept: a decorator over FakeBackgroundTransferring whose arm/release gates and
// `setCurrentTasksHook` are called from DownloadSchedulingTests and DownloadReconciliationTests,
// outside this change's file list. Fold the gates into the shared fake when those move.
/// Harness-only seam for opening the adapter suspension window without changing the shared fake's
/// semantics for the rest of the SyncEngine test target.
final class DownloadSchedulingBackgroundTransferring: BackgroundTransferring, @unchecked Sendable {
  private let base = FakeBackgroundTransferring()
  private let enqueueGate = DownloadScheduleEnqueueGate(label: "enqueue")
  private let pauseGate = DownloadScheduleEnqueueGate(label: "pause")
  private let currentTasksHook = DownloadCurrentTasksHook()
  private let requests = Locked<[AuthorizedTransferRequest]>([])

  var calls: [FakeBackgroundTransferring.RecordedCall] { base.calls }
  var events: AsyncStream<BackgroundTransferEvent> { base.events }
  var enqueuedRequests: [AuthorizedTransferRequest] { requests.value }
  var acknowledgedFinishes: [TransferIdentity] { base.acknowledgedFinishes }

  func enqueue(_ request: AuthorizedTransferRequest, destination: DownloadDestinationToken) async {
    requests.withValue { $0.append(request) }
    await base.enqueue(request, destination: destination)
    await enqueueGate.waitOnFirstCallIfArmed()
  }

  func pause(identity: TransferIdentity) async {
    let isGated = pauseGate.claimFirstCallIfArmed()
    await base.pause(identity: identity)
    if isGated { await pauseGate.waitForRelease() }
  }
  func resume(identity: TransferIdentity) async { await base.resume(identity: identity) }
  func cancel(identity: TransferIdentity) async { await base.cancel(identity: identity) }
  func currentTasks() async -> [BackgroundTransferSnapshot] {
    if let hook = await currentTasksHook.take() {
      await hook()
    }
    return await base.currentTasks()
  }

  func armEnqueueGate() { enqueueGate.arm() }

  func releaseEnqueueGate() { enqueueGate.release() }

  func armPauseGate() { pauseGate.arm() }

  func releasePauseGate() { pauseGate.release() }

  func setCurrentTasksHook(_ hook: @escaping @Sendable () async -> Void) async {
    await currentTasksHook.set(hook)
  }

  func undeliveredFinishes() async -> Set<TransferIdentity> { await base.undeliveredFinishes() }
  func acknowledgeFinish(identity: TransferIdentity) async {
    await base.acknowledgeFinish(identity: identity)
  }

  func pushEvent(_ event: BackgroundTransferEvent) { base.pushEvent(event) }
  func setCurrentTasks(_ snapshots: [BackgroundTransferSnapshot]) { base.setCurrentTasks(snapshots) }
  func setUndeliveredFinishes(_ identities: Set<TransferIdentity>) {
    base.setUndeliveredFinishes(identities)
  }
}

private actor DownloadCurrentTasksHook {
  private var hook: (@Sendable () async -> Void)?

  func set(_ hook: @escaping @Sendable () async -> Void) {
    self.hook = hook
  }

  func take() -> (@Sendable () async -> Void)? {
    defer { hook = nil }
    return hook
  }
}

/// Parks the first call after `arm()` until `release()`; later calls pass. A call that arrives
/// after the release passes at once, and a parked call stays parked through task cancellation.
private final class DownloadScheduleEnqueueGate: @unchecked Sendable {
  private let armed = Locked(false)
  private let gate: TestGate<Void>

  init(label: String) {
    gate = TestGate(label: label, ignoresCancellation: true)
  }

  func arm() {
    armed.withValue { $0 = true }
    gate.hold()
  }

  func claimFirstCallIfArmed() -> Bool {
    armed.withValue { armed in
      defer { armed = false }
      return armed
    }
  }

  func waitOnFirstCallIfArmed() async {
    guard claimFirstCallIfArmed() else { return }
    await waitForRelease()
  }

  func waitForRelease() async {
    await gate.pass()
  }

  func release() {
    gate.release()
  }
}
