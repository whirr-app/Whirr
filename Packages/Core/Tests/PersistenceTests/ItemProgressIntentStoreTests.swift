import GRDB
import Testing

@testable import Persistence

@Suite("Item progress intents")
struct ItemProgressIntentStoreTests {
  @Test("reset progress atomically updates the local projection and queues a zero-position mutation")
  func resetProgressUpdatesProjectionAndOutbox() async throws {
    let harness = try await Harness()

    try harness.store.setProgress(
      itemID: harness.serverItemID,
      currentTime: 0,
      isFinished: false,
      originKey: harness.clientUUID)

    let (progress, operation) = try harness.readItemRows()
    #expect(progress.currentTime == 0)
    #expect(progress.isFinished == false)
    #expect(progress.localSequence == 8)
    #expect(progress.origin == .local)
    #expect(progress.originKey == harness.clientUUID)
    #expect(operation.entityKey == harness.serverItemID)
    #expect(operation.podcastEpisodeId == nil)
    #expect(operation.payloadCurrentTime == 0)
    #expect(operation.payloadIsFinished == false)
    #expect(operation.localSequence == 8)
  }

  @Test("ebook reset clears reading state and queues a dedicated reset mutation")
  func ebookResetUpdatesProjectionAndOutbox() async throws {
    let harness = try await Harness()
    try await harness.database.writeAsync { db in
      var progress = try #require(
        try MediaProgressRecord
          .filter(Column("itemId") == harness.itemRowID)
          .filter(Column("podcastEpisodeId") == nil)
          .fetchOne(db))
      progress.ebookProgress = 0.63
      progress.ebookLocation = "epubcfi(/6/4!/4/2/1:0)"
      progress.readingPositionJSON = "{\"href\":\"chapter.xhtml\"}"
      progress.isFinished = true
      try progress.update(db)
    }

    try harness.store.resetEbookProgress(
      itemID: harness.serverItemID, originKey: harness.clientUUID)

