import ABSApi
import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite(.timeLimit(.minutes(1))) struct NativeEpisodeServerSaveRecoveryTests {
  @Test func createUncertainResolvesShowPersistsIDAndNeverCreatesAgain() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedCreateUncertain()
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "recovered-show")), writer: writer)

    let result = await coordinator.recover(attemptID: attemptID)

    #expect(result == .accepted(attemptID: attemptID, serverItemID: "recovered-show"))
    #expect((writer.createCount, writer.enqueueCount) == (0, 1))
    let record = try #require(try await fixture.store.fetchAttemptAsync(id: attemptID))
    #expect(record.serverItemId == "recovered-show")
    #expect(record.state == .accepted)
  }

  @Test func createUncertainWithoutShowReturnsToPreparingWithoutSending() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedCreateUncertain()
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.needsChoice), writer: writer)

    let result = await coordinator.recover(attemptID: attemptID)

    #expect(result == .inProgress(attemptID: attemptID, state: .preparing, serverItemID: nil))
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .preparing)
  }

  @Test(arguments: [
    APIError.transport,
    APIError.serverFailure(statusCode: 500),
    APIError.forbidden,
    APIError.notFound,
  ])
  func createUncertainResolutionFailureStaysUncertainWithoutSending(
    _ error: APIError
  ) async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedCreateUncertain()
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.failure(error)), writer: writer)

    let result = await coordinator.recover(attemptID: attemptID)

    #expect(result.state == .createUncertain)
    #expect(result.errorCategory == NativeEpisodeServerSaveSupport.apiCategory(error))
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .createUncertain)
  }

  @Test func uncertainRecoveryConfirmsAndDoesNotSend() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedUncertain()
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")),
      writer: writer,
      detail: FakeNativeEpisodeServerSaveItemDetailReading(item(episodeID: "confirmed-id")))

    let result = await coordinator.recover(attemptID: attemptID)

    #expect(result.state == .confirmed)
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .confirmed)
  }

  @Test func uncertainRetryRequiresAbsenceAndEnqueuesExactlyOnce() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedUncertain()
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")), writer: writer)

    let result = await coordinator.retry(attemptID: attemptID)

    #expect(result == .accepted(attemptID: attemptID, serverItemID: "show"))
    #expect((writer.createCount, writer.enqueueCount) == (0, 1))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .accepted)
  }

  @Test func incompleteListRefusesRetryAndNeverSends() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedUncertain()
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")),
      writer: writer,
      detail: FakeNativeEpisodeServerSaveItemDetailReading(incompleteItem()))

    let result = await coordinator.retry(attemptID: attemptID)

    #expect(
      result
        == .uncertain(
          attemptID: attemptID, state: .uncertain, category: .incompleteEpisodeList))
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .uncertain)
  }

  /// The retry's absence check is what authorises a second enqueue. A list that lost an episode
  /// in decoding cannot rule out that the first request landed: the lost element may be it.
  @Test func listThatLostAnEpisodeInDecodingRefusesRetryAndNeverSends() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedUncertain()
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")),
      writer: writer,
      detail: makeLossyDetailReader(item()))

    let result = await coordinator.retry(attemptID: attemptID)

    #expect(
      result
        == .uncertain(
          attemptID: attemptID, state: .uncertain, category: .incompleteEpisodeList))
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .uncertain)
  }

  @Test func duplicateEpisodeIDsRefuseRetryAndNeverSend() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedUncertain()
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")),
      writer: writer,
      detail: FakeNativeEpisodeServerSaveItemDetailReading(duplicateEpisodeIDItem()))

    let result = await coordinator.retry(attemptID: attemptID)

    #expect(
      result
        == .uncertain(
          attemptID: attemptID, state: .uncertain, category: .incompleteEpisodeList))
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .uncertain)
  }

  @Test(arguments: [
    (APIError.transport, NativeEpisodeServerSaveErrorCategory.transport),
    (APIError.serverFailure(statusCode: 500), NativeEpisodeServerSaveErrorCategory.serverFailure),
    (APIError.forbidden, NativeEpisodeServerSaveErrorCategory.permissionChanged),
    (APIError.notFound, NativeEpisodeServerSaveErrorCategory.staleIdentity),
  ])
  func inconclusiveReadRefusesRetryAndNeverSends(
    error: APIError,
    category: NativeEpisodeServerSaveErrorCategory
  ) async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedUncertain()
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")),
      writer: writer,
      detail: FakeNativeEpisodeServerSaveItemDetailReading(plans: [.failure(error)]))

    let result = await coordinator.retry(attemptID: attemptID)

    #expect(result == .uncertain(attemptID: attemptID, state: .uncertain, category: category))
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .uncertain)
  }

  @Test func retryBeforeConfirmedAbsenceRefusesEveryNonAbsentState() async throws {
    for state in [
      NativeEpisodeServerSaveAttemptState.preparing,
      .createUncertain, .accepted, .confirmed,
    ] {
      let fixture = try await RecoveryFixture.make()
      let attemptID = try await fixture.seed(state)
      let writer = makeRecoveryWriter()
      let coordinator = fixture.coordinator(
        destination: RecoveryDestination(.reuse(serverItemID: "show")), writer: writer)

      let result = await coordinator.retry(attemptID: attemptID)

      #expect(result.state == state)
      #expect((writer.createCount, writer.enqueueCount) == (0, 0))
      #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == state)
    }
  }

  @Test func retryWaitsForAnActiveSaveFlightAndDoesNotDoubleSend() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seed(.preparing)
    let writer = makeHeldEnqueueWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")), writer: writer)

    let saveTask = Task {
      await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    }
    await writer.enqueueGate.waitUntilParked(count: 1)
    let retryTask = Task { await coordinator.retry(attemptID: attemptID) }
    writer.enqueueGate.release()

    let saveResult = await saveTask.value
    let retryResult = await retryTask.value

    #expect(saveResult == .accepted(attemptID: attemptID, serverItemID: "show"))
    #expect(retryResult.state == .accepted)
    #expect((writer.createCount, writer.enqueueCount) == (0, 1))
  }

  @Test func recoveryWorksWithOnlyTheDurableRowAndNoPriorFlight() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedUncertain()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")),
      writer: makeRecoveryWriter(),
      detail: FakeNativeEpisodeServerSaveItemDetailReading(item(episodeID: "relaunch-id")))

    let result = await coordinator.recover(attemptID: attemptID)

    #expect(result.state == .confirmed)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.serverEpisodeId == "relaunch-id")
  }

  @Test func accountReplacementStopsRecoveryBeforeAnyWrite() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedUncertain()
    fixture.accountReader.stubAccount(fixture.replacementAccount())
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")),
      writer: writer,
      detail: FakeNativeEpisodeServerSaveItemDetailReading(item(episodeID: "blocked-id")))

    let result = await coordinator.recover(attemptID: attemptID)

    #expect(
      result
        == .uncertain(
          attemptID: attemptID, state: .uncertain, category: .accountReplaced))
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .uncertain)
  }

  @Test func interruptedCreateIsCheckpointedAndResumedWithoutCreatingAgain() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seed(.creatingShow)
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "recovered-show")), writer: writer)

    let result = await coordinator.recover(attemptID: attemptID)

    #expect(result == .accepted(attemptID: attemptID, serverItemID: "recovered-show"))
    #expect((writer.createCount, writer.enqueueCount) == (0, 1))
    let record = try #require(try await fixture.store.fetchAttemptAsync(id: attemptID))
    #expect(record.state == .accepted)
    #expect(record.serverItemId == "recovered-show")
  }

  @Test func interruptedCreateWithoutAShowLandsInPreparingWithoutSending() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seed(.creatingShow)
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.needsChoice), writer: writer)

    let result = await coordinator.recover(attemptID: attemptID)

    #expect(result == .inProgress(attemptID: attemptID, state: .preparing, serverItemID: nil))
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .preparing)
  }

  @Test func interruptedEnqueueIsCheckpointedAsUncertainAndReconciledWithoutSending() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seed(.requestingDownload)
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")), writer: writer,
      detail: FakeNativeEpisodeServerSaveItemDetailReading(item(episodeID: "server-episode")))

    let result = await coordinator.recover(attemptID: attemptID)

    #expect(result == .inProgress(attemptID: attemptID, state: .confirmed, serverItemID: "show"))
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
    let record = try #require(try await fixture.store.fetchAttemptAsync(id: attemptID))
    #expect(record.state == .confirmed)
    #expect(record.serverEpisodeId == "server-episode")
  }

  @Test func interruptedEnqueueWithoutAMatchStaysUncertainAndNeverResends() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seed(.requestingDownload)
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")), writer: writer,
      detail: FakeNativeEpisodeServerSaveItemDetailReading(item()))

    let result = await coordinator.recover(attemptID: attemptID)

    #expect(result.state == .uncertain)
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .uncertain)
  }

  @Test func acceptedRecoveryReconcilesAndNeverRetries() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    let writer = makeRecoveryWriter()
    let absent = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")), writer: writer,
      detail: FakeNativeEpisodeServerSaveItemDetailReading(item()))

    let stillAccepted = await absent.recover(attemptID: attemptID)
    #expect(stillAccepted == .accepted(attemptID: attemptID, serverItemID: "show"))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .accepted)

    let landed = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")), writer: writer,
      detail: FakeNativeEpisodeServerSaveItemDetailReading(item(episodeID: "server-episode")))
    let confirmed = await landed.recover(attemptID: attemptID)
    #expect(confirmed == .inProgress(attemptID: attemptID, state: .confirmed, serverItemID: "show"))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .confirmed)
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
  }

  @Test func pendingRecoveryVisitsOnlyTheAccountsUnsettledRowsForTheFeed() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    let writer = makeRecoveryWriter()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.reuse(serverItemID: "show")), writer: writer,
      detail: FakeNativeEpisodeServerSaveItemDetailReading(item(episodeID: "server-episode")))

    #expect(await coordinator.recoverPendingAttempts(feedId: 99).isEmpty)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .accepted)

    #expect(await coordinator.recoverPendingAttempts(feedId: fixture.command.feedId) == [attemptID])
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .confirmed)

    // Confirmed rows are settled and are not visited again.
    #expect(await coordinator.recoverPendingAttempts(feedId: nil).isEmpty)
    #expect((writer.createCount, writer.enqueueCount) == (0, 0))
  }

  @Test func recoveryAndRetryDiagnosticsContainNoSensitiveLocatorValues() async throws {
    let fixture = try await RecoveryFixture.make()
    let attemptID = try await fixture.seedUncertain()
    let coordinator = fixture.coordinator(
      destination: RecoveryDestination(.failure(.transport)), writer: makeRecoveryWriter())

    let result = await coordinator.retry(attemptID: attemptID)
    let diagnostics = result.description + String(reflecting: result)

    #expect(diagnostics.contains("https://") == false)
    #expect(diagnostics.contains("/api/") == false)
    #expect(diagnostics.contains("secret") == false)
    #expect(diagnostics.contains("episode.mp3") == false)
  }
}

