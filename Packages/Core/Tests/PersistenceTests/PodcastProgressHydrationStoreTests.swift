import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite("Podcast progress hydration selection")
struct PodcastProgressHydrationStoreTests {
  @Test("an excluded library's cached show is never selected for episode hydration")
  func excludedLibraryIsNotSelected() async throws {
    let harness = try await HydrationHarness()
    _ = try await harness.insertShow("excluded-show")
    try await harness.setLibraryIncluded(false)

    let needs = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID,
      identities: [PodcastProgressIdentity(serverItemID: "excluded-show", serverEpisodeID: "ep-1")],
      now: Self.now,
      limit: 10)

    #expect(needs.isEmpty)
  }

  @Test("a show whose in-progress episode has no local episode row needs hydration")
  func neverHydratedShowNeedsHydration() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")

    let needs = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID,
      identities: [PodcastProgressIdentity(serverItemID: "show-1", serverEpisodeID: "ep-1")],
      now: Self.now,
      limit: 10)

    #expect(needs.map(\.serverItemID) == ["show-1"])
    #expect(needs.map(\.localItemID) == [showID])
  }

  /// The case the login gap actually produces on a previously opened show: episode rows exist,
  /// but the progress the server holds for one of them was never written locally, so nothing
  /// joins it into Continue Listening.
  @Test("an episode row without a progress row still needs hydration")
  func episodeRowWithoutProgressNeedsHydration() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    _ = try await harness.insertEpisode(itemID: showID, serverEpisodeID: "ep-1")

    let needs = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID,
      identities: [PodcastProgressIdentity(serverItemID: "show-1", serverEpisodeID: "ep-1")],
      now: Self.now,
      limit: 10)

    #expect(needs.map(\.serverItemID) == ["show-1"])
  }

  @Test("an episode that already carries local progress needs nothing")
  func coveredEpisodeIsNotSelected() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    let episodeID = try await harness.insertEpisode(itemID: showID, serverEpisodeID: "ep-1")
    try await harness.insertEpisodeProgress(itemID: showID, episodeID: episodeID)

    let needs = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID,
      identities: [PodcastProgressIdentity(serverItemID: "show-1", serverEpisodeID: "ep-1")],
      now: Self.now,
      limit: 10)

    #expect(needs.isEmpty)
  }

  /// One covered episode says nothing about a second one on the same show. Selection is per
  /// episode identity, collapsed to the show only once something is missing.
  @Test("a second uncovered episode still selects an otherwise covered show")
  func partiallyCoveredShowIsStillSelected() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    let episodeID = try await harness.insertEpisode(itemID: showID, serverEpisodeID: "ep-1")
    try await harness.insertEpisodeProgress(itemID: showID, episodeID: episodeID)

    let needs = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID,
      identities: [
        PodcastProgressIdentity(serverItemID: "show-1", serverEpisodeID: "ep-1"),
        PodcastProgressIdentity(serverItemID: "show-1", serverEpisodeID: "ep-2"),
      ],
      now: Self.now,
      limit: 10)

    #expect(needs.map(\.serverItemID) == ["show-1"])
  }

  @Test("a soft-deleted episode row does not count as coverage")
  func softDeletedEpisodeIsNotCoverage() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    let episodeID = try await harness.insertEpisode(
      itemID: showID, serverEpisodeID: "ep-1", softDeleted: true)
    try await harness.insertEpisodeProgress(itemID: showID, episodeID: episodeID)

    let needs = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID,
      identities: [PodcastProgressIdentity(serverItemID: "show-1", serverEpisodeID: "ep-1")],
      now: Self.now,
      limit: 10)

    #expect(needs.map(\.serverItemID) == ["show-1"])
  }

  @Test("an unknown or soft-deleted show is never selected")
  func unknownAndDeletedShowsAreSkipped() async throws {
    let harness = try await HydrationHarness()
    _ = try await harness.insertShow("deleted-show", softDeleted: true)

    let needs = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID,
      identities: [
        PodcastProgressIdentity(serverItemID: "deleted-show", serverEpisodeID: "ep-1"),
        PodcastProgressIdentity(serverItemID: "never-pulled", serverEpisodeID: "ep-2"),
      ],
      now: Self.now,
      limit: 10)

    #expect(needs.isEmpty)
  }

  /// A book that (wrongly) carried an episode-shaped progress row must not send this pass down
  /// the podcast expansion route.
  @Test("a non-podcast item is never selected")
  func nonPodcastItemIsSkipped() async throws {
    let harness = try await HydrationHarness()
    _ = try await harness.insertShow("a-book", mediaKind: "book")

    let needs = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID,
      identities: [PodcastProgressIdentity(serverItemID: "a-book", serverEpisodeID: "ep-1")],
      now: Self.now,
      limit: 10)

    #expect(needs.isEmpty)
  }

  /// Shares `podcastRefreshState` with the catalogue pass, so a show that keeps failing to expand
  /// cannot be re-requested on every single foreground.
  @Test("a show inside its failure backoff window is skipped until it expires")
  func backoffWindowIsHonored() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    try await harness.insertRefreshState(
      itemID: showID, nextEligibleAttemptAt: Self.now.addingTimeInterval(60))
    let identities = [PodcastProgressIdentity(serverItemID: "show-1", serverEpisodeID: "ep-1")]

    let blocked = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID, identities: identities, now: Self.now, limit: 10)
    #expect(blocked.isEmpty)

    let allowed = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID, identities: identities,
      now: Self.now.addingTimeInterval(61), limit: 10)
    #expect(allowed.map(\.serverItemID) == ["show-1"])
  }

  /// Callers hand the identities over in server-recency order, so the truncation this applies is
  /// "the most recently listened shows", not an arbitrary slice.
  @Test("selection preserves the caller's order and honors the limit")
  func orderIsPreservedAndLimited() async throws {
    let harness = try await HydrationHarness()
    for name in ["show-a", "show-b", "show-c"] { _ = try await harness.insertShow(name) }

    let needs = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID,
      identities: [
        PodcastProgressIdentity(serverItemID: "show-c", serverEpisodeID: "ep-1"),
        PodcastProgressIdentity(serverItemID: "show-a", serverEpisodeID: "ep-2"),
        PodcastProgressIdentity(serverItemID: "show-c", serverEpisodeID: "ep-3"),
        PodcastProgressIdentity(serverItemID: "show-b", serverEpisodeID: "ep-4"),
      ],
      now: Self.now,
      limit: 2)

    #expect(needs.map(\.serverItemID) == ["show-c", "show-a"])
  }

  @Test("another account's rows are never selected or counted as coverage")
  func accountScopeIsEnforced() async throws {
    let harness = try await HydrationHarness()
    let otherAccountID = try await harness.insertSecondAccount()
    _ = try await harness.insertShow("show-1", accountID: otherAccountID)

    let needs = try await harness.store.showsNeedingHydration(
      accountId: harness.accountID,
      identities: [PodcastProgressIdentity(serverItemID: "show-1", serverEpisodeID: "ep-1")],
      now: Self.now,
      limit: 10)

    #expect(needs.isEmpty)
  }

  @Test("a queued visibility write protects only visibility while a newer server position applies")
  func visibilityPendingDoesNotBlockAudioPosition() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    let episodeID = try await harness.insertEpisode(itemID: showID, serverEpisodeID: "ep-1")
    try await harness.insertEpisodeProgress(itemID: showID, episodeID: episodeID)
    try await harness.database.writeAsync { db in
      try MediaProgressRecord
        .filter(Column("podcastEpisodeId") == episodeID)
        .updateAll(db, Column("hideFromContinueListening").set(to: true))
    }
    _ = try OutboxStore(database: harness.database).enqueueContinueListeningVisibility(
      accountId: harness.accountID, entityKey: "show-1", podcastEpisodeId: episodeID,
      localSequence: 1, hideFromContinueListening: true)

    try await harness.store.reconcileKnownProgress(
      accountId: harness.accountID,
      observations: [
        PodcastProgressReconciliationObservation(
          identity: PodcastProgressIdentity(serverItemID: "show-1", serverEpisodeID: "ep-1"),
          currentTime: 240, isFinished: false, hideFromContinueListening: false,
          serverUpdatedAt: Self.now.addingTimeInterval(10))
      ]
    ) { _ in .applyServer }

    let progress = try #require(
      await MediaProgressDAO(database: harness.database).fetchCurrentAsync(
        accountId: harness.accountID,
        identity: .episode(itemId: showID, podcastEpisodeId: episodeID)))
    #expect(progress.currentTime == 240)
    #expect(progress.hideFromContinueListening)
  }

  @Test("Array.chunked preserves empty, exact, remainder, and unit chunks")
  func chunkedPreservesTheSharedContract() {
    #expect([Int]().chunked(maximumCount: 3) == [])
    #expect([1, 2, 3, 4].chunked(maximumCount: 2) == [[1, 2], [3, 4]])
    #expect([1, 2, 3, 4, 5].chunked(maximumCount: 2) == [[1, 2], [3, 4], [5]])
    #expect([1, 2, 3].chunked(maximumCount: 1) == [[1], [2], [3]])
  }

  @Test("Array.chunked keeps empty input safe for non-positive sizes")
  func chunkedKeepsEmptyInputSafeForNonPositiveSizes() {
    #expect([Int]().chunked(maximumCount: 0) == [])
    #expect([Int]().chunked(maximumCount: -1) == [])
    #expect([1, 2, 3].chunked(maximumCount: 0) == [])
    #expect([1, 2, 3].chunked(maximumCount: -1) == [])
    #expect([1, 2, 3].chunked(maximumCount: 1) == [[1], [2], [3]])
  }

  private static let now = Date(timeIntervalSince1970: 1_700_000_000)
}

