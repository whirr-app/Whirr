import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import ABSApi
@testable import AppModel

/// Privacy canary sweep: diagnostics, "Now Playing"-feeding metadata, persisted outbox/session
/// rows and formatted errors never leak a token, credential-bearing URL, or (where forbidden) a
/// raw item/session id, position or delta. Core has no `NowPlaying` type (the MediaPlayer adapter
/// is in the App target), so that surface is covered by proving `PreparedPlaybackTrack.url`, the
/// one thing the adapter reads from Core, carries no credential. A canary token/item id is
/// planted at the bottom of the stack (`InMemoryTokenStore`, `ItemRecord.serverItemId`) and every
/// privacy-sensitive surface reachable from AppModel/SyncEngine/Persistence is swept for it.
@Suite("Playback privacy canary sweep")
struct PlaybackPrivacyCanaryTests {

  static let canaryAccessToken = "CANARY-ACCESS-TOKEN-DO-NOT-LEAK"
  static let canaryRefreshToken = "CANARY-REFRESH-TOKEN-DO-NOT-LEAK"
  static let canaryItemID = "canary-item-do-not-leak-id"
  static let canaryPodcastOrigin = "https://podcast-origin.invalid/private-feed"

  // MARK: - Diagnostics: category/timing/endpoint-class only (SECURITY.md)

