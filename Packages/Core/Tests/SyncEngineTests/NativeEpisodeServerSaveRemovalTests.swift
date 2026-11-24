import ABSApi
import Foundation
import TestSupport
import Testing

@testable import Persistence
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1))) struct NativeEpisodeServerSaveRemovalTests {
  @Test func happyPathPersistsDeletingBeforeExactSingleEpisodeSendAndRemoves() async throws {
    let fixture = try await RemovalFixture.make(
      detail: .success(fixtureItem(episodes: [])),
      writer: makeRemovalWriter(plan: .success))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")
    let writer = fixture.writer
    writer.stubBeforeRemoval {
      let state = try? await fixture.store.fetchAttemptAsync(id: attemptID)?.state
      await fixture.trace.append("state:\(state?.rawValue ?? "missing")")
    }

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.state == .removed)
    #expect(result.description.contains("removedFromAudiobookshelf"))
    let calls = writer.removals
    #expect(calls.count == 1)
    #expect(calls.first?.itemID == "stored-item")
    #expect(calls.first?.episodeID == "stored-episode")
    #expect(await fixture.trace.values() == ["state:deleting"])
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .removed)
  }

  @Test func disabledNativeSubscriptionsStopRemovalBeforeTheDeleteSend() async throws {
    let fixture = try await RemovalFixture.make(
      detail: .success(fixtureItem(episodes: [])),
      writer: makeRemovalWriter(plan: .success),
      subscriptions: makeRemovalSubscriptions(enabled: false))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result == .failed(attemptID: attemptID, state: .confirmed, category: .unsubscribed))
    #expect(fixture.writer.removals.isEmpty)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .confirmed)
  }

  @Test func confirmedRemovalUsesPersistedIDsAfterRSSRowPruning() async throws {
    let fixture = try await RemovalFixture.make(
      detail: .success(fixtureItem(episodes: [])),
      writer: makeRemovalWriter(plan: .success))
    let attemptID = try await fixture.seed(
      .confirmed, itemID: "stored-item", episodeID: "stored-episode",
      preflight: .absentBeforeRequest)
    await fixture.commandReader.setError(.episodeNotFound)

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.state == .removed)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .removed)
    #expect(
      fixture.writer.removals == [
        RecordedRemoval(itemID: "stored-item", episodeID: "stored-episode")
      ])
  }

  @Test func stalePersistedShowCannotRedirectRemovalToAnotherShowID() async throws {
    let fixture = try await RemovalFixture.make(
      detail: .failure(.notFound),
      writer: makeRemovalWriter(plan: .success))
    let attemptID = try await fixture.seed(
      .confirmed, itemID: "stored-item", episodeID: "stored-episode",
      preflight: .absentBeforeRequest)

    _ = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(fixture.writer.removals.allSatisfy { $0.itemID == "stored-item" })
  }

  @Test(arguments: [
    NativeEpisodeServerSaveAttemptState.accepted,
    NativeEpisodeServerSaveAttemptState.confirmed,
  ])
  func onlyConfirmedEligibleProvenanceCanRemove(_ state: NativeEpisodeServerSaveAttemptState) async throws {
    let fixture = try await RemovalFixture.make(detail: .success(fixtureItem(episodes: [])))
    let attemptID = try await fixture.seed(
      state, itemID: "stored-item", episodeID: "stored-episode",
      preflight: state == .accepted ? .absentBeforeRequest : .preExisting)

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.state == state)
    #expect(fixture.writer.removals.isEmpty)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == state)
  }

  @Test func missingEpisodeIDAndMissingItemIDAreRefusedWithoutADelete() async throws {
    for itemID in [String?(nil), "stored-item"] {
      let fixture = try await RemovalFixture.make(detail: .success(fixtureItem(episodes: [])))
      let attemptID = try await fixture.seed(
        .confirmed, itemID: itemID, episodeID: itemID == nil ? "stored-episode" : nil)

      let result = await fixture.coordinator.remove(attemptID: attemptID)

      #expect(result.state == .confirmed)
      #expect(fixture.writer.removals.isEmpty)
    }
  }

  @Test func capabilityFalseRefusesDefaultAdminWithoutDeletePermission() async throws {
    let fixture = try await RemovalFixture.make(
      capability: FakeServerPodcastMutationCapabilityReading(canSave: true, canRemove: false),
      detail: .success(fixtureItem(episodes: [])))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.errorCategory == .permissionChanged)
    #expect(result.state == .confirmed)
    #expect(fixture.writer.removals.isEmpty)
  }

  @Test func forbiddenWinsOverStaleCapabilityAndPersistsDefinitiveFailure() async throws {
    let fixture = try await RemovalFixture.make(
      detail: .success(fixtureItem(episodes: [])),
      writer: makeRemovalWriter(plan: .failure(.forbidden)))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result == .failed(attemptID: attemptID, state: .deleteFailed, category: .permissionChanged))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .deleteFailed)
  }

  @Test func notFoundReconcilesCompleteItemToRemoved() async throws {
    let fixture = try await RemovalFixture.make(
      detail: .success(fixtureItem(episodes: [])),
      writer: makeRemovalWriter(plan: .failure(.notFound)))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.state == .removed)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .removed)
  }

  @Test func badRequestIsDefinitiveInvalidDestinationFailure() async throws {
    let fixture = try await RemovalFixture.make(
      detail: .success(fixtureItem(episodes: [])),
      writer: makeRemovalWriter(plan: .failure(.badRequest)))
    let attemptID = try await fixture.seed(
      .confirmed, itemID: "stored-item", episodeID: "stored-episode")

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(
      result
        == .failed(
          attemptID: attemptID, state: .deleteFailed, category: .invalidDestination))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .deleteFailed)
  }

  @Test(arguments: [
    (APIError.transport, NativeEpisodeServerSaveErrorCategory.transport),
    (APIError.serverFailure(statusCode: 503), NativeEpisodeServerSaveErrorCategory.serverFailure),
    (APIError.decoding, NativeEpisodeServerSaveErrorCategory.malformedResponse),
  ])
  func ambiguousDeleteResultsBecomeDeleteUncertainWithoutRetry(
    error: APIError,
    category: NativeEpisodeServerSaveErrorCategory
  ) async throws {
    let fixture = try await RemovalFixture.make(
      detail: .success(fixtureItem(episodes: [])),
      writer: makeRemovalWriter(plan: .failure(error)))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result == .uncertain(attemptID: attemptID, state: .deleteUncertain, category: category))
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .deleteUncertain)
    #expect(fixture.writer.removals.count == 1)
  }

  @Test func cancellationAfterSendIsUncertainAndDoesNotAutomaticallyRetry() async throws {
    let fixture = try await RemovalFixture.make(
      detail: .success(fixtureItem(episodes: [])),
      writer: makeRemovalWriter(plan: .cancelled))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")

    let result = await fixture.coordinator.remove(attemptID: attemptID)
    let retryableResult = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.errorCategory == .cancelled)
    #expect(result.state == .deleteUncertain)
    #expect(retryableResult.state == .removed)
    #expect(fixture.writer.removals.count == 1)
  }

  @Test func incompleteOrPresentEpisodeNeverConfirmsRemoval() async throws {
    for detail in [
      DetailPlan.success(fixtureItem(episodes: [], complete: false)),
      DetailPlan.success(fixtureItem(episodes: [fixtureEpisode(id: "stored-episode")])),
    ] {
      let fixture = try await RemovalFixture.make(detail: detail)
      let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")

      let result = await fixture.coordinator.remove(attemptID: attemptID)

      #expect(result.state == .deleteUncertain)
      #expect(result.errorCategory == (detail.isIncomplete ? .incompleteEpisodeList : .serverFailure))
      #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .deleteUncertain)
    }
  }

  @Test func duplicateEpisodeIDsNeverConfirmRemoval() async throws {
    let fixture = try await RemovalFixture.make(
      detail: .success(
        fixtureItem(
          episodes: [fixtureEpisode(id: "duplicate"), fixtureEpisode(id: "duplicate")]))
    )
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.state == .deleteUncertain)
    #expect(result.errorCategory == .incompleteEpisodeList)
    #expect(fixture.writer.removals.count == 1)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .deleteUncertain)
  }

  @Test func listThatLostAnEpisodeInDecodingNeverConfirmsRemoval() async throws {
    let fixture = try await RemovalFixture.make(
      detail: .lossy(fixtureItem(episodes: [fixtureEpisode(id: "other-episode")])))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.state == .deleteUncertain)
    #expect(result.errorCategory == .incompleteEpisodeList)
    #expect(fixture.writer.removals.count == 1)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .deleteUncertain)
  }

  @Test func wrongItemOrKindNeverConfirmsRemoval() async throws {
    for detail in [
      fixtureItem(id: "another-item", episodes: []),
      fixtureItem(mediaType: "book", episodes: []),
    ] {
      let fixture = try await RemovalFixture.make(detail: .success(detail))
      let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")

      let result = await fixture.coordinator.remove(attemptID: attemptID)

      #expect(result.state == .deleteUncertain)
      #expect(result.errorCategory == .incompleteEpisodeList)
      #expect(fixture.writer.removals.count == 1)
      #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .deleteUncertain)
    }
  }

  @Test func ambiguousLocalItemRowsKeepConvergencePendingAndNeverResendDelete() async throws {
    let fixture = try await RemovalFixture.make(detail: .success(fixtureItem(episodes: [])))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")
    try await fixture.insertDuplicateItemRow()

    let first = await fixture.coordinator.remove(attemptID: attemptID)
    let second = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(first.state == .deleteUncertain)
    #expect(first.errorCategory == .localPersistence)
    #expect(second.state == .deleteUncertain)
    #expect(second.errorCategory == .localPersistence)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .deleteUncertain)
    #expect(
      try await fixture.store.fetchAttemptAsync(id: attemptID)?.errorCategory
        == .localPersistence)
    #expect(fixture.writer.removals.count == 1)
  }

  /// A local item row that no longer exists has no catalogue state for the removed transition to
  /// run ahead of, so a proven server absence converges instead of looping in convergence-pending.
  @Test func missingLocalItemConvergesToRemovedWithoutResendingDelete() async throws {
    let fixture = try await RemovalFixture.make(detail: .success(fixtureItem(episodes: [])))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")
    try await fixture.deleteLocalItemRow()

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.state == .removed)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .removed)
    #expect(fixture.writer.removals.count == 1)
  }

  @Test func convergencePendingRowWithMissingLocalItemRecoversToRemoved() async throws {
    let fixture = try await RemovalFixture.make(detail: .success(fixtureItem(episodes: [])))
    let attemptID = try await fixture.seed(.deleting, itemID: "stored-item", episodeID: "stored-episode")
    let accountID = try await fixture.accounts.currentAccount().accountID
    _ = try await fixture.store.markRemovalConvergencePendingAsync(
      attemptId: attemptID, serverItemId: "stored-item", accountId: accountID,
      errorCategory: .localPersistence)
    try await fixture.deleteLocalItemRow()

    let result = await fixture.coordinator.recover(attemptID: attemptID)

    #expect(result.state == .removed)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .removed)
    #expect(fixture.writer.removals.isEmpty)
  }

  /// A podcast item the server no longer has cannot contain the episode, so a 404 on the item is
  /// absence, not an inconclusive read that leaves the row uncertain forever.
  @Test func deleteUncertainRowWhoseServerItemIsGoneRecoversToRemoved() async throws {
    let fixture = try await RemovalFixture.make(detail: .failure(.notFound))
    let attemptID = try await fixture.seed(.deleting, itemID: "stored-item", episodeID: "stored-episode")
    _ = try await fixture.store.transitionAsync(
      attemptId: attemptID, to: .deleteUncertain, serverItemId: "stored-item",
      errorCategory: .transport)

    let result = await fixture.coordinator.recover(attemptID: attemptID)

    #expect(result.state == .removed)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .removed)
    #expect(fixture.writer.removals.isEmpty)
  }

  @Test func serverItemGoneAfterDeleteSendConvergesToRemoved() async throws {
    let fixture = try await RemovalFixture.make(detail: .failure(.notFound))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.state == .removed)
    #expect(fixture.writer.removals.count == 1)
  }

  @Test func newerSameItemSavePreventsStaleRemovalSnapshotCommit() async throws {
    let fixture = try await RemovalFixture.make(detail: .success(fixtureItem(episodes: [])))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")
    let accountID = try await fixture.accounts.currentAccount().accountID
    let newer = try await fixture.store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 3, episodeIdentityKey: "guid:newer",
      preflightPresence: .absentBeforeRequest)
    let newerID = try #require(newer.id)
    _ = try await fixture.store.recordServerItemIDAsync("stored-item", attemptId: newerID)
    _ = try await fixture.store.transitionAsync(
      attemptId: newerID, to: .requestingDownload, serverItemId: "stored-item")
    _ = try await fixture.store.transitionAsync(
      attemptId: newerID, to: .accepted, serverItemId: "stored-item")

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.state == .deleteUncertain)
    #expect(result.errorCategory == .localPersistence)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .deleteUncertain)
    #expect(fixture.writer.removals.count == 1)
  }

  @Test func accountReplacementStopsBeforeDeletingWrite() async throws {
    let fixture = try await RemovalFixture.make(detail: .success(fixtureItem(episodes: [])))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")
    fixture.accounts.stubAccount(fixture.replacementAccount)

    let result = await fixture.coordinator.remove(attemptID: attemptID)

    #expect(result.errorCategory == .accountReplaced)
    #expect(fixture.writer.removals.isEmpty)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .confirmed)
  }

  @Test func recoveryOfDeletingRowReconcilesWithoutSendingAndNoSensitiveRemovalValueEscapes() async throws {
    let fixture = try await RemovalFixture.make(detail: .success(fixtureItem(episodes: [])))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")
    _ = try await fixture.store.transitionAsync(
      attemptId: attemptID, to: .deleting, serverItemId: "stored-item", errorCategory: nil)

    let result = await fixture.coordinator.recover(attemptID: attemptID)

    #expect(result.state == .removed)
    #expect(fixture.writer.removals.isEmpty)
    #expect(result.description.contains("https://") == false)
    #expect(result.description.contains("/api/") == false)
    #expect(result.description.contains("secret") == false)
  }

  @Test func removalAndSaveForOneEpisodeShareTheFlightAndNeverOverlap() async throws {
    let fixture = try await RemovalFixture.make(detail: .success(fixtureItem(episodes: [])))
    let attemptID = try await fixture.seed(.confirmed, itemID: "stored-item", episodeID: "stored-episode")
    let gate = RemovalGate()
    fixture.writer.stubBeforeRemoval {
      await gate.enter()
      await gate.waitForRelease()
    }

    let removal = Task { await fixture.coordinator.remove(attemptID: attemptID) }
    await gate.waitForEntry()
    let save = Task { await fixture.coordinator.save(feedId: 1, episodeId: 2, choice: nil) }
    await gate.release()
    let removalResult = await removal.value
    let saveResult = await save.value

    #expect(removalResult.state == .removed)
    #expect(saveResult.state == .preparing)
    #expect(fixture.writer.removals.count == 1)
    #expect(fixture.writer.enqueueCount == 0)
  }

  /// `reconcile` sends a destructive row through the removal observation, not the save
  /// reconciler: the answer is the removal's absence report and nothing is sent or written.
  @Test func reconcilingADeletingRowObservesThroughTheRemovalPipeline() async throws {
    let fixture = try await RemovalFixture.make(detail: .success(fixtureItem(episodes: [])))
    let attemptID = try await fixture.seed(
      .deleting, itemID: "stored-item", episodeID: "stored-episode")

    let result = await fixture.coordinator.reconcile(attemptID: attemptID)

    #expect(result == .absent(attemptID: attemptID, state: .deleting))
    #expect(fixture.writer.removals.isEmpty)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .deleting)
  }

  /// The `.deleting` checkpoint and the DELETE it authorises are both abandoned when the fence
  /// no longer matches at that checkpoint: the durable row and the server stay untouched.
  @Test func fenceFailureAtTheDeletingCheckpointAbortsTheWriteAndTheDelete() async throws {
    let capability = FakeServerPodcastMutationCapabilityReading(canSave: true, canRemove: true)
    capability.gate.hold()
    let fixture = try await RemovalFixture.make(
      capability: capability,
      detail: .success(fixtureItem(episodes: [])))
    let attemptID = try await fixture.seed(
      .confirmed, itemID: "stored-item", episodeID: "stored-episode")

    let removal = Task { await fixture.coordinator.remove(attemptID: attemptID) }
    await capability.gate.waitUntilParked()
    fixture.accounts.stubAccount(fixture.replacementAccount)
    capability.gate.release()
    let result = await removal.value

    #expect(result == .failed(attemptID: attemptID, state: .confirmed, category: .accountReplaced))
    #expect(fixture.writer.removals.isEmpty)
    #expect(try await fixture.store.fetchAttemptAsync(id: attemptID)?.state == .confirmed)
  }
}

