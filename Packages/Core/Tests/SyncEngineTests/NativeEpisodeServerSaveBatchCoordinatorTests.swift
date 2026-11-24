import ABSApi
import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite struct NativeEpisodeServerSaveBatchCoordinatorTests {
  @Test func reusesTheEstablishedShowForEachFollowingEpisode() async throws {
    let fixture = try await SaveFixture.make()
    await fixture.commandReader.setCommands([
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
      makeCommand(episodeId: 4, guid: "guid-4"),
    ])
    let resolver = StubDestinationResolver(.reuse(serverItemID: "show"))
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(fixture, destination: resolver, writer: writer)

    let result = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3, 4], choice: nil),
      cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { _ in }

    #expect(result.stop == .completed)
    #expect(result.notAttempted.isEmpty)
    #expect(result.serverItemID == "show")
    #expect(result.outcomes.map(\.episodeId) == [2, 3, 4])
    #expect(result.outcomes.allSatisfy { if case .accepted = $0.outcome { true } else { false } })
    #expect(await writer.counts() == (0, 3))
    // The resolver's catalogue scan runs for the first episode only; the show it named is reused
    // directly for the rest.
    #expect(await resolver.recordedChoices() == [nil])
  }

  /// Once the first outcome names the show, the batch reads its full episode list once more and
  /// every remaining episode preflights against that read, rather than scanning per episode.
  @Test func anEstablishedShowIsReadOnceForTheRemainingEpisodes() async throws {
    let fixture = try await SaveFixture.make()
    let commands = [
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
      makeCommand(episodeId: 4, guid: "guid-4"),
    ]
    await fixture.commandReader.setCommands(commands)
    let landed = commands.enumerated().map { index, command in
      PodcastEpisode(
        id: "server-\(index)", title: command.episodeTitle, guid: command.episodeGUID,
        enclosureURL: nil, contentUrl: nil, mimeType: "audio/mpeg", duration: nil,
        publishedAt: nil)
    }
    // The first episode's own preflight, the batch's shared read, then the one convergence look.
    let detail = SequencedItemDetailReader([
      completeItem(), completeItem(), completeItem(episodes: landed),
    ])
    let resolver = StubDestinationResolver(.reuse(serverItemID: "show"))
    let coordinator = makeCoordinator(
      fixture,
      destination: resolver,
      writer: StubPodcastWriter(trace: fixture.trace),
      detail: detail)

    let result = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3, 4], choice: nil),
      cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { _ in }

    #expect(result.stop == .completed)
    #expect(result.outcomes.allSatisfy { if case .accepted = $0.outcome { true } else { false } })
    #expect(await resolver.callCount() == 1)
    // Confirmations are written one episode at a time after the batch returns; wait for all of
    // them, not one, before asserting on the set.
    await waitUntil("episodes 2-4 confirmed") {
      await Self.allConfirmed(fixture, episodeIDs: [2, 3, 4])
    }
    #expect(await detail.callCount() == 3)
    for episodeID in [Int64(2), Int64(3), Int64(4)] {
      #expect(
        try await fixture.baseStore.fetchAttemptsAsync(
          accountId: fixture.accountID, feedId: 1, episodeId: episodeID
        ).first?.state == .confirmed)
    }
  }

  /// The batch's shared read stands in for each remaining episode's own preflight read, so it
  /// carries its own diagnostics: one that lost an episode in decoding cannot prove any of them
  /// absent, and no second copy of an episode that may already be there is enqueued.
  @Test func aSharedReadThatLostAnEpisodeCannotProveTheRemainingEpisodesAbsent() async throws {
    let fixture = try await SaveFixture.make()
    await fixture.commandReader.setCommands([
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
    ])
    // The first episode's own preflight is clean; the batch's shared read is lossy.
    let detail = SequencedItemDetailReader([completeItem()], lossyCalls: [2])
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture,
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: detail)

    let result = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3], choice: nil),
      cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { _ in }

    #expect(result.outcomes.map(\.episodeId) == [2, 3])
    #expect(result.outcomes[0].outcome == .accepted(attemptID: 1, serverItemID: "show"))
    #expect(
      result.outcomes[1].outcome
        == .failed(attemptID: 2, state: .failed, category: .incompleteEpisodeList))
    #expect(result.stop == .failed(episodeId: 3, category: .incompleteEpisodeList))
    #expect(await writer.counts() == (0, 1))
    #expect(await detail.callCountWithoutDiagnostics() == 0)
  }

  /// Grouped convergence reads the show once for every accepted attempt; a lossy read must leave
  /// each of them inconclusive rather than absent.
  @Test func groupedReconciliationNeverReportsAbsenceFromALossyRead() async throws {
    let fixture = try await SaveFixture.make()
    // The save's preflight and its post-accept look are clean; the grouped read is lossy.
    let detail = SequencedItemDetailReader([completeItem()], lossyCalls: [3])
    let coordinator = makeCoordinator(
      fixture,
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: StubPodcastWriter(trace: fixture.trace),
      detail: detail)
    let saved = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    #expect(saved == .accepted(attemptID: 1, serverItemID: "show"))
    await coordinator.lastConvergence?.value

    let results = await coordinator.reconcileGroup(
      attemptIDs: [1], serverItemID: "show",
      fence: NativeEpisodeServerSaveAccountFence(account: fixture.account))

    #expect(results == [.inconclusive(attemptID: 1, state: .accepted, category: .incompleteEpisodeList)])
    #expect(await detail.callCount() == 3)
  }

  @Test func needsChoiceResumesTheExistingPreparingAttempt() async throws {
    let prompt = NativeEpisodeServerSaveChoicePrompt.libraryAndFolder(libraries: [
      NativeEpisodeServerSaveLibraryChoice(
        libraryID: "library", displayName: "Secret Library", folders: [])
    ])
    let fixture = try await SaveFixture.make()
    await fixture.commandReader.setCommands([
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
      makeCommand(episodeId: 4, guid: "guid-4"),
    ])
    let resolver = StubDestinationResolver([
      .needsChoice(prompt), .create(testDestination()), .reuse(serverItemID: "created"),
      .reuse(serverItemID: "created"),
    ])
    let writer = StubPodcastWriter(trace: fixture.trace, createPlan: .success("created"))
    let coordinator = makeCoordinator(fixture, destination: resolver, writer: writer)
    let token = NativeEpisodeServerSaveBatchCancellationToken()

    let first = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3, 4], choice: nil),
      cancellation: token
    ) { _ in }
    #expect(first.stop == .needsChoice(episodeId: 2, attemptID: 1, prompt: prompt))
    #expect(first.outcomes.count == 1)
    #expect(first.notAttempted == [3, 4])
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1)?.state == .preparing)

    let choice = ServerPodcastSaveChoice.libraryAndFolder(libraryID: "library", folderID: "folder")
    let second = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3, 4], choice: choice),
      cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { _ in }
    #expect(second.stop == .completed)
    #expect(second.outcomes.map(\.episodeId) == [2, 3, 4])
    #expect(await writer.counts() == (1, 3))
    #expect(await resolver.recordedChoices().filter { $0 == choice }.count == 1)
    #expect(
      try await fixture.baseStore.fetchAttemptsAsync(
        accountId: fixture.accountID, feedId: 1, episodeId: 2
      ).count == 1)
  }

  @Test func missingEpisodeContinuesButTransportFailureStops() async throws {
    let fixture = try await SaveFixture.make()
    await fixture.commandReader.setCommands([
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
      makeCommand(episodeId: 4, guid: "guid-4"),
    ])
    await fixture.commandReader.setError(.episodeNotFound, for: 3)
    let writer = makeBatchWriter(failures: [nil, .api(.transport)])
    let coordinator = makeCoordinator(
      fixture,
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer)

    let result = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3, 4], choice: nil),
      cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { _ in }

    #expect(result.outcomes.count == 3)
    #expect(
      result.outcomes[1].outcome
        == .failed(
          attemptID: nil, state: .failed, category: .missingEpisode))
    #expect(
      result.outcomes[2].outcome
        == .uncertain(
          attemptID: 2, state: .uncertain, category: .transport))
    #expect(result.stop == .uncertain(episodeId: 4, attemptID: 2, category: .transport))
    #expect(result.notAttempted.isEmpty)
    #expect(writer.enqueueCount == 2)
  }

  @Test func cancellationIsOnlyObservedBetweenEpisodes() async throws {
    let fixture = try await SaveFixture.make()
    await fixture.commandReader.setCommands([
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
      makeCommand(episodeId: 4, guid: "guid-4"),
    ])
    let gate = BlockingGate()
    let writer = StubPodcastWriter(trace: fixture.trace, enqueueGate: gate)
    let coordinator = makeCoordinator(
      fixture,
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer)
    let token = NativeEpisodeServerSaveBatchCancellationToken()
    let task = Task {
      await coordinator.saveBatch(
        NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3, 4], choice: nil),
        cancellation: token
      ) { _ in }
    }
    await gate.waitUntilEntered()
    token.cancel()
    await gate.release()
    let result = await task.value

    #expect(result.stop == .cancelled)
    #expect(result.notAttempted == [3, 4])
    #expect(result.outcomes.count == 1)
    #expect(await writer.counts() == (0, 1))
    #expect(
      try await fixture.baseStore.fetchAttemptsAsync(
        accountId: fixture.accountID, feedId: 1, episodeId: 3
      ).isEmpty)
  }

  @Test func accountReplacementStopsBeforeTheNextSubmissionAndDoesNotNotifyForIt() async throws {
    let fixture = try await SaveFixture.make()
    await fixture.commandReader.setCommands([
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
    ])
    let replacement = try await fixture.replacementAccount(clientUUID: "replacement-client")
    let callbackEpisodes = EventLog()
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture,
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer)

    let result = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3], choice: nil),
      cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { entry in
      await callbackEpisodes.append(String(entry.episodeId))
      if entry.episodeId == 2 { await fixture.accountReader.replace(replacement) }
    }

    #expect(result.stop == .failed(episodeId: 3, category: .accountReplaced))
    #expect(result.notAttempted.isEmpty)
    #expect(result.outcomes.count == 2)
    #expect(await callbackEpisodes.values() == ["2"])
    #expect(await writer.counts() == (0, 1))
  }

  @Test func groupedConvergenceUsesOneDetailReadPerTick() async throws {
    let fixture = try await SaveFixture.make()
    let commands = [
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
      makeCommand(episodeId: 4, guid: "guid-4"),
    ]
    await fixture.commandReader.setCommands(commands)
    let landed = commands.enumerated().map { index, command in
      PodcastEpisode(
        id: "server-\(index)", title: command.episodeTitle, guid: command.episodeGUID,
        enclosureURL: nil, contentUrl: nil, mimeType: "audio/mpeg", duration: nil,
        publishedAt: nil)
    }
    // The first episode's preflight, the batch's shared read, a look that misses, a look that
    // lands.
    let detail = SequencedItemDetailReader([
      completeItem(), completeItem(), completeItem(), completeItem(episodes: landed),
    ])
    let coordinator = makeCoordinator(
      fixture,
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: StubPodcastWriter(trace: fixture.trace),
      detail: detail,
      foregroundConvergenceDelays: [.zero, .zero])

    _ = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3, 4], choice: nil),
      cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { _ in }
    // Confirmations are written one episode at a time after the batch returns; wait for all of
    // them, not one, before asserting on the set.
    await waitUntil("episodes 2-4 confirmed") {
      await Self.allConfirmed(fixture, episodeIDs: [2, 3, 4])
    }
    #expect(await detail.callCount() == 4)
    for episodeID in [Int64(2), Int64(3), Int64(4)] {
      #expect(
        try await fixture.baseStore.fetchAttemptsAsync(
          accountId: fixture.accountID, feedId: 1, episodeId: episodeID
        ).first?.state == .confirmed)
    }
  }

  /// Convergence outlives the batch by minutes, and the coordinator's client stays bound to the
  /// server the batch was saved on. An account that replaces the batch's in that window must never
  /// have its credentials sent there, and convergence ends at the first look after it.
  @Test func groupedConvergenceNeverReadsUnderAReplacementAccount() async throws {
    let fixture = try await SaveFixture.make()
    await fixture.commandReader.setCommands([
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
    ])
    let replacement = NativeEpisodeServerSaveAccount(
      accountID: fixture.accountID + 1,
      clientUUID: "replacement-client",
      serverIdentityFingerprint: "replacement-server",
      tokenAccount: try TokenAccount(
        credentialNamespace: "account:replacement-client", userID: "replacement-user"))
    // The first episode's preflight and the batch's shared read succeed. The first convergence look
    // fails in transit, which keeps convergence going, and the account is replaced during it.
    let detail = makeAccountRecordingDetailReader(
      plans: [.success(completeItem()), .success(completeItem()), .failure(.transport)],
      beforeCall: [3: { await fixture.accountReader.replace(replacement) }])
    let coordinator = makeCoordinator(
      fixture,
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: StubPodcastWriter(trace: fixture.trace),
      detail: detail,
      foregroundConvergenceDelays: [.zero, .zero])

    let result = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3], choice: nil),
      cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { _ in }
    #expect(result.stop == .completed)
    await coordinator.lastBatchConvergence?.value

    let original = fixture.account.tokenAccount
    #expect(detail.recordedAccounts == [original, original, original])
    for attemptID in [Int64(1), Int64(2)] {
      #expect(try await fixture.baseStore.fetchAttemptAsync(id: attemptID)?.state == .accepted)
    }
  }

  /// Removing the account cascades the batch's attempts away. Convergence must not report the
  /// vanished attempts as still accepted and keep looking for them.
  @Test func groupedConvergenceEndsWhenAccountRemovalTakesItsAttempts() async throws {
    let fixture = try await SaveFixture.make()
    await fixture.commandReader.setCommands([
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
    ])
    let accounts = FakeNativeEpisodeServerSaveAccountReading(fixture.account)
    let detail = makeAccountRecordingDetailReader(
      plans: [.success(completeItem()), .success(completeItem()), .failure(.transport)],
      beforeCall: [
        3: {
          _ = try? await fixture.database.writeAsync { db in
            _ = try AccountRecord.deleteOne(db, key: fixture.accountID)
          }
          accounts.stubError(NativeEpisodeServerSaveAccountReadingError.notAuthenticated)
        }
      ])
    let coordinator = makeCoordinator(
      fixture,
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: StubPodcastWriter(trace: fixture.trace),
      detail: detail,
      foregroundConvergenceDelays: [.zero, .zero],
      accounts: accounts)

    let result = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3], choice: nil),
      cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { _ in }
    #expect(result.stop == .completed)
    await coordinator.lastBatchConvergence?.value

    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1) == nil)
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 2) == nil)
    #expect(detail.recordedAccounts.count == 3)
    // At most the one look that finds the account gone.
    #expect(accounts.failedReadCount <= 1)

    let results = await coordinator.reconcileGroup(
      attemptIDs: [1, 2], serverItemID: "show",
      fence: NativeEpisodeServerSaveAccountFence(account: fixture.account))
    #expect(
      results == [
        .inconclusive(attemptID: 1, state: .failed, category: .accountReplaced),
        .inconclusive(attemptID: 2, state: .failed, category: .accountReplaced),
      ])
    #expect(detail.recordedAccounts.count == 3)
  }

  /// A failed grouped read reports each attempt in its stored state. One whose row is gone has no
  /// state to report and must not read as accepted, or convergence keeps looking for it.
  @Test func aFailedGroupedReadEndsConvergenceForAttemptsThatAreGone() async throws {
    let fixture = try await SaveFixture.make()
    await fixture.commandReader.setCommands([
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
    ])
    let detail = makeAccountRecordingDetailReader(
      plans: [.success(completeItem()), .success(completeItem()), .failure(.transport)],
      beforeCall: [
        3: {
          _ = try? await fixture.database.writeAsync { db in
            _ = try NativeEpisodeServerSaveAttemptRecord.deleteAll(db)
          }
        }
      ])
    let coordinator = makeCoordinator(
      fixture,
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: StubPodcastWriter(trace: fixture.trace),
      detail: detail,
      foregroundConvergenceDelays: [.zero, .zero])

    let result = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3], choice: nil),
      cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { _ in }
    #expect(result.stop == .completed)
    await coordinator.lastBatchConvergence?.value

    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1) == nil)
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 2) == nil)
    #expect(detail.recordedAccounts.count == 3)
  }

  /// Attempt rows can go while the batch's account is still signed in. A convergence look must not
  /// read the show for rows that are gone: it reads only for the rows still stored, and not at all
  /// once none are, reporting each missing row as `reconcile` does.
  @Test func groupedConvergenceReadsOnlyForAttemptsStillStored() async throws {
    let fixture = try await SaveFixture.make()
    await fixture.commandReader.setCommands([
      makeCommand(episodeId: 2, guid: "guid-2"),
      makeCommand(episodeId: 3, guid: "guid-3"),
    ])
    // The batch's one convergence look fails in transit, leaving both attempts accepted.
    let detail = makeAccountRecordingDetailReader(
      plans: [.success(completeItem()), .success(completeItem()), .failure(.transport)])
    let coordinator = makeCoordinator(
      fixture,
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: StubPodcastWriter(trace: fixture.trace),
      detail: detail)
    let fence = NativeEpisodeServerSaveAccountFence(account: fixture.account)

    let result = await coordinator.saveBatch(
      NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2, 3], choice: nil),
      cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { _ in }
    #expect(result.stop == .completed)
    await coordinator.lastBatchConvergence?.value
    #expect(detail.recordedAccounts.count == 3)
    for attemptID in [Int64(1), Int64(2)] {
      #expect(try await fixture.baseStore.fetchAttemptAsync(id: attemptID)?.state == .accepted)
    }

    _ = try await fixture.database.writeAsync { db in
      try NativeEpisodeServerSaveAttemptRecord.deleteOne(db, key: 1)
    }
    let partial = await coordinator.reconcileGroup(attemptIDs: [1, 2], serverItemID: "show", fence: fence)
    #expect(partial.map(\.attemptID) == [1, 2])
    #expect(partial.first == .inconclusive(attemptID: 1, state: .failed, category: .unknown))
    #expect(detail.recordedAccounts.count == 4)

    _ = try await fixture.database.writeAsync { db in
      try NativeEpisodeServerSaveAttemptRecord.deleteAll(db)
    }
    await coordinator.convergeBatch(attemptIDs: [1, 2], serverItemID: "show", fence: fence)
    let gone = await coordinator.reconcileGroup(attemptIDs: [1, 2], serverItemID: "show", fence: fence)

    #expect(
      gone == [
        .inconclusive(attemptID: 1, state: .failed, category: .unknown),
        .inconclusive(attemptID: 2, state: .failed, category: .unknown),
      ])
    #expect(detail.recordedAccounts == Array(repeating: fixture.account.tokenAccount, count: 4))
  }

  @Test func noOpAndBatchDiagnosticsAreRedacted() async {
    let prompt = NativeEpisodeServerSaveChoicePrompt.libraryAndFolder(libraries: [
      NativeEpisodeServerSaveLibraryChoice(
        libraryID: "library-id", displayName: "Do Not Log Library", folders: [])
    ])
    let request = NativeEpisodeServerSaveBatchRequest(feedId: 1, episodeIds: [2], choice: nil)
    let result = await NoOpNativeEpisodeServerSaveBatchSaving().saveBatch(
      request, cancellation: NativeEpisodeServerSaveBatchCancellationToken()
    ) { _ in }
    let choiceStop = NativeEpisodeServerSaveBatchStop.needsChoice(
      episodeId: 2, attemptID: 1, prompt: prompt)

    #expect(result.stop == .failed(episodeId: 2, category: .permissionChanged))
    #expect(result.notAttempted.isEmpty)
    #expect(String(reflecting: choiceStop).contains("Do Not Log Library") == false)
    #expect(choiceStop.description.contains("Do Not Log Library") == false)
    #expect(String(reflecting: result).contains("permissionChanged"))
  }

  private static func allConfirmed(_ fixture: SaveFixture, episodeIDs: [Int64]) async -> Bool {
    for episodeID in episodeIDs {
      let attempts = try? await fixture.baseStore.fetchAttemptsAsync(
        accountId: fixture.accountID, feedId: 1, episodeId: episodeID)
      guard attempts?.first?.state == .confirmed else { return false }
    }
    return true
  }

  private func makeCoordinator(
    _ fixture: SaveFixture,
    destination: any NativeEpisodeServerSaveDestinationResolving,
    writer: any NativeEpisodeServerSavePodcastWriting,
    detail: any NativeEpisodeServerSaveItemDetailReading = StubItemDetailReader(
      .success(completeItem())),
    foregroundConvergenceDelays: [Duration] = [],
    accounts: (any NativeEpisodeServerSaveAccountReading)? = nil
  ) -> NativeEpisodeServerSaveCoordinator {
    NativeEpisodeServerSaveCoordinator(
      accountReader: accounts ?? fixture.accountReader,
      capabilityReader: FixedCapabilityReader(canSave: true),
      commandReader: fixture.commandReader,
      destinationResolver: destination,
      podcastWriter: writer,
      itemDetailReader: detail,
      attemptStore: fixture.attemptStore,
      nativeSubscriptions: fixture.subscriptions,
      foregroundConvergenceDelays: foregroundConvergenceDelays)
  }
}

