import Foundation
import GRDB
import TestSupport
import Testing

@testable import ABSApi
@testable import Persistence
@testable import SyncEngine

@Suite("Smart list show expansion")
struct SmartListShowExpansionTests {
  // MARK: - Chunking

  private func show(_ id: Int64, _ count: Int?) -> SmartListShowExpansion.ChunkShow {
    .init(localItemID: id, serverItemID: "s\(id)", knownEpisodeCount: count)
  }

  @Test("chunks hold at most 10 shows and 2,000 known episodes")
  func chunksAreBoundedByShowsAndEpisodes() {
    let small = (1...25).map { show(Int64($0), 5) }
    let chunks = SmartListShowExpansion.chunks(small)
    #expect(chunks.map(\.count) == [10, 10, 5])

    let heavy = [show(1, 900), show(2, 900), show(3, 300), show(4, 1)]
    let heavyChunks = SmartListShowExpansion.chunks(heavy)
    #expect(heavyChunks.map { $0.map(\.localItemID) } == [[1, 2], [3, 4]])
    #expect(
      heavyChunks.allSatisfy { $0.reduce(0) { $0 + ($1.knownEpisodeCount ?? 0) } <= 2_000 })
  }

  @Test("an unknown count is a chunk of its own and a show over the cap skips batch")
  func unknownAndOversizedShows() {
    let shows = [show(1, 10), show(2, nil), show(3, 10), show(4, 2_001), show(5, 2_000)]
    let chunks = SmartListShowExpansion.chunks(shows)
    #expect(chunks.map { $0.map(\.localItemID) } == [[1], [2], [3], [5]])
  }

  // MARK: - Completeness

  @Test("a batch response never soft-deletes or completes; the per-show fetch does both")
  func batchIsPartialAndPerShowFetchIsComplete() async throws {
    let harness = try await ExpansionHarness()
    let showID = try await harness.insertShow("show-1")
    try await harness.insertEpisode(itemID: showID, serverEpisodeID: "stale")
    try await harness.makeList(scope: .only, shows: ["show-1"])
    harness.http.failItemGets = true

    let first = await harness.expansion().expandDueShows()

    // The batch landed, then the single fetch was refused (a whole-pass failure), so only the
    // batch's effect is on disk.
    #expect(harness.http.paths.contains("/api/items/batch/get"))
    #expect(first.batchFilledShows == 1)
    #expect(first.completedShows == 0)
    #expect(try harness.episode("fresh")?.softDeleted == false)
    #expect(try harness.episode("stale")?.softDeleted == false)
    #expect(try harness.lastCompleteEpisodeListAt(showID) == nil)

    harness.http.failItemGets = false
    let second = await harness.expansion().expandDueShows()

    #expect(second.completedShows == 1)
    #expect(try harness.episode("stale")?.softDeleted == true)
    #expect(try harness.episode("fresh")?.softDeleted == false)
    #expect(try harness.lastCompleteEpisodeListAt(showID) != nil)
  }

  @Test("a complete show is not fetched again")
  func completeShowIsLeftAlone() async throws {
    let harness = try await ExpansionHarness()
    try await harness.insertShow("show-1")
    try await harness.makeList(scope: .only, shows: ["show-1"])

    _ = await harness.expansion().expandDueShows()
    let before = harness.http.paths.count
    let again = await harness.expansion().expandDueShows()

    #expect(harness.http.paths.count == before)
    #expect(again == SmartListShowExpansion.Summary())
  }

  // MARK: - Chunk halving

  @Test("a size refusal halves the chunk down to single shows and never sends an over-large body")
  func sizeRefusalHalvesTheChunk() async throws {
    let harness = try await ExpansionHarness()
    for number in 1...4 { try await harness.insertShow("show-\(number)", count: 10) }
    try await harness.makeList(scope: .all, shows: [])
    harness.http.refuseBatchesLargerThan = 1

    let summary = await harness.expansion().expandDueShows()

    // Sizes asked for: 4 (refused), 2 (refused), 1, 1, 2 (refused), 1, 1 — never more than one
    // show once a size refusal was seen below that size.
    #expect(harness.http.batchSizes == [4, 2, 1, 1, 2, 1, 1])
    #expect(summary.batchFilledShows == 4)
    #expect(summary.completedShows == 4)
    #expect(harness.http.largestBodyServed <= BoundedDecoderLimits.maximumBodyBytes)
  }

  @Test("a single show refused for size skips batch and is still fetched on its own")
  func singleOversizedShowSkipsBatch() async throws {
    let harness = try await ExpansionHarness()
    let showID = try await harness.insertShow("show-1", count: 10)
    try await harness.makeList(scope: .only, shows: ["show-1"])
    harness.http.refuseBatchesLargerThan = 0

    let summary = await harness.expansion().expandDueShows()

    #expect(harness.http.batchSizes == [1])
    #expect(summary.batchFilledShows == 0)
    #expect(summary.completedShows == 1)
    #expect(try harness.lastCompleteEpisodeListAt(showID) != nil)
  }

  @Test("a show over the episode cap never goes to batch")
  func hugeShowIsNotBatched() async throws {
    let harness = try await ExpansionHarness()
    try await harness.insertShow("show-1", count: 5_000)
    try await harness.makeList(scope: .only, shows: ["show-1"])

    let summary = await harness.expansion().expandDueShows()

    #expect(harness.http.batchSizes.isEmpty)
    #expect(summary.completedShows == 1)
  }

  // MARK: - Budget and backoff

  @Test("the per-pass budget bounds the shows expanded")
  func budgetBoundsThePass() async throws {
    let harness = try await ExpansionHarness()
    for number in 1...3 { try await harness.insertShow("show-\(number)", count: 1) }
    try await harness.makeList(scope: .all, shows: [])

    let summary = await harness.expansion(showBudget: 2).expandDueShows()

    #expect(summary.completedShows == 2)
    #expect(harness.http.itemGetPaths == ["/api/items/show-1", "/api/items/show-2"])
  }

  @Test("a show in backoff is skipped and a show-level failure backs off and carries on")
  func perShowBackoffIsHonoured() async throws {
    let harness = try await ExpansionHarness()
    let backedOff = try await harness.insertShow("show-1", count: 1)
    let missing = try await harness.insertShow("show-2", count: 1)
    try await harness.insertShow("show-3", count: 1)
    try await harness.makeList(scope: .all, shows: [])
    try await PodcastCatalogRefreshStore(database: harness.database).recordShowFailure(
      itemID: backedOff, at: ExpansionHarness.now, randomUnit: 0.5)
    harness.http.notFoundItems = ["show-2"]

    let summary = await harness.expansion().expandDueShows()

    #expect(harness.http.itemGetPaths == ["/api/items/show-2", "/api/items/show-3"])
    #expect(summary.completedShows == 1)
    #expect(summary.failedShows == 1)
    #expect(try harness.nextEligibleAttempt(missing) != nil)
  }

  // MARK: - Cancellation

  @Test("cancelling stops the pass and keeps what already committed")
  func cancellationKeepsCommittedProgress() async throws {
    let harness = try await ExpansionHarness()
    let first = try await harness.insertShow("show-1", count: 1)
    try await harness.insertShow("show-2", count: 1)
    try await harness.insertShow("show-3", count: 1)
    try await harness.makeList(scope: .all, shows: [])
    harness.http.suspendItemGets = ["show-2"]
    let expansion = harness.expansion()

    let task = Task { await expansion.expandDueShows() }
    await harness.http.waitForPath("/api/items/show-2")
    task.cancel()
    let summary = await task.value

    #expect(summary.completedShows == 1)
    #expect(try harness.lastCompleteEpisodeListAt(first) != nil)
    #expect(harness.http.itemGetPaths == ["/api/items/show-1", "/api/items/show-2"])
  }

  @Test("an already cancelled task sends nothing")
  func cancelledBeforeStartSendsNothing() async throws {
    let harness = try await ExpansionHarness()
    try await harness.insertShow("show-1", count: 1)
    try await harness.makeList(scope: .all, shows: [])
    let expansion = harness.expansion()

    let task = Task { () -> SmartListShowExpansion.Summary in
      // Sleep throws only on cancellation, so this returns once the test has cancelled the task.
      do { try await Task.sleep(for: .seconds(60)) } catch {}
      return await expansion.expandDueShows()
    }
    task.cancel()
    _ = await task.value

    #expect(harness.http.paths.isEmpty)
  }

  // MARK: - Save-time expansion

  @Test("save-time expansion touches only the saved list's shows")
  func saveTimeExpansionIsScopedToTheList() async throws {
    let harness = try await ExpansionHarness()
    try await harness.insertShow("show-1", count: 1)
    try await harness.insertShow("show-2", count: 1)
    try await harness.insertShow("show-3", count: 1)
    let saved = try await harness.makeList(scope: .only, shows: ["show-1"])
    try await harness.makeList(scope: .only, shows: ["show-2"])

    let summary = await harness.expansion().expand(listID: saved)

    #expect(summary.completedShows == 1)
    #expect(harness.http.itemGetPaths == ["/api/items/show-1"])
  }

  @Test("all and all-except lists name the shows the routine pass expands")
  func allAndAllExceptListsAreResolved() async throws {
    let harness = try await ExpansionHarness()
    for number in 1...3 { try await harness.insertShow("show-\(number)", count: 1) }
    try await harness.makeList(scope: .allExcept, shows: ["show-2"])

    _ = await harness.expansion().expandDueShows()

    #expect(harness.http.itemGetPaths == ["/api/items/show-1", "/api/items/show-3"])
  }

  @Test("a list's updating state clears once its shows are complete")
  func updatingStateFollowsCompleteness() async throws {
    let harness = try await ExpansionHarness()
    try await harness.insertShow("show-1", count: 1)
    let list = try await harness.makeList(scope: .only, shows: ["show-1"])
    let reading = SmartListExpansionReading(database: harness.database)

    #expect(try await reading.isUpdating(listID: list, accountID: harness.accountID))
    _ = await harness.expansion().expand(listID: list)
    #expect(try await reading.isUpdating(listID: list, accountID: harness.accountID) == false)
  }
}