private struct RemovalFixture: Sendable {
  let database: AppDatabase
  let store: NativeEpisodeServerSaveAttemptStore
  let coordinator: NativeEpisodeServerSaveCoordinator
  let writer: FakeNativeEpisodeServerSavePodcastWriting
  let commandReader: RemovalCommandReader
  let accounts: FakeNativeEpisodeServerSaveAccountReading
  let replacementAccount: NativeEpisodeServerSaveAccount
  let trace: RemovalTrace

  static func make(
    capability: any ServerPodcastMutationCapabilityReading =
      FakeServerPodcastMutationCapabilityReading(canSave: true, canRemove: true),
    detail: DetailPlan,
    writer: FakeNativeEpisodeServerSavePodcastWriting? = nil,
    subscriptions: any NativePodcastSubscriptionsReading = makeRemovalSubscriptions(enabled: true)
  ) async throws -> RemovalFixture {
    let database = try AppDatabase.inMemory()
    let accountID = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: "client", serverBaseURL: "https://server.example", serverUserId: "user",
        serverVersion: "2.35.1")
      try record.insert(db)
      let accountID = try #require(record.id)
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "library", mediaType: "podcast", name: "Library")
      try library.insert(db)
      let libraryID = try #require(library.id)
      var item = ItemRecord(
        accountId: accountID, libraryId: libraryID, serverItemId: "stored-item",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try item.insert(db)
      return accountID
    }
    let persisted = try await database.readAsync { db in
      try #require(try AccountRecord.fetchOne(db, key: accountID))
    }
    let token = try persisted.credentialTokenAccount
    let account = NativeEpisodeServerSaveAccount(
      accountID: accountID, clientUUID: persisted.clientUUID,
      serverIdentityFingerprint: persisted.serverIdentityFingerprint,
      tokenAccount: token)
    let replacement = NativeEpisodeServerSaveAccount(
      accountID: accountID, clientUUID: "replacement-client",
      serverIdentityFingerprint: account.serverIdentityFingerprint, tokenAccount: token)
    let trace = RemovalTrace()
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let actualWriter = writer ?? makeRemovalWriter(plan: .success)
    let accounts = FakeNativeEpisodeServerSaveAccountReading(account)
    let commandReader = RemovalCommandReader()
    let coordinator = NativeEpisodeServerSaveCoordinator(
      accountReader: accounts, capabilityReader: capability,
      commandReader: commandReader, destinationResolver: RemovalDestinationResolver(),
      podcastWriter: actualWriter, itemDetailReader: makeRemovalDetailReader(detail), attemptStore: store,
      nativeSubscriptions: subscriptions,
      foregroundConvergenceDelays: [])
    return RemovalFixture(
      database: database, store: store, coordinator: coordinator, writer: actualWriter,
      commandReader: commandReader,
      accounts: accounts,
      replacementAccount: replacement,
      trace: trace)
  }

  func deleteLocalItemRow() async throws {
    let accountID = try await accounts.currentAccount().accountID
    try await database.writeAsync { db in
      for item in try ItemRecord.fetchAll(db)
      where item.accountId == accountID && item.serverItemId == "stored-item" {
        try item.delete(db)
      }
    }
  }

  /// `serverItemId` is unique only within a library, so a second library may legally carry the
  /// same id; the removal contract treats that as an ambiguous target.
  func insertDuplicateItemRow() async throws {
    let accountID = try await accounts.currentAccount().accountID
    try await database.writeAsync { db in
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "library-2", mediaType: "podcast", name: "Other")
      try library.insert(db)
      var item = ItemRecord(
        accountId: accountID, libraryId: try #require(library.id), serverItemId: "stored-item",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try item.insert(db)
    }
  }

  func seed(
    _ state: NativeEpisodeServerSaveAttemptState,
    itemID: String?, episodeID: String?,
    preflight: NativeEpisodeServerSavePreflightPresence = .absentBeforeRequest
  ) async throws -> Int64 {
    let accountID = try await accounts.currentAccount().accountID
    let attempt = try await store.createAttemptAsync(
      accountId: accountID,
      feedId: 1, episodeId: 2, episodeIdentityKey: "guid:episode", preflightPresence: preflight)
    let attemptID = try #require(attempt.id)
    if state == .confirmed && (itemID == nil || episodeID == nil) {
      try await database.writeAsync { db in
        var row = try #require(try NativeEpisodeServerSaveAttemptRecord.fetchOne(db, key: attemptID))
        row.serverItemId = itemID
        row.serverEpisodeId = episodeID
        row.state = .confirmed
        try row.update(db)
      }
      return attemptID
    }
    if let itemID { _ = try await store.recordServerItemIDAsync(itemID, attemptId: attemptID) }
    guard state != .accepted else {
      _ = try await store.transitionAsync(
        attemptId: attemptID, to: .requestingDownload,
        serverItemId: itemID, errorCategory: nil)
      _ = try await store.transitionAsync(
        attemptId: attemptID, to: .accepted, serverItemId: itemID, errorCategory: nil)
      return attemptID
    }
    if let itemID {
      _ = try await store.transitionAsync(
        attemptId: attemptID, to: .requestingDownload,
        serverItemId: itemID, errorCategory: nil)
      _ = try await store.transitionAsync(
        attemptId: attemptID, to: .accepted,
        serverItemId: itemID, errorCategory: nil)
    }
    if state == .confirmed, let episodeID {
      _ = try await store.transitionAsync(
        attemptId: attemptID, to: .confirmed,
        serverItemId: itemID, serverEpisodeId: episodeID, errorCategory: nil)
    }
    if state == .deleting, let episodeID {
      _ = try await store.transitionAsync(
        attemptId: attemptID, to: .confirmed,
        serverItemId: itemID, serverEpisodeId: episodeID, errorCategory: nil)
      _ = try await store.transitionAsync(
        attemptId: attemptID, to: .deleting,
        serverItemId: itemID, errorCategory: nil)
    }
    return attemptID
  }
}