private struct RecoveryFixture: Sendable {
  let database: AppDatabase
  let accountID: Int64
  let command: NativeEpisodeServerSaveCommand
  let accountReader: FakeNativeEpisodeServerSaveAccountReading
  let commandReader: RecoveryCommandReader
  let subscriptions: FakeNativePodcastSubscriptionsReading
  let store: NativeEpisodeServerSaveAttemptStore

  static func make() async throws -> Self {
    let database = try AppDatabase.inMemory()
    let accountID = try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "recovery-client",
        serverBaseURL: "https://server.example",
        serverUserId: "server-user",
        serverVersion: "2.35.1")
      try account.insert(db)
      return try #require(account.id)
    }
    let record = try await database.readAsync { db in
      try #require(try AccountRecord.fetchOne(db, key: accountID))
    }
    let account = NativeEpisodeServerSaveAccount(
      accountID: accountID,
      clientUUID: record.clientUUID,
      serverIdentityFingerprint:
        record.serverIdentityFingerprint,
      tokenAccount: try record.credentialTokenAccount)
    return Self(
      database: database,
      accountID: accountID,
      command: makeCommand(),
      accountReader: FakeNativeEpisodeServerSaveAccountReading(account),
      commandReader: RecoveryCommandReader(makeCommand()),
      subscriptions: makeRecoverySubscriptions(),
      store: NativeEpisodeServerSaveAttemptStore(database: database))
  }

  func replacementAccount() -> NativeEpisodeServerSaveAccount {
    NativeEpisodeServerSaveAccount(
      accountID: accountID,
      clientUUID: "replacement-client",
      serverIdentityFingerprint: (try? database.read { db in
        try AccountRecord.fetchOne(db, key: accountID).map {
          $0.serverIdentityFingerprint
        }
      }) ?? "",
      tokenAccount: try! TokenAccount(
        credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: "replacement-client"),
        userID: "server-user"))
  }

  func seed(_ state: NativeEpisodeServerSaveAttemptState) async throws -> Int64 {
    let attempt = try await store.beginAttemptAsync(
      accountId: accountID, feedId: command.feedId, episodeId: command.episodeId,
      episodeIdentityKey: command.episodeIdentityKey)
    let id = try #require(attempt.id)
    if state == .createUncertain || state == .creatingShow {
      _ = try await store.recordPreflightPresenceAsync(.absentBeforeRequest, attemptId: id)
    } else if state != .preparing {
      _ = try await store.recordServerItemIDAsync("show", attemptId: id)
      _ = try await store.recordPreflightPresenceAsync(.absentBeforeRequest, attemptId: id)
    }
    switch state {
    case .preparing:
      break
    case .creatingShow:
      _ = try await store.transitionAsync(
        attemptId: id, to: .creatingShow, serverItemId: nil, errorCategory: nil)
    case .requestingDownload:
      _ = try await store.transitionAsync(
        attemptId: id, to: .requestingDownload, serverItemId: "show", errorCategory: nil)
    case .createUncertain:
      _ = try await store.transitionAsync(
        attemptId: id, to: .creatingShow, serverItemId: nil, errorCategory: nil)
      _ = try await store.transitionAsync(
        attemptId: id, to: .createUncertain, serverItemId: nil, errorCategory: .malformedResponse)
    case .uncertain:
      _ = try await store.transitionAsync(
        attemptId: id, to: .requestingDownload, serverItemId: "show", errorCategory: nil)
      _ = try await store.transitionAsync(
        attemptId: id, to: .accepted, serverItemId: "show", errorCategory: nil)
      _ = try await store.transitionAsync(
        attemptId: id, to: .uncertain, serverItemId: "show", errorCategory: .transport)
    case .accepted:
      _ = try await store.transitionAsync(
        attemptId: id, to: .requestingDownload, serverItemId: "show", errorCategory: nil)
      _ = try await store.transitionAsync(
        attemptId: id, to: .accepted, serverItemId: "show", errorCategory: nil)
    case .confirmed:
      _ = try await store.transitionAsync(
        attemptId: id, to: .requestingDownload, serverItemId: "show", errorCategory: nil)
      _ = try await store.transitionAsync(
        attemptId: id, to: .accepted, serverItemId: "show", errorCategory: nil)
      _ = try await store.transitionAsync(
        attemptId: id, to: .confirmed, serverItemId: "show", serverEpisodeId: "confirmed-id",
        errorCategory: nil)
    default:
      throw RecoveryTestError.unsupportedSeed
    }
    return id
  }

  func seedCreateUncertain() async throws -> Int64 { try await seed(.createUncertain) }
  func seedUncertain() async throws -> Int64 { try await seed(.uncertain) }

  func coordinator(
    destination: any NativeEpisodeServerSaveDestinationResolving,
    writer: any NativeEpisodeServerSavePodcastWriting,
    detail: any NativeEpisodeServerSaveItemDetailReading =
      FakeNativeEpisodeServerSaveItemDetailReading(item())
  ) -> NativeEpisodeServerSaveCoordinator {
    NativeEpisodeServerSaveCoordinator(
      accountReader: accountReader,
      capabilityReader: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: false),
      commandReader: commandReader,
      destinationResolver: destination,
      podcastWriter: writer,
      itemDetailReader: detail,
      attemptStore: store,
      nativeSubscriptions: subscriptions,
      foregroundConvergenceDelays: [])
  }
}

