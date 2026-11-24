import ABSApi
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence
@testable import SyncEngine

// MARK: - Reader stubs

/// Answers each item-detail read with the next planned detail, repeating the last one. The reads
/// numbered in `lossyCalls` (counting from 1) stand for a payload that lost an episode in decoding:
/// the planned detail already lacks it, and only the diagnostics the caller passed record the drop.
// Kept: built and queried (`callCount()`) by Coordinator and Batch suites outside this packet.
actor SequencedItemDetailReader: NativeEpisodeServerSaveItemDetailReading {
  private var details: [ItemDetail]
  private let lossyCalls: Set<Int>
  private var calls = 0
  private var callsWithoutDiagnostics = 0

  init(_ details: [ItemDetail], lossyCalls: Set<Int> = []) {
    self.details = details
    self.lossyCalls = lossyCalls
  }

  func callCount() -> Int { calls }
  func callCountWithoutDiagnostics() -> Int { callsWithoutDiagnostics }

  func fetchItemDetail(
    account: TokenAccount,
    itemID: String,
    diagnostics: DecodeDiagnostics?
  ) async throws -> ItemDetail {
    calls += 1
    if diagnostics == nil { callsWithoutDiagnostics += 1 }
    if lossyCalls.contains(calls) { recordDroppedEpisode(into: diagnostics) }
    if details.count > 1 { return details.removeFirst() }
    return details[0]
  }
}

// MARK: - Save fixture

struct SaveFixture: Sendable {
  let database: AppDatabase
  let accountID: Int64
  let account: NativeEpisodeServerSaveAccount
  let command: NativeEpisodeServerSaveCommand
  let accountReader: MutableAccountReader
  let commandReader: StubCommandReader
  let subscriptions: FakeNativePodcastSubscriptionsReading
  let trace: EventLog
  let baseStore: NativeEpisodeServerSaveAttemptStore
  let attemptStore: TracingAttemptStore

  static func make(command: NativeEpisodeServerSaveCommand = makeCommand()) async throws -> SaveFixture {
    let database = try AppDatabase.inMemory()
    let accountID = try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "original-client",
        serverBaseURL: "https://server.example",
        serverUserId: "server-user",
        serverVersion: "2.35.1")
      try account.insert(db)
      return try #require(account.id)
    }
    let record = try await database.readAsync { db in
      try #require(try AccountRecord.fetchOne(db, key: accountID))
    }
    let tokenAccount = try record.credentialTokenAccount
    let account = NativeEpisodeServerSaveAccount(
      accountID: accountID,
      clientUUID: record.clientUUID,
      serverIdentityFingerprint:
        record.serverIdentityFingerprint,
      tokenAccount: tokenAccount)
    let trace = EventLog()
    let baseStore = NativeEpisodeServerSaveAttemptStore(database: database)
    return SaveFixture(
      database: database,
      accountID: accountID,
      account: account,
      command: command,
      accountReader: MutableAccountReader(account),
      commandReader: StubCommandReader(command),
      subscriptions: FakeNativePodcastSubscriptionsReading(enabled: true),
      trace: trace,
      baseStore: baseStore,
      attemptStore: TracingAttemptStore(base: baseStore, trace: trace))
  }

  func replacementAccount(clientUUID: String) async throws -> NativeEpisodeServerSaveAccount {
    let record = try await database.readAsync { db in
      try #require(try AccountRecord.fetchOne(db, key: accountID))
    }
    return NativeEpisodeServerSaveAccount(
      accountID: accountID,
      clientUUID: clientUUID,
      serverIdentityFingerprint:
        record.serverIdentityFingerprint,
      tokenAccount: try record.credentialTokenAccount)
  }
}

// MARK: - Command and item fixtures