private enum RemovalWriterPlan: Sendable {
  case success
  case failure(APIError)
  case cancelled
}

private actor RemovalGate {
  private nonisolated let entries = TestCountRecorder(label: "RemovalGate entries")
  // The removal runs to completion regardless of cancellation, so a cancelled one stays parked.
  private nonisolated let gate = TestGate<Void>(
    label: "RemovalGate release", ignoresCancellation: true)

  init() {
    gate.hold()
  }

  func enter() {
    entries.record()
  }

  func waitForEntry() async {
    await entries.waitUntil(count: 1)
  }

  func release() {
    gate.release()
  }

  func waitForRelease() async {
    await gate.pass()
  }
}

private struct RecordedRemoval: Equatable, Sendable {
  let itemID: String
  let episodeID: String
}

private enum DetailPlan: Sendable {
  case success(ItemDetail)
  /// A read that dropped an episode in decoding: the detail already lacks it, and the drop is
  /// recorded only in the diagnostics the caller passed.
  case lossy(ItemDetail)
  case failure(APIError)
  var isIncomplete: Bool {
    if case .success(let detail) = self, case .podcast(let media)? = detail.media {
      return media.isEpisodeListStructurallyComplete == false
    }
    return false
  }
}

private actor RemovalCommandReader: NativeEpisodeServerSaveCommandReading {
  private var error: NativeEpisodeServerSaveCommandReaderError?

  func setError(_ error: NativeEpisodeServerSaveCommandReaderError?) { self.error = error }

  func read(feedId: Int64, episodeId: Int64) async throws -> NativeEpisodeServerSaveCommand {
    if let error { throw error }
    return NativeEpisodeServerSaveCommand(
      feedId: feedId, episodeId: episodeId, episodeIdentityKey: "guid:episode",
      feedTitle: "Show", feedAuthor: "Author", feedSynopsis: nil, episodeGUID: "episode",
      episodeTitle: "Episode", episodeSynopsis: nil, enclosureType: "audio/mpeg", declaredBytes: 1,
      durationSeconds: 1, seasonNumber: nil, episodeNumber: nil, publishedAt: nil,
      feedURL: URL(string: "https://feeds.example/feed.xml")!,
      enclosureURL: URL(string: "https://media.example/episode.mp3")!)
  }
}