    let (progress, operation) = try harness.readItemRows()
    #expect(progress.currentTime == 900)
    #expect(progress.ebookProgress == 0)
    #expect(progress.ebookLocation == nil)
    #expect(progress.readingPositionJSON == nil)
    #expect(progress.isFinished == false)
    #expect(operation.operationKind == OutboxOperationKind.progressReset.rawValue)
    #expect(operation.payloadCurrentTime == nil)
    #expect(operation.payloadEbookProgress == nil)
    #expect(operation.payloadIsFinished == nil)
  }

  @Test("reset progress queues a row-deleting reset of the audio medium")
  func resetProgressQueuesAnAudioProgressReset() async throws {
    let harness = try await Harness()

    try harness.store.resetProgress(itemID: harness.serverItemID, originKey: harness.clientUUID)

    let (progress, operation) = try harness.readItemRows()
    #expect(progress.currentTime == 0)
    #expect(progress.isFinished == false)
    #expect(progress.localSequence == 8)
    #expect(operation.operationKind == OutboxOperationKind.progressReset.rawValue)
    #expect(operation.progressResetMedium == .audio)
    #expect(operation.progressResetPhase == .resolve)
    #expect(operation.podcastEpisodeId == nil)
    #expect(operation.localSequence == 8)
    #expect(operation.payloadCurrentTime == nil)
    #expect(operation.payloadIsFinished == nil)
  }

  @Test("an episode reset is an audio reset scoped to the episode")
  func episodeResetQueuesAnEpisodeScopedProgressReset() async throws {
    let harness = try await Harness()

    try await harness.store.resetProgressAsync(
      itemID: Harness.serverShowID, episodeID: Harness.serverEpisodeID,
      originKey: harness.clientUUID)

    let operation = try #require(
      try await harness.database.readAsync { db in
        try OutboxOperationRecord.filter(Column("podcastEpisodeId") == harness.episodeRowID)
          .fetchOne(db)
      })
    #expect(operation.operationKind == OutboxOperationKind.progressReset.rawValue)
    #expect(operation.entityKey == Harness.serverShowID)
    #expect(operation.progressResetMedium == .audio)
  }

  @Test("a queued reset protects its own medium and the shared finish, and nothing else")
  func queuedResetsProtectTheirOwnFields() async throws {
    let harness = try await Harness()
    let dao = MediaProgressDAO(database: harness.database)
    let identity = MediaProgressIdentity.item(itemId: harness.itemRowID)
    let accountId = try #require(
      try await harness.database.readAsync { db in try AccountRecord.fetchOne(db)?.id })

    try harness.store.resetProgress(itemID: harness.serverItemID, originKey: harness.clientUUID)
    #expect(try dao.hasUnacknowledgedLocalOperation(accountId: accountId, identity: identity))
    #expect(
      try dao.hasUnacknowledgedLocalOperation(
        accountId: accountId, identity: identity, field: .sharedFinish))
    #expect(
      try dao.hasUnacknowledgedLocalOperation(
        accountId: accountId, identity: identity, field: .ebookPosition) == false)

    try await harness.database.writeAsync { db in _ = try OutboxOperationRecord.deleteAll(db) }
    try harness.store.resetEbookProgress(
      itemID: harness.serverItemID, originKey: harness.clientUUID)
    #expect(
      try dao.hasUnacknowledgedLocalOperation(
        accountId: accountId, identity: identity, field: .ebookPosition))
    #expect(
      try dao.hasUnacknowledgedLocalOperation(
        accountId: accountId, identity: identity, field: .sharedFinish))
    #expect(try dao.hasUnacknowledgedLocalOperation(accountId: accountId, identity: identity) == false)
  }

  @Test("ebook reset raises the local sequence past earlier queued ebook work")
  func ebookResetKeepsProjectionAndOperationSequencesAligned() async throws {
    let harness = try await Harness()
    let outbox = try OutboxStore(database: harness.database)
    let accountID = try harness.database.read { db in
      try #require(try AccountRecord.fetchOne(db)?.id)
    }
    _ = try outbox.enqueueEbookPosition(
      accountId: accountID,
      entityKey: harness.serverItemID,
      localSequence: 20,
      payload: OutboxEbookPositionPayload(ebookProgress: 0.4))

    try harness.store.resetEbookProgress(
      itemID: harness.serverItemID, originKey: harness.clientUUID)

    let rows = try harness.database.read { db in
      (
        try MediaProgressRecord
          .filter(Column("itemId") == harness.itemRowID)
          .filter(Column("podcastEpisodeId") == nil)
          .fetchOne(db),
        try OutboxOperationRecord
          .filter(Column("operationKind") == OutboxOperationKind.progressReset.rawValue)
          .fetchOne(db)
      )
    }
    let progress = try #require(rows.0)
    let operation = try #require(rows.1)
    #expect(progress.localSequence == operation.localSequence)
    #expect(operation.localSequence == 21)
  }

  @Test("mark finished uses the duration and starts a distinct progress mutation")
  func markFinishedUsesDuration() async throws {
    let harness = try await Harness()

    try harness.store.setProgress(
      itemID: harness.serverItemID,
      currentTime: 3_600,
      isFinished: true,
      originKey: harness.clientUUID)

    let (progress, operation) = try harness.readItemRows()
    #expect(progress.currentTime == 3_600)
    #expect(progress.isFinished)
    #expect(operation.payloadCurrentTime == 3_600)
    #expect(operation.payloadIsFinished == true)
  }

  @Test("continue listening visibility changes only its local field and queues one mutation")
  func continueListeningVisibilityUpdatesOnlyVisibility() async throws {
    let harness = try await Harness()
    let before = try harness.database.read { db in
      try #require(
        try MediaProgressRecord
          .filter(Column("itemId") == harness.itemRowID)
          .filter(Column("podcastEpisodeId") == nil)
          .fetchOne(db))
    }

    try harness.store.setContinueListeningVisibility(
      itemID: harness.serverItemID,
      isHidden: true,
      originKey: harness.clientUUID)

    let (progress, operation) = try harness.readItemRows()
    #expect(progress.currentTime == before.currentTime)
    #expect(progress.isFinished == before.isFinished)
    #expect(progress.ebookProgress == before.ebookProgress)
    #expect(progress.ebookLocation == before.ebookLocation)
    #expect(progress.readingPositionJSON == before.readingPositionJSON)
    #expect(progress.hideFromContinueListening)
    #expect(progress.localSequence == before.localSequence + 1)
    #expect(progress.origin == .local)
    #expect(progress.originKey == harness.clientUUID)
    #expect(operation.operationKind == OutboxOperationKind.continueListeningVisibility.rawValue)
    #expect(operation.podcastEpisodeId == nil)
    #expect(operation.payloadHideFromContinueListening == true)
    #expect(operation.payloadCurrentTime == nil)
    #expect(operation.payloadIsFinished == nil)
    #expect(operation.payloadAccumulatedDeltaSeconds == nil)
    #expect(operation.localSequence == progress.localSequence)
  }

  @Test("an episode-scoped intent writes the episode's own progress row, never the show's")
  func episodeIntentWritesEpisodeProgressRow() async throws {
    let harness = try await Harness()

    try harness.store.setProgress(
      itemID: Harness.serverShowID,
      episodeID: Harness.serverEpisodeID,
      currentTime: 2_400,
      isFinished: true,
      originKey: harness.clientUUID)

    let (progress, operation) = try harness.readEpisodeRows()
    #expect(progress.podcastEpisodeId == harness.episodeRowID)
    #expect(progress.currentTime == 2_400)
    #expect(progress.isFinished)
    #expect(progress.localSequence == 4)
    #expect(progress.origin == .local)
    #expect(progress.originKey == harness.clientUUID)
    // `entityKey` stays the show's server item id. The drainer resolves the episode's server id
    // from `podcastEpisodeId` at send time and routes to `/progress/{itemId}/{episodeId}`.
    #expect(operation.entityKey == Harness.serverShowID)
    #expect(operation.podcastEpisodeId == harness.episodeRowID)
    #expect(operation.payloadCurrentTime == 2_400)
    #expect(operation.payloadIsFinished == true)
    #expect(operation.localSequence == 4)
  }

  @Test("an episode-scoped intent leaves the show's own progress row untouched")
  func episodeIntentDoesNotTouchTheShow() async throws {
    let harness = try await Harness()

    try harness.store.setProgress(
      itemID: Harness.serverShowID,
      episodeID: Harness.serverEpisodeID,
      currentTime: 2_400,
      isFinished: true,
      originKey: harness.clientUUID)

    // A finished episode does not finish its show: the two identities never share a row.
    let showProgress = try harness.showProgressRow()
    #expect(showProgress.currentTime == 120)
    #expect(showProgress.isFinished == false)
    #expect(showProgress.localSequence == 2)
  }

  @Test("an episode with no progress row yet gets one created rather than adopting the show's")
  func episodeIntentCreatesMissingProgressRow() async throws {
    let harness = try await Harness()

    try harness.store.setProgress(
      itemID: Harness.serverShowID,
      episodeID: Harness.secondServerEpisodeID,
      currentTime: 0,
      isFinished: false,
      originKey: harness.clientUUID)

    let created = try harness.database.read { db in
      try MediaProgressRecord
        .filter(Column("podcastEpisodeId") == harness.secondEpisodeRowID)
        .fetchOne(db)
    }
    let progress = try #require(created)
    #expect(progress.currentTime == 0)
    #expect(progress.isFinished == false)
    #expect(progress.localSequence == 1)
  }

  @Test("unknown episode is rejected without creating progress or outbox rows")
  func unknownEpisodeDoesNotWrite() async throws {
    let harness = try await Harness()
    let before = try harness.rowCounts()

    #expect(throws: ItemProgressIntentStoreError.episodeNotFound("missing")) {
      try harness.store.setProgress(
        itemID: Harness.serverShowID,
        episodeID: "missing",
        currentTime: 0,
        isFinished: false,
        originKey: harness.clientUUID)
    }

    #expect(try harness.rowCounts() == before)
  }

  @Test("unknown item is rejected without creating progress or outbox rows")
  func unknownItemDoesNotWrite() async throws {
    let harness = try await Harness()
    let before = try harness.rowCounts()

    #expect(throws: ItemProgressIntentStoreError.itemNotFound("missing")) {
      try harness.store.setProgress(
        itemID: "missing",
        currentTime: 0,
        isFinished: false,
        originKey: harness.clientUUID)
    }

    #expect(try harness.rowCounts() == before)
  }
}

