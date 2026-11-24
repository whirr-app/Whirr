import ABSApi
import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite(.timeLimit(.minutes(1))) struct NativeEpisodeServerSaveReconcilerTests {
  @Test func guidMatchConfirmsAndPersistsExactEpisodeID() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubDetail(item(episode(id: "exact-id", guid: "episode-guid")))

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .confirmed(
          attemptID: attemptID, state: .confirmed, serverEpisodeID: "exact-id"))
    let record = try #require(try await fixture.store.fetchAttemptAsync(id: attemptID))
    #expect(record.state == .confirmed)
    #expect(record.serverEpisodeId == "exact-id")
  }

  @Test func duplicateGUIDCandidatesRemainAbsentDuringRecovery() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    let detail = ItemDetail(
      id: "show", libraryID: "podcasts", mediaType: "podcast",
      media: .podcast(
        PodcastMedia(
          title: "Native Show", author: "Native Author", description: "Native Synopsis",
          episodes: [
            episode(id: "duplicate-a", guid: "episode-guid"),
            episode(id: "duplicate-b", guid: "episode-guid"),
          ], isEpisodeListStructurallyComplete: true)))
    fixture.details.stubDetail(detail)

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(result == .absent(attemptID: attemptID, state: .accepted))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.serverEpisodeId == nil)
  }

  @Test func enclosureURLFallbackConfirmsWhenSourceGUIDIsAbsent() async throws {
    let fixture = try await ReconcileFixture.make(command: makeCommand(guid: nil))
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubDetail(
      item(
        episode(
          id: "url-id", guid: "server-guid", enclosureURL: "HTTPS://MEDIA.EXAMPLE:443/episode.mp3/")))

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .confirmed(
          attemptID: attemptID, state: .confirmed, serverEpisodeID: "url-id"))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.serverEpisodeId == "url-id")
    // The hashed identity cannot be expanded from the server list; the RSS row supplied the URL.
    #expect(await fixture.commandReader.readCount() == 1)
  }

  @Test func hashedIdentityWithPrunedSourceIsInconclusiveNeverAbsent() async throws {
    let fixture = try await ReconcileFixture.make(command: makeCommand(guid: nil))
    let attemptID = try await fixture.seed(.accepted)
    await fixture.commandReader.setError(.episodeNotFound)
    fixture.details.stubDetail(
      item(
        episode(
          id: "url-id", guid: "server-guid", enclosureURL: "https://media.example/episode.mp3")))

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .inconclusive(attemptID: attemptID, state: .accepted, category: .missingEpisode))
    let record = try #require(try await fixture.store.fetchAttemptAsync(id: attemptID))
    #expect(record.state == .accepted)
    #expect(record.serverEpisodeId == nil)
  }

  @Test func hashedIdentityUncertainWithPrunedSourceRefusesRetry() async throws {
    let fixture = try await ReconcileFixture.make(command: makeCommand(guid: nil))
    let attemptID = try await fixture.seed(.uncertain)
    await fixture.commandReader.setError(.episodeNotFound)
    let writer = makeReconcileWriter()
    fixture.details.stubDetail(item(episode(id: "other", guid: "other-guid")))

    let result = await fixture.makeCoordinator(writer: writer).retry(attemptID: attemptID)

    #expect(result.state == .uncertain)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .uncertain)
  }

  @Test func nullGUIDRowNeverMatches() async throws {
    let fixture = try await ReconcileFixture.make(command: makeCommand(guid: nil))
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubDetail(
      item(
        episode(
          id: "null-guid", guid: nil, enclosureURL: "https://media.example/episode.mp3")))

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(result == .absent(attemptID: attemptID, state: .accepted))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .accepted)
  }

  @Test func titleAndContentURLNeverConfirm() async throws {
    let fixture = try await ReconcileFixture.make(command: makeCommand(guid: nil))
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubDetail(
      item(
        episode(
          id: "wrong-identity", guid: "other-guid", title: "Native Episode",
          enclosureURL: nil, contentURL: "https://media.example/episode.mp3")))

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(result == .absent(attemptID: attemptID, state: .accepted))
  }

  @Test func changedServerShowIDIsInconclusiveAndCannotPersistAnEpisodeID() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubDetail(item(id: "show-b", episode: episode(id: "wrong-show-id")))

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .inconclusive(
          attemptID: attemptID, state: .accepted, category: .staleIdentity))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.serverEpisodeId == nil)
  }

  @Test func missingPersistedServerShowIsNotRetriedUnderAnotherShowID() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubPlans([
      .failure(APIError.notFound),
      .success(item(id: "show-b", episode: episode(id: "wrong-show-id"))),
    ])

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .inconclusive(
          attemptID: attemptID, state: .accepted, category: .staleIdentity))
    #expect(fixture.details.callCount == 1)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.serverEpisodeId == nil)
  }

  @Test func prunedSourceConfirmsFromDurableIdentityWithoutReadingRSSAgain() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    await fixture.commandReader.setError(.episodeNotFound)
    fixture.details.stubDetail(item(episode: episode(id: "durable-episode-id")))

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .confirmed(
          attemptID: attemptID, state: .confirmed, serverEpisodeID: "durable-episode-id"))
    #expect(await fixture.commandReader.readCount() == 0)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .confirmed)
  }

  @Test func completeListWithoutMatchReportsAbsenceAndKeepsAccepted() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubDetail(item(episode(id: "other-id", guid: "other-guid")))

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(result == .absent(attemptID: attemptID, state: .accepted))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .accepted)
  }

  @Test func incompleteListIsInconclusiveAndNeverAbsence() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubDetail(incompleteItem())

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .inconclusive(
          attemptID: attemptID, state: .accepted, category: .incompleteEpisodeList))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .accepted)
  }

  @Test func incompleteListPreservesUncertain() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.uncertain)
    fixture.details.stubDetail(incompleteItem())

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .inconclusive(
          attemptID: attemptID, state: .uncertain, category: .incompleteEpisodeList))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .uncertain)
  }

  /// An absence result authorises an explicit resend, so a list that lost an episode in decoding
  /// must not produce one: the lost element may be this very episode.
  /// A match proves presence even when another element was dropped in decoding, so an accepted
  /// attempt on a show with one malformed element can still confirm.
  @Test func matchInAListThatLostAnotherEpisodeStillConfirms() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubLossy(item(episode(id: "exact-id", guid: "episode-guid")))

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .confirmed(
          attemptID: attemptID, state: .confirmed, serverEpisodeID: "exact-id"))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .confirmed)
  }

  @Test func listThatLostAnEpisodeInDecodingIsInconclusiveAndNeverAbsence() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubLossy(item(episode(id: "other-id", guid: "other-guid")))

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .inconclusive(
          attemptID: attemptID, state: .accepted, category: .incompleteEpisodeList))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .accepted)
  }

  @Test func duplicateEpisodeIDsAreInconclusiveAndNeverAbsence() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.uncertain)
    fixture.details.stubDetail(duplicateEpisodeIDItem())

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .inconclusive(
          attemptID: attemptID, state: .uncertain, category: .incompleteEpisodeList))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .uncertain)
  }

  /// A batch's shared read is judged by the diagnostics it was decoded with, not trusted because
  /// it was fetched elsewhere.
  @Test func sharedReadThatLostAnEpisodeIsInconclusiveWithoutAnotherRead() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    let diagnostics = DecodeDiagnostics()
    recordDroppedEpisode(into: diagnostics)
    let shared = NativeEpisodeServerSaveCoordinator.ItemDetailRead(
      detail: item(episode(id: "other-id", guid: "other-guid")), diagnostics: diagnostics)

    let result = await fixture.coordinator.reconcile(attemptID: attemptID, sharedDetail: shared)

    #expect(
      result
        == .inconclusive(
          attemptID: attemptID, state: .accepted, category: .incompleteEpisodeList))
    #expect(fixture.details.callCount == 0)
  }

  @Test func cleanSharedReadStillProvesAbsence() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    let shared = NativeEpisodeServerSaveCoordinator.ItemDetailRead(
      detail: item(episode(id: "other-id", guid: "other-guid")), diagnostics: DecodeDiagnostics())

    let result = await fixture.coordinator.reconcile(attemptID: attemptID, sharedDetail: shared)

    #expect(result == .absent(attemptID: attemptID, state: .accepted))
    #expect(fixture.details.callCount == 0)
  }

  @Test func uncertainWithMatchTransitionsStraightToConfirmed() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.uncertain)
    fixture.details.stubDetail(item(episode(id: "recovered-id", guid: "episode-guid")))

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .confirmed(
          attemptID: attemptID, state: .confirmed, serverEpisodeID: "recovered-id"))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .confirmed)
  }

  @Test func confirmedReconciliationIsIdempotentAndDoesNotReadOrWrite() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.confirmed)
    let before = try #require(try await fixture.store.fetchAttemptAsync(id: attemptID))
    fixture.details.stubFailure(.transport)

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .confirmed(
          attemptID: attemptID, state: .confirmed, serverEpisodeID: "confirmed-id"))
    #expect(fixture.details.callCount == 0)
    let after = try #require(try await fixture.store.fetchAttemptAsync(id: attemptID))
    #expect(after == before)
  }

  @Test(arguments: [
    (APIError.forbidden, NativeEpisodeServerSaveErrorCategory.permissionChanged),
    (APIError.notFound, NativeEpisodeServerSaveErrorCategory.staleIdentity),
    (APIError.serverFailure(statusCode: 500), NativeEpisodeServerSaveErrorCategory.serverFailure),
    (APIError.transport, NativeEpisodeServerSaveErrorCategory.transport),
  ])
  func serverReadFailureLeavesStateUnchanged(
    error: APIError,
    category: NativeEpisodeServerSaveErrorCategory
  ) async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubFailure(error)

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(result == .inconclusive(attemptID: attemptID, state: .accepted, category: category))
    let record = try #require(try await fixture.store.fetchAttemptAsync(id: attemptID))
    #expect(record.state == .accepted)
    #expect(record.serverEpisodeId == nil)
  }

  @Test func accountReplacementStopsBeforeConfirmationWrite() async throws {
    let fixture = try await ReconcileFixture.make()
    let attemptID = try await fixture.seed(.accepted)
    fixture.details.stubDetail(item(episode(id: "blocked-id", guid: "episode-guid")))
    fixture.details.stubBeforeReturn { _, _ in
      fixture.accountReader.stubAccount(fixture.replacementAccount())
    }

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(
      result
        == .inconclusive(
          attemptID: attemptID, state: .accepted, category: .accountReplaced))
    let record = try #require(try await fixture.store.fetchAttemptAsync(id: attemptID))
    #expect(record.state == .accepted)
    #expect(record.serverEpisodeId == nil)
  }

  @Test func postAcceptedTriggerRunsOnePassWithoutChangingSaveOutcome() async throws {
    let fixture = try await ReconcileFixture.make()
    fixture.details.stubPlans([
      .success(item(episode(id: "other-id", guid: "other-guid"))),
      .success(item(episode(id: "trigger-id", guid: "episode-guid"))),
    ])
    let writer = makeReconcileWriter()
    let coordinator = fixture.makeCoordinator(writer: writer)

    let saveResult = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    await fixture.details.recorder.waitUntil(count: 2)

    #expect(saveResult == .accepted(attemptID: 1, serverItemID: "show"))
    #expect(writer.enqueueCount == 1)
    #expect(fixture.details.callCount == 2)
  }

  @Test func reconciliationDescriptionsContainNoSensitiveLocatorValues() async throws {
    let result = NativeEpisodeServerSaveReconciliationOutcome.inconclusive(
      attemptID: 7, state: .accepted, category: .transport)
    let description = result.description + String(reflecting: result)

    #expect(description.contains("https://") == false)
    #expect(description.contains("/api/") == false)
    #expect(description.contains("secret") == false)
    #expect(description.contains("episode.mp3") == false)
  }
}