private struct RemovalDestinationResolver: NativeEpisodeServerSaveDestinationResolving {
  func resolveNativeEpisodeServerSaveDestination(
    feedURL: URL, nativeFeedTitle: String, account: TokenAccount, choice: ServerPodcastSaveChoice?
  ) async throws -> NativeEpisodeServerSaveDestinationResolution {
    .needsChoice(.existing(candidates: []))
  }
}

private actor RemovalTrace {
  private var entries = [String]()
  func append(_ value: String) { entries.append(value) }
  func values() -> [String] { entries }
}

private func fixtureEpisode(id: String) -> PodcastEpisode {
  PodcastEpisode(
    id: id, title: "Episode", guid: "other", enclosureURL: nil, contentUrl: nil,
    mimeType: "audio/mpeg", duration: nil, publishedAt: nil)
}

private func fixtureItem(
  id: String = "stored-item",
  mediaType: String = "podcast",
  episodes: [PodcastEpisode],
  complete: Bool = true
) -> ItemDetail {
  ItemDetail(
    id: id, libraryID: "podcasts", mediaType: mediaType,
    media: .podcast(
      PodcastMedia(
        title: "Show", author: "Author", description: nil, episodes: episodes,
        isEpisodeListStructurallyComplete: complete)))
}

/// A writer whose creates and enqueues fail as an unavailable server would, and whose removals
/// follow `plan`.
private func makeRemovalWriter(
  plan: RemovalWriterPlan
) -> FakeNativeEpisodeServerSavePodcastWriting {
  let writer = FakeNativeEpisodeServerSavePodcastWriting()
  writer.stubCreate(.failure(APIError.transport))
  writer.stubEnqueue(.failure(APIError.transport))
  switch plan {
  case .success: writer.stubRemove(.success(()))
  case .failure(let error): writer.stubRemove(.failure(error))
  case .cancelled: writer.stubRemove(.failure(CancellationError()))
  }
  return writer
}