  @Test("a session-gone diagnostic never carries the token, item id, position, or delta")
  func sessionGoneDiagnosticNeverCarriesTokenItemIdPositionOrDelta() async throws {
    let env = try await CanaryEnvironment()
    let sessionId = try env.seedActiveSession()
    _ = try env.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 123.456, isFinished: false, deltaSecondsSinceLastTick: 78.9, localSequence: 1,
        originKey: env.clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    env.http.enqueue(HTTPResponse(statusCode: 404, headers: [:], body: Data()))  // /sync 404 → session-gone
    env.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // preserved-position PATCH

    await env.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_020))

    let event = try #require(env.diagnostics.recorded.first { $0.category == .sessionLostDelta })
    #expect(event.category == .sessionLostDelta)
    let template = try #require(event.endpointTemplate?.path)
    // `EndpointTemplate.init?` already rejects anything containing a concrete id, query string
    // or credential (digits from a real position/delta cannot survive its charset). This asserts
    // the value is the templated form, not an accidentally passing coincidence.
    #expect(template == "/api/session/:id/sync")
    #expect(template.contains(Self.canaryItemID) == false)
    #expect(template.contains(Self.canaryAccessToken) == false)
    #expect(template.contains("123.456") == false, "no position leaks into the diagnostic")
    #expect(template.contains("78.9") == false, "no delta leaks into the diagnostic")

    // The full struct has no other free-text field: `category`/`statusClass` are closed enums
    // and `durationMilliseconds` is numeric.
    #expect(event.durationMilliseconds == 0)
  }

  // MARK: - Persisted outbox/session rows: no token ever lands in local storage

  @Test("no persisted outbox or session row ever contains the access or refresh token")
  func noPersistedRowEverContainsTheAccessOrRefreshToken() async throws {
    let env = try await CanaryEnvironment()
    let sessionId = try env.seedActiveSession()
    _ = try env.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 50, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: env.clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    _ = try env.sessionStore.close(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: 55, deltaSecondsSinceLastSend: 1, localSequence: 2,
        now: Date(timeIntervalSince1970: 1_700_000_012)))

    // `String(reflecting:)` sweeps every stored property, including the `payload*` family and
    // `podcastEpisodeId`, so a new column is covered without naming it by hand.
    let outboxRows = try env.database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(outboxRows.isEmpty == false)
    for row in outboxRows {
      let exposed = String(reflecting: row)
      #expect(exposed.contains(Self.canaryAccessToken) == false, "\(exposed)")
      #expect(exposed.contains(Self.canaryRefreshToken) == false, "\(exposed)")
    }

    let sessionRows = try env.database.read { db in try PlaybackSessionRecord.fetchAll(db) }
    #expect(sessionRows.isEmpty == false)
    for row in sessionRows {
      let exposed = String(reflecting: row)
      #expect(exposed.contains(Self.canaryAccessToken) == false, "\(exposed)")
      #expect(exposed.contains(Self.canaryRefreshToken) == false, "\(exposed)")
    }

    let accountRows = try env.database.read { db in try AccountRecord.fetchAll(db) }
    #expect(accountRows.isEmpty == false)
    for row in accountRows {
      let exposed = String(reflecting: row)
      #expect(exposed.contains(Self.canaryAccessToken) == false, "\(exposed)")
      #expect(exposed.contains(Self.canaryRefreshToken) == false, "\(exposed)")
    }
  }

  // MARK: - Formatted errors: no raw item id, url, or token in user-facing copy

  @Test("PlaybackCopy's start-failure messages never interpolate the item id, url, or token")
  func startFailureMessagesNeverInterpolateItemIdUrlOrToken() {
    let cases: [PlaybackCoordinatorError] = [
      .notAuthenticated,
      .unknownItem(PlaybackPrivacyCanaryTests.canaryItemID),
      .unusableStream,
      .persistenceFailed,
      .quiescedForLogout,
    ]
    for error in cases {
      let message = PlaybackCopy.startFailureMessage(for: error)
      #expect(message.contains(Self.canaryItemID) == false, "\(error): \(message)")
      #expect(message.contains(Self.canaryAccessToken) == false, "\(error): \(message)")
      #expect(message.contains("https://") == false, "\(error): \(message) - no raw URL in user-facing copy")
    }
  }

  // MARK: - "Now Playing"-feeding metadata: the resolved stream URL carries no credential

  @Test("a resolved playback stream URL never carries the access token, even with one configured")
  func resolvedStreamURLNeverCarriesTheAccessToken() async throws {
    let env = try await CanaryEnvironment()
    env.http.enqueue(
      CanaryEnvironment.playResponse(itemID: CanaryEnvironment.itemID, currentTime: 0, duration: 200))

    let prepared = try await env.coordinator.startSession(itemID: CanaryEnvironment.itemID, episodeID: nil)

    for track in prepared.tracks {
      let url = track.url.absoluteString
      #expect(url.contains(Self.canaryAccessToken) == false)
      #expect(url.contains(Self.canaryRefreshToken) == false)
      #expect(url.contains("token") == false, "no token-shaped query parameter at all (API-CONVENTIONS rule 2)")
    }
  }

  @Test("podcast playback stays authenticated to the configured ABS server and never contacts the feed origin")
  func podcastPlaybackNeverMakesAnUnauthorizedOrOriginRequest() async throws {
    let env = try await CanaryEnvironment()
    try await env.seedPodcastEpisode(episodeID: "episode-safe")
    env.http.enqueue(
      CanaryEnvironment.playResponse(
        itemID: CanaryEnvironment.itemID, episodeID: "episode-safe",
        currentTime: 0, duration: 200))

    let prepared = try await env.coordinator.startSession(
      itemID: CanaryEnvironment.itemID, episodeID: "episode-safe")

    #expect(env.http.requests.isEmpty == false)
    for request in env.http.requests {
      #expect(request.url.scheme == "https")
      #expect(request.url.host == "canary.example.test")
      #expect(request.url.absoluteString.contains(Self.canaryPodcastOrigin) == false)
      #expect(request.headers["Authorization"] == "Bearer \(Self.canaryAccessToken)")
    }
    for track in prepared.tracks {
      #expect(track.url.host == "canary.example.test")
      #expect(track.url.absoluteString.contains(Self.canaryPodcastOrigin) == false)
      #expect(track.url.absoluteString.contains(Self.canaryAccessToken) == false)
      #expect(track.url.absoluteString.contains(Self.canaryRefreshToken) == false)
    }
  }

  // MARK: - Episode/show projections expose display state, never stored-audio credentials

  @Test("episode metadata projection omits the stored-audio locator, token, server URL, and feed origin")
  func podcastEpisodeProjectionOmitsPrivateTransportMetadata() async throws {
    let env = try await DownloadCanaryEnvironment()
    _ = try await env.seedPodcastEpisode(
      storedAudioIno:
        "\(Self.canaryAccessToken)-\(Self.canaryRefreshToken)-\(Self.canaryPodcastOrigin)")
    var iterator = DefaultPodcastReading(database: env.database)
      .observeEpisodes(itemId: DownloadCanaryEnvironment.itemID).makeAsyncIterator()

    let episode = try #require(await iterator.next()?.first)
    let exposed = String(reflecting: episode)

    #expect(episode.isAvailableOnServer)
    #expect(exposed.contains(Self.canaryAccessToken) == false)
    #expect(exposed.contains(Self.canaryRefreshToken) == false)
    #expect(exposed.contains("download-canary.example.test") == false)
    #expect(exposed.contains(Self.canaryPodcastOrigin) == false)
  }

  @Test("durable Up Next rows omit account URL, stored-audio locator, token, and feed origin")
  func listeningQueueRowsOmitPrivateTransportMetadata() async throws {
    let env = try await DownloadCanaryEnvironment()
    _ = try await env.seedPodcastEpisode(
      storedAudioIno:
        "\(Self.canaryAccessToken)-\(Self.canaryRefreshToken)-\(Self.canaryPodcastOrigin)")
    let queue = ListeningQueueStore(database: env.database, accountId: env.accountId)
    let identity = try #require(
      ListeningIdentity.podcastEpisode(
        itemID: DownloadCanaryEnvironment.itemID,
        episodeID: DownloadCanaryEnvironment.episodeID))

    try await queue.append(identity: identity)
    let row = try #require(await queue.fetchQueue().first)
    let exposed = String(reflecting: row)

    #expect(exposed.contains(Self.canaryAccessToken) == false)
    #expect(exposed.contains(Self.canaryRefreshToken) == false)
    #expect(exposed.contains("download-canary.example.test") == false)
    #expect(exposed.contains(Self.canaryPodcastOrigin) == false)
  }

  // MARK: - Download rows never carry the access/refresh token or an absolute/real path

  @Test("no persisted download row ever contains the access/refresh token, and paths stay relative")
  func noPersistedDownloadRowEverContainsTheTokenOrAnAbsolutePath() async throws {
    let env = try await DownloadCanaryEnvironment()
    let downloadId = try env.completeDownload(ino: "canary-ino")

    let rows = try env.database.read { db in try DownloadRecord.fetchAll(db) }
    #expect(rows.isEmpty == false)
    for row in rows {
      let exposed = String(reflecting: row)
      #expect(exposed.contains(Self.canaryAccessToken) == false, "\(exposed)")
      #expect(exposed.contains(Self.canaryRefreshToken) == false, "\(exposed)")
      #expect(exposed.contains(env.downloadsRoot.path) == false, "no real container path leaks in")
      #expect(
        row.destinationRelativePath.hasPrefix("/") == false,
        "never an absolute path - only ever relative to the downloads root")
    }

    // A completion failure records only a closed-enum category, never a payload, as with the
    // playback diagnostics sweep.
    let failingDownloadId = try env.enqueueMismatchedDownload(ino: "canary-mismatch")
    #expect(throws: DownloadCompletionFailure.self) {
      _ = try env.downloadFileStore.completeTransfer(
        downloadId: failingDownloadId, temporaryFileURL: env.makeTempFile(bytes: 10),
        response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "text/html", contentLength: 10))
    }
    let failed = try #require(try env.downloadStore.fetch(downloadId: failingDownloadId))
    #expect(failed.errorCategory == .validation, "a closed category only - no message, no path, no token")

    _ = downloadId
  }

  @Test("episode download rows remain episode-scoped, relative, and free of credentials or origins")
  func episodeDownloadRowsStayPrivateAndEpisodeScoped() async throws {
    let env = try await DownloadCanaryEnvironment()
    let episodeRowID = try await env.seedPodcastEpisode(storedAudioIno: "safe-file-ino")
    _ = try env.completeEpisodeDownload(episodeRowID: episodeRowID, ino: "safe-file-ino")

    let row = try #require(
      try env.database.read { db in
        try DownloadRecord.fetchAll(db)
          .first(where: { $0.podcastEpisodeId == episodeRowID })
      })
    let exposed = String(reflecting: row)

    #expect(row.podcastEpisodeId == episodeRowID)
    #expect(row.destinationRelativePath.hasPrefix("/") == false)
    #expect(row.destinationRelativePath.contains(env.downloadsRoot.path) == false)
    #expect(exposed.contains(Self.canaryAccessToken) == false)
    #expect(exposed.contains(Self.canaryRefreshToken) == false)
    #expect(exposed.contains("download-canary.example.test") == false)
    #expect(exposed.contains(Self.canaryPodcastOrigin) == false)
  }

  // MARK: - Resolution descriptors never carry the access/refresh token

  @Test("ResolutionCenter's open-item descriptors never contain the access/refresh token")
  func resolutionDescriptorsNeverContainTheAccessOrRefreshToken() async throws {
    let env = try await DownloadCanaryEnvironment()
    _ = try env.enqueuePausedAuthDownload(ino: "canary-pausedauth")
    try env.enqueueDeadLetteredProgress(entityKey: "canary-item-progress")

    let resolutionCenter = env.makeResolutionCenter()
    let items = try await resolutionCenter.fetchOpenItems()
    #expect(items.isEmpty == false)

    for item in items {
      #expect(item.itemTitle.contains(Self.canaryAccessToken) == false)
      #expect(item.itemTitle.contains(Self.canaryRefreshToken) == false)
      switch item.kind {
      case .deadLetter(_, let reason):
        #expect(reason?.contains(Self.canaryAccessToken) != true)
        #expect(reason?.contains(Self.canaryRefreshToken) != true)
      case .progressConflict, .skewConfirmation, .pausedAuthDownload:
        break
      }
    }
  }

  // MARK: - Removal diagnostics/copy never leak a token or a real path

  @Test("account-removal's blocking-failure error carries no payload, and its copy never leaks the token or a path")
  func accountRemovalFailureCarriesNoPayloadAndItsCopyNeverLeaksTokenOrPath() throws {
    // `AccountRemovalError.deletionFailed` is a payload-free enum case, so it cannot leak. A
    // post-removal remote-confirmation failure is swallowed below the AppModel boundary and
    // cannot carry a server payload either.
    let mirror = Mirror(reflecting: AccountRemovalError.deletionFailed)
    #expect(mirror.children.isEmpty, "no associated value slot exists at all - nothing to leak")
    #expect(String(describing: AccountRemovalError.deletionFailed) == "deletionFailed")

    // The user-facing copy for this failure (SettingsCopy) is static text, asserted to contain
    // no interpolated token/path/id.
    for copy in [SettingsCopy.logoutFailedTitle, SettingsCopy.logoutFailedMessage, SettingsCopy.logoutMessage] {
      #expect(copy.contains(Self.canaryAccessToken) == false)
      #expect(copy.contains(Self.canaryRefreshToken) == false)
      #expect(copy.contains("https://") == false, "no raw URL in user-facing copy")
    }
  }
}

