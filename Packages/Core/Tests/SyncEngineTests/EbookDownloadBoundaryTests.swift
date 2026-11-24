import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite("Ebook download boundary", .timeLimit(.minutes(1)))
struct EbookDownloadBoundaryTests {

  @Test("an authorized ebook request crosses BackgroundTransferring without a FileDownloadRequest")
  func authorizedEbookRequestCanBeHandedToBackgroundTransfer() async throws {
    let server = try ABSServerConfig(url: URL(string: "https://books.example.test")!)
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: account)
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: store)
    let request = try EbookRequest(itemID: "item-ebook")
    let ebookFile = EbookFileInfo(ino: "ebook-ino", ext: "epub", filename: nil, size: 10)
    let authorized = try await client.makeAuthorizedEbookRequest(
      request, ebookFile: ebookFile, account: account)
    let destination = DownloadDestinationToken(
      identity: .abs(rowID: 42), destinationURL: URL(fileURLWithPath: "/tmp/item-ebook.epub"))
    let transferring = FakeBackgroundTransferring()
    let transferRequest = AuthorizedTransferRequest(
      request: authorized.makeURLRequest(), expectedMIMEType: authorized.expectedMIMEType,
      expectedBytes: Int64(authorized.expectedSize), itemID: authorized.itemID,
      fileID: authorized.fileID)

    await transferring.enqueue(transferRequest, destination: destination)

    let recorded = try #require(transferring.enqueuedRequests.first)
    #expect(recorded.request == transferRequest)
    #expect(recorded.request.fileID == "ebook-ino")
    #expect(recorded.request.expectedMIMEType == "application/epub+zip")
    #expect(recorded.request.expectedBytes == 10)
    #expect(recorded.destination == destination)
  }

  @Test("the coordinator routes an EPUB row through the ebook authorization path")
  func coordinatorRoutesEbookRowWithoutAnAudioRequest() async throws {
    let fixture = try await EbookCoordinatorFixture()
    let download = try fixture.downloadStore.enqueue(
      accountId: fixture.accountId,
      itemId: fixture.itemID,
      serverFileIno: "ebook-ino",
      orderIndex: 0,
      destinationRelativePath: "ebook/item-ebook.epub",
      expectedBytes: 10,
      expectedMimeType: EbookRequest.acceptedMIMETypes[0],
      fileDurationSeconds: 0
    )
    let downloadID = try #require(download.id)

    await fixture.coordinator.schedule()

    #expect(try fixture.downloadStore.fetch(downloadId: downloadID)?.state == .downloading)
    let requests = fixture.transferring.enqueuedRequests
    #expect(requests.count == 1)
    #expect(requests.first?.request.fileID == "ebook-ino")
    #expect(requests.first?.request.expectedMIMEType == "application/epub+zip")
    #expect(requests.first?.request.expectedBytes == 10)
    #expect(
      requests.first?.request.makeURLRequest().url?.path
        == "/api/items/\(fixture.serverItemID)/ebook")
  }
}

private final class EbookCoordinatorFixture: @unchecked Sendable {
  let database: AppDatabase
  let accountId: Int64
  let itemID: Int64
  let serverItemID = "item-ebook"
  let downloadStore: DownloadStore
  let downloadFileStore: DownloadFileStore
  let transferring: FakeBackgroundTransferring
  let coordinator: DownloadCoordinator

  private let temporaryRoot: URL

  init() async throws {
    let server = try ABSServerConfig(url: URL(string: "https://books.example.test")!)
    let clientUUID = UUID().uuidString
    let tokenAccount = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: tokenAccount)
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: tokenStore)

    let database = try AppDatabase.inMemory()
    let account = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture", serverVersion: "2.35.1")
      try record.insert(db)
      return record
    }
    guard let accountId = account.id else { throw EbookCoordinatorFixtureError.missingID }

    let libraryId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: "library-ebook", mediaType: "book", name: "Books")
      try library.insert(db)
      guard let id = library.id else { throw EbookCoordinatorFixtureError.missingID }
      return id
    }
    let itemDAO = ItemDAO(database: database)
    let item = try await itemDAO.upsertAsync(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-ebook",
        mediaKind: "ebook", title: "Ebook", sortTitle: "ebook"))
    guard let itemID = item.id else { throw EbookCoordinatorFixtureError.missingID }

    let downloadStore = try DownloadStore(database: database)
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EbookDownloadBoundaryTests-\(UUID().uuidString)", isDirectory: true)
    let downloadFileStore = try DownloadFileStore(
      rootURL: temporaryRoot,
      fileAttributes: InertFileAttributes(),
      downloadStore: downloadStore,
      fileMover: POSIXDownloadFileMover())
    let transferring = FakeBackgroundTransferring()
    let preferences = FakeDownloadPreferences()
    let networkConditions = FakeNetworkConditions()
    let diagnostics = FakeDiagnosticsRecording()
    let freeSpaceReporting = FakeFreeSpaceReporting()
    let coordinator = DownloadCoordinator(
      client: client,
      database: database,
      downloadStore: downloadStore,
      downloadFileStore: downloadFileStore,
      backgroundTransferring: transferring,
      downloadPreferences: preferences,
      networkConditions: networkConditions,
      diagnostics: diagnostics,
      freeSpaceReporting: freeSpaceReporting)

    self.database = database
    self.accountId = accountId
    self.itemID = itemID
    self.downloadStore = downloadStore
    self.downloadFileStore = downloadFileStore
    self.transferring = transferring
    self.coordinator = coordinator
    self.temporaryRoot = temporaryRoot
  }

  deinit {
    try? FileManager.default.removeItem(at: temporaryRoot)
  }
}

private enum EbookCoordinatorFixtureError: Error {
  case missingID
}