private enum BoundedDecoderLimits {
  static var maximumBodyBytes: Int { EndpointDecodeLimits.standard.maximumBodyBytes }
}

// MARK: - Fixtures

private final class ExpansionHarness: @unchecked Sendable {
  static let now = Date(timeIntervalSince1970: 1_700_000_000)

  let database: AppDatabase
  let http = ExpansionHTTPClient()
  let accountID: Int64
  private let libraryID: Int64
  private let client: ABSClient

  init() async throws {
    database = try AppDatabase.inMemory()
    let server = try ABSServerConfig(url: try #require(URL(string: "https://sync.example.test")))
    let clientUUID = "expansion-client"
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID),
      userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
    client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    (accountID, libraryID) = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture", serverVersion: "2.35.1")
      try record.insert(db)
      var library = LibraryRecord(
        accountId: record.id!, serverLibraryId: "podcasts", mediaType: "podcast", name: "Podcasts")
      try library.insert(db)
      return (record.id!, library.id!)
    }
  }

  func expansion(showBudget: Int = 20) -> SmartListShowExpansion {
    let showRefresh = PodcastRefreshCoordinator(
      database: database, client: client, persistence: PodcastRefreshStore(database: database))
    return SmartListShowExpansion(
      database: database, client: client, showRefresh: showRefresh, showBudget: showBudget,
      now: { Self.now }, randomSource: { 1.0 })
  }

  @discardableResult
  func insertShow(_ serverItemID: String, count: Int? = nil) async throws -> Int64 {
    try await database.writeAsync { [accountID, libraryID] db in
      var item = ItemRecord(
        accountId: accountID, libraryId: libraryID, serverItemId: serverItemID,
        mediaKind: "podcast", title: serverItemID, sortTitle: serverItemID,
        podcastServerEpisodeCount: count)
      try item.insert(db)
      return item.id!
    }
  }

  func insertEpisode(itemID: Int64, serverEpisodeID: String) async throws {
    try await database.writeAsync { [accountID] db in
      var episode = PersistenceFixtures.episode(
        accountId: accountID, itemId: itemID, serverEpisodeId: serverEpisodeID,
        title: serverEpisodeID, lastSeenGeneration: 1)
      try episode.insert(db)
    }
  }

  @discardableResult
  func makeList(scope: SmartListShowScope, shows: [String]) async throws -> Int64 {
    let role: SmartListShowRole = scope == .allExcept ? .excluded : .included
    return try await SmartListStore(database: database).create(
      name: "List \(UUID().uuidString.prefix(6))", rules: SmartListRules(showScope: scope),
      shows: shows.map {
        SmartListShowSelection(
          ref: .server(serverUserID: "user_fixture", serverItemID: $0), role: role,
          titleSnapshot: $0)
      }
    ).id
  }

  func episode(_ serverEpisodeID: String) throws -> PodcastEpisodeRecord? {
    try database.read { db in
      try PodcastEpisodeRecord.filter(Column("serverEpisodeId") == serverEpisodeID).fetchOne(db)
    }
  }

  func lastCompleteEpisodeListAt(_ itemID: Int64) throws -> Date? {
    try database.read { db in
      try PodcastRefreshStateRecord.fetchOne(db, key: itemID)?.lastCompleteEpisodeListAt
    }
  }

  func nextEligibleAttempt(_ itemID: Int64) throws -> Date? {
    try database.read { db in
      try PodcastRefreshStateRecord.fetchOne(db, key: itemID)?.nextEligibleAttemptAt
    }
  }
}