extension FakeNativeEpisodeServerSavePodcastWriting {
  /// The removals that reached the writer, in order.
  fileprivate var removals: [RecordedRemoval] {
    calls.compactMap { call -> RecordedRemoval? in
      if case .remove(_, let itemID, let episodeID) = call {
        return RecordedRemoval(itemID: itemID, episodeID: episodeID)
      }
      return nil
    }
  }

  /// Runs `action` before each removal is recorded; creates and enqueues do not run it.
  fileprivate func stubBeforeRemoval(_ action: @escaping @Sendable () async -> Void) {
    stubBeforeCall { call in
      if case .remove = call { await action() }
    }
  }
}

/// A reader whose every read follows `plan`; a lossy read records a dropped episode into the
/// caller's diagnostics.
private func makeRemovalDetailReader(
  _ plan: DetailPlan
) -> FakeNativeEpisodeServerSaveItemDetailReading {
  switch plan {
  case .success(let detail):
    return FakeNativeEpisodeServerSaveItemDetailReading(detail)
  case .lossy(let detail):
    let reader = FakeNativeEpisodeServerSaveItemDetailReading(detail)
    reader.stubBeforeReturn { _, diagnostics in recordDroppedEpisode(into: diagnostics) }
    return reader
  case .failure(let error):
    return FakeNativeEpisodeServerSaveItemDetailReading(plans: [.failure(error)])
  }
}

/// Subscriptions with the given preference whose observation finishes without a value.
private func makeRemovalSubscriptions(enabled: Bool) -> FakeNativePodcastSubscriptionsReading {
  let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: enabled)
  subscriptions.finishObservations()
  return subscriptions
}
