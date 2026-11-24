import ABSApi
import Foundation
import Testing

@testable import Persistence
@testable import SyncEngine

extension NativeEpisodeServerSaveCoordinatorTests {
  @Test func pruningSourceAfterCreateDoesNotChangeTheCapturedEnqueue() async throws {
    let fixture = try await SaveFixture.make()
    try await insertPrunableSourceRows(in: fixture.database)
    let gate = BlockingGate()
    let writer = StubPodcastWriter(trace: fixture.trace, createGate: gate)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.create(pruningDestination())),
      writer: writer,
      detail: StubItemDetailReader(.success(pruningCompleteItem(id: "created-show"))))

    let saveTask = Task {
      await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    }
    await gate.waitUntilEntered()
    try await fixture.database.writeAsync { db in
      try db.execute(
        sql: "DELETE FROM rssEpisode WHERE id = ?",
        arguments: [fixture.command.episodeId])
    }
    await fixture.commandReader.setError(.episodeNotFound)
    await gate.release()

    let result = await saveTask.value
    #expect(result == .accepted(attemptID: 1, serverItemID: "created-show"))
    #expect(await writer.counts() == (1, 1))
    #expect(
      await writer.recordedEpisode()?.enclosureURL == fixture.command.enclosureURL.absoluteString)

    let record = try #require(try await fixture.baseStore.fetchAttemptAsync(id: 1))
    #expect(record.state == .accepted)
    #expect(record.accountId == fixture.accountID)
    #expect(record.accountClientUUID == fixture.account.clientUUID)
    #expect(record.accountServerIdentityFingerprint == fixture.account.serverIdentityFingerprint)
  }

  @Test func pruningDuringThePostCreateDetailReadStillRecordsTheFailure() async throws {
    let fixture = try await SaveFixture.make()
    try await insertPrunableSourceRows(in: fixture.database)
    let writer = StubPodcastWriter(trace: fixture.trace)
    let detail = StubItemDetailReader(
      .failure(.notFound),
      beforeReturn: {
        try? await fixture.database.writeAsync { db in
          try db.execute(
            sql: "DELETE FROM rssEpisode WHERE id = ?",
            arguments: [fixture.command.episodeId])
        }
        await fixture.commandReader.setError(.episodeNotFound)
      })
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.create(pruningDestination())),
      writer: writer,
      detail: detail)

    let result = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    // The create was sent, so the failure is recorded under the account fence alone; a source
    // re-read cannot veto it and leave the row stuck in `.creatingShow`.
    #expect(result == .failed(attemptID: 1, state: .failed, category: .staleIdentity))
    #expect(await writer.counts() == (1, 0))
    let record = try #require(try await fixture.baseStore.fetchAttemptAsync(id: 1))
    #expect(record.state == .failed)
    #expect(record.serverItemId == "created-show")
    #expect(record.errorCategory == .staleIdentity)
  }

  @Test func saveAfterPruningSourceFailsClosedWithoutARepeatSend() async throws {
    let fixture = try await SaveFixture.make()
    try await insertPrunableSourceRows(in: fixture.database)
    try await fixture.database.writeAsync { db in
      try db.execute(
        sql: "DELETE FROM rssEpisode WHERE id = ?",
        arguments: [fixture.command.episodeId])
    }
    await fixture.commandReader.setError(.episodeNotFound)
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(pruningCompleteItem())))

    let result = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .failed(attemptID: nil, state: .failed, category: .missingEpisode))
    #expect(await writer.counts() == (0, 0))
    #expect(
      try fixture.baseStore.fetchAttempts(
        accountId: fixture.accountID,
        feedId: fixture.command.feedId,
        episodeId: fixture.command.episodeId
      ).isEmpty)
  }
}

private func insertPrunableSourceRows(in database: AppDatabase) async throws {
  try await database.writeAsync { db in
    var feed = RSSFeedRecord(
      id: 1,
      feedURL: "https://feeds.example/prunable.xml",
      title: "Native Show",
      subscribedAt: Date(),
      refreshGeneration: 1)
    try feed.insert(db)
    var episode = RSSEpisodeRecord(
      id: 2,
      feedId: 1,
      identityKey: "guid:episode-guid",
      guid: "episode-guid",
      title: "Native Episode",
      enclosureURL: "https://media.example/episode.mp3",
      lastSeenGeneration: 1)
    try episode.insert(db)
  }
}

private func pruningDestination() -> ServerPodcastDestination {
  ServerPodcastDestination(
    libraryID: "podcasts",
    folder: LibraryFolder(id: "folder", fullPath: "/srv/podcasts", libraryID: "podcasts"),
    nativeFeedTitle: "Native Show")!
}

private func pruningCompleteItem(id: String = "show") -> ItemDetail {
  ItemDetail(
    id: id,
    libraryID: "podcasts",
    mediaType: "podcast",
    media: .podcast(
      PodcastMedia(
        title: "Native Show",
        author: "Native Author",
        description: "Native Synopsis",
        episodes: [],
        isEpisodeListStructurallyComplete: true)))
}