extension ItemProgressIntentStoreTests {
  /// "Mark all as played" over a filtered list is one user action, and the outbox rows it queues
  /// have to land together. A partial write would leave half a show finished with nothing to say
  /// which half.
  @Test("a bulk episode intent writes every projection and outbox row in one transaction")
  func bulkEpisodeIntentWritesEveryRowAtOnce() async throws {
    let harness = try await Harness()

    try harness.store.setProgress(
      itemID: Harness.serverShowID,
      episodes: [
        EpisodeProgressChange(episodeID: Harness.serverEpisodeID, currentTime: 2_400),
        EpisodeProgressChange(episodeID: Harness.secondServerEpisodeID, currentTime: 1_800),
      ],
      isFinished: true,
      originKey: harness.clientUUID)

    for rowID in [harness.episodeRowID, harness.secondEpisodeRowID] {
      let progress = try harness.database.read { db in
        try MediaProgressRecord.filter(Column("podcastEpisodeId") == rowID).fetchOne(db)
      }
      #expect(progress?.isFinished == true)
      #expect(progress?.origin == .local)
    }
    #expect(try harness.episodeOutboxCount() == 2)
  }

  /// One failure fails the whole batch: an episode that is not cached takes the transaction
  /// down rather than leaving a silently partial result the user would read as success.
  @Test func bulkEpisodeIntentRollsBackEntirelyOnAnUnknownEpisode() async throws {
    let harness = try await Harness()

    #expect(throws: ItemProgressIntentStoreError.episodeNotFound("ep-gone")) {
      try harness.store.setProgress(
        itemID: Harness.serverShowID,
        episodes: [
          EpisodeProgressChange(episodeID: Harness.serverEpisodeID, currentTime: 2_400),
          EpisodeProgressChange(episodeID: "ep-gone", currentTime: 10),
        ],
        isFinished: true,
        originKey: harness.clientUUID)
    }