/// Answers by route. Every show carries episodes `fresh` (the batch body carries only that) and
/// the per-show body the same, so a show's stale rows can only leave through a complete fetch.
// Stays: a route-answering server with test-mutable failure knobs (refuse batches, 404, suspend)
// read live by the handler; FakeHTTPClient has no such state and must not grow mode flags.
private final class ExpansionHTTPClient: HTTPClienting, @unchecked Sendable {
  private let lock = NSLock()
  private var captured: [HTTPRequest] = []
  private var servedBytes = 0
  private var batchRefusalLimit: Int?
  private var failGets = false
  private var missing: Set<String> = []
  private var suspended: Set<String> = []

  var failItemGets: Bool {
    get { locked { failGets } }
    set { locked { failGets = newValue } }
  }
  var refuseBatchesLargerThan: Int? {
    get { locked { batchRefusalLimit } }
    set { locked { batchRefusalLimit = newValue } }
  }
  var notFoundItems: Set<String> {
    get { locked { missing } }
    set { locked { missing = newValue } }
  }
  var suspendItemGets: Set<String> {
    get { locked { suspended } }
    set { locked { suspended = newValue } }
  }
  var paths: [String] { locked { captured.map(\.url.path) } }
  var itemGetPaths: [String] {
    locked {
      captured.filter { $0.method == .get && $0.url.path.hasPrefix("/api/items/") }.map(\.url.path)
    }
  }
  var batchSizes: [Int] {
    locked {
      captured.filter { $0.url.path == "/api/items/batch/get" }.map { Self.ids(in: $0).count }
    }
  }
  var largestBodyServed: Int { locked { servedBytes } }

