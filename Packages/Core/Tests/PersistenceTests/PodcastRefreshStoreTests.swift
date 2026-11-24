import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite struct PodcastRefreshStoreTests {
  @Test("active online episode session protects local progress from an older foreground refresh")
  func activeOnlineEpisodeProtectsLocalProgress() async throws {
    try await Self.assertActiveEpisodeProtectsLocalProgress(isOffline: false)
  }

  @Test("active offline episode session protects local progress from an older foreground refresh")
  func activeOfflineEpisodeProtectsLocalProgress() async throws {
    try await Self.assertActiveEpisodeProtectsLocalProgress(isOffline: true)
  }

  @Test("a queued visibility write does not block a podcast position pull")
  func visibilityPendingDoesNotBlockPosition() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let episodeID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "episode-1",
      title: "Episode", generation: 1)

    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: episodeID,
        currentTime: 120, isFinished: false, localSequence: 4, origin: .local,
        originKey: "fixture-client")
      progress.hideFromContinueListening = true
      try progress.insert(db)
    }
    _ = try OutboxStore(database: database).enqueueContinueListeningVisibility(
      accountId: seeded.accountId, entityKey: seeded.serverItemID, podcastEpisodeId: episodeID,
      localSequence: 5, hideFromContinueListening: true)

    try PodcastRefreshStore(database: database).apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "episode-1",
            title: "Episode", generation: 2)
        ],
        progressObservations: [
          PodcastEpisodeProgressObservation(
            serverEpisodeId: "episode-1", currentTime: 240, isFinished: false,
            hideFromContinueListening: false,
            serverUpdatedAt: Date(timeIntervalSince1970: 2_000))
        ],
        responseIsComplete: false)
    ) { context in
      #expect(context.hasUnacknowledgedLocalOperation == false)
      return .applyServer
    }

    let progress = try #require(
      try database.read { db in try MediaProgressRecord.fetchOne(db, key: episodeID) })
    #expect(progress.currentTime == 240)
    #expect(progress.hideFromContinueListening)
  }

  @Test("refresh upserts episodes, progress, conflicts, and diagnostics atomically")
  func appliesRefreshAndPreservesEpisodeIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let existingID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "existing",
      title: "Old title", generation: 1)

    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: existingID,
        currentTime: 12, isFinished: false, localSequence: 41, origin: .local,
        originKey: "fixture-client")
      try progress.insert(db)
      var download = DownloadRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: existingID,
        serverFileIno: "existing-audio", orderIndex: 0,
        destinationRelativePath: "podcasts/existing.mp3", expectedBytes: 1_000,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 100)
      try download.insert(db)
      var operation = OutboxOperationRecord(
        accountId: seeded.accountId, clientOperationId: "existing-operation",
        entityKey: seeded.serverItemID, podcastEpisodeId: existingID,
        operationKind: "progress", coalescingKey: "episode:existing", payloadVersion: 1,
        localSequence: 41)
      try operation.insert(db)
    }

    let serverUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    try PodcastRefreshStore(database: database).apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId,
        itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "existing",
            title: "Updated title", generation: 99),
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "new",
            title: "New episode", generation: 99),
        ],
        progressObservations: [
          PodcastEpisodeProgressObservation(
            serverEpisodeId: "existing", currentTime: 75, isFinished: true,
            serverUpdatedAt: serverUpdatedAt),
          PodcastEpisodeProgressObservation(
            serverEpisodeId: "new", currentTime: 30, isFinished: false,
            serverUpdatedAt: serverUpdatedAt),
        ],
        autoDownloadEpisodes: true,
        autoDownloadSchedule: "0 0 * * *",
        lastEpisodeCheck: serverUpdatedAt,
        maxEpisodesToKeep: 10,
        maxNewEpisodesToDownload: 3,
        responseIsComplete: true)
    ) { context in
      #expect(context.identity.podcastEpisodeId != nil)
      #expect(context.hasUnacknowledgedLocalOperation == (context.serverEpisodeId == "existing"))
      #expect(context.durationSeconds == nil)
      return context.serverEpisodeId == "existing"
        ? .applyServer
        : .recordConflict(detectedAt: Date(timeIntervalSince1970: 1_800_000_100))
    }

    try database.read { db in
      let existing = try #require(
        try PodcastEpisodeRecord
          .filter(Column("itemId") == seeded.itemId)
          .filter(Column("serverEpisodeId") == "existing")
          .fetchOne(db))
      let new = try #require(
        try PodcastEpisodeRecord
          .filter(Column("itemId") == seeded.itemId)
          .filter(Column("serverEpisodeId") == "new")
          .fetchOne(db))
      #expect(existing.id == existingID)
      #expect(existing.title == "Updated title")
      #expect(existing.lastSeenGeneration == 2)
      #expect(existing.softDeleted == false)
      #expect(new.lastSeenGeneration == 2)

      let progress = try #require(
        try MediaProgressRecord
          .filter(Column("accountId") == seeded.accountId)
          .filter(Column("podcastEpisodeId") == existingID)
          .fetchOne(db))
      #expect(progress.currentTime == 75)
      #expect(progress.isFinished)
      #expect(progress.localSequence == 41)
      #expect(progress.origin == .server)
      #expect(
        try DownloadRecord.filter(Column("podcastEpisodeId") == existingID).fetchCount(db) == 1)
      #expect(
        try OutboxOperationRecord.filter(Column("podcastEpisodeId") == existingID).fetchCount(db)
          == 1)

      let conflict = try #require(
        try ProgressConflictRecord
          .filter(Column("podcastEpisodeId") == new.id)
          .fetchOne(db))
      #expect(conflict.serverCurrentTime == 30)
      #expect(conflict.detectedAt == Date(timeIntervalSince1970: 1_800_000_100))

      let item = try #require(try ItemRecord.fetchOne(db, key: seeded.itemId))
      #expect(item.podcastAutoDownloadEpisodes == true)
      #expect(item.podcastAutoDownloadSchedule == "0 0 * * *")
      #expect(item.podcastLastEpisodeCheck == serverUpdatedAt)
      #expect(item.podcastMaxEpisodesToKeep == 10)
      #expect(item.podcastMaxNewEpisodesToDownload == 3)
    }
  }

  @Test("a complete response writes all three new podcast server settings")
  func completeResponseWritesNewPodcastServerSettings() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)

    try PodcastRefreshStore(database: database).apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId,
        itemId: seeded.itemId,
        episodes: [],
        autoDownloadSchedule: "0 */6 * * *",
        maxEpisodesToKeep: 0,
        maxNewEpisodesToDownload: 0,
        responseIsComplete: true)
    ) { _ in .keepLocal }

    let item = try #require(
      try database.read { db in try ItemRecord.fetchOne(db, key: seeded.itemId) })
    #expect(item.podcastAutoDownloadSchedule == "0 */6 * * *")
    #expect(item.podcastMaxEpisodesToKeep == 0)
    #expect(item.podcastMaxNewEpisodesToDownload == 0)
  }

  @Test("complete refresh stores a deduplicated episode count while incomplete refresh preserves it")
  func completeRefreshCountIsDeduplicatedAndPartialRefreshPreservesIt() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let store = PodcastRefreshStore(database: database)

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "one",
            title: "First", generation: 1),
          // A malformed duplicate must not inflate the local catalogue count.
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "one",
            title: "First (latest)", generation: 1),
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "two",
            title: "Second", generation: 1),
        ],
        responseIsComplete: true)
    ) { _ in .keepLocal }
    #expect(
      try database.read { db in try ItemRecord.fetchOne(db, key: seeded.itemId)?.podcastServerEpisodeCount }
        == 2)

    // The partial response sees a different subset but cannot prove that the omitted episode was
    // removed, so it must leave the last authoritative count untouched.
    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "three",
            title: "Third", generation: 2)
        ],
        responseIsComplete: false)
    ) { _ in .keepLocal }
    #expect(
      try database.read { db in try ItemRecord.fetchOne(db, key: seeded.itemId)?.podcastServerEpisodeCount }
        == 2)

    // Complete zero is authoritative and hides the retained container from catalogue readers;
    // the next complete positive observation restores the same container and count.
    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId, episodes: [], responseIsComplete: true)
    ) { _ in .keepLocal }
    #expect(
      try database.read { db in try ItemRecord.fetchOne(db, key: seeded.itemId)?.podcastServerEpisodeCount }
        == 0)

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "three",
            title: "Third", generation: 3),
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "three",
            title: "Third (latest)", generation: 3),
        ],
        responseIsComplete: true)
    ) { _ in .keepLocal }
    let restored = try database.read { db in
      (
        try ItemRecord.fetchOne(db, key: seeded.itemId)?.podcastServerEpisodeCount,
        try PodcastEpisodeRecord
          .filter(Column("itemId") == seeded.itemId)
          .filter(Column("softDeleted") == false)
          .fetchAll(db)
          .map(\.serverEpisodeId)
      )
    }
    #expect(restored.0 == 1)
    #expect(restored.1 == ["three"])
  }

  @Test("missing episodes are deleted only for a complete response")
  func deletionInferenceRequiresCompleteResponse() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let missingID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "missing",
      title: "Missing", generation: 1)
    let store = PodcastRefreshStore(database: database)

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "present",
            title: "Present", generation: 2)
        ],
        responseIsComplete: false)
    ) { _ in .keepLocal }
    #expect(
      try database.read { db in
        try PodcastEpisodeRecord.fetchOne(db, key: missingID)?.softDeleted
      } == false)

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "present",
            title: "Present", generation: 3)
        ],
        responseIsComplete: true)
    ) { _ in .keepLocal }
    #expect(
      try database.read { db in
        try PodcastEpisodeRecord.fetchOne(db, key: missingID)?.softDeleted
      } == true)
  }

  /// Generation-based soft deletion is reversible: an episode that vanished from one response and
  /// came back in the next must be visible again, not stranded behind the soft-delete flag.
  @Test("an episode that reappears after a transient absence is revived from soft deletion")
  func reappearingEpisodeIsRevivedFromSoftDeletion() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let episodeID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "flaky",
      title: "Flaky", generation: 1)
    let store = PodcastRefreshStore(database: database)

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId, episodes: [],
        responseIsComplete: true)
    ) { _ in .keepLocal }
    #expect(
      try database.read { db in
        try PodcastEpisodeRecord.fetchOne(db, key: episodeID)?.softDeleted
      } == true)

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "flaky",
            title: "Flaky", generation: 3)
        ],
        responseIsComplete: true)
    ) { _ in .keepLocal }

    let revived = try #require(
      try database.read { db in try PodcastEpisodeRecord.fetchOne(db, key: episodeID) })
    #expect(revived.softDeleted == false)
    #expect(revived.id == episodeID)
  }

  /// Decision 2's read-only diagnostic line must go stale, never blank: a partial response that
  /// lost a field carries no information about it, so the previously known value is preserved
  /// (the same preserve-on-absent rule T4B.3 applies to `addedAt`).
  @Test("a partial response never nulls a previously known diagnostic field")
  func partialResponsePreservesKnownDiagnosticFields() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let store = PodcastRefreshStore(database: database)
    let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId, episodes: [],
        autoDownloadEpisodes: true,
        autoDownloadSchedule: "0 0 * * *",
        lastEpisodeCheck: checkedAt,
        maxEpisodesToKeep: 10,
        maxNewEpisodesToDownload: 3,
        responseIsComplete: true)
    ) { _ in .keepLocal }

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId, episodes: [],
        autoDownloadEpisodes: nil,
        autoDownloadSchedule: nil,
        lastEpisodeCheck: nil,
        maxEpisodesToKeep: nil,
        maxNewEpisodesToDownload: nil,
        responseIsComplete: false)
    ) { _ in .keepLocal }

    var item = try #require(
      try database.read { db in try ItemRecord.fetchOne(db, key: seeded.itemId) })
    #expect(item.podcastAutoDownloadEpisodes == true)
    #expect(item.podcastAutoDownloadSchedule == "0 0 * * *")
    #expect(item.podcastLastEpisodeCheck == checkedAt)
    #expect(item.podcastMaxEpisodesToKeep == 10)
    #expect(item.podcastMaxNewEpisodesToDownload == 3)

    // A partial response that did carry a field still updates it.
    let recheckedAt = Date(timeIntervalSince1970: 1_800_009_000)
    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId, episodes: [],
        autoDownloadEpisodes: false,
        autoDownloadSchedule: "0 * * * *",
        lastEpisodeCheck: recheckedAt,
        maxEpisodesToKeep: 7,
        maxNewEpisodesToDownload: 2,
        responseIsComplete: false)
    ) { _ in .keepLocal }
    item = try #require(try database.read { db in try ItemRecord.fetchOne(db, key: seeded.itemId) })
    #expect(item.podcastAutoDownloadEpisodes == false)
    #expect(item.podcastAutoDownloadSchedule == "0 * * * *")
    #expect(item.podcastLastEpisodeCheck == recheckedAt)
    #expect(item.podcastMaxEpisodesToKeep == 7)
    #expect(item.podcastMaxNewEpisodesToDownload == 2)

    // A complete response remains authoritative, including for a field the server dropped.
    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId, episodes: [],
        autoDownloadEpisodes: nil,
        autoDownloadSchedule: nil,
        lastEpisodeCheck: nil,
        maxEpisodesToKeep: nil,
        maxNewEpisodesToDownload: nil,
        responseIsComplete: true)
    ) { _ in .keepLocal }
    item = try #require(try database.read { db in try ItemRecord.fetchOne(db, key: seeded.itemId) })
    #expect(item.podcastAutoDownloadEpisodes == nil)
    #expect(item.podcastAutoDownloadSchedule == nil)
    #expect(item.podcastLastEpisodeCheck == nil)
    #expect(item.podcastMaxEpisodesToKeep == nil)
    #expect(item.podcastMaxNewEpisodesToDownload == nil)
  }

  /// The show synopsis is written by the same expanded refresh and obeys the same rule: a partial
  /// response that lost `metadata.description` leaves the stored blurb alone.
  @Test("a partial response never nulls a previously known show description")
  func partialResponsePreservesKnownShowDescription() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let store = PodcastRefreshStore(database: database)

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId, episodes: [],
        showDescription: "A show about shows", responseIsComplete: true)
    ) { _ in .keepLocal }

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId, episodes: [],
        showDescription: nil, responseIsComplete: false)
    ) { _ in .keepLocal }
    var item = try #require(
      try database.read { db in try ItemRecord.fetchOne(db, key: seeded.itemId) })
    #expect(item.itemDescription == "A show about shows")

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId, episodes: [],
        showDescription: "A rewritten blurb", responseIsComplete: false)
    ) { _ in .keepLocal }
    item = try #require(try database.read { db in try ItemRecord.fetchOne(db, key: seeded.itemId) })
    #expect(item.itemDescription == "A rewritten blurb")

    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId, episodes: [],
        showDescription: nil, responseIsComplete: true)
    ) { _ in .keepLocal }
    item = try #require(try database.read { db in try ItemRecord.fetchOne(db, key: seeded.itemId) })
    #expect(item.itemDescription == nil)
  }

  @Test("duplicate episode and progress ids are last-wins; unknown progress is dropped")
  func duplicateAndUnknownIDsAreDeterministic() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let episodeID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "duplicate",
      title: "Original", generation: 1)
    try await database.writeAsync { db in
      var local = MediaProgressRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: episodeID,
        currentTime: 4, isFinished: false, localSequence: 2, origin: .local,
        originKey: "fixture-client")
      try local.insert(db)
    }

    try PodcastRefreshStore(database: database).apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId,
        itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "duplicate",
            title: "First", generation: 2),
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "duplicate",
            title: "Last", generation: 2),
        ],
        progressObservations: [
          PodcastEpisodeProgressObservation(
            serverEpisodeId: "duplicate", currentTime: 8, isFinished: false,
            serverUpdatedAt: nil),
          PodcastEpisodeProgressObservation(
            serverEpisodeId: "duplicate", currentTime: 9, isFinished: true,
            serverUpdatedAt: nil),
          PodcastEpisodeProgressObservation(
            serverEpisodeId: "unknown", currentTime: 999, isFinished: true,
            serverUpdatedAt: nil),
        ],
        responseIsComplete: true)
    ) { context in
      #expect(context.incomingCurrentTime == 9)
      #expect(context.incomingIsFinished)
      #expect(context.currentProgress?.currentTime == 4)
      return .recordConflict(detectedAt: Date(timeIntervalSince1970: 10))
    }

    try database.read { db in
      let episode = try #require(try PodcastEpisodeRecord.fetchOne(db, key: episodeID))
      #expect(episode.title == "Last")
      #expect(
        try PodcastEpisodeRecord
          .filter(Column("itemId") == seeded.itemId)
          .filter(Column("serverEpisodeId") == "duplicate")
          .fetchCount(db) == 1)
      let progress = try #require(
        try MediaProgressRecord
          .filter(Column("podcastEpisodeId") == episodeID)
          .fetchOne(db))
      #expect(progress.currentTime == 4, "last conflict outcome must leave local progress visible")
      #expect(
        try ProgressConflictRecord
          .filter(Column("podcastEpisodeId") == episodeID)
          .fetchCount(db) == 1)
      #expect(
        try MediaProgressRecord
          .filter(Column("itemId") == seeded.itemId)
          .filter(Column("podcastEpisodeId") == nil)
          .fetchCount(db) == 0,
        "unknown episode progress must never fall back to item progress")
    }
  }

  @Test("validation failure and pre-apply cancellation retain prior rows")
  func failureAndCancellationDoNotPartiallyApply() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let existingID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "existing",
      title: "Before", generation: 1)
    let store = PodcastRefreshStore(database: database)
    let invalid = PodcastRefreshApplication(
      accountId: seeded.accountId,
      itemId: seeded.itemId,
      episodes: [
        Self.episode(
          accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "existing",
          title: "After", generation: 2),
        Self.episode(
          accountId: seeded.accountId + 999, itemId: seeded.itemId, serverEpisodeID: "invalid",
          title: "Invalid", generation: 2),
      ],
      autoDownloadEpisodes: true,
      responseIsComplete: true)

    #expect(throws: PodcastRefreshStoreError.invalidEpisodeScope) {
      try store.apply(invalid) { _ in .keepLocal }
    }
    var retained = try #require(
      try database.read { db in try PodcastEpisodeRecord.fetchOne(db, key: existingID) })
    #expect(retained.title == "Before")
    #expect(retained.softDeleted == false)
    #expect(
      try database.read { db in
        try ItemRecord.fetchOne(db, key: seeded.itemId)?.podcastAutoDownloadEpisodes
      } == nil)

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await store.applyAsync(
        PodcastRefreshApplication(
          accountId: seeded.accountId,
          itemId: seeded.itemId,
          episodes: [
            Self.episode(
              accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "existing",
              title: "Cancelled", generation: 3)
          ],
          responseIsComplete: true)
      ) { _ in .keepLocal }
    }
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    retained = try #require(
      try database.read { db in try PodcastEpisodeRecord.fetchOne(db, key: existingID) })
    #expect(retained.title == "Before")
  }

  @Test("a response begun before removal cannot restore a pre-delete episode")
  func staleResponseCannotRestoreAfterRemoval() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let removedID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "removed",
      title: "Removed", generation: 1)
    let store = PodcastRefreshStore(database: database)

    // The removal snapshot is authoritative but has no refresh checkpoint. The
    // save-attempt row below is the durable ordering evidence that fences the older response.
    try await database.writeAsync { db in
      try PodcastRefreshStore.applyRemovalReconciliation(
        accountId: seeded.accountId, serverItemId: seeded.serverItemID, episodes: [], refreshedAt: nil,
        in: db)
    }
    try await Self.insertSaveAttempt(
      database, accountId: seeded.accountId, serverItemID: seeded.serverItemID,
      episodeID: 7, state: .removed, updatedAt: Date(timeIntervalSince1970: 200))

    let requestStartedAt = Date(timeIntervalSince1970: 100)
    let stale = PodcastRefreshApplication(
      accountId: seeded.accountId,
      itemId: seeded.itemId,
      episodes: [
        Self.episode(
          accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "restored",
          title: "Stale restore", generation: 99)
      ],
      responseIsComplete: true,
      refreshedAt: Date(timeIntervalSince1970: 300),
      serverItemId: seeded.serverItemID,
      requestStartedAt: requestStartedAt)

    #expect(throws: PodcastRefreshStoreError.supersededByNewerMutation) {
      try store.apply(stale) { _ in .keepLocal }
    }

    let state = try database.read { db in
      (
        try PodcastEpisodeRecord.fetchOne(db, key: removedID),
        try ItemRecord.fetchOne(db, key: seeded.itemId),
        try PodcastEpisodeRecord
          .filter(Column("itemId") == seeded.itemId)
          .filter(Column("serverEpisodeId") == "restored")
          .fetchCount(db)
      )
    }
    #expect(state.0?.softDeleted == true)
    #expect(state.1?.podcastServerEpisodeCount == 0)
    #expect(state.2 == 0)
  }

  @Test("a save for another episode of the same show fences an older complete response")
  func sameItemMutationForDifferentEpisodeFencesRefresh() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let existingID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "existing",
      title: "Before", generation: 1)
    try await database.writeAsync { db in
      var item = try #require(try ItemRecord.fetchOne(db, key: seeded.itemId))
      item.podcastServerEpisodeCount = 1
      try item.update(db)
    }
    try await Self.insertSaveAttempt(
      database, accountId: seeded.accountId, serverItemID: seeded.serverItemID,
      episodeID: 8, state: .accepted, updatedAt: Date(timeIntervalSince1970: 200))

    let stale = PodcastRefreshApplication(
      accountId: seeded.accountId,
      itemId: seeded.itemId,
      episodes: [
        Self.episode(
          accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "new",
          title: "Stale new", generation: 9)
      ],
      autoDownloadEpisodes: true,
      responseIsComplete: true,
      refreshedAt: Date(timeIntervalSince1970: 300),
      serverItemId: seeded.serverItemID,
      requestStartedAt: Date(timeIntervalSince1970: 100))

    #expect(throws: PodcastRefreshStoreError.supersededByNewerMutation) {
      try PodcastRefreshStore(database: database).apply(stale) { _ in .keepLocal }
    }
    let retained = try database.read { db in
      (
        try PodcastEpisodeRecord.fetchOne(db, key: existingID),
        try ItemRecord.fetchOne(db, key: seeded.itemId),
        try PodcastEpisodeRecord.filter(Column("itemId") == seeded.itemId).fetchCount(db)
      )
    }
    #expect(retained.0?.title == "Before")
    #expect(retained.0?.softDeleted == false)
    #expect(retained.1?.podcastServerEpisodeCount == 1)
    #expect(retained.2 == 1)
  }

  @Test("an old uncertain attempt does not permanently block a later complete refresh")
  func laterRefreshConvergesAfterOldUncertainAttempt() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    try await Self.insertSaveAttempt(
      database, accountId: seeded.accountId, serverItemID: seeded.serverItemID,
      episodeID: 9, state: .uncertain, updatedAt: Date(timeIntervalSince1970: 50))

    try PodcastRefreshStore(database: database).apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId,
        itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "converged",
            title: "Converged", generation: 1)
        ],
        responseIsComplete: true,
        refreshedAt: Date(timeIntervalSince1970: 150),
        serverItemId: seeded.serverItemID,
        requestStartedAt: Date(timeIntervalSince1970: 100))
    ) { _ in .keepLocal }

    let result = try database.read { db in
      (
        try ItemRecord.fetchOne(db, key: seeded.itemId)?.podcastServerEpisodeCount,
        try PodcastEpisodeRecord
          .filter(Column("itemId") == seeded.itemId)
          .filter(Column("softDeleted") == false)
          .fetchAll(db)
          .map(\.serverEpisodeId)
      )
    }
    #expect(result.0 == 1)
    #expect(result.1 == ["converged"])
  }

  @Test("equal mutation and request timestamps fail closed")
  func equalMutationTimestampFencesRefresh() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let timestamp = Date(timeIntervalSince1970: 100)
    try await Self.insertSaveAttempt(
      database, accountId: seeded.accountId, serverItemID: seeded.serverItemID,
      episodeID: 10, state: .deleting, updatedAt: timestamp)

    let tied = PodcastRefreshApplication(
      accountId: seeded.accountId, itemId: seeded.itemId,
      episodes: [
        Self.episode(
          accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "same-time",
          title: "Same time", generation: 1)
      ],
      responseIsComplete: true,
      refreshedAt: Date(timeIntervalSince1970: 150),
      serverItemId: seeded.serverItemID,
      requestStartedAt: timestamp)

    #expect(throws: PodcastRefreshStoreError.supersededByNewerMutation) {
      try PodcastRefreshStore(database: database).apply(tied) { _ in .keepLocal }
    }

    #expect(
      try database.read { db in
        try PodcastEpisodeRecord
          .filter(Column("itemId") == seeded.itemId)
          .filter(Column("serverEpisodeId") == "same-time")
          .fetchCount(db)
      } == 0)
  }

  @Test("the stale fence is scoped to account and server item")
  func staleFenceIsScopedToAccountAndServerItem() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let otherAccountID = try await Self.insertAccount(database, suffix: "other")
    try await Self.insertSaveAttempt(
      database, accountId: otherAccountID, serverItemID: seeded.serverItemID,
      episodeID: 11, state: .removed, updatedAt: Date(timeIntervalSince1970: 200))
    try await Self.insertSaveAttempt(
      database, accountId: seeded.accountId, serverItemID: "other-show",
      episodeID: 12, state: .removed, updatedAt: Date(timeIntervalSince1970: 200))

    try PodcastRefreshStore(database: database).apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId,
        itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "in-scope",
            title: "In scope", generation: 1)
        ],
        responseIsComplete: true,
        refreshedAt: Date(timeIntervalSince1970: 300),
        serverItemId: seeded.serverItemID,
        requestStartedAt: Date(timeIntervalSince1970: 100))
    ) { _ in .keepLocal }

    #expect(
      try database.read { db in
        try PodcastEpisodeRecord
          .filter(Column("itemId") == seeded.itemId)
          .filter(Column("serverEpisodeId") == "in-scope")
          .fetchCount(db)
      } == 1)
  }

  @Test("a newer authoritative refresh checkpoint fences an older response atomically")
  func newerRefreshCheckpointFencesOlderResponse() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let store = PodcastRefreshStore(database: database)
    try store.apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId, itemId: seeded.itemId,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "authoritative",
            title: "Authoritative", generation: 1)
        ],
        responseIsComplete: true,
        refreshedAt: Date(timeIntervalSince1970: 200),
        serverItemId: seeded.serverItemID)
    ) { _ in .keepLocal }

    let stale = PodcastRefreshApplication(
      accountId: seeded.accountId, itemId: seeded.itemId,
      episodes: [
        Self.episode(
          accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "old",
          title: "Old", generation: 2)
      ],
      responseIsComplete: true,
      refreshedAt: Date(timeIntervalSince1970: 300),
      serverItemId: seeded.serverItemID,
      requestStartedAt: Date(timeIntervalSince1970: 100))

    #expect(throws: PodcastRefreshStoreError.supersededByNewerMutation) {
      try store.apply(stale) { _ in .keepLocal }
    }
    let result = try database.read { db in
      (
        try ItemRecord.fetchOne(db, key: seeded.itemId)?.podcastServerEpisodeCount,
        try PodcastEpisodeRecord
          .filter(Column("itemId") == seeded.itemId)
          .filter(Column("softDeleted") == false)
          .fetchAll(db)
          .map(\.serverEpisodeId)
      )
    }
    #expect(result.0 == 1)
    #expect(result.1 == ["authoritative"])
  }

  @Test("refresh rejects a non-podcast item without writing")
  func rejectsNonPodcastItems() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET mediaKind = 'book' WHERE id = ?",
        arguments: [seeded.itemId])
    }

    #expect(throws: PodcastRefreshStoreError.itemIsNotPodcast) {
      try PodcastRefreshStore(database: database).apply(
        PodcastRefreshApplication(
          accountId: seeded.accountId,
          itemId: seeded.itemId,
          episodes: [
            Self.episode(
              accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "invalid",
              title: "Invalid", generation: 1)
          ],
          autoDownloadEpisodes: true,
          responseIsComplete: true)
      ) { _ in .applyServer }
    }
    #expect(
      try database.read { db in
        try PodcastEpisodeRecord.filter(Column("itemId") == seeded.itemId).fetchCount(db)
      } == 0)
    #expect(
      try database.read { db in
        try ItemRecord.fetchOne(db, key: seeded.itemId)?.podcastAutoDownloadEpisodes
      } == nil)
  }

  @Test(
    "removal reconciliation resolves the item by account and server item id, upserts episodes, and soft-deletes what is missing"
  )
  func removalReconciliationUpsertsAndSoftDeletesMissingEpisodes() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let staleID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, serverEpisodeID: "stale",
      title: "Stale", generation: 1)

    try await database.writeAsync { db in
      try PodcastRefreshStore.applyRemovalReconciliation(
        accountId: seeded.accountId,
        serverItemId: seeded.serverItemID,
        episodes: [
          Self.episode(
            accountId: seeded.accountId, itemId: 0, serverEpisodeID: "remaining",
            title: "Remaining", generation: 0)
        ],
        refreshedAt: Date(timeIntervalSince1970: 1_900_000_000),
        in: db)
    }

    try database.read { db in
      let stale = try #require(try PodcastEpisodeRecord.fetchOne(db, key: staleID))
      #expect(stale.softDeleted)

      let remaining = try #require(
        try PodcastEpisodeRecord
          .filter(Column("itemId") == seeded.itemId)
          .filter(Column("serverEpisodeId") == "remaining")
          .fetchOne(db))
      #expect(remaining.softDeleted == false)
      #expect(remaining.itemId == seeded.itemId)

      let item = try #require(try ItemRecord.fetchOne(db, key: seeded.itemId))
      #expect(item.podcastServerEpisodeCount == 1)
    }
  }

  @Test("removal reconciliation throws itemNotFound for a missing server item id")
  func removalReconciliationThrowsForMissingItem() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)

    try await database.writeAsync { db in
      #expect(throws: PodcastRefreshStoreError.itemNotFound) {
        try PodcastRefreshStore.applyRemovalReconciliation(
          accountId: seeded.accountId, serverItemId: "no-such-item", episodes: [],
          refreshedAt: nil, in: db)
      }
    }
  }

  @Test("removal reconciliation throws itemNotFound rather than resolving another account's item id")
  func removalReconciliationThrowsForCrossAccountItem() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)

    try await database.writeAsync { db in
      #expect(throws: PodcastRefreshStoreError.itemNotFound) {
        try PodcastRefreshStore.applyRemovalReconciliation(
          accountId: seeded.accountId + 999, serverItemId: seeded.serverItemID, episodes: [],
          refreshedAt: nil, in: db)
      }
    }
    let item = try #require(try database.read { db in try ItemRecord.fetchOne(db, key: seeded.itemId) })
    #expect(item.podcastServerEpisodeCount == nil)
  }

  @Test("removal reconciliation rejects an ambiguous account-wide server item id")
  func removalReconciliationRejectsAmbiguousServerItemID() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)

    // Item identity is scoped to a library, so a corrupt/transitional cache can contain the same
    // server id twice for one account. Removal must not let `fetchOne` choose one row arbitrarily.
    try await database.writeAsync { db in
      var secondLibrary = LibraryRecord(
        accountId: seeded.accountId, serverLibraryId: "other-podcasts", mediaType: "podcast",
        name: "Other Podcasts")
      try secondLibrary.insert(db)
      var secondItem = ItemRecord(
        accountId: seeded.accountId, libraryId: secondLibrary.id!, serverItemId: seeded.serverItemID,
        mediaKind: "podcast", title: "Duplicate", sortTitle: "duplicate")
      try secondItem.insert(db)

      #expect(throws: PodcastRefreshStoreError.itemScopeMismatch) {
        try PodcastRefreshStore.applyRemovalReconciliation(
          accountId: seeded.accountId, serverItemId: seeded.serverItemID, episodes: [],
          refreshedAt: nil, in: db)
      }
    }

    let counts = try database.read { db in
      try ItemRecord
        .filter(Column("accountId") == seeded.accountId)
        .filter(Column("serverItemId") == seeded.serverItemID)
        .fetchAll(db)
        .map(\.podcastServerEpisodeCount)
    }
    #expect(counts.allSatisfy { $0 == nil })
  }

  private static func seedShow(
    _ database: AppDatabase
  ) async throws -> (accountId: Int64, itemId: Int64, serverItemID: String) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "fixture-client", serverBaseURL: "fixture-server",
        serverUserId: "fixture-user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "podcasts", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "show-1",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try item.insert(db)
      return (account.id!, item.id!, item.serverItemId)
    }
  }

  private static func insertAccount(
    _ database: AppDatabase,
    suffix: String
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var account = PersistenceFixtures.account(
        clientUUID: "fixture-client-\(suffix)", serverBaseURL: "fixture-server",
        serverUserId: "fixture-user-\(suffix)", serverVersion: "2.35.1")
      try account.insert(db)
      return try #require(account.id)
    }
  }

  private static func insertSaveAttempt(
    _ database: AppDatabase,
    accountId: Int64,
    serverItemID: String,
    episodeID: Int64,
    state: NativeEpisodeServerSaveAttemptState,
    updatedAt: Date
  ) async throws {
    try await database.writeAsync { db in
      var attempt = NativeEpisodeServerSaveAttemptRecord(
        accountId: accountId,
        accountClientUUID: "fixture-client",
        accountServerIdentityFingerprint: String(repeating: "a", count: 64),
        feedId: 1,
        episodeId: episodeID,
        episodeIdentityKey: "guid:fixture-\(episodeID)",
        serverItemId: serverItemID,
        state: state,
        createdAt: updatedAt,
        updatedAt: updatedAt)
      try attempt.insert(db)
    }
  }

  private static func assertActiveEpisodeProtectsLocalProgress(isOffline: Bool) async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await seedShow(database)
    let episodeID = try await insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId,
      serverEpisodeID: "active-episode", title: "Active episode", generation: 1)

    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: episodeID,
        currentTime: 120, isFinished: false, localSequence: 7, origin: .local,
        originKey: "fixture-client")
      try progress.insert(db)

      var session = PlaybackSessionRecord(
        accountId: seeded.accountId,
        clientSessionId: isOffline ? "offline-active" : "online-active",
        serverSessionId: isOffline ? nil : "server-session",
        itemId: seeded.itemId,
        podcastEpisodeId: episodeID,
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 120),
        isOffline: isOffline,
        globalPosition: 120,
        state: .active,
        lastLocalSequence: 7)
      try session.insert(db)

      if isOffline == false {
        var operation = OutboxOperationRecord(
          accountId: seeded.accountId,
          clientOperationId: "active-session-sync",
          entityKey: "session:\(session.clientSessionId)",
          podcastEpisodeId: nil,
          operationKind: "sessionSync",
          coalescingKey: "session:\(session.clientSessionId):tick-0",
          payloadVersion: 1,
          localSequence: 7,
          playbackSessionId: session.id)
        try operation.insert(db)
      }
    }

    try PodcastRefreshStore(database: database).apply(
      PodcastRefreshApplication(
        accountId: seeded.accountId,
        itemId: seeded.itemId,
        episodes: [
          episode(
            accountId: seeded.accountId, itemId: seeded.itemId,
            serverEpisodeID: "active-episode", title: "Active episode", generation: 2)
        ],
        progressObservations: [
          PodcastEpisodeProgressObservation(
            serverEpisodeId: "active-episode", currentTime: 5, isFinished: false,
            serverUpdatedAt: Date(timeIntervalSince1970: 200))
        ],
        responseIsComplete: false)
    ) { context in
      #expect(context.hasUnacknowledgedLocalOperation)
      return context.hasUnacknowledgedLocalOperation ? .keepLocal : .applyServer
    }

    let retained = try database.read { db in
      try MediaProgressRecord
        .filter(Column("accountId") == seeded.accountId)
        .filter(Column("podcastEpisodeId") == episodeID)
        .fetchOne(db)
    }
    #expect(retained?.currentTime == 120)
    #expect(retained?.origin == .local)
  }

  private static func episode(
    accountId: Int64,
    itemId: Int64,
    serverEpisodeID: String,
    title: String,
    generation: Int
  ) -> PodcastEpisodeRecord {
    PodcastEpisodeRecord(
      accountId: accountId, itemId: itemId, serverEpisodeId: serverEpisodeID, title: title,
      lastSeenGeneration: generation)
  }

  @discardableResult
  private static func insertEpisode(
    _ database: AppDatabase,
    accountId: Int64,
    itemId: Int64,
    serverEpisodeID: String,
    title: String,
    generation: Int
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = self.episode(
        accountId: accountId, itemId: itemId, serverEpisodeID: serverEpisodeID, title: title,
        generation: generation)
      try episode.insert(db)
      return episode.id!
    }
  }
}