    let progress = try harness.database.read { db in
      try MediaProgressRecord
        .filter(Column("podcastEpisodeId") == harness.episodeRowID)
        .fetchOne(db)
    }
    #expect(progress?.isFinished != true, "the first episode's write rolled back with the batch")
  }

  @Test("the item progress async twin preserves the projection and outbox rows")
  func setProgressAsyncMatchesSyncTwin() async throws {
    let syncHarness = try await Harness()
    let asyncHarness = try await Harness()

    try syncHarness.store.setProgress(
      itemID: syncHarness.serverItemID,
      currentTime: 2_345,
      isFinished: true,
      originKey: syncHarness.clientUUID)
    try await asyncHarness.store.setProgressAsync(
      itemID: asyncHarness.serverItemID,
      currentTime: 2_345,
      isFinished: true,
      originKey: asyncHarness.clientUUID)

    let sync = try syncHarness.readItemRows()
    let async = try await asyncHarness.readItemRowsAsync()
    #expect(async.0.currentTime == sync.0.currentTime)
    #expect(async.0.isFinished == sync.0.isFinished)
    #expect(async.0.localSequence == sync.0.localSequence)
    #expect(async.1.operationKind == sync.1.operationKind)
    #expect(async.1.entityKey == sync.1.entityKey)
    #expect(async.1.payloadCurrentTime == 2_345)
    #expect(async.1.payloadIsFinished == true)
    #expect(try await asyncHarness.episodeOutboxCountAsync() == 0)
  }

  @Test("the ebook reset async twin preserves the cleared projection and reset operation")
  func resetEbookProgressAsyncMatchesSyncTwin() async throws {
    let syncHarness = try await Harness()
    let asyncHarness = try await Harness()
    for harness in [syncHarness, asyncHarness] {
      try await harness.database.writeAsync { db in
        var progress = try #require(
          try MediaProgressRecord
            .filter(Column("itemId") == harness.itemRowID)
            .filter(Column("podcastEpisodeId") == nil)
            .fetchOne(db))
        progress.ebookProgress = 0.63
        progress.ebookLocation = "epubcfi(/6/4!/4/2/1:0)"
        progress.readingPositionJSON = "{\"href\":\"chapter.xhtml\"}"
        progress.isFinished = true
        try progress.update(db)
      }
    }

    try syncHarness.store.resetEbookProgress(
      itemID: syncHarness.serverItemID, originKey: syncHarness.clientUUID)
    try await asyncHarness.store.resetEbookProgressAsync(
      itemID: asyncHarness.serverItemID, originKey: asyncHarness.clientUUID)

    let sync = try syncHarness.readItemRows()
    let async = try await asyncHarness.readItemRowsAsync()
    #expect(async.0.currentTime == sync.0.currentTime)
    #expect(async.0.ebookProgress == 0)
    #expect(async.0.ebookLocation == nil)
    #expect(async.0.readingPositionJSON == nil)
    #expect(async.0.isFinished == false)
    #expect(async.1.operationKind == OutboxOperationKind.progressReset.rawValue)
    #expect(async.1.localSequence == async.0.localSequence)
  }

  @Test("the bulk progress async twin commits every projection and outbox row")
  func bulkProgressAsyncMatchesSyncTwin() async throws {
    let syncHarness = try await Harness()
    let asyncHarness = try await Harness()
    let changes = [
      EpisodeProgressChange(episodeID: Harness.serverEpisodeID, currentTime: 2_400),
      EpisodeProgressChange(episodeID: Harness.secondServerEpisodeID, currentTime: 1_800),
    ]

    try syncHarness.store.setProgress(
      itemID: Harness.serverShowID, episodes: changes, isFinished: true,
      originKey: syncHarness.clientUUID)
    try await asyncHarness.store.setProgressAsync(
      itemID: Harness.serverShowID, episodes: changes, isFinished: true,
      originKey: asyncHarness.clientUUID)

    for rowID in [asyncHarness.episodeRowID, asyncHarness.secondEpisodeRowID] {
      let progress = try await asyncHarness.database.readAsync { db in
        try MediaProgressRecord.filter(Column("podcastEpisodeId") == rowID).fetchOne(db)
      }
      #expect(progress?.isFinished == true)
      #expect(progress?.origin == .local)
    }
    #expect(try await asyncHarness.episodeOutboxCountAsync() == 2)
    let syncCount = try syncHarness.episodeOutboxCount()
    let asyncCount = try await asyncHarness.episodeOutboxCountAsync()
    #expect(syncCount == asyncCount)
  }

  fileprivate struct Harness {
    let database: AppDatabase
    let store: ItemProgressIntentStore
    let itemRowID: Int64
    let showRowID: Int64
    let episodeRowID: Int64
    let secondEpisodeRowID: Int64
    static let serverItemID = "book-1"
    static let serverShowID = "show-1"
    static let serverEpisodeID = "ep-1"
    static let secondServerEpisodeID = "ep-2"
    static let clientUUID = "device-origin"
    var serverItemID: String { Self.serverItemID }
    var clientUUID: String { Self.clientUUID }

    init() async throws {
      database = try AppDatabase.inMemory()
      store = try ItemProgressIntentStore(database: database)

      let accountID = try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: Self.clientUUID,
          serverBaseURL: "https://example.test",
          serverUserId: "user",
          serverVersion: "2.26.0")
        try account.insert(db)
        return try #require(account.id)
      }
      let libraryID = try await database.writeAsync { db in
        var library = LibraryRecord(
          accountId: accountID,
          serverLibraryId: "library-1",
          mediaType: "book",
          name: "Audiobooks")
        try library.insert(db)
        return try #require(library.id)
      }
      itemRowID = try await database.writeAsync { db in
        var item = ItemRecord(
          accountId: accountID,
          libraryId: libraryID,
          serverItemId: Self.serverItemID,
          mediaKind: "book",
          title: "A Book",
          sortTitle: "a book")
        try item.insert(db)
        return try #require(item.id)
      }
      showRowID = try await database.writeAsync { db in
        var show = ItemRecord(
          accountId: accountID,
          libraryId: libraryID,
          serverItemId: Self.serverShowID,
          mediaKind: "podcast",
          title: "A Show",
          sortTitle: "a show")
        try show.insert(db)
        return try #require(show.id)
      }
      let showRowID = showRowID
      episodeRowID = try await database.writeAsync { db in
        var episode = PodcastEpisodeRecord(
          accountId: accountID,
          itemId: showRowID,
          serverEpisodeId: Self.serverEpisodeID,
          title: "Episode One",
          lastSeenGeneration: 1)
        try episode.insert(db)
        return try #require(episode.id)
      }
      secondEpisodeRowID = try await database.writeAsync { db in
        var episode = PodcastEpisodeRecord(
          accountId: accountID,
          itemId: showRowID,
          serverEpisodeId: Self.secondServerEpisodeID,
          title: "Episode Two",
          lastSeenGeneration: 1)
        try episode.insert(db)
        return try #require(episode.id)
      }

      let itemRowID = itemRowID
      let episodeRowID = episodeRowID
      try await database.writeAsync { db in
        var progress = MediaProgressRecord(
          accountId: accountID,
          itemId: itemRowID,
          currentTime: 900,
          isFinished: false,
          localSequence: 7,
          origin: .local,
          originKey: Self.clientUUID)
        try progress.insert(db)

        var showProgress = MediaProgressRecord(
          accountId: accountID,
          itemId: showRowID,
          currentTime: 120,
          isFinished: false,
          localSequence: 2,
          origin: .local,
          originKey: Self.clientUUID)
        try showProgress.insert(db)

        var episodeProgress = MediaProgressRecord(
          accountId: accountID,
          itemId: showRowID,
          podcastEpisodeId: episodeRowID,
          currentTime: 60,
          isFinished: false,
          localSequence: 3,
          origin: .local,
          originKey: Self.clientUUID)
        try episodeProgress.insert(db)
      }
    }

    func readItemRows() throws -> (MediaProgressRecord, OutboxOperationRecord) {
      let rows = try database.read { db in
        (
          try MediaProgressRecord.filter(Column("itemId") == itemRowID).fetchOne(db),
          try OutboxOperationRecord.filter(Column("podcastEpisodeId") == nil).fetchOne(db)
        )
      }
      return (try #require(rows.0), try #require(rows.1))
    }

    func readItemRowsAsync() async throws -> (MediaProgressRecord, OutboxOperationRecord) {
      let rows = try await database.readAsync { db in
        (
          try MediaProgressRecord.filter(Column("itemId") == itemRowID).fetchOne(db),
          try OutboxOperationRecord.filter(Column("podcastEpisodeId") == nil).fetchOne(db)
        )
      }
      return (try #require(rows.0), try #require(rows.1))
    }

    func episodeOutboxCount() throws -> Int {
      try database.read { db in
        try OutboxOperationRecord.filter(Column("podcastEpisodeId") != nil).fetchCount(db)
      }
    }

    func episodeOutboxCountAsync() async throws -> Int {
      try await database.readAsync { db in
        try OutboxOperationRecord.filter(Column("podcastEpisodeId") != nil).fetchCount(db)
      }
    }

    func readEpisodeRows() throws -> (MediaProgressRecord, OutboxOperationRecord) {
      let rows = try database.read { db in
        (
          try MediaProgressRecord
            .filter(Column("podcastEpisodeId") == episodeRowID).fetchOne(db),
          try OutboxOperationRecord
            .filter(Column("podcastEpisodeId") == episodeRowID).fetchOne(db)
        )
      }
      return (try #require(rows.0), try #require(rows.1))
    }

    func showProgressRow() throws -> MediaProgressRecord {
      let row = try database.read { db in
        try MediaProgressRecord
          .filter(Column("itemId") == showRowID)
          .filter(Column("podcastEpisodeId") == nil)
          .fetchOne(db)
      }
      return try #require(row)
    }

    func rowCounts() throws -> (progress: Int, outbox: Int) {
      try database.read { db in
        (
          try MediaProgressRecord.fetchCount(db),
          try OutboxOperationRecord.fetchCount(db)
        )
      }
    }
  }
}
