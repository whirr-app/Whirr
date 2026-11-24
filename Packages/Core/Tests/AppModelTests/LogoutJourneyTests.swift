import Foundation
import GRDB
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import ABSApi
@testable import AppModel

/// The logout product journey ("warn, allow cancellation, and on confirmation fully and
/// irreversibly remove every local artifact") as one deterministic, composed-model test.
/// Drives the real `SettingsModel` (`SettingsCopy.logoutMessage` is the warning text) over a real
/// `AccountLifecycleService`/`AccountRemovalCoordinator`, wired as `AccountRemovalWorkflowTests`
/// proves production wires it. A real on-disk `AppDatabase` and a file genuinely produced by
/// `DownloadStore`/`DownloadFileStore` give "both sweeps green" (`AccountRemover`'s DB-row sweep
/// and file-system-root sweep) something real to verify absent.
@MainActor
@Suite("Logout journey (PRODUCT journey 9)")
struct LogoutJourneyTests {

  @Test("cancelling at the warning leaves the account, its download, and tokens fully intact")
  func cancellingAtTheWarningLeavesEverythingIntact() async throws {
    let env = try await LogoutJourneyEnvironment()
    let model = try env.makeSettingsModel()

    model.requestLogout()
    #expect(model.logoutState == .confirming)
    // The warning copy must enumerate what confirming would destroy.
    #expect(SettingsCopy.logoutMessage.contains("downloaded book"))
    // Removal cancels in-flight transfers, so the warning has to name them. A user who reads only
    // "downloaded book" can reasonably think a running download is safe.
    #expect(SettingsCopy.logoutMessage.contains("still in progress"))
    #expect(SettingsCopy.logoutMessage.contains("offline listening progress"))

    model.cancelLogout()
    #expect(model.logoutState == .idle, "cancelling never calls logout() at all")

    #expect(try env.fetchAccountRow() != nil)
    #expect(try env.hasStoredTokens())
    #expect(FileManager.default.fileExists(atPath: env.downloadedFileURL.path))
    try env.assertBothSweepsWouldFindSomethingToRemove()
  }

  @Test("confirming logout removes the account, its downloaded book, and offline progress - both sweeps green")
  func confirmingLogoutRemovesEverythingWithBothSweepsGreen() async throws {
    let env = try await LogoutJourneyEnvironment()
    env.stubSuccessfulServerLogout()
    let model = try env.makeSettingsModel()

    model.requestLogout()
    #expect(model.logoutState == .confirming)
    await model.confirmLogout()

    // `.idle` (never `.failed`) is only reached once `AccountRemovalCoordinator.confirmRemoval()`
    // returned without throwing `AccountRemovalError.deletionFailed`, meaning both `AccountRemover`
    // sweeps (schema-driven DB rows, file-system roots) verified nothing survived.
    #expect(model.logoutState == .idle, "both sweeps passed - no AccountRemovalError surfaced")

    #expect(try env.fetchAccountRow() == nil, "account row and every row it owned, including the download, are gone")
    #expect(try env.hasStoredTokens() == false)
    #expect(
      FileManager.default.fileExists(atPath: env.downloadedFileURL.path) == false,
      "the downloaded book's file is gone")
    #expect(
      FileManager.default.fileExists(atPath: env.downloadsAccountRootURL.path) == false,
      "the whole per-account downloads directory is gone")

    // A second confirm (e.g. a stray repeat call) stays a no-op: nothing is left to remove.
    await model.confirmLogout()
    #expect(model.logoutState == .idle)
  }
}

// MARK: - Environment

/// One journey's fixed identity over a real temporary on-disk `AppDatabase` and downloads root.
/// Follows `AccountRemovalTestSupport.swift`'s harness shape, with a genuine completed download
/// for both of `AccountRemover`'s sweeps to verify gone, wrapped in the real
/// `SettingsModel`/`AccountLifecycleService` layers `AccountRemovalWorkflowTests` does not cover.
private final class LogoutJourneyEnvironment: @unchecked Sendable {
  let serverBaseURL = "https://logout-journey.example.test"
  let serverUserId = "user-1"

  let database: AppDatabase
  let downloadsRootURL: URL
  let coverCacheRootURL: URL
  let exportedDiagnosticsRootURL: URL
  let tokenStore: InMemoryTokenStore
  let tokenAccount: TokenAccount
  let http: FakeHTTPClient
  let server: ABSServerConfig
  let accountId: Int64
  let downloadedFileURL: URL
  let downloadsAccountRootURL: URL

  private let fixture: SuiteOnDiskDatabases