private enum RecoveryTestError: Error { case unsupportedSeed }

private enum DestinationPlan: Sendable {
  case reuse(serverItemID: String)
  case needsChoice
  case failure(APIError)
}

private actor RecoveryDestination: NativeEpisodeServerSaveDestinationResolving {
  private let plan: DestinationPlan

  init(_ plan: DestinationPlan) { self.plan = plan }

  func resolveNativeEpisodeServerSaveDestination(
    feedURL: URL,
    nativeFeedTitle: String,
    account: TokenAccount,
    choice: ServerPodcastSaveChoice?
  ) async throws -> NativeEpisodeServerSaveDestinationResolution {
    switch plan {
    case .reuse(let id): return .reuse(serverItemID: id)
    case .needsChoice: return .needsChoice(.libraryAndFolder(libraries: []))
    case .failure(let error): throw error
    }
  }
}

private actor RecoveryCommandReader: NativeEpisodeServerSaveCommandReading {
  private let value: NativeEpisodeServerSaveCommand

  init(_ value: NativeEpisodeServerSaveCommand) { self.value = value }
  func read(feedId: Int64, episodeId: Int64) async throws -> NativeEpisodeServerSaveCommand { value }
}

private func makeCommand() -> NativeEpisodeServerSaveCommand {
  NativeEpisodeServerSaveCommand(
    feedId: 1,
    episodeId: 2,
    episodeIdentityKey: "guid:episode-guid",
    feedTitle: "Native Show",
    feedAuthor: "Native Author",
    feedSynopsis: "Native Synopsis",
    episodeGUID: "episode-guid",
    episodeTitle: "Native Episode",
    episodeSynopsis: "Episode Synopsis",
    enclosureType: "audio/mpeg",
    declaredBytes: 42,
    durationSeconds: 12.5,
    seasonNumber: 2,
    episodeNumber: 3,
    publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
    feedURL: URL(string: "https://feeds.example/feed.xml")!,
    enclosureURL: URL(string: "https://media.example/episode.mp3")!)
}