  func waitForPath(_ path: String) async {
    _ = await awaitCondition("a request to \(path)") { self.paths.contains(path) }
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    locked { captured.append(request) }
    let path = request.url.path
    if path == "/api/me" { return Self.json(#"{"mediaProgresses":[]}"#) }
    if path == "/api/items/batch/get" {
      let ids = Self.ids(in: request)
      if let limit = refuseBatchesLargerThan, ids.count > limit {
        // One byte over the decoder's cap, as the server would send for too many episodes.
        return HTTPResponse(
          statusCode: 200, headers: ["Content-Type": "application/json"],
          body: Data(count: BoundedDecoderLimits.maximumBodyBytes + 1))
      }
      let items = ids.map { Self.itemJSON($0) }.joined(separator: ",")
      let response = Self.json(#"{"libraryItems":[\#(items)]}"#)
      locked { servedBytes = max(servedBytes, response.body.count) }
      return response
    }
    let itemID = String(path.dropFirst("/api/items/".count))
    if suspendItemGets.contains(itemID) {
      while true { try await Task.sleep(for: .seconds(1)) }
    }
    if failItemGets { return HTTPResponse(statusCode: 503, headers: [:], body: Data()) }
    if notFoundItems.contains(itemID) {
      return HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }
    return Self.json(Self.itemJSON(itemID))
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private static func ids(in request: HTTPRequest) -> [String] {
    guard let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return [] }
    return object["libraryItemIds"] as? [String] ?? []
  }

  private static func itemJSON(_ itemID: String) -> String {
    """
    {"id":"\(itemID)","libraryId":"podcasts","mediaType":"podcast","media":{
      "metadata":{"title":"Show"},
      "episodes":[{"id":"fresh","title":"Fresh","audioFile":{"ino":"ino-\(itemID)","size":1024,"mimeType":"audio/mpeg","duration":60}}]
    }}
    """
  }

  private static func json(_ body: String) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
  }
}