/// A writer whose enqueues fail as `failures` says (`nil` succeeds), in order, then succeed. This
/// double never removes; a removal reaching it fails as an unavailable writer would.
private func makeBatchWriter(
  failures: [WriterFailure?]
) -> FakeNativeEpisodeServerSavePodcastWriting {
  let writer = FakeNativeEpisodeServerSavePodcastWriting()
  writer.stubCreate(.success("created"))
  writer.stubEnqueueSequence(
    failures.map { failure -> Result<Void, any Error> in
      switch failure {
      case nil: return .success(())
      case .api(let error)?: return .failure(error)
      case .podcast(let error)?: return .failure(error)
      case .cancelled?: return .failure(CancellationError())
      }
    })
  writer.stubRemove(.failure(RemovalUnsupportedByWriter()))
  return writer
}

extension CoordinatorDetailPlan {
  fileprivate var result: Result<ItemDetail, any Error> {
    switch self {
    case .success(let detail): return .success(detail)
    case .failure(let error): return .failure(error)
    case .cancelled: return .failure(CancellationError())
    }
  }
}

/// Records the credential account of every item-detail read. Read `n` (counting from 1) first runs
/// `beforeCall[n]` and then answers with `plans[n - 1]`, the last plan repeating.
private func makeAccountRecordingDetailReader(
  plans: [CoordinatorDetailPlan],
  beforeCall: [Int: @Sendable () async -> Void] = [:]
) -> FakeNativeEpisodeServerSaveItemDetailReading {
  let reader = FakeNativeEpisodeServerSaveItemDetailReading(plans: plans.map(\.result))
  reader.stubBeforeReturn { number, _ in
    if let hook = beforeCall[number] { await hook() }
  }
  return reader
}