private struct ReconcileFixture: Sendable {
  let database: AppDatabase
  let accountID: Int64
  let command: NativeEpisodeServerSaveCommand
  let accountReader: FakeNativeEpisodeServerSaveAccountReading
  let commandReader: ReconcileCommandReader
  let details: FakeNativeEpisodeServerSaveItemDetailReading
  let store: NativeEpisodeServerSaveAttemptStore
  let subscriptions: FakeNativePodcastSubscriptionsReading

  static func make(
    command: NativeEpisodeServerSaveCommand = makeCommand()
  ) async throws -> Self {
    let database = try AppDatabase.inMemory()
    let accountID = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: "reconcile-client", serverBaseURL: "https://server.example",
        serverUserId: "server-user", serverVersion: "2.35.1")
      try record.insert(db)
      return try #require(record.id)
    }
    let accountRecord = try await database.readAsync { db in
      try #require(try AccountRecord.fetchOne(db, key: accountID))
    }
    let account = NativeEpisodeServerSaveAccount(
      accountID: accountID, clientUUID: accountRecord.clientUUID,
      serverIdentityFingerprint:
        accountRecord.serverIdentityFingerprint,
      tokenAccount: try accountRecord.credentialTokenAccount)
    return Self(
      database: database, accountID: accountID, command: command,
      accountReader: FakeNativeEpisodeServerSaveAccountReading(account),
      commandReader: ReconcileCommandReader(command),
      details: FakeNativeEpisodeServerSaveItemDetailReading(item()),
      store: NativeEpisodeServerSaveAttemptStore(database: database),
      subscriptions: makeReconcileSubscriptions())
  }

  func replacementAccount() -> NativeEpisodeServerSaveAccount {
    NativeEpisodeServerSaveAccount(
      accountID: accountID, clientUUID: "replacement-client",
      serverIdentityFingerprint: commandAccountFingerprint(), tokenAccount: accountToken())
  }

  private func commandAccountFingerprint() -> String {
    // The account reader's replacement preserves server identity but changes the client fence.
    // The fingerprint comes from the persisted account, not recomputed here.
    (try? database.read { db in
      try AccountRecord.fetchOne(db, key: accountID).map {
        $0.serverIdentityFingerprint
      }
    }) ?? ""
  }

  private func accountToken() -> TokenAccount {
    try! TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: "replacement-client"),
      userID: "server-user")
  }

  func makeCoordinator(
    writer: any NativeEpisodeServerSavePodcastWriting = makeReconcileWriter()
  ) -> NativeEpisodeServerSaveCoordinator {
    NativeEpisodeServerSaveCoordinator(
      accountReader: accountReader,
      capabilityReader: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: false),
      commandReader: commandReader,
      destinationResolver: ReconcileDestination(),
      podcastWriter: writer,
      itemDetailReader: details,
      attemptStore: store,
      nativeSubscriptions: subscriptions,
      foregroundConvergenceDelays: [])
  }

  var coordinator: NativeEpisodeServerSaveCoordinator { makeCoordinator() }

  func seed(_ state: NativeEpisodeServerSaveAttemptState) async throws -> Int64 {
    let attempt = try await store.beginAttemptAsync(
      accountId: accountID, feedId: command.feedId, episodeId: command.episodeId,
      episodeIdentityKey: command.episodeIdentityKey)
    let id = try #require(attempt.id)
    _ = try await store.recordServerItemIDAsync("show", attemptId: id)
    _ = try await store.recordPreflightPresenceAsync(.absentBeforeRequest, attemptId: id)
    _ = try await store.transitionAsync(
      attemptId: id, to: .requestingDownload, serverItemId: "show", errorCategory: nil)
    _ = try await store.transitionAsync(
      attemptId: id, to: .accepted, serverItemId: "show", errorCategory: nil)
    switch state {
    case .accepted: break
    case .uncertain:
      _ = try await store.transitionAsync(
        attemptId: id, to: .uncertain, serverItemId: "show", errorCategory: .transport)
    case .confirmed:
      _ = try await store.transitionAsync(
        attemptId: id, to: .confirmed, serverItemId: "show", serverEpisodeId: "confirmed-id",
        errorCategory: nil)
    default: throw TestError.invalidSeed
    }
    return id
  }
}

