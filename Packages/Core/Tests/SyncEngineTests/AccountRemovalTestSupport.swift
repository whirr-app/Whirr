import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Shared plumbing for `AccountRemovalWorkflowTests`/`AccountRemovalCrashRecoveryTests`: an
/// on-disk `AppDatabase` (reopened across a simulated relaunch), a shared `InMemoryTokenStore`
/// (the Keychain survives a real relaunch, so reuse across simulated launches is accurate), and
/// real temp directories for the downloads, cover cache and exported-diagnostics roots so file
/// removal is exercised for real.
final class AccountRemovalTestHarness: @unchecked Sendable {
  let databaseURL: URL
  let tokenStore: InMemoryTokenStore
  let transport: ScriptedAccountTransport
  let downloadsRootURL: URL
  let coverCacheRootURL: URL
  let exportedDiagnosticsRootURL: URL
  /// Two roots, as the app passes them: the App Group widget folder and the private token map.
  let widgetRootURLs: [URL]

  let serverBaseURL = "https://books.example.test"
  let serverUserId = "user-1"
  private(set) var credentialNamespace: String?

  private let tempDirectory: URL

  init() throws {
    tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AccountRemovalTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    databaseURL = tempDirectory.appendingPathComponent("app.sqlite")
    downloadsRootURL = tempDirectory.appendingPathComponent("Downloads", isDirectory: true)
    coverCacheRootURL = tempDirectory.appendingPathComponent("CoverImages", isDirectory: true)
    exportedDiagnosticsRootURL = tempDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    widgetRootURLs = [
      tempDirectory.appendingPathComponent("AppGroup/Widgets", isDirectory: true),
      tempDirectory.appendingPathComponent("WidgetTokens", isDirectory: true),
    ]
    tokenStore = InMemoryTokenStore()
    transport = ScriptedAccountTransport()
  }

  deinit {
    try? FileManager.default.removeItem(at: tempDirectory)
  }

  /// Opens a fresh `AppDatabase` over this harness's on-disk file: the "relaunch" moment a
  /// crash-recovery test cuts across. The first open clones the migrated template.
  func openDatabase() throws -> AppDatabase {
    try OnDiskDatabaseTemplate.seedIfAbsent(at: databaseURL)
    return try AppDatabase.onDisk(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
  }

  /// Seeds a signed-in account row plus its matching Keychain tokens, and (optionally) a
  /// downloaded file under this harness's downloads root so removal has something real to delete
  /// and verify.
  @discardableResult
  func seedSignedInAccount(database: AppDatabase, withDownloadFile: Bool = false) async throws -> Int64 {
    let saved = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: serverBaseURL, serverUserId: serverUserId,
        serverVersion: "2.35.1")
      try record.save(db)
      return record
    }
    let accountId = try #require(saved.id)
    credentialNamespace = saved.credentialNamespace
    let tokenAccount = try saved.credentialTokenAccount
    try tokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: tokenAccount)

    for root in widgetRootURLs {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try Data([0x1]).write(to: root.appendingPathComponent("file"))
    }
    if withDownloadFile {
      let accountDir = downloadsRootURL.appendingPathComponent("\(accountId)", isDirectory: true)
      try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
      try Data([0x1]).write(to: accountDir.appendingPathComponent("file.m4b"))
    }
    return accountId
  }

  /// Queues one `200` `/logout` response. Call twice up front in a crash-recovery test that
  /// might legitimately attempt the network call twice (once per "launch"). A resumed attempt
  /// after tokens are already wiped never calls the network (`ABSApi`'s `logoutImpl` skips the
  /// request once no tokens are found), so this is consumed at most once in practice, but
  /// queuing defensively avoids coupling a test to that detail.
  func stubSuccessfulLogout() async {
    await transport.stub(
      path: "/logout", response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
  }

  func makeCoordinator(
    database: AppDatabase,
    tokenStore overrideTokenStore: (any TokenStoring)? = nil,
    customHeaderStore: (any CustomHeaderStoring)? = nil,
    playback: (any PlaybackSyncing)? = nil,
    downloadCoordinator: DownloadCoordinator? = nil,
    cancelForegroundSync: @escaping @Sendable () async -> Void = {},
    drainOutboxBeforeRemoval: @escaping @Sendable () async -> Void = {},
    outboxDrainBound: Duration = .seconds(5),
    clearCachedArtwork: @escaping @Sendable () async throws -> Void = {},
    client liveClient: ABSClient? = nil,
    useDownloadsRoot: Bool = true,
    useCoverCache: Bool = true,
    useDiagnostics: Bool = true,
    useWidgetRoots: Bool = true
  ) -> AccountRemovalCoordinator {
    let transport = self.transport
    let headerStore = customHeaderStore ?? InMemoryCustomHeaderStore()
    return AccountRemovalCoordinator(
      tokenStore: overrideTokenStore ?? tokenStore,
      accountDAO: AccountDAO(database: database),
      accountEndpointDAO: AccountEndpointDAO(database: database),
      journalStore: AccountRemovalJournalStore(database: database),
      accountRemover: AccountRemover(database: database),
      customHeaderStore: headerStore,
      // A supplied client stands in for the runtime graph's shared one, which removal reuses
      // instead of building its own.
      clientFactory: { server, tokenStore in
        if let liveClient { return liveClient }
        return ABSClient(
          server: server, httpClient: transport, tokenStore: tokenStore,
          customHeaderStore: headerStore)
      },
      playback: playback,
      downloadCoordinator: downloadCoordinator,
      cancelForegroundSync: cancelForegroundSync,
      drainOutboxBeforeRemoval: drainOutboxBeforeRemoval,
      outboxDrainBound: outboxDrainBound,
      downloadsRootURL: useDownloadsRoot ? downloadsRootURL : nil,
      coverCacheRootURL: useCoverCache ? coverCacheRootURL : nil,
      exportedDiagnosticsRootURL: useDiagnostics ? exportedDiagnosticsRootURL : nil,
      widgetRootURLs: useWidgetRoots ? widgetRootURLs : [],
      clearCachedArtwork: clearCachedArtwork
    )
  }

  func fetchAccountRow(database: AppDatabase) throws -> AccountRecord? {
    try AccountDAO(database: database).fetch()
  }

  func hasStoredTokens() throws -> Bool {
    let namespace = try #require(credentialNamespace)
    let tokenAccount = try TokenAccount(credentialNamespace: namespace, userID: serverUserId)
    return try tokenStore.load(for: tokenAccount) != nil
  }
}

