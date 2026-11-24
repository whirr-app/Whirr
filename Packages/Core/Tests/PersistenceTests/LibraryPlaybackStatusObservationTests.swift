import Foundation
import GRDB
import Synchronization
import TestSupport
import Testing

@testable import Persistence

extension LibraryReadingObservationTests {
  // MARK: - Item playback status

  @Test("item playback progress floors position to the minute")
  func itemPlaybackProgressFloorsPosition() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "audio",
        mediaKind: "book", title: "audio", sortTitle: "audio")
      try item.insert(db)
      var progress = MediaProgressRecord(
        accountId: accountId, itemId: item.id!, currentTime: 930.5,
        isFinished: false, localSequence: 1, origin: .local, originKey: "client")
      try progress.insert(db)
    }

    let observations = PersistenceObservationCollector(
      reading.observeItemPlaybackProgress(itemIDs: ["audio"]))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    #expect(observations.values.last?["audio"]?.currentTime == 900)
  }

  @Test("item playback progress is scoped to requested items and follows position changes")
  func itemPlaybackProgressFollowsRequestedItems() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    let rowIDs = try await database.writeAsync { db -> [String: Int64] in
      var rowIDs: [String: Int64] = [:]
      for serverItemID in ["audio", "ebook", "outside"] {
        var item = ItemRecord(
          accountId: accountId, libraryId: libraryRowId, serverItemId: serverItemID,
          mediaKind: "book", title: serverItemID, sortTitle: serverItemID)
        try item.insert(db)
        rowIDs[serverItemID] = item.id!
      }
      return rowIDs
    }

    let observations = PersistenceObservationCollector(
      reading.observeItemPlaybackProgress(itemIDs: ["audio", "ebook"]))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    #expect(observations.values.first?.isEmpty == true)

    try await database.writeAsync { db in
      var audio = MediaProgressRecord(
        accountId: accountId, itemId: rowIDs["audio"]!, currentTime: 900,
        isFinished: false, localSequence: 1, origin: .local, originKey: "client")
      try audio.insert(db)
      var ebook = MediaProgressRecord(
        accountId: accountId, itemId: rowIDs["ebook"]!, currentTime: 0,
        isFinished: false, localSequence: 1, origin: .local, originKey: "client",
        ebookProgress: 0.4)
      try ebook.insert(db)
      var outside = MediaProgressRecord(
        accountId: accountId, itemId: rowIDs["outside"]!, currentTime: 300,
        isFinished: false, localSequence: 1, origin: .local, originKey: "client")
      try outside.insert(db)
    }

    #expect(
      await TestSupport.waitUntil {
        observations.values.last?["audio"]?.currentTime == 900
          && observations.values.last?["ebook"]?.ebookProgress == 0.4
      })
    let started = try #require(observations.values.last)
    #expect(started["audio"] == ItemPlaybackProgress(currentTime: 900, isFinished: false))
    #expect(
      started["ebook"]
        == ItemPlaybackProgress(currentTime: 0, ebookProgress: 0.4, isFinished: false))
    #expect(started["outside"] == nil)

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE mediaProgress SET currentTime = 1800, isFinished = 1 WHERE itemId = ?",
        arguments: [rowIDs["audio"]!])
    }

    #expect(
      await TestSupport.waitUntil {
        observations.values.last?["audio"]
          == ItemPlaybackProgress(currentTime: 1800, isFinished: true)
      })
  }

  @Test("item playback statuses include audio and ebook progress but exclude episode rows and soft-deletes")
  func itemPlaybackStatusesFollowItemLevelProgress() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(database, serverLibraryId: "lib1")

    let observations = PersistenceObservationCollector(reading.observeItemPlaybackStatuses())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.isEmpty)

    // One finished book, one part-listened book, and a podcast show whose episode progress is
    // finished. The show itself is not finished and must never be reported as such.
    let itemRowIds = try await database.writeAsync { db -> [String: Int64] in
      var rowIds: [String: Int64] = [:]
      for serverItemId in ["finished-book", "started-book", "started-ebook", "podcast-show"] {
        var item = ItemRecord(
          accountId: accountId, libraryId: libraryRowId, serverItemId: serverItemId,
          mediaKind: "book", title: serverItemId, sortTitle: serverItemId)
        try item.insert(db)
        rowIds[serverItemId] = item.id!
      }
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: rowIds["podcast-show"]!, serverEpisodeId: "ep1",
        title: "Episode 1", lastSeenGeneration: 1)
      try episode.insert(db)

      for (serverItemId, isFinished) in [("finished-book", true), ("started-book", false)] {
        var progress = MediaProgressRecord(
          accountId: accountId, itemId: rowIds[serverItemId]!, currentTime: 120, isFinished: isFinished,
          localSequence: 1, origin: .local, originKey: "client")
        try progress.insert(db)
      }
      var ebookProgress = MediaProgressRecord(
        accountId: accountId, itemId: rowIds["started-ebook"]!, currentTime: 0,
        isFinished: false, localSequence: 1, origin: .local, originKey: "client",
        ebookProgress: 0.4)
      try ebookProgress.insert(db)
      var episodeProgress = MediaProgressRecord(
        accountId: accountId, itemId: rowIds["podcast-show"]!, podcastEpisodeId: episode.id!,
        currentTime: 600, isFinished: true, localSequence: 1, origin: .local, originKey: "client")
      try episodeProgress.insert(db)
      return rowIds
    }

    let afterFinishCount = observations.values.count
    #expect(
      await TestSupport.waitUntil {
        let values = observations.values
        return values.count > afterFinishCount
          && values.last
            == [
              "finished-book": .finished,
              "started-book": .inProgress,
              "started-ebook": .inProgress,
            ]
      })
    let afterFinish = try #require(observations.values.last)
    #expect(afterFinish["finished-book"] == .finished)
    #expect(afterFinish["started-book"] == .inProgress)
    #expect(afterFinish["started-ebook"] == .inProgress)
    #expect(afterFinish["podcast-show"] == nil)

    // Un-finishing retains a positive position as in-progress, while finishing wins over it.
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE mediaProgress SET isFinished = 0 WHERE itemId = ? AND podcastEpisodeId IS NULL",
        arguments: [itemRowIds["finished-book"]!])
      try db.execute(
        sql: "UPDATE mediaProgress SET isFinished = 1 WHERE itemId = ? AND podcastEpisodeId IS NULL",
        arguments: [itemRowIds["started-book"]!])
    }

    let afterResetCount = observations.values.count
    #expect(
      await TestSupport.waitUntil {
        let values = observations.values
        return values.count > afterResetCount
          && values.last?["finished-book"] == .inProgress
          && values.last?["started-book"] == .finished
      })
    let afterReset = try #require(observations.values.last)
    #expect(afterReset["finished-book"] == .inProgress)
    #expect(afterReset["started-book"] == .finished)

    // A removed item cannot keep reporting itself finished behind a stale row.
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE id = ?",
        arguments: [itemRowIds["started-book"]!])
    }

    let afterSoftDeleteCount = observations.values.count
    #expect(
      await TestSupport.waitUntil {
        let values = observations.values
        return values.count > afterSoftDeleteCount
          && values.last?["started-book"] == nil
          && values.last?["finished-book"] == .inProgress
      })
    let afterSoftDelete = try #require(observations.values.last)
    #expect(afterSoftDelete["started-book"] == nil)
    #expect(afterSoftDelete["finished-book"] == .inProgress)
    #expect(afterSoftDelete["started-ebook"] == .inProgress)
  }

  @Test("episode playback statuses follow episode-level progress, keyed by listening identity")
  func episodePlaybackStatusesFollowEpisodeLevelProgress() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(database, serverLibraryId: "lib1")

    let observations = PersistenceObservationCollector(reading.observeEpisodePlaybackStatuses())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    #expect(try #require(observations.values.first).isEmpty)

    let finished = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "finished-ep"))
    let started = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "started-ep"))

    // A show whose own item-level row is finished, with one finished, one started, and one
    // untouched episode. The show's status must not leak into any of them (Search would offer
    // Reset on every episode of a finished show), and theirs must not become the show's.
    let episodeRowIds = try await database.writeAsync { db -> [String: Int64] in
      var show = ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "show",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try show.insert(db)
      var showProgress = MediaProgressRecord(
        accountId: accountId, itemId: show.id!, currentTime: 0, isFinished: true,
        localSequence: 1, origin: .local, originKey: "client")
      try showProgress.insert(db)

      var rowIds: [String: Int64] = [:]
      for serverEpisodeId in ["finished-ep", "started-ep", "untouched-ep"] {
        var episode = PodcastEpisodeRecord(
          accountId: accountId, itemId: show.id!, serverEpisodeId: serverEpisodeId,
          title: serverEpisodeId, lastSeenGeneration: 1)
        try episode.insert(db)
        rowIds[serverEpisodeId] = episode.id!
      }
      var finishedProgress = MediaProgressRecord(
        accountId: accountId, itemId: show.id!, podcastEpisodeId: rowIds["finished-ep"]!,
        currentTime: 600, isFinished: true, localSequence: 2, origin: .local, originKey: "client")
      try finishedProgress.insert(db)
      var startedProgress = MediaProgressRecord(
        accountId: accountId, itemId: show.id!, podcastEpisodeId: rowIds["started-ep"]!,
        currentTime: 90, isFinished: false, localSequence: 3, origin: .local, originKey: "client")
      try startedProgress.insert(db)
      return rowIds
    }

    #expect(
      await TestSupport.waitUntil {
        observations.values.last == [finished: .finished, started: .inProgress]
      })

    // Resetting the started episode to a zero, unfinished position drops it from the projection
    // rather than reporting an explicit "not started".
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE mediaProgress SET currentTime = 0 WHERE podcastEpisodeId = ?",
        arguments: [episodeRowIds["started-ep"]!])
    }
    #expect(await TestSupport.waitUntil { observations.values.last == [finished: .finished] })

    // A soft-deleted episode cannot keep reporting itself finished behind a stale row.
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?",
        arguments: [episodeRowIds["finished-ep"]!])
    }
    #expect(await TestSupport.waitUntil { observations.values.last?.isEmpty == true })
  }

  @Test("hidden item-level progress projects as an audiobook identity")
  func continueListeningHiddenProjectsItemLevelProgress() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    let observations = PersistenceObservationCollector(reading.observeContinueListeningHidden())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let expectedIdentity = try #require(
      ListeningIdentity.audiobook(itemID: "hidden-book"))

    try await database.writeAsync { db in
      var hiddenItem = ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "hidden-book",
        mediaKind: "book", title: "Hidden Book", sortTitle: "hidden book")
      try hiddenItem.insert(db)
      var visibleItem = ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "visible-book",
        mediaKind: "book", title: "Visible Book", sortTitle: "visible book")
      try visibleItem.insert(db)

      var hiddenProgress = MediaProgressRecord(
        accountId: accountId, itemId: hiddenItem.id!, currentTime: 30, isFinished: false,
        hideFromContinueListening: true, localSequence: 1, origin: .local, originKey: "client")
      try hiddenProgress.insert(db)
      var visibleProgress = MediaProgressRecord(
        accountId: accountId, itemId: visibleItem.id!, currentTime: 30, isFinished: false,
        hideFromContinueListening: false, localSequence: 1, origin: .local, originKey: "client")
      try visibleProgress.insert(db)
    }

    #expect(
      await TestSupport.waitUntil {
        observations.values.last == [expectedIdentity]
      })
  }

  @Test("hidden episode progress projects its server episode identity, not its show")
  func continueListeningHiddenProjectsEpisodeLevelProgress() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    let observations = PersistenceObservationCollector(reading.observeContinueListeningHidden())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let expectedIdentity = try #require(
      ListeningIdentity.podcastEpisode(
        itemID: "show-1", episodeID: "episode-server-1"))
    let showIdentity = try #require(ListeningIdentity.audiobook(itemID: "show-1"))

    try await database.writeAsync { db in
      var show = ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "show-1", mediaKind: "podcast",
        title: "Show", sortTitle: "show")
      try show.insert(db)
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: show.id!, serverEpisodeId: "episode-server-1",
        title: "Episode", lastSeenGeneration: 1)
      try episode.insert(db)
      var progress = MediaProgressRecord(
        accountId: accountId, itemId: show.id!, podcastEpisodeId: episode.id!, currentTime: 30,
        isFinished: false, hideFromContinueListening: true, localSequence: 1, origin: .local,
        originKey: "client")
      try progress.insert(db)
    }

    #expect(
      await TestSupport.waitUntil {
        observations.values.last
          == [expectedIdentity]
      })
    let hidden = try #require(observations.values.last)
    #expect(hidden.contains(showIdentity) == false)
  }

  @Test("a dismissed native-feed episode projects its device-owned RSS episode identity")
  func continueListeningHiddenProjectsRSSEpisodeState() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let observations = PersistenceObservationCollector(reading.observeContinueListeningHidden())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })

    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/hidden-native.xml")!, title: "Native Feed",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: ["hidden-guid", "visible-guid"].map { key in
        RSSEpisodeUpsert(
          identityKey: key, title: key,
          enclosureURL: URL(string: "https://example.com/\(key).mp3")!,
          publishedAt: Date(timeIntervalSince1970: 1_650_000_000), durationSeconds: 600)
      })
    try await database.writeAsync { db in
      for (key, isHidden) in [("hidden-guid", true), ("visible-guid", false)] {
        let episodeId = try #require(
          try Int64.fetchOne(
            db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
            arguments: [feedId, key]))
        try RSSEpisodeStateRecord(
          episodeId: episodeId, position: 30, finished: false,
          hideFromContinueListening: isHidden, localSequence: 1, updatedAt: Date()
        ).insert(db)
      }
    }

    let expectedIdentity = try #require(
      ListeningIdentity.rssEpisode(feedID: feedId, episodeID: "hidden-guid"))
    #expect(
      await TestSupport.waitUntil {
        observations.values.last == [expectedIdentity]
      })
  }

  @Test("hidden progress excludes soft-deleted items and episodes and excluded libraries")
  func continueListeningHiddenRespectsVisibilityFilters() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let (accountId, libraryRowIds) = try await Self.seedAccountAndLibraries(
      database, serverLibraryIds: ["included", "excluded"])
    let includedLibraryID = libraryRowIds[0]
    let excludedLibraryID = libraryRowIds[1]
    let observations = PersistenceObservationCollector(reading.observeContinueListeningHidden())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let validIdentity = try #require(ListeningIdentity.audiobook(itemID: "valid-book"))
    let sentinelIdentity = try #require(
      ListeningIdentity.audiobook(itemID: "sentinel-book"))

    let validItemID = try await database.writeAsync { db -> Int64 in
      var item = ItemRecord(
        accountId: accountId, libraryId: includedLibraryID, serverItemId: "valid-book",
        mediaKind: "book", title: "Valid", sortTitle: "valid")
      try item.insert(db)
      var progress = MediaProgressRecord(
        accountId: accountId, itemId: item.id!, currentTime: 30, isFinished: false,
        hideFromContinueListening: true, localSequence: 1, origin: .local, originKey: "client")
      try progress.insert(db)
      return item.id!
    }
    #expect(
      await TestSupport.waitUntil {
        observations.values.last == [validIdentity]
      })

    try await database.writeAsync { db in
      var deletedItem = ItemRecord(
        accountId: accountId, libraryId: includedLibraryID, serverItemId: "deleted-book",
        mediaKind: "book", title: "Deleted", sortTitle: "deleted", softDeleted: true)
      try deletedItem.insert(db)
      var deletedItemProgress = MediaProgressRecord(
        accountId: accountId, itemId: deletedItem.id!, currentTime: 30, isFinished: false,
        hideFromContinueListening: true, localSequence: 1, origin: .local, originKey: "client")
      try deletedItemProgress.insert(db)

      var deletedEpisodeShow = ItemRecord(
        accountId: accountId, libraryId: includedLibraryID, serverItemId: "deleted-episode-show",
        mediaKind: "podcast", title: "Deleted Episode Show", sortTitle: "deleted episode show")
      try deletedEpisodeShow.insert(db)
      var deletedEpisode = PodcastEpisodeRecord(
        accountId: accountId, itemId: deletedEpisodeShow.id!, serverEpisodeId: "deleted-episode",
        title: "Deleted Episode", lastSeenGeneration: 1, softDeleted: true)
      try deletedEpisode.insert(db)
      var deletedEpisodeProgress = MediaProgressRecord(
        accountId: accountId, itemId: deletedEpisodeShow.id!, podcastEpisodeId: deletedEpisode.id!,
        currentTime: 30, isFinished: false, hideFromContinueListening: true, localSequence: 1,
        origin: .local, originKey: "client")
      try deletedEpisodeProgress.insert(db)

      var excludedItem = ItemRecord(
        accountId: accountId, libraryId: excludedLibraryID, serverItemId: "excluded-book",
        mediaKind: "book", title: "Excluded", sortTitle: "excluded")
      try excludedItem.insert(db)
      var excludedProgress = MediaProgressRecord(
        accountId: accountId, itemId: excludedItem.id!, currentTime: 30, isFinished: false,
        hideFromContinueListening: true, localSequence: 1, origin: .local, originKey: "client")
      try excludedProgress.insert(db)
      try db.execute(
        sql: "UPDATE library SET isIncluded = 0 WHERE id = ?", arguments: [excludedLibraryID])

      // A sentinel written in the same transaction as the three rows that must not project. Without
      // it the assertion below would pass on the previous emission, before the observation had
      // seen this write at all, and prove nothing about the exclusions.
      var sentinel = ItemRecord(
        accountId: accountId, libraryId: includedLibraryID, serverItemId: "sentinel-book",
        mediaKind: "book", title: "Sentinel", sortTitle: "sentinel")
      try sentinel.insert(db)
      var sentinelProgress = MediaProgressRecord(
        accountId: accountId, itemId: sentinel.id!, currentTime: 30, isFinished: false,
        hideFromContinueListening: true, localSequence: 1, origin: .local, originKey: "client")
      try sentinelProgress.insert(db)
    }

    #expect(
      await TestSupport.waitUntil {
        observations.values.last
          == [validIdentity, sentinelIdentity]
      })

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [validItemID])
    }
    #expect(
      await TestSupport.waitUntil {
        observations.values.last == [sentinelIdentity]
      })
  }
}