func makeCommand(
  feedId: Int64 = 1,
  episodeId: Int64 = 2,
  guid: String? = "episode-guid",
  enclosureURL: String = "https://media.example/episode.mp3",
  feedArtworkURL: URL? = nil
) -> NativeEpisodeServerSaveCommand {
  NativeEpisodeServerSaveCommand(
    feedId: feedId,
    episodeId: episodeId,
    episodeIdentityKey: guid.map { "guid:\($0)" } ?? "sha256:" + String(repeating: "0", count: 64),
    feedTitle: "Native Show",
    feedAuthor: "Native Author",
    feedSynopsis: "Native Synopsis",
    episodeGUID: guid,
    episodeTitle: "Native Episode",
    episodeSynopsis: "Episode Synopsis",
    enclosureType: "audio/mpeg",
    declaredBytes: 42,
    durationSeconds: 12.5,
    seasonNumber: 2,
    episodeNumber: 3,
    publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
    feedURL: URL(string: "https://feeds.example/feed.xml")!,
    enclosureURL: URL(string: enclosureURL)!,
    feedArtworkURL: feedArtworkURL)
}

func testDestination() -> ServerPodcastDestination {
  ServerPodcastDestination(
    libraryID: "podcasts",
    folder: LibraryFolder(id: "folder", fullPath: "/srv/podcasts", libraryID: "podcasts"),
    nativeFeedTitle: "Native Show")!
}

func completeItem(
  episodes: [PodcastEpisode] = []
) -> ItemDetail {
  ItemDetail(
    id: "show",
    libraryID: "podcasts",
    mediaType: "podcast",
    media: .podcast(
      PodcastMedia(
        title: "Native Show",
        author: "Native Author",
        description: "Native Synopsis",
        episodes: episodes,
        isEpisodeListStructurallyComplete: true)))
}

func incompleteNativeEpisodeItem() -> ItemDetail {
  ItemDetail(
    id: "show",
    libraryID: "podcasts",
    mediaType: "podcast",
    media: .podcast(
      PodcastMedia(
        title: "Native Show",
        author: nil,
        description: nil,
        episodes: [],
        isEpisodeListStructurallyComplete: false)))
}

/// A structurally complete list whose two episodes share one id, so decoding has collapsed or
/// misidentified at least one of them. Neither carries the fixture command's GUID.
func duplicateEpisodeIDItem() -> ItemDetail {
  let duplicate = PodcastEpisode(
    id: "duplicate", title: "Duplicate", guid: "other-guid", enclosureURL: nil, contentUrl: nil,
    mimeType: "audio/mpeg", duration: nil, publishedAt: nil)
  return completeItem(episodes: [duplicate, duplicate])
}

private struct DroppedEpisodeProbe: Decodable {
  let id: String?
}