// Kept: a decorator over the harness's own store, which the harness reads back to prove what was
// cleared; `FakeTokenStoring` would hold a second copy of the tokens.
final class ToggleClearTokenStore: TokenStoring, @unchecked Sendable {
  private let base: any TokenStoring
  private let lock = NSLock()
  private var clearFails = true

  init(base: any TokenStoring) {
    self.base = base
  }

  var shouldFailClear: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return clearFails
    }
    set {
      lock.lock()
      clearFails = newValue
      lock.unlock()
    }
  }

  func save(_ tokens: TokenPair, for account: TokenAccount) throws {
    try base.save(tokens, for: account)
  }

  func load(for account: TokenAccount) throws -> TokenPair? {
    try base.load(for: account)
  }

  func clear(for account: TokenAccount) throws {
    if shouldFailClear { throw FakeCredentialStoreError.clearFailed }
    try base.clear(for: account)
  }
}

final class ToggleClearHeaderStore: CustomHeaderStoring, @unchecked Sendable {
  private let base = InMemoryCustomHeaderStore()
  private let lock = NSLock()
  private var clearFails = true

  var shouldFailClear: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return clearFails
    }
    set {
      lock.lock()
      clearFails = newValue
      lock.unlock()
    }
  }

  func save(_ headers: CustomHeaders, for serverURL: URL) throws {
    try base.save(headers, for: serverURL)
  }

  func load(for serverURL: URL) throws -> CustomHeaders? {
    try base.load(for: serverURL)
  }

  func clear(for serverURL: URL) throws {
    if shouldFailClear { throw FakeCredentialStoreError.clearFailed }
    try base.clear(for: serverURL)
  }
}

enum FakeCredentialStoreError: Error, Sendable, Equatable {
  case clearFailed
}

// Kept: a decorator over the harness's store whose `clear` claims success and mutates nothing.
final class StickyClearTokenStore: TokenStoring, @unchecked Sendable {
  private let base: any TokenStoring

  init(base: any TokenStoring) {
    self.base = base
  }

  func save(_ tokens: TokenPair, for account: TokenAccount) throws {
    try base.save(tokens, for: account)
  }

  func load(for account: TokenAccount) throws -> TokenPair? {
    try base.load(for: account)
  }

  func clear(for account: TokenAccount) throws {
    // Claims success without mutating the underlying store.
  }
}

actor AccountRemovalCancellationGate {
  private var calls = 0
  // The blocked call runs to completion regardless of cancellation, so a cancelled one stays
  // parked until released.
  private nonisolated let gate = TestGate<Void>(
    label: "AccountRemovalCancellationGate block", ignoresCancellation: true)

  init() {
    gate.hold()
  }

  var callCount: Int { calls }

  func block() async {
    calls += 1
    await gate.pass()
  }

  func waitUntilBlocked() async {
    await gate.waitUntilParked()
  }

  func release() {
    gate.release()
  }
}

/// A minimal thread-safe counter for spying on a `@Sendable () async -> Void` closure's call
/// count (`TestSupport`'s own `Locked` is internal to that module, not visible here).
final class TestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