// MARK: - Harness

private final class CanaryEnvironment: @unchecked Sendable {
  static let itemID = "item_canary_fixture"
  static let libraryID = "lib-canary"
  static let serverSessionId = "server-session-canary"
  static let syncPath = "/api/session/\(serverSessionId)/sync"

  let http: FakeHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let diagnostics = FakeDiagnosticsRecording()
  let coordinator: PlaybackSessionCoordinator
  let drainer: OutboxDrainer
  let accountId: Int64
  let itemRowId: Int64
  let clientUUID: String

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://canary.example.test")))
    let localClientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: localClientUUID), userID: "user-1")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(
        accessToken: PlaybackPrivacyCanaryTests.canaryAccessToken,
        refreshToken: PlaybackPrivacyCanaryTests.canaryRefreshToken),
      for: account)
    http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

    let localDatabase = try AppDatabase.inMemory()
    database = localDatabase
    let accountDAO = AccountDAO(database: localDatabase)
    let saved = try accountDAO.save(
      AccountRecord(
        clientUUID: localClientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user-1",
        serverVersion: "2.35.1"))
    let localAccountId = try #require(saved.id)
    accountId = localAccountId
    clientUUID = localClientUUID
    let libraryRowId = try await localDatabase.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: Self.libraryID, mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: localDatabase)
    itemRowId = try #require(
      try itemDAO.upsert(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryRowId, serverItemId: Self.itemID, mediaKind: "book",
          title: "Title",
          sortTitle: "title")
      ).id)

    let localOutbox = try OutboxStore(database: localDatabase)
    outbox = localOutbox
    sessionStore = PlaybackSessionStore(database: localDatabase, outbox: localOutbox)
    let localDiagnostics = diagnostics
    drainer = OutboxDrainer(
      outboxStore: localOutbox, database: localDatabase, absClient: client, account: account, accountId: localAccountId,
      diagnostics: localDiagnostics)
    coordinator = PlaybackSessionCoordinator(
      client: client, database: localDatabase, outbox: localOutbox, clientSessionIDGenerator: { UUID().uuidString })
  }

  @discardableResult
  func seedActiveSession(serverSessionId: String? = CanaryEnvironment.serverSessionId) throws -> Int64 {
    let started = try sessionStore.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemRowId, duration: 3600,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let sessionId = try #require(started.id)
    if let serverSessionId {
      _ = try sessionStore.setServerSessionId(sessionId: sessionId, serverSessionId: serverSessionId)
    }
    return sessionId
  }

  func seedPodcastEpisode(episodeID: String) async throws {
    try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: itemRowId, serverEpisodeId: episodeID,
        title: "Privacy-safe episode", durationSeconds: 200, lastSeenGeneration: 1)
      try episode.insert(db)
    }
  }

  static func playResponse(
    itemID: String, episodeID: String? = nil, currentTime: Double, duration: Double
  ) -> HTTPResponse {
    var object: [String: Any] = [
      "id": serverSessionId,
      "libraryItemId": itemID,
      "mediaType": episodeID == nil ? "book" : "podcast",
      "displayTitle": "Fixture Book",
      "duration": duration,
      "currentTime": currentTime,
      "playMethod": 0,
      "deviceInfo": ["deviceId": "server-echoed-id"],
      "audioTracks": [
        [
          "index": 1, "startOffset": 0, "duration": duration, "title": "Track 1",
          "contentUrl": "/api/items/\(itemID)/file/101", "mimeType": "audio/mpeg",
        ]
      ],
      "chapters": [] as [Any],
    ]
    if let episodeID { object["episodeId"] = episodeID }
    return HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}