/// Records the diagnostic item-detail decoding leaves when it drops an episode element that
/// arrived without an id, through the same public lossy-array decode, so a stub can model a lossy
/// read without a test-only hook into `DecodeDiagnostics`. A nil `diagnostics` records nothing,
/// as the real read would.
func recordDroppedEpisode(into diagnostics: DecodeDiagnostics?) {
  _ = try? BoundedDecoder().decodeLossyArray(
    DroppedEpisodeProbe.self,
    from: Data(#"[{"title":"Dropped"}]"#.utf8),
    endpoint: "/api/items/:id",
    diagnostics: diagnostics,
    validating: { $0.id != nil },
    requiredKey: "id")
}

// MARK: - Seam stubs

actor EventLog {
  private var entries = [String]()

  func append(_ entry: String) { entries.append(entry) }
  func values() -> [String] { entries }
}

// Kept: `await fixture.accountReader.replace(_:)` is called from suites outside this packet.
actor MutableAccountReader: NativeEpisodeServerSaveAccountReading {
  private var value: NativeEpisodeServerSaveAccount

  init(_ value: NativeEpisodeServerSaveAccount) { self.value = value }

  func replace(_ value: NativeEpisodeServerSaveAccount) { self.value = value }
  func currentAccount() async throws -> NativeEpisodeServerSaveAccount { value }
}

// Kept: constructed by Coordinator, Batch, Pruning and Lifecycle suites outside this packet.
struct FixedCapabilityReader: ServerPodcastMutationCapabilityReading {
  let canSave: Bool

  func capability() async -> ServerPodcastMutationCapability {
    ServerPodcastMutationCapability(canSave: canSave, canRemove: false)
  }

  func invalidate() async {}
}

actor StubCommandReader: NativeEpisodeServerSaveCommandReading {
  private let command: NativeEpisodeServerSaveCommand
  private var error: NativeEpisodeServerSaveCommandReaderError?
  private var errors = [Int64: NativeEpisodeServerSaveCommandReaderError]()
  private var commands = [Int64: NativeEpisodeServerSaveCommand]()
  private var reads = 0

  init(_ command: NativeEpisodeServerSaveCommand) { self.command = command }

  func setError(_ error: NativeEpisodeServerSaveCommandReaderError?) { self.error = error }
  func setError(_ error: NativeEpisodeServerSaveCommandReaderError, for episodeID: Int64) {
    errors[episodeID] = error
  }
  func setCommands(_ commands: [Int64: NativeEpisodeServerSaveCommand]) { self.commands = commands }
  func setCommands(_ commands: [NativeEpisodeServerSaveCommand]) {
    self.commands = Dictionary(uniqueKeysWithValues: commands.map { ($0.episodeId, $0) })
  }
  func readCount() -> Int { reads }

  func read(feedId: Int64, episodeId: Int64) async throws -> NativeEpisodeServerSaveCommand {
    reads += 1
    if let error = errors[episodeId] { throw error }
    if let error { throw error }
    return commands[episodeId] ?? command
  }
}

actor StubDestinationResolver: NativeEpisodeServerSaveDestinationResolving {
  private let resolution: NativeEpisodeServerSaveDestinationResolution
  private var resolutions = [NativeEpisodeServerSaveDestinationResolution]()
  private var calls = 0
  private var choices = [ServerPodcastSaveChoice?]()

  init(_ resolution: NativeEpisodeServerSaveDestinationResolution) { self.resolution = resolution }
  init(_ resolutions: [NativeEpisodeServerSaveDestinationResolution]) {
    self.resolution = resolutions.last ?? .noAccessiblePodcastLibraries
    self.resolutions = resolutions
  }

  func callCount() -> Int { calls }
  func recordedChoices() -> [ServerPodcastSaveChoice?] { choices }

  func resolveNativeEpisodeServerSaveDestination(
    feedURL: URL,
    nativeFeedTitle: String,
    account: TokenAccount,
    choice: ServerPodcastSaveChoice?
  ) async throws -> NativeEpisodeServerSaveDestinationResolution {
    calls += 1
    choices.append(choice)
    if resolutions.isEmpty { return resolution }
    if resolutions.count > 1 { return resolutions.removeFirst() }
    return resolutions[0]
  }
}

// MARK: - Writer stubs and gates

enum WriterFailure: Error, Sendable {
  case api(APIError)
  case podcast(PodcastWriteError)
  case cancelled
}

enum CreatePlan: Sendable {
  case success(String)
  case failure(WriterFailure)
}

enum EnqueuePlan: Sendable {
  case success
  case failure(WriterFailure)
}

/// Two one-shot latches, each bounded: a wait that is never satisfied records an Issue naming it
/// instead of parking until the suite's time limit.
actor BlockingGate {
  private nonisolated let entered = WaitableState(false, label: "BlockingGate entered")
  // Stays parked on task cancellation, as the work it stands in for runs to completion.
  private nonisolated let releasedGate = TestGate<Void>(
    label: "BlockingGate released", ignoresCancellation: true)

  init() {
    releasedGate.hold()
  }

  func markEntered() {
    entered.mutate { $0 = true }
  }

  func waitUntilEntered() async {
    await entered.waitUntil("being entered") { $0 }
  }

  func release() {
    releasedGate.release()
  }

  func waitUntilReleased() async {
    await releasedGate.pass()
  }
}

// Kept: writes ordered `send.*` entries into the shared `EventLog` and is built by suites outside
// this packet.
actor StubPodcastWriter: NativeEpisodeServerSavePodcastWriting {
  private let trace: EventLog
  private let createPlan: CreatePlan
  private let enqueuePlan: EnqueuePlan
  private let createGate: BlockingGate?
  private let enqueueGate: BlockingGate?
  private var createCalls = 0
  private var enqueueCalls = 0
  private var lastCreateRequest: PodcastCreateRequest?
  private var lastEpisode: PodcastEpisodeDownloadRequest?

  init(
    trace: EventLog,
    createPlan: CreatePlan = .success("created-show"),
    enqueuePlan: EnqueuePlan = .success,
    createGate: BlockingGate? = nil,
    enqueueGate: BlockingGate? = nil
  ) {
    self.trace = trace
    self.createPlan = createPlan
    self.enqueuePlan = enqueuePlan
    self.createGate = createGate
    self.enqueueGate = enqueueGate
  }

  func counts() -> (Int, Int) { (createCalls, enqueueCalls) }
  func recordedCreateRequest() -> PodcastCreateRequest? { lastCreateRequest }
  func recordedEpisode() -> PodcastEpisodeDownloadRequest? { lastEpisode }

  func createPodcast(
    account: TokenAccount,
    request: PodcastCreateRequest,
    diagnostics: DecodeDiagnostics?
  ) async throws -> String {
    createCalls += 1
    lastCreateRequest = request
    await trace.append("send.create")
    if let createGate {
      await createGate.markEntered()
      await createGate.waitUntilReleased()
    }
    switch createPlan {
    case .success(let itemID): return itemID
    case .failure(let failure):
      switch failure {
      case .api(let error): throw error
      case .podcast(let error): throw error
      case .cancelled: throw CancellationError()
      }
    }
  }

  func enqueuePodcastEpisode(
    account: TokenAccount,
    itemID: String,
    episode: PodcastEpisodeDownloadRequest
  ) async throws {
    enqueueCalls += 1
    lastEpisode = episode
    await trace.append("send.enqueue")
    if let enqueueGate {
      await enqueueGate.markEntered()
      await enqueueGate.waitUntilReleased()
    }
    switch enqueuePlan {
    case .success: return
    case .failure(let failure):
      switch failure {
      case .api(let error): throw error
      case .podcast(let error): throw error
      case .cancelled: throw CancellationError()
      }
    }
  }

  /// This double never removes; a removal reaching it fails as an unavailable writer would.
  func removePodcastEpisode(account: TokenAccount, itemID: String, episodeID: String) async throws {
    throw RemovalUnsupportedByWriter()
  }
}

/// Thrown by writer doubles that implement only the save half of the writer contract.
struct RemovalUnsupportedByWriter: Error, Sendable {}

enum CoordinatorDetailPlan: Sendable {
  case success(ItemDetail)
  case failure(APIError)
  case cancelled
}

// MARK: - Attempt store and reader spies

// Kept: used by Coordinator, Batch, Pruning and Lifecycle suites outside this packet.
actor StubItemDetailReader: NativeEpisodeServerSaveItemDetailReading {
  private let plan: CoordinatorDetailPlan
  private let beforeReturn: (@Sendable () async -> Void)?
  private var calls = 0

  init(
    _ plan: CoordinatorDetailPlan,
    beforeReturn: (@Sendable () async -> Void)? = nil
  ) {
    self.plan = plan
    self.beforeReturn = beforeReturn
  }

  func callCount() -> Int { calls }

  func fetchItemDetail(
    account: TokenAccount,
    itemID: String,
    diagnostics: DecodeDiagnostics?
  ) async throws -> ItemDetail {
    calls += 1
    if let beforeReturn { await beforeReturn() }
    switch plan {
    case .success(let detail): return detail
    case .failure(let error): throw error
    case .cancelled: throw CancellationError()
    }
  }
}

struct TracingAttemptStore: NativeEpisodeServerSaveAttemptStoring {
  let base: NativeEpisodeServerSaveAttemptStore
  let trace: EventLog

  func beginAttemptAsync(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await base.beginAttemptAsync(
      accountId: accountId,
      feedId: feedId,
      episodeId: episodeId,
      episodeIdentityKey: episodeIdentityKey,
      alternateEpisodeIdentityKeys: [],
      preflightPresence: nil,
      now: Date())
  }

  func fetchAttemptAsync(id: Int64) async throws -> NativeEpisodeServerSaveAttemptRecord? {
    try await base.fetchAttemptAsync(id: id)
  }

  func fetchAttemptsAsync(
    accountId: Int64,
    states: Set<NativeEpisodeServerSaveAttemptState>
  ) async throws -> [NativeEpisodeServerSaveAttemptRecord] {
    try await base.fetchAttemptsAsync(accountId: accountId, states: states)
  }

  func confirmPreExistingAsync(
    attemptId: Int64,
    serverItemId: String,
    serverEpisodeId: String
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    let result = try await base.confirmPreExistingAsync(
      attemptId: attemptId, serverItemId: serverItemId, serverEpisodeId: serverEpisodeId,
      now: Date())
    await trace.append("persist.confirmPreExisting.\(serverEpisodeId)")
    return result
  }

  func recordServerEpisodeIDAsync(
    _ serverEpisodeId: String,
    attemptId: Int64
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    let result = try await base.recordServerEpisodeIDAsync(
      serverEpisodeId, attemptId: attemptId, now: Date(), updatingLocalState: { _ in })
    await trace.append("persist.serverEpisodeID")
    return result
  }

  func transitionAsync(
    attemptId: Int64,
    to newState: NativeEpisodeServerSaveAttemptState,
    serverItemId: String?,
    errorCategory: NativeEpisodeServerSaveErrorCategory?
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    let result = try await base.transitionAsync(
      attemptId: attemptId,
      to: newState,
      serverItemId: serverItemId,
      serverEpisodeId: nil,
      alternateEpisodeIdentityKeys: [],
      preflightPresence: nil,
      errorCategory: errorCategory,
      now: Date(),
      updatingLocalState: { _ in })
    await trace.append("persist.state.\(newState.rawValue)")
    return result
  }

  func transitionToRemovedApplyingReconciliation(
    attemptId: Int64,
    serverItemId: String,
    accountId: Int64,
    episodes: [PodcastEpisodeRecord]?,
    refreshedAt: Date
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    let result = try await base.transitionToRemovedApplyingReconciliation(
      attemptId: attemptId, serverItemId: serverItemId, accountId: accountId, episodes: episodes,
      refreshedAt: refreshedAt)
    await trace.append("persist.state.\(NativeEpisodeServerSaveAttemptState.removed.rawValue)")
    return result
  }

  func recordServerItemIDAsync(
    _ serverItemId: String,
    attemptId: Int64
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    let result = try await base.recordServerItemIDAsync(
      serverItemId, attemptId: attemptId, now: Date(), updatingLocalState: { _ in })
    await trace.append("persist.item.\(serverItemId)")
    return result
  }

  func recordPreflightPresenceAsync(
    _ presence: NativeEpisodeServerSavePreflightPresence,
    attemptId: Int64
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    let result = try await base.recordPreflightPresenceAsync(
      presence, attemptId: attemptId, now: Date(), updatingLocalState: { _ in })
    await trace.append("persist.preflight.\(presence.rawValue)")
    return result
  }

  /// Traced as the plain `.deleteUncertain` transition, without the concrete store's in-place
  /// refresh of an already-pending row.
  func markRemovalConvergencePendingAsync(
    attemptId: Int64,
    serverItemId: String,
    accountId: Int64,
    errorCategory: NativeEpisodeServerSaveErrorCategory
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await transitionAsync(
      attemptId: attemptId, to: .deleteUncertain, serverItemId: serverItemId,
      errorCategory: errorCategory)
  }
}
