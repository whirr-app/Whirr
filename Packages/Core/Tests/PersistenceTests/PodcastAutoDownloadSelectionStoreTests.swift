import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct PodcastAutoDownloadSelectionStoreTests {

  // MARK: - Show enablement

  @Test func disabledShowYieldsNoCandidates() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    _ = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "ep-1",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)

    let candidates = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(candidates.isEmpty)
  }

  @Test func showOnOverridesGlobalOff() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let enabledAt = Date(timeIntervalSince1970: 1_000)
    try await Self.setShowOverride(
      database, fixture: fixture, override: .enabled, enabledAt: enabledAt)
    _ = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "ep-1",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)

    let candidates = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(candidates.map(\.episodeID) == ["ep-1"])
  }

  @Test func showOffSuppressesCandidateAgainstGlobalOn() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await Self.setGlobalEnabled(database, accountId: fixture.accountId, enabledAt: Date(timeIntervalSince1970: 500))
    try await Self.setShowOverride(database, fixture: fixture, override: .disabled, enabledAt: nil)
    _ = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "ep-1",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)

    let candidates = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(candidates.isEmpty)
  }

  // MARK: - The activation floor

  @Test func episodePublishedBeforeTheFloorIsNeverACandidate() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let enabledAt = Date(timeIntervalSince1970: 2_000)
    try await Self.setShowOverride(database, fixture: fixture, override: .enabled, enabledAt: enabledAt)
    _ = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "before",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    _ = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "after",
      publishedAt: Date(timeIntervalSince1970: 3_000))
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)

    let candidates = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(candidates.map(\.episodeID) == ["after"])
  }

  @Test func nullPublishedAtIsNeverACandidate() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await Self.setShowOverride(
      database, fixture: fixture, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
    _ = try await Self.addEpisode(database, fixture: fixture, serverEpisodeId: "no-date", publishedAt: nil)
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)

    let candidates = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(candidates.isEmpty)
  }

  // MARK: - Idempotence and manual-delete durability

  @Test func decidedEpisodeIsNeverACandidateAgain() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await Self.setShowOverride(
      database, fixture: fixture, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
    _ = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "ep-1",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)
    let before = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)
    #expect(before.map(\.episodeID) == ["ep-1"])

    try await store.markDecided(itemID: fixture.serverItemID, episodeID: "ep-1")

    let after = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)
    #expect(after.isEmpty)
  }

  @Test func manuallyDeletedEpisodeIsNeverReDownloaded() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await Self.setShowOverride(
      database, fixture: fixture, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
    let episodeRowId = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "ep-1",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)

    // Simulate the automatic pass: a download row is created, then the decided stamp lands.
    let downloadStore = try DownloadStore(database: database)
    let download = try downloadStore.enqueue(
      accountId: fixture.accountId, itemId: fixture.itemId, podcastEpisodeId: episodeRowId,
      serverFileIno: "ino-1", orderIndex: 0, destinationRelativePath: "path",
      expectedBytes: 100, expectedMimeType: "audio/mpeg", fileDurationSeconds: 10,
      origin: .automatic)
    try await store.markDecided(itemID: fixture.serverItemID, episodeID: "ep-1")

    // The user deletes it manually.
    _ = try downloadStore.transition(downloadId: download.id!, to: .deleting)
    try downloadStore.finalizeDeletion(downloadId: download.id!)

    let candidates = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(candidates.isEmpty)
  }

  // MARK: - Other exclusions

  @Test func alreadyDownloadedFinishedSoftDeletedOrAudiolessEpisodesDoNotQualify() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await Self.setShowOverride(
      database, fixture: fixture, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
    let downloadStore = try DownloadStore(database: database)

    let alreadyDownloadedId = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "already-downloaded",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    _ = try downloadStore.enqueue(
      accountId: fixture.accountId, itemId: fixture.itemId, podcastEpisodeId: alreadyDownloadedId,
      serverFileIno: "ino-existing", orderIndex: 0, destinationRelativePath: "path",
      expectedBytes: 100, expectedMimeType: "audio/mpeg", fileDurationSeconds: 10,
      origin: .manual)

    _ = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "finished",
      publishedAt: Date(timeIntervalSince1970: 1_100), progressIsFinished: true)

    _ = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "soft-deleted",
      publishedAt: Date(timeIntervalSince1970: 1_200), softDeleted: true)

    _ = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "audioless",
      publishedAt: Date(timeIntervalSince1970: 1_300), storedAudioIno: nil)

    _ = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "qualifies",
      publishedAt: Date(timeIntervalSince1970: 1_400))

    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)
    let candidates = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(candidates.map(\.episodeID) == ["qualifies"])
  }

  // MARK: - Keep-latest window

  @Test func candidatesRespectTheKeepLatestWindow() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await Self.setShowOverride(
      database, fixture: fixture, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
    try await Self.setShowKeepLatestOverride(database, fixture: fixture, count: 2)
    for index in 0..<4 {
      _ = try await Self.addEpisode(
        database, fixture: fixture, serverEpisodeId: "ep-\(index)",
        publishedAt: Date(timeIntervalSince1970: Double(1_000 + index * 100)))
    }
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)

    let candidates = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    // Only the two newest by publishedAt survive the keep-latest-2 window.
    #expect(candidates.map(\.episodeID) == ["ep-3", "ep-2"])
  }

  @Test func keepAllDisablesTheWindow() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await Self.setShowOverride(
      database, fixture: fixture, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
    try await Self.setShowKeepLatestOverride(database, fixture: fixture, count: 0)
    for index in 0..<4 {
      _ = try await Self.addEpisode(
        database, fixture: fixture, serverEpisodeId: "ep-\(index)",
        publishedAt: Date(timeIntervalSince1970: Double(1_000 + index * 100)))
    }
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)

    let candidates = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(candidates.count == 4)
  }

  // MARK: - Ordering and budgets

  @Test func candidateOrderIsPublishedAtDescendingThenEpisodeId() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await Self.setShowOverride(
      database, fixture: fixture, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
    let tie = Date(timeIntervalSince1970: 1_000)
    _ = try await Self.addEpisode(database, fixture: fixture, serverEpisodeId: "b-tie", publishedAt: tie)
    _ = try await Self.addEpisode(database, fixture: fixture, serverEpisodeId: "a-tie", publishedAt: tie)
    _ = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)

    let candidates = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(candidates.map(\.episodeID) == ["newest", "a-tie", "b-tie"])
  }

  @Test func perShowAndPerPassBudgetsBound() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await Self.seed(database, suffix: "first")
    let second = try await Self.seed(database, suffix: "second", accountId: first.accountId, libraryId: first.libraryId)
    try await Self.setShowOverride(
      database, fixture: first, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
    try await Self.setShowOverride(
      database, fixture: second, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
    for index in 0..<4 {
      _ = try await Self.addEpisode(
        database, fixture: first, serverEpisodeId: "first-\(index)",
        publishedAt: Date(timeIntervalSince1970: Double(1_000 + index * 100)))
      _ = try await Self.addEpisode(
        database, fixture: second, serverEpisodeId: "second-\(index)",
        publishedAt: Date(timeIntervalSince1970: Double(1_000 + index * 100)))
    }
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: first.accountId)

    let candidates = try await store.fetchCandidates(maxPerShow: 2, maxPerPass: 3)

    #expect(candidates.count == 3)
    let perShow = Dictionary(grouping: candidates, by: \.itemID)
    for (_, episodes) in perShow {
      #expect(episodes.count <= 2)
    }
  }

  // MARK: - Scoping

  @Test func candidateQueryIsAccountScoped() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await Self.seed(database, suffix: "first")
    let second = try await Self.seed(database, suffix: "second")
    try await Self.setShowOverride(
      database, fixture: first, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
    try await Self.setShowOverride(
      database, fixture: second, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
    _ = try await Self.addEpisode(
      database, fixture: first, serverEpisodeId: "ep-1",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    _ = try await Self.addEpisode(
      database, fixture: second, serverEpisodeId: "ep-1",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    let firstStore = PodcastAutoDownloadSelectionStore(database: database, accountId: first.accountId)
    let secondStore = PodcastAutoDownloadSelectionStore(database: database, accountId: second.accountId)

    let firstCandidates = try await firstStore.fetchCandidates(maxPerShow: 5, maxPerPass: 20)
    let secondCandidates = try await secondStore.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(firstCandidates.map(\.itemID) == [first.serverItemID])
    #expect(secondCandidates.map(\.itemID) == [second.serverItemID])
  }

  @Test func candidateQueryExcludesEpisodesFromAnExcludedLibrary() async throws {
    let database = try AppDatabase.inMemory()
    let included = try await Self.seed(database, suffix: "included")
    let excludedLibraryID = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: included.accountId, serverLibraryId: "library-excluded", mediaType: "podcast",
        name: "Excluded", isIncluded: false)
      try library.insert(db)
      return try #require(library.id)
    }
    let excluded = try await Self.seed(
      database, suffix: "excluded", accountId: included.accountId, libraryId: excludedLibraryID)
    for fixture in [included, excluded] {
      try await Self.setShowOverride(
        database, fixture: fixture, override: .enabled, enabledAt: Date(timeIntervalSince1970: 0))
      _ = try await Self.addEpisode(
        database, fixture: fixture, serverEpisodeId: "episode-\(fixture.serverItemID)",
        publishedAt: Date(timeIntervalSince1970: 1_000))
    }

    let candidates = try await PodcastAutoDownloadSelectionStore(
      database: database, accountId: included.accountId
    ).fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(candidates.map(\.itemID) == [included.serverItemID])
  }

  // MARK: - Repair

  @Test func repairStampsDecidedOnAutomaticRowsMissingTheStamp() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let episodeRowId = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "ep-1",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    let downloadStore = try DownloadStore(database: database)
    // Crash-window shape: the row was created but the process died before `markDecided` ran.
    _ = try downloadStore.enqueue(
      accountId: fixture.accountId, itemId: fixture.itemId, podcastEpisodeId: episodeRowId,
      serverFileIno: "ino-1", orderIndex: 0, destinationRelativePath: "path",
      expectedBytes: 100, expectedMimeType: "audio/mpeg", fileDurationSeconds: 10,
      origin: .automatic)
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)

    let before = try database.read { db in
      try PodcastEpisodeRecord.fetchOne(db, key: episodeRowId)?.autoDownloadDecidedAt
    }
    #expect(before == nil)

    let repaired = try await store.repairDecidedStamps()

    #expect(repaired == 1)
    let after = try database.read { db in
      try PodcastEpisodeRecord.fetchOne(db, key: episodeRowId)?.autoDownloadDecidedAt
    }
    #expect(after != nil)

    // Idempotent: a second pass finds nothing left to repair.
    let secondPass = try await store.repairDecidedStamps()
    #expect(secondPass == 0)
  }

  @Test func repairLeavesManualOriginRowsAlone() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let episodeRowId = try await Self.addEpisode(
      database, fixture: fixture, serverEpisodeId: "ep-1",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    let downloadStore = try DownloadStore(database: database)
    _ = try downloadStore.enqueue(
      accountId: fixture.accountId, itemId: fixture.itemId, podcastEpisodeId: episodeRowId,
      serverFileIno: "ino-1", orderIndex: 0, destinationRelativePath: "path",
      expectedBytes: 100, expectedMimeType: "audio/mpeg", fileDurationSeconds: 10,
      origin: .manual)
    let store = PodcastAutoDownloadSelectionStore(database: database, accountId: fixture.accountId)

    let repaired = try await store.repairDecidedStamps()

    #expect(repaired == 0)
    let after = try database.read { db in
      try PodcastEpisodeRecord.fetchOne(db, key: episodeRowId)?.autoDownloadDecidedAt
    }
    #expect(after == nil)
  }

  // MARK: - Fixtures

  private struct Fixture {
    let accountId: Int64
    let libraryId: Int64
    let itemId: Int64
    let serverItemID: String
  }

  private static func seed(
    _ database: AppDatabase,
    suffix: String = "primary",
    accountId presetAccountId: Int64? = nil,
    libraryId presetLibraryId: Int64? = nil
  ) async throws -> Fixture {
    try await database.writeAsync { db in
      let accountId: Int64
      let libraryId: Int64
      if let presetAccountId, let presetLibraryId {
        accountId = presetAccountId
        libraryId = presetLibraryId
      } else {
        var account = AccountRecord(
          clientUUID: "client-\(suffix)", serverBaseURL: "server-\(suffix)",
          serverUserId: "user-\(suffix)", serverVersion: "2.35.1")
        try account.insert(db)
        var library = LibraryRecord(
          accountId: account.id!, serverLibraryId: "library-\(suffix)", mediaType: "podcast",
          name: "Podcasts")
        try library.insert(db)
        accountId = account.id!
        libraryId = library.id!
      }
      let serverItemID = "show-\(suffix)"
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemID,
        mediaKind: "podcast", title: "Show \(suffix)", sortTitle: "show \(suffix)")
      try item.insert(db)
      return Fixture(
        accountId: accountId, libraryId: libraryId, itemId: item.id!, serverItemID: serverItemID)
    }
  }

  private static func setGlobalEnabled(_ database: AppDatabase, accountId: Int64, enabledAt: Date) async throws {
    try await database.writeAsync { db in
      let record = PodcastSettingsRecord(
        accountId: accountId, autoDownloadEnabled: true, enabledAt: enabledAt)
      try record.save(db)
    }
  }

  private static func setShowOverride(
    _ database: AppDatabase, fixture: Fixture, override: PodcastShowAutoDownloadOverride,
    enabledAt: Date?
  ) async throws {
    try await database.writeAsync { db in
      let record = PodcastShowSettingsRecord(
        itemId: fixture.itemId, accountId: fixture.accountId, autoDownloadOverride: override,
        enabledAt: enabledAt)
      try record.save(db)
    }
  }

  private static func setShowKeepLatestOverride(
    _ database: AppDatabase, fixture: Fixture, count: Int
  ) async throws {
    try await database.writeAsync { db in
      guard
        var record = try PodcastShowSettingsRecord.fetchOne(
          db, key: ["itemId": fixture.itemId])
      else {
        preconditionFailure("show override must be set before keep-latest override in these tests")
      }
      record.keepLatestOverride = count
      try record.save(db)
    }
  }

  @discardableResult
  private static func addEpisode(
    _ database: AppDatabase,
    fixture: Fixture,
    serverEpisodeId: String,
    publishedAt: Date?,
    softDeleted: Bool = false,
    storedAudioIno: String? = "ino",
    progressIsFinished: Bool = false
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: fixture.accountId, itemId: fixture.itemId, serverEpisodeId: serverEpisodeId,
        title: "Episode \(serverEpisodeId)",
        durationSeconds: 600,
        publishedAt: publishedAt,
        storedAudioIno: storedAudioIno,
        storedAudioExpectedSize: storedAudioIno != nil ? 4_096 : nil,
        storedAudioMimeType: storedAudioIno != nil ? "audio/mpeg" : nil,
        storedAudioDurationSeconds: storedAudioIno != nil ? 600 : nil,
        lastSeenGeneration: 1,
        softDeleted: softDeleted)
      try episode.insert(db)
      let episodeRowId = episode.id!

      if progressIsFinished {
        var progress = MediaProgressRecord(
          accountId: fixture.accountId, itemId: fixture.itemId, podcastEpisodeId: episodeRowId,
          currentTime: 600, isFinished: true, localSequence: 1, origin: .local,
          originKey: "client")
        try progress.insert(db)
      }
      return episodeRowId
    }
  }
}