private func episode(episodeID: String = "server-episode") -> PodcastEpisode {
  PodcastEpisode(
    id: episodeID,
    title: "Unrelated title",
    guid: "episode-guid",
    enclosureURL: nil,
    contentUrl: "/api/items/show/episodes/\(episodeID)",
    mimeType: "audio/mpeg",
    duration: nil,
    publishedAt: nil)
}

private func item(episodeID: String? = nil) -> ItemDetail {
  ItemDetail(
    id: "show",
    libraryID: "podcasts",
    mediaType: "podcast",
    media: .podcast(
      PodcastMedia(
        title: "Native Show",
        author: "Native Author",
        description: "Native Synopsis",
        episodes: episodeID.map { [episode(episodeID: $0)] } ?? [],
        isEpisodeListStructurallyComplete: true)))
}

private func incompleteItem() -> ItemDetail {
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

/// A writer that creates and enqueues like the shared default. A removal reaching it fails as an
/// unavailable writer would.
private func makeRecoveryWriter() -> FakeNativeEpisodeServerSavePodcastWriting {
  let writer = FakeNativeEpisodeServerSavePodcastWriting()
  writer.stubRemove(.failure(RemovalUnsupportedByWriter()))
  return writer
}

/// A writer whose enqueue parks until `enqueueGate` is released.
private func makeHeldEnqueueWriter() -> FakeNativeEpisodeServerSavePodcastWriting {
  let writer = makeRecoveryWriter()
  writer.enqueueGate.hold()
  return writer
}

/// A reader whose every read answers `detail` and records a dropped episode into the caller's
/// diagnostics: the detail already lacks it, and only the diagnostics show the drop.
private func makeLossyDetailReader(
  _ detail: ItemDetail
) -> FakeNativeEpisodeServerSaveItemDetailReading {
  let reader = FakeNativeEpisodeServerSaveItemDetailReading(detail)
  reader.stubBeforeReturn { _, diagnostics in recordDroppedEpisode(into: diagnostics) }
  return reader
}

/// Subscriptions that are enabled and whose observation finishes without a value.
private func makeRecoverySubscriptions() -> FakeNativePodcastSubscriptionsReading {
  let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
  subscriptions.finishObservations()
  return subscriptions
}