private enum TestError: Error { case invalidSeed }

private func makeCommand(guid: String? = "episode-guid") -> NativeEpisodeServerSaveCommand {
  NativeEpisodeServerSaveCommand(
    feedId: 1, episodeId: 2,
    episodeIdentityKey: guid.map { "guid:\($0)" } ?? "sha256:" + String(repeating: "0", count: 64),
    feedTitle: "Native Show", feedAuthor: "Native Author", feedSynopsis: "Native Synopsis",
    episodeGUID: guid, episodeTitle: "Native Episode", episodeSynopsis: "Episode Synopsis",
    enclosureType: "audio/mpeg", declaredBytes: 42, durationSeconds: 12.5,
    seasonNumber: 2, episodeNumber: 3, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
    feedURL: URL(string: "https://feeds.example/feed.xml")!,
    enclosureURL: URL(string: "https://media.example/episode.mp3")!)
}

private func episode(
  id: String = "server-episode",
  guid: String? = "episode-guid",
  title: String? = "Unrelated title",
  enclosureURL: String? = nil,
  contentURL: String? = "/api/items/show/episodes/server-episode"
) -> PodcastEpisode {
  PodcastEpisode(
    id: id, title: title, guid: guid, enclosureURL: enclosureURL,
    contentUrl: contentURL, mimeType: "audio/mpeg", duration: nil, publishedAt: nil)
}