private final class HydrationHarness: @unchecked Sendable {
  let database: AppDatabase
  let store: PodcastProgressHydrationStore
  private(set) var accountID: Int64 = 0
  private var libraryID: Int64 = 0

  init() async throws {
    database = try AppDatabase.inMemory()
    store = PodcastProgressHydrationStore(database: database)
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "hydration-client", serverBaseURL: "https://sync.example.test",
        serverUserId: "user_fixture", serverVersion: "2.35.1")
      try account.insert(db)
      accountID = account.id!
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "podcasts", mediaType: "podcast", name: "Podcasts")
      try library.insert(db)
      libraryID = library.id!
    }
  }

  func insertSecondAccount() async throws -> Int64 {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "other-client", serverBaseURL: "https://other.example.test",
        serverUserId: "other_user", serverVersion: "2.35.1")
      try account.insert(db)
      return account.id!
    }
  }

  @discardableResult
  func insertShow(
    _ serverItemID: String,
    mediaKind: String = "podcast",
    softDeleted: Bool = false,
    accountID: Int64? = nil
  ) async throws -> Int64 {
    let owner = accountID ?? self.accountID
    return try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: owner, libraryId: libraryID, serverItemId: serverItemID,
        mediaKind: mediaKind, title: serverItemID, sortTitle: serverItemID,
        softDeleted: softDeleted)
      try item.insert(db)
      return item.id!
    }
  }

  @discardableResult
  func insertEpisode(
    itemID: Int64,
    serverEpisodeID: String,
    softDeleted: Bool = false
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = PersistenceFixtures.episode(
        accountId: accountID, itemId: itemID, serverEpisodeId: serverEpisodeID,
        title: serverEpisodeID, lastSeenGeneration: 1, softDeleted: softDeleted)
      try episode.insert(db)
      return episode.id!
    }
  }

  func insertEpisodeProgress(itemID: Int64, episodeID: Int64) async throws {
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: accountID, itemId: itemID, podcastEpisodeId: episodeID,
        currentTime: 120, isFinished: false, localSequence: 0, origin: .server,
        originKey: ProgressOrigin.serverOriginKey)
      try progress.insert(db)
    }
  }

  func insertRefreshState(itemID: Int64, nextEligibleAttemptAt: Date) async throws {
    try await database.writeAsync { db in
      let state = PodcastRefreshStateRecord(
        itemId: itemID, consecutiveFailures: 1, nextEligibleAttemptAt: nextEligibleAttemptAt)
      try state.save(db)
    }
  }

  func setLibraryIncluded(_ included: Bool) async throws {
    try await database.writeAsync { db in
      try LibraryRecord
        .filter(Column("id") == libraryID)
        .updateAll(db, Column("isIncluded").set(to: included))
    }
  }
}