  init() async throws {
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "LogoutJourneyTests")
    self.fixture = fixture
    let directory = fixture.scope.directoryURL
    downloadsRootURL = directory.appendingPathComponent("Downloads", isDirectory: true)
    coverCacheRootURL = directory.appendingPathComponent("CoverImages", isDirectory: true)
    exportedDiagnosticsRootURL = directory.appendingPathComponent("Diagnostics", isDirectory: true)
    try FileManager.default.createDirectory(at: coverCacheRootURL, withIntermediateDirectories: true)
    try Data([0x1]).write(to: coverCacheRootURL.appendingPathComponent("cover.jpg"))
    try FileManager.default.createDirectory(at: exportedDiagnosticsRootURL, withIntermediateDirectories: true)
    try Data([0x1]).write(to: exportedDiagnosticsRootURL.appendingPathComponent("diagnostics.txt"))

    tokenStore = InMemoryTokenStore()
    http = FakeHTTPClient()
    server = try ABSServerConfig(url: try #require(URL(string: serverBaseURL)))

    database = try fixture.scope.open(fileAttributes: POSIXFileAttributeApplier())
    let accountDAO = AccountDAO(database: database)
    let saved = try accountDAO.save(
      AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: serverBaseURL, serverUserId: serverUserId,
        serverVersion: "2.35.1"))
    let localAccountId = try #require(saved.id)
    accountId = localAccountId
    let tokenAccount = try saved.credentialTokenAccount
    self.tokenAccount = tokenAccount
    try tokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: tokenAccount)

    let libraryRowId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: database)
    let itemRowId = try #require(
      try itemDAO.upsert(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryRowId, serverItemId: "item-1", mediaKind: "book",
          title: "Book", sortTitle: "book")
      ).id)

    // A genuinely completed download: a real `DownloadStore` row plus a real file moved into
    // place by `DownloadFileStore`'s own completion protocol, never a bare placeholder.
    let downloadStore = try DownloadStore(database: database)
    let downloadFileStore = try DownloadFileStore(
      rootURL: downloadsRootURL, fileAttributes: InertFileAttributes(), downloadStore: downloadStore)
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: localAccountId, itemId: itemRowId, podcastEpisodeId: nil, orderIndex: 0,
      serverFileIno: "ino-1", mimeType: "audio/mpeg")
    let record = try downloadStore.enqueue(
      accountId: localAccountId, itemId: itemRowId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: relativePath, expectedBytes: 10, expectedMimeType: "audio/mpeg",
      fileDurationSeconds: 60)
    let downloadId = try #require(record.id)
    _ = try await downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x1, count: 10).write(to: tempFile)
    _ = try downloadFileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: tempFile,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 10))

    downloadedFileURL = downloadFileStore.absoluteURL(forRelativePath: relativePath)
    downloadsAccountRootURL = downloadsRootURL.appendingPathComponent("\(localAccountId)", isDirectory: true)
    #expect((try? downloadStore.fetch(downloadId: downloadId)?.state) == .completed)
  }

  func stubSuccessfulServerLogout() {
    http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
  }

  @MainActor
  func makeSettingsModel() throws -> SettingsModel {
    let accountDAO = AccountDAO(database: database)
    let accountRemover = AccountRemover(database: database)
    let journalStore = AccountRemovalJournalStore(database: database)
    let http = self.http
    let removalCoordinator = AccountRemovalCoordinator(
      tokenStore: tokenStore,
      accountDAO: accountDAO,
      accountEndpointDAO: AccountEndpointDAO(database: database),
      journalStore: journalStore,
      accountRemover: accountRemover,
      clientFactory: { server, tokenStore in ABSClient(server: server, httpClient: http, tokenStore: tokenStore) },
      downloadsRootURL: downloadsRootURL,
      coverCacheRootURL: coverCacheRootURL,
      exportedDiagnosticsRootURL: exportedDiagnosticsRootURL
    )
    let lifecycle = AccountLifecycleService(
      tokenStore: tokenStore, accountDAO: accountDAO,
      accountEndpointDAO: AccountEndpointDAO(database: database), accountRemover: accountRemover,
      removalCoordinator: removalCoordinator)
    return SettingsModel(downloadPreferences: NoOpDownloadPreferences(), account: lifecycle)
  }

  func fetchAccountRow() throws -> AccountRecord? {
    try AccountDAO(database: database).fetch()
  }

  func hasStoredTokens() throws -> Bool {
    return try tokenStore.load(for: tokenAccount) != nil
  }

  /// Sanity check for the cancellation test: this environment did seed something for both sweeps
  /// to find, so "everything intact" after cancelling is a meaningful assertion.
  func assertBothSweepsWouldFindSomethingToRemove() throws {
    let owned = try AccountRemover(database: database).accountOwnedTables()
    #expect(owned.contains("download"), "the schema-driven sweep covers the download table")
    #expect(FileManager.default.fileExists(atPath: downloadsAccountRootURL.path))
  }
}