// MARK: - Canary harness: downloads/resolution/removal

/// Shared plumbing for the download/resolution/removal canary sweeps: a real
/// `DownloadStore`/`DownloadFileStore` (on a temp downloads root, since `DownloadFileStore`
/// does actual file I/O) plus `OutboxStore`/`ResolutionCenter`, composed against the same canary
/// access/refresh tokens `CanaryEnvironment` plants. Mirrors that environment's construction.
private final class DownloadCanaryEnvironment: @unchecked Sendable {
  static let itemID = "item_download_canary_fixture"
  static let episodeID = "episode-download-canary-fixture"
  static let libraryID = "lib-download-canary"

  let database: AppDatabase
  let downloadStore: DownloadStore
  let downloadFileStore: DownloadFileStore
  let downloadsRoot: URL
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let client: ABSClient
  let accountId: Int64
  let itemRowId: Int64

  private let cleanupRoot: () -> Void

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://download-canary.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(
        accessToken: PlaybackPrivacyCanaryTests.canaryAccessToken,
        refreshToken: PlaybackPrivacyCanaryTests.canaryRefreshToken),
      for: account)
    let http = FakeHTTPClient()
    client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

    let localDatabase = try AppDatabase.inMemory()
    database = localDatabase
    let accountDAO = AccountDAO(database: localDatabase)
    let saved = try accountDAO.save(
      AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user-1",
        serverVersion: "2.35.1"))
    let localAccountId = try #require(saved.id)
    accountId = localAccountId
    let libraryRowId = try await localDatabase.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: Self.libraryID, mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: localDatabase)
    // Every episode seeded here hangs off this item, and the queue store resolves an episode
    // identity through `ItemMediaCategory.derive`, so the show item has to be a podcast.
    itemRowId = try #require(
      try itemDAO.upsert(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryRowId, serverItemId: Self.itemID,
          mediaKind: "podcast",
          title: "Title", sortTitle: "title")
      ).id)

    downloadStore = try DownloadStore(database: localDatabase)
    let (root, cleanup) = Self.makeTempRoot()
    downloadsRoot = root
    cleanupRoot = cleanup
    downloadFileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: InertFileAttributes(), downloadStore: downloadStore)
    outbox = try OutboxStore(database: localDatabase)
    sessionStore = PlaybackSessionStore(database: localDatabase, outbox: outbox)
  }

  deinit { cleanupRoot() }

  @discardableResult
  func completeDownload(ino: String, bytes: Int64 = 50) throws -> Int64 {
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: nil, orderIndex: 0, serverFileIno: ino,
      mimeType: "audio/mpeg")
    let record = try downloadStore.enqueue(
      accountId: accountId, itemId: itemRowId, serverFileIno: ino, orderIndex: 0,
      destinationRelativePath: relativePath, expectedBytes: bytes, expectedMimeType: "audio/mpeg",
      fileDurationSeconds: 60)
    let downloadId = try #require(record.id)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    _ = try downloadFileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: try makeTempFile(bytes: bytes),
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: bytes))
    return downloadId
  }

  @discardableResult
  func seedPodcastEpisode(storedAudioIno: String) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: itemRowId, serverEpisodeId: Self.episodeID,
        title: "Privacy-safe episode", subtitle: "Privacy-safe show",
        durationSeconds: 60, sizeBytes: 50,
        storedAudioIno: storedAudioIno, storedAudioExpectedSize: 50,
        storedAudioMimeType: "audio/mpeg", storedAudioDurationSeconds: 60,
        lastSeenGeneration: 1)
      try episode.insert(db)
      return episode.id!
    }
  }

  @discardableResult
  func completeEpisodeDownload(
    episodeRowID: Int64, ino: String, bytes: Int64 = 50
  ) throws -> Int64 {
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: episodeRowID,
      orderIndex: 0, serverFileIno: ino, mimeType: "audio/mpeg")
    let record = try downloadStore.enqueue(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: episodeRowID,
      serverFileIno: ino, orderIndex: 0, destinationRelativePath: relativePath,
      expectedBytes: bytes, expectedMimeType: "audio/mpeg", fileDurationSeconds: 60)
    let downloadId = try #require(record.id)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    _ = try downloadFileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: try makeTempFile(bytes: bytes),
      response: DownloadTransferResponse(
        httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: bytes))
    return downloadId
  }

  /// A row whose expected MIME type will mismatch the completion response, forcing
  /// `completeTransfer` down the validation-failure/quarantine path.
  @discardableResult
  func enqueueMismatchedDownload(ino: String) throws -> Int64 {
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: nil, orderIndex: 1, serverFileIno: ino,
      mimeType: "audio/mpeg")
    let record = try downloadStore.enqueue(
      accountId: accountId, itemId: itemRowId, serverFileIno: ino, orderIndex: 1,
      destinationRelativePath: relativePath, expectedBytes: 10, expectedMimeType: "audio/mpeg",
      fileDurationSeconds: 60)
    let downloadId = try #require(record.id)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    return downloadId
  }

  @discardableResult
  func enqueuePausedAuthDownload(ino: String) throws -> Int64 {
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: nil, orderIndex: 2, serverFileIno: ino,
      mimeType: "audio/mpeg")
    let record = try downloadStore.enqueue(
      accountId: accountId, itemId: itemRowId, serverFileIno: ino, orderIndex: 2,
      destinationRelativePath: relativePath, expectedBytes: 10, expectedMimeType: "audio/mpeg",
      fileDurationSeconds: 60)
    let downloadId = try #require(record.id)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    _ = try downloadStore.transition(downloadId: downloadId, to: .pausedAuth)
    return downloadId
  }

  func enqueueDeadLetteredProgress(entityKey: String) throws {
    let operation = try outbox.enqueueProgress(
      accountId: accountId, entityKey: entityKey, podcastEpisodeId: nil, coalescingKey: entityKey, localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 10, isFinished: false, accumulatedDeltaSeconds: 5))
    let operationId = try #require(operation.id)
    _ = try outbox.transition(operationId: operationId, to: .sending)
    _ = try outbox.transition(operationId: operationId, to: .deadLetter, deadLetterReason: "unauthorized")
  }

  func makeResolutionCenter() -> ResolutionCenter {
    let backgroundTransferring = FakeBackgroundTransferring()
    let downloadCoordinator = DownloadCoordinator.make(
      client: client, database: database, downloadStore: downloadStore, downloadFileStore: downloadFileStore,
      backgroundTransferring: backgroundTransferring, downloadPreferences: FakeDownloadPreferences(),
      networkConditions: FakeNetworkConditions())
    return ResolutionCenter(
      database: database, outboxStore: outbox, downloadStore: downloadStore,
      downloadCoordinator: downloadCoordinator, client: client)
  }

  func makeTempFile(bytes: Int64) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x1, count: Int(bytes)).write(to: url)
    return url
  }

  private static func makeTempRoot() -> (url: URL, cleanup: () -> Void) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "DownloadCanaryTests-\(UUID().uuidString)", isDirectory: true)
    return (directory, { try? FileManager.default.removeItem(at: directory) })
  }
}