private func item(_ episode: PodcastEpisode? = nil) -> ItemDetail {
  item(id: "show", episode: episode)
}

private func item(id: String = "show", episode: PodcastEpisode? = nil) -> ItemDetail {
  ItemDetail(
    id: id, libraryID: "podcasts", mediaType: "podcast",
    media: .podcast(
      PodcastMedia(
        title: "Native Show", author: "Native Author", description: "Native Synopsis",
        episodes: episode.map { [$0] } ?? [], isEpisodeListStructurallyComplete: true)))
}

private func incompleteItem() -> ItemDetail {
  ItemDetail(
    id: "show", libraryID: "podcasts", mediaType: "podcast",
    media: .podcast(
      PodcastMedia(
        title: "Native Show", author: nil, description: nil, episodes: [],
        isEpisodeListStructurallyComplete: false)))
}

private actor ReconcileCommandReader: NativeEpisodeServerSaveCommandReading {
  private let value: NativeEpisodeServerSaveCommand
  private var error: NativeEpisodeServerSaveCommandReaderError?
  private var reads = 0

  init(_ value: NativeEpisodeServerSaveCommand) { self.value = value }
  func setError(_ error: NativeEpisodeServerSaveCommandReaderError?) { self.error = error }
  func readCount() -> Int { reads }

  func read(feedId: Int64, episodeId: Int64) async throws -> NativeEpisodeServerSaveCommand {
    reads += 1
    if let error { throw error }
    return value
  }
}

