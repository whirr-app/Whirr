import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine
import Testing

@testable import Whirr

/// Composition-level coverage for the auth-recovery bridge and model, on the real service graph
/// as in `AppEnvironmentCompositionTests`, with no fakes below the composition seam.
///
/// Wiring only: `ResolutionCenter.requestReAuthentication` reaches the real `AuthRecoveryModel`,
/// not the no-op, and bridge and model dedupe as `PodcastBackgroundRefreshHardware.sharedServices`
/// does. Transitions are in `AuthRecoveryModelTests`, events in `AuthEventObservingTests`.
@MainActor
@Suite("Auth recovery composition", .serialized)
struct AuthRecoveryCompositionTests {

  @Test("the composed ResolutionCenter's requestReAuthentication reaches the real AuthRecoveryModel, not the no-op")
  func productionEnvironmentWiresResolutionCenterReauthenticationRequest() async throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "auth-recovery-composition",
        serverBaseURL: "https://auth-recovery-composition.invalid",
        serverUserId: "auth-recovery-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "auth-recovery-library"))
    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)

    let model = try #require(environment.authRecoveryModel)
    #expect(model.state == .idle)

    await environment.dependencies.resolutionCenterAccess.requestReAuthentication()

    #expect(model.state == .required)
  }

  @Test("runtime recovery uses the same lifecycle instance exposed for account operations")
  func runtimeRecoveryModelIsBoundToRuntimeAccountLifecycle() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "auth-recovery-runtime-lifecycle",
        serverBaseURL: "https://auth-recovery-runtime-lifecycle.invalid",
        serverUserId: "auth-recovery-runtime-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "auth-recovery-runtime-library"))
    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)

    let model = try #require(environment.authRecoveryModel)
    #expect(
      (model.accountLifecycle as AnyObject) === (environment.dependencies.account as AnyObject))
  }

  @Test(
    "a same-process background wake resolves to the identical auth-recovery bridge/model the runtime composition already built"
  )
  func runtimeCompositionSharesAuthRecoveryModelWithBackgroundWake() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "auth-recovery-bg-share",
        serverBaseURL: "https://auth-recovery-bg-share.invalid",
        serverUserId: "auth-recovery-bg-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "auth-recovery-bg-library"))
    let accountId = try #require(account.id)

    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)
    let model = try #require(environment.authRecoveryModel)

    let server = try ABSServerConfig(url: try #require(URL(string: "https://auth-recovery-bg-share.invalid")))
    let services = PodcastBackgroundRefreshHardware.sharedServices(
      key: AppEnvironment.sharedServicesKey(server: server, accountID: accountId),
      server: server,
      tokenAccount: try account.credentialTokenAccount,
      tokenStore: try KeychainTokenStore(),
      database: database,
      diagnostics: DiagnosticsStore(database: database),
      accountLifecycle: AccountLifecycleService(
        tokenStore: try KeychainTokenStore(), accountDAO: AccountDAO(database: database),
        accountEndpointDAO: AccountEndpointDAO(database: database),
        accountRemover: AccountRemover(database: database)),
      appLifecycle: environment.dependencies.appLifecycle,
      networkConditions: NetworkConditionsReducer(path: RealPathObserving(), power: RealPowerObserving()),
      podcastSettingsReading: PodcastSettingsStore(database: database, accountId: accountId),
      accountId: accountId)

    #expect(services.authRecoveryEventBridge.model === model)
  }

  @Test("rebuilding AppEnvironment against the same account never creates a second auth-recovery model")
  func appEnvironmentRebuildReusesSharedAuthRecoveryModel() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "auth-recovery-rebuild",
        serverBaseURL: "https://auth-recovery-rebuild.invalid",
        serverUserId: "auth-recovery-rebuild-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "auth-recovery-rebuild-library"))

    // Mirrors `RootView.rebuildAfterAuthentication` and `.handleLoggedOut`: a fresh
    // `AppEnvironment` over the same on-disk state.
    let first = Self.environment(hardware: hardware, mode: .runtime, database: database)
    let second = Self.environment(hardware: hardware, mode: .runtime, database: database)

    let firstModel = try #require(first.authRecoveryModel)
    let secondModel = try #require(second.authRecoveryModel)
    #expect(firstModel === secondModel)
  }

  @Test("the auth-recovery bridge records only the six credential-free diagnostic categories")
  func authRecoveryBridgeRecordsCredentialFreeDiagnostics() async throws {
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "auth-recovery-diagnostics",
        serverBaseURL: "https://auth-recovery-diagnostics.invalid",
        serverUserId: "CANARY-USERNAME",
        serverVersion: "2.35.1",
        defaultLibraryId: "auth-recovery-diagnostics-library"))
    let accountId = try #require(account.id)
    let diagnostics = DiagnosticsStore(database: database)
    let bridge = AuthRecoveryEventBridge(
      accountLifecycle: AccountLifecycleService(
        tokenStore: try KeychainTokenStore(), accountDAO: AccountDAO(database: database),
        accountEndpointDAO: AccountEndpointDAO(database: database),
        accountRemover: AccountRemover(database: database)),
      diagnostics: diagnostics,
      accountId: accountId)
    let tokenAccount = try TokenAccount(
      serverURL: URL(string: "https://auth-recovery-diagnostics.invalid")!,
      userID: "CANARY-USERNAME")

    await bridge.authEvent(.refreshTransport(tokenAccount))
    await bridge.authEvent(.refreshRateLimited(tokenAccount))
    await bridge.authEvent(.refreshServerFailure(tokenAccount))
    await bridge.authEvent(.refreshDecoding(tokenAccount))
    await bridge.authEvent(.reauthenticationRequired(tokenAccount))
    await bridge.authEvent(.reauthenticationSucceeded(tokenAccount))

    let stored = try diagnostics.fetchAll(accountId: accountId)
    #expect(
      stored.map(\.category) == [
        .refreshTransport,
        .refreshRateLimited,
        .refreshServerFailure,
        .refreshDecoding,
        .reauthenticationRequired,
        .reauthenticationSucceeded,
      ])
    #expect(stored.allSatisfy { $0.durationMilliseconds == 0 })
    #expect(stored.allSatisfy { $0.endpointTemplate == nil })

    let export = try diagnostics.export(accountId: accountId)
    #expect(export.contains("CANARY-TOKEN") == false)
    #expect(export.contains("CANARY-USERNAME") == false)
    #expect(export.contains(#"{"accessToken":"CANARY-TOKEN","username":"CANARY-USERNAME"}"#) == false)
  }

  @Test("only a successful reauthentication requests an outbox drain, once, after the dead-letter requeue")
  func successfulReauthenticationRequestsOneDrain() async throws {
    let database = try AppDatabase.inMemory()
    let bridge = AuthRecoveryEventBridge(
      accountLifecycle: AccountLifecycleService(
        tokenStore: try KeychainTokenStore(), accountDAO: AccountDAO(database: database),
        accountEndpointDAO: AccountEndpointDAO(database: database),
        accountRemover: AccountRemover(database: database)),
      diagnostics: NoOpDiagnosticsRecording(),
      accountId: nil)
    let drains = DrainRequestCounter()
    bridge.requestDrainAfterRecovery = { await drains.record() }
    let tokenAccount = try TokenAccount(
      serverURL: URL(string: "https://auth-recovery-drain.invalid")!, userID: "auth-recovery-drain-user")

    await bridge.authEvent(.refreshTransport(tokenAccount))
    await bridge.authEvent(.reauthenticationRequired(tokenAccount))
    #expect(await drains.count == 0)

    await bridge.authEvent(.reauthenticationSucceeded(tokenAccount))
    #expect(await drains.count == 1)
  }

  @Test("the bridge answers nil for unset slots and survives concurrent late binding")
  func lateBoundSlotsAreLockedAndKeepTheirUnsetAnswer() async throws {
    let database = try AppDatabase.inMemory()
    let bridge = AuthRecoveryEventBridge(
      accountLifecycle: AccountLifecycleService(
        tokenStore: try KeychainTokenStore(), accountDAO: AccountDAO(database: database),
        accountEndpointDAO: AccountEndpointDAO(database: database),
        accountRemover: AccountRemover(database: database)),
      diagnostics: NoOpDiagnosticsRecording(),
      accountId: nil)
    #expect(bridge.resolutionCenter == nil)
    #expect(bridge.requestDrainAfterRecovery == nil)

    let environment = Self.environment(
      hardware: PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering()), database: database)
    let center = try #require(environment.dependencies.resolutionCenterAccess as? ResolutionCenter)
    bridge.resolutionCenter = center

    // `ABSClient` reports auth events off the main actor, so both slots are read and written from
    // tasks that are not main-actor-isolated.
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask {
          #expect(bridge.resolutionCenter === center)
          bridge.requestDrainAfterRecovery = {}
          #expect(bridge.requestDrainAfterRecovery != nil)
        }
      }
    }

    bridge.resolutionCenter = nil
    bridge.requestDrainAfterRecovery = nil
    #expect(bridge.resolutionCenter == nil)
    #expect(bridge.requestDrainAfterRecovery == nil)
  }

  @Test(
    "a successful reauthentication event resumes paused-auth downloads and requeues the unauthorized dead letter exactly once"
  )
  func successfulRecoveryResumesPausedAuthDownloadsAndUnauthorizedDeadLettersOnce() async throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "auth-recovery-resume",
        serverBaseURL: "https://auth-recovery-resume.invalid",
        serverUserId: "auth-recovery-resume-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "auth-recovery-resume-library"))
    let accountId = try #require(account.id)
    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)

    guard let downloadCoordinator = handDownloadCoordinator(environment) else {
      Issue.record("expected the production DownloadCoordinator conformance")
      return
    }
    guard let resolutionCenter = environment.dependencies.resolutionCenterAccess as? ResolutionCenter else {
      Issue.record("expected the production ResolutionCenter conformance")
      return
    }
    _ = downloadCoordinator

    let library = try LibraryDAO(database: database).upsert(
      LibraryRecord(
        accountId: accountId, serverLibraryId: "lib-resume", mediaType: "book", name: "Library",
        lastSeenGeneration: 1))
    let libraryId = try #require(library.id)
    let itemRecord = try ItemDAO(database: database).upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "server-item-resume",
        mediaKind: "book", title: "Title", sortTitle: "Title"))
    let itemRowId = try #require(itemRecord.id)

    let downloadStore = try DownloadStore(database: database)
    let downloadRecord = try downloadStore.enqueue(
      accountId: accountId, itemId: itemRowId, serverFileIno: "1", orderIndex: 0,
      destinationRelativePath: "resume/file-0", expectedBytes: 10, expectedMimeType: "audio/mp4",
      fileDurationSeconds: 5)
    let downloadId = try #require(downloadRecord.id)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    _ = try downloadStore.transition(downloadId: downloadId, to: .pausedAuth)

    let outboxStore = try OutboxStore(database: database)
    let operation = try outboxStore.enqueueProgress(
      accountId: accountId, entityKey: "server-item-resume", podcastEpisodeId: nil,
      coalescingKey: "auth-recovery-composition-fixture", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 0))
    let operationId = try #require(operation.id)
    _ = try outboxStore.transition(operationId: operationId, to: .sending)
    _ = try outboxStore.transition(operationId: operationId, to: .deadLetter, deadLetterReason: "unauthorized")

    let server = try ABSServerConfig(url: try #require(URL(string: "https://auth-recovery-resume.invalid")))
    let services = PodcastBackgroundRefreshHardware.sharedServices(
      key: AppEnvironment.sharedServicesKey(server: server, accountID: accountId),
      server: server,
      tokenAccount: try account.credentialTokenAccount,
      tokenStore: try KeychainTokenStore(),
      database: database,
      diagnostics: DiagnosticsStore(database: database),
      accountLifecycle: AccountLifecycleService(
        tokenStore: try KeychainTokenStore(), accountDAO: AccountDAO(database: database),
        accountEndpointDAO: AccountEndpointDAO(database: database),
        accountRemover: AccountRemover(database: database)),
      appLifecycle: environment.dependencies.appLifecycle,
      networkConditions: NetworkConditionsReducer(path: RealPathObserving(), power: RealPowerObserving()),
      podcastSettingsReading: PodcastSettingsStore(database: database, accountId: accountId),
      accountId: accountId)

    // The identical `ResolutionCenter` that `AppEnvironment` composed, not a second one.
    #expect(services.authRecoveryEventBridge.resolutionCenter === resolutionCenter)

    let tokenAccount = try TokenAccount(
      serverURL: URL(string: "https://auth-recovery-resume.invalid")!, userID: "auth-recovery-resume-user")
    await services.authRecoveryEventBridge.authEvent(.reauthenticationSucceeded(tokenAccount))
    // A second delivery is idempotent. `ResolutionCenter` already guarantees that for repeated
    // calls.
    await services.authRecoveryEventBridge.authEvent(.reauthenticationSucceeded(tokenAccount))

    #expect(try downloadStore.fetch(downloadId: downloadId)?.state != .pausedAuth)
    let requeued = try database.read { db in
      try OutboxOperationRecord.fetchOne(db, key: operationId)
    }
    // Requeued, not dead-lettered. Recovery then drains it at once against this fixture's
    // unreachable host, so it may already be waiting to retry.
    #expect(requeued?.state == .pending || requeued?.state == .retryWaiting)
  }

  private static func environment(
    hardware: PlaybackHardware,
    mode: AppEnvironment.Mode = .runtime,
    database: AppDatabase? = nil
  ) -> AppEnvironment {
    let database = database ?? (try! AppDatabase.inMemory())
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "whirr-auth-recovery-composition-\(UUID().uuidString)", isDirectory: true)
    return AppEnvironment(
      hardware: hardware,
      mode: mode,
      database: database,
      applicationSupportDirectory: directory)
  }
}

private actor DrainRequestCounter {
  private(set) var count = 0
  func record() { count += 1 }
}