private struct ReconcileDestination: NativeEpisodeServerSaveDestinationResolving {
  func resolveNativeEpisodeServerSaveDestination(
    feedURL: URL, nativeFeedTitle: String, account: TokenAccount,
    choice: ServerPodcastSaveChoice?
  ) async throws -> NativeEpisodeServerSaveDestinationResolution {
    .reuse(serverItemID: "show")
  }
}

/// A writer that creates and enqueues like the shared default. A removal reaching it fails as an
/// unavailable writer would.
private func makeReconcileWriter() -> FakeNativeEpisodeServerSavePodcastWriting {
  let writer = FakeNativeEpisodeServerSavePodcastWriting()
  writer.stubRemove(.failure(RemovalUnsupportedByWriter()))
  return writer
}

/// Subscriptions that are enabled and whose observation finishes without a value.
private func makeReconcileSubscriptions() -> FakeNativePodcastSubscriptionsReading {
  let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
  subscriptions.finishObservations()
  return subscriptions
}

extension FakeNativeEpisodeServerSaveItemDetailReading {
  /// Every read answers `detail`.
  fileprivate func stubDetail(_ detail: ItemDetail) { stubPlans([.success(detail)]) }

  /// Every read throws `error`.
  fileprivate func stubFailure(_ error: APIError) { stubPlans([.failure(error)]) }

  /// Every read answers `detail`, and records a dropped episode into the caller's diagnostics: the
  /// detail already lacks it, and only the diagnostics show the drop.
  fileprivate func stubLossy(_ detail: ItemDetail) {
    stubPlans([.success(detail)])
    stubBeforeReturn { _, diagnostics in recordDroppedEpisode(into: diagnostics) }
  }
}
