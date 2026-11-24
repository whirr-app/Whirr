import ABSApi
import Foundation
import GRDB
import Testing

@testable import Persistence
@testable import SyncEngine

/// Uses the production attempt store against an in-memory database. The other boundaries are
/// actor-backed seams so every test can assert the order and count of mutating calls without
/// constructing an HTTP client.
@Suite(.timeLimit(.minutes(1))) struct NativeEpisodeServerSaveCoordinatorTests {

  @Test func capabilityFalseBlocksSaveBeforeAnyAttemptOrNetworkSend() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: false),
      destination: StubDestinationResolver(.reuse(serverItemID: "item")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .failed(attemptID: nil, state: .failed, category: .permissionChanged))
    #expect(await writer.counts() == (0, 0))
    let attempts = try fixture.baseStore.fetchAttempts(
      accountId: fixture.accountID,
      feedId: fixture.command.feedId,
      episodeId: fixture.command.episodeId
    )
    #expect(attempts.isEmpty)
  }

  @Test(arguments: [
    NativeEpisodeServerSaveCommandReaderError.nativeSubscriptionsDisabled,
    NativeEpisodeServerSaveCommandReaderError.credentialedFeed,
    NativeEpisodeServerSaveCommandReaderError.episodeNotFound,
  ])
  func readerIneligibilityStopsBeforeAnyNetworkSend(
    _ error: NativeEpisodeServerSaveCommandReaderError
  ) async throws {
    let fixture = try await SaveFixture.make()
    await fixture.commandReader.setError(error)
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "item")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    let expected: NativeEpisodeServerSaveErrorCategory =
      switch error {
      case .nativeSubscriptionsDisabled: .unsubscribed
      case .credentialedFeed: .credentialedFeed
      default: .missingEpisode
      }

    #expect(result == .failed(attemptID: nil, state: .failed, category: expected))
    #expect(await writer.counts() == (0, 0))
    let attempts = try fixture.baseStore.fetchAttempts(
      accountId: fixture.accountID,
      feedId: fixture.command.feedId,
      episodeId: fixture.command.episodeId
    )
    #expect(attempts.isEmpty)
  }

  @Test func matchedOneReusesShowAndEnqueuesExactlyOnce() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "existing-show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .accepted(attemptID: 1, serverItemID: "existing-show"))
    #expect(await writer.counts() == (0, 1))
    let record = try #require(try await fixture.baseStore.fetchAttemptAsync(id: 1))
    #expect(record.state == .accepted)
    #expect(record.serverItemId == "existing-show")
    #expect(record.preflightPresence == .absentBeforeRequest)
  }

  @Test(arguments: [
    NativeEpisodeServerSaveChoicePrompt.existing(candidates: [
      NativeEpisodeServerSaveExistingChoice(serverItemID: "one", displayName: "One"),
      NativeEpisodeServerSaveExistingChoice(serverItemID: "two", displayName: "Two"),
    ]),
    NativeEpisodeServerSaveChoicePrompt.libraryAndFolder(libraries: [
      NativeEpisodeServerSaveLibraryChoice(
        libraryID: "library",
        displayName: "Library",
        folders: [NativeEpisodeServerSaveFolderChoice(folderID: "folder", displayName: "Folder")])
    ]),
  ])
  func unresolvedDestinationNeedsChoiceWithoutMutatingSends(
    _ prompt: NativeEpisodeServerSaveChoicePrompt
  ) async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.needsChoice(prompt)),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .needsChoice(attemptID: 1, prompt: prompt))
    #expect(await writer.counts() == (0, 0))
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1)?.state == .preparing)
  }

  /// A destination sheet that is dismissed, or an app that is killed while resolving, leaves the
  /// row in preparing with no flight behind it. Save stays offered for that row, so a second tap
  /// must resume it rather than open a second attempt for the same episode.
  @Test func savingAgainOnAPreparingRowResumesItWithoutASecondAttempt() async throws {
    let prompt = NativeEpisodeServerSaveChoicePrompt.libraryAndFolder(libraries: [
      NativeEpisodeServerSaveLibraryChoice(
        libraryID: "library",
        displayName: "Library",
        folders: [NativeEpisodeServerSaveFolderChoice(folderID: "folder", displayName: "Folder")])
    ])
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.needsChoice(prompt)),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let first = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    #expect(first == .needsChoice(attemptID: 1, prompt: prompt))

    let second = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(second == .needsChoice(attemptID: 1, prompt: prompt))
    let attempts = try await fixture.baseStore.fetchAttemptsAsync(
      accountId: fixture.accountID, feedId: fixture.command.feedId,
      episodeId: fixture.command.episodeId)
    #expect(attempts.count == 1)
    #expect(attempts.first?.state == .preparing)
    #expect(await writer.counts() == (0, 0))
  }

  @Test func createPersistsEveryCheckpointBeforeTheFollowingNetworkStep() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(
      trace: fixture.trace,
      createPlan: .success("created-show"),
      enqueuePlan: .success)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.create(testDestination())),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .accepted(attemptID: 1, serverItemID: "created-show"))
    #expect(await writer.counts() == (1, 1))
    #expect(
      await fixture.trace.values() == [
        "persist.preflight.absentBeforeRequest",
        "persist.state.creatingShow",
        "send.create",
        "persist.item.created-show",
        "persist.state.requestingDownload",
        "send.enqueue",
        "persist.state.accepted",
      ])
  }

  @Test func createForwardsOnlyNewShowArtwork() async throws {
    let artworkURL = URL(string: "https://images.example/show.png?token=opaque")!
    let fixture = try await SaveFixture.make(command: makeCommand(feedArtworkURL: artworkURL))
    let writer = StubPodcastWriter(
      trace: fixture.trace,
      createPlan: .success("created-show"),
      enqueuePlan: .success)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.create(testDestination())),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem())))

    let result = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .accepted(attemptID: 1, serverItemID: "created-show"))
    #expect(await writer.recordedCreateRequest()?.imageURL == artworkURL.absoluteString)
    #expect(await writer.counts() == (1, 1))
  }

  @Test func existingShowDoesNotReceiveArtworkOrCreateRequest() async throws {
    let fixture = try await SaveFixture.make(
      command: makeCommand(feedArtworkURL: URL(string: "https://images.example/show.png")!))
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "existing-show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem())))

    let result = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .accepted(attemptID: 1, serverItemID: "existing-show"))
    #expect(await writer.recordedCreateRequest() == nil)
    #expect(await writer.counts() == (0, 1))
  }

  @Test func invalidCommandArtworkIsOmittedWithoutChangingCreateAndEnqueue() async throws {
    let fixture = try await SaveFixture.make(
      command: makeCommand(feedArtworkURL: URL(string: "https://127.0.0.1/show.png")!))
    let writer = StubPodcastWriter(
      trace: fixture.trace,
      createPlan: .success("created-show"),
      enqueuePlan: .success)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.create(testDestination())),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem())))

    let result = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .accepted(attemptID: 1, serverItemID: "created-show"))
    #expect(await writer.recordedCreateRequest()?.imageURL == nil)
    #expect(await writer.counts() == (1, 1))
  }

  @Test func createFailureAfterResponseRetainsThePersistedItemID() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(
      trace: fixture.trace,
      createPlan: .success("created-show"),
      enqueuePlan: .failure(.api(.serverFailure(statusCode: 500))))
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.create(testDestination())),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    let record = try #require(try await fixture.baseStore.fetchAttemptAsync(id: 1))

    #expect(result == .uncertain(attemptID: 1, state: .uncertain, category: .serverFailure))
    #expect(record.serverItemId == "created-show")
    #expect(record.state == .uncertain)
    #expect(await writer.counts() == (1, 1))
  }

  @Test func malformedCreateSuccessBecomesCreateUncertainWithoutEnqueue() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(
      trace: fixture.trace,
      createPlan: .success("   "),
      enqueuePlan: .success)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.create(testDestination())),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .uncertain(attemptID: 1, state: .createUncertain, category: .malformedResponse))
    #expect(await writer.counts() == (1, 0))
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1)?.serverItemId == nil)
  }

  @Test func incompleteEpisodeListFailsBeforeAnyMutatingSend() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(incompleteNativeEpisodeItem()))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .failed(attemptID: 1, state: .failed, category: .incompleteEpisodeList))
    #expect(await writer.counts() == (0, 0))
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1)?.state == .failed)
  }

  /// Decoding drops an episode element without an id and records the drop only in the read's
  /// diagnostics. The list left behind looks like one without this episode, so the preflight
  /// must refuse it rather than record absence and enqueue a second copy.
  @Test func preflightRefusesAListThatLostAnEpisodeInDecoding() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: SequencedItemDetailReader([completeItem()], lossyCalls: [1]))

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .failed(attemptID: 1, state: .failed, category: .incompleteEpisodeList))
    #expect(await writer.counts() == (0, 0))
    let record = try #require(try await fixture.baseStore.fetchAttemptAsync(id: 1))
    #expect(record.state == .failed)
    #expect(record.preflightPresence == nil)
  }

  @Test func preflightRefusesAListWithDuplicateEpisodeIDs() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(duplicateEpisodeIDItem())))

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .failed(attemptID: 1, state: .failed, category: .incompleteEpisodeList))
    #expect(await writer.counts() == (0, 0))
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1)?.preflightPresence == nil)
  }

  /// The other half of the rule: a list that decoded whole, read with diagnostics attached, still
  /// proves absence and lets the save enqueue.
  @Test func preflightReadsWithDiagnosticsAndACleanListStillProvesAbsence() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(trace: fixture.trace)
    let detail = SequencedItemDetailReader([completeItem()])
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: detail)

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    await coordinator.lastConvergence?.value

    #expect(result == .accepted(attemptID: 1, serverItemID: "show"))
    #expect(await writer.counts() == (0, 1))
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1)?.preflightPresence == .absentBeforeRequest)
    // The preflight and the post-accept look both attached diagnostics to their reads.
    #expect(await detail.callCount() == 2)
    #expect(await detail.callCountWithoutDiagnostics() == 0)
  }

  /// The lossy-list tests across the save suites rely on this helper leaving the one entry a
  /// real dropped element leaves; an extra or missing entry would let them pass for another reason.
  @Test func recordDroppedEpisodeLeavesExactlyOneDiagnostic() {
    let diagnostics = DecodeDiagnostics()
    recordDroppedEpisode(into: diagnostics)
    #expect(diagnostics.entries.count == 1)
  }

  /// The stricter evidence gates absence only. A list that lost some other element in decoding but
  /// still contains this episode proves it is already on the server, so a show with one malformed
  /// element can still confirm saves instead of failing them forever.
  @Test func preflightFindsAnEpisodeInALossyListAsAlreadyPresent() async throws {
    let fixture = try await SaveFixture.make()
    let episode = PodcastEpisode(
      id: "server-episode",
      title: "A different title",
      guid: fixture.command.episodeGUID,
      enclosureURL: nil,
      contentUrl: "/api/items/show/episodes/server-episode",
      mimeType: "audio/mpeg",
      duration: nil,
      publishedAt: nil)
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: SequencedItemDetailReader([completeItem(episodes: [episode])], lossyCalls: [1]))

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .alreadyPresent(attemptID: 1, serverItemID: "show"))
    #expect(await writer.counts() == (0, 0))
    let record = try #require(try await fixture.baseStore.fetchAttemptAsync(id: 1))
    #expect(record.preflightPresence == .preExisting)
    #expect(record.serverEpisodeId == "server-episode")
  }

  @Test func preExistingByGUIDRecordsProvenanceAndSkipsEnqueue() async throws {
    let fixture = try await SaveFixture.make()
    let episode = PodcastEpisode(
      id: "server-episode",
      title: "A different title",
      guid: fixture.command.episodeGUID,
      enclosureURL: nil,
      contentUrl: "/api/items/show/episodes/server-episode",
      mimeType: "audio/mpeg",
      duration: nil,
      publishedAt: nil)
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem(episodes: [episode])))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .alreadyPresent(attemptID: 1, serverItemID: "show"))
    #expect(await writer.counts() == (0, 0))
    let record = try #require(try await fixture.baseStore.fetchAttemptAsync(id: 1))
    #expect(record.preflightPresence == .preExisting)
    #expect(record.state == .confirmed)
    #expect(record.serverItemId == "show")
    #expect(record.serverEpisodeId == "server-episode")
    #expect(record.errorCategory == nil)

    // A second tap coalesces into the finished attempt and never starts a request.
    let again = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    #expect(again == .inProgress(attemptID: 1, state: .confirmed, serverItemID: "show"))
    #expect(await writer.counts() == (0, 0))
  }

  @Test func preflightUsesNormalizedEnclosureURLOnlyWhenGUIDIsAbsent() async throws {
    let command = makeCommand(guid: nil, enclosureURL: "https://media.example/episode.mp3")
    let fixture = try await SaveFixture.make(command: command)
    let matchingEpisode = PodcastEpisode(
      id: "server-episode",
      title: "Unrelated title",
      guid: "server-guid",
      enclosureURL: "HTTPS://MEDIA.EXAMPLE:443/episode.mp3/",
      contentUrl: "/api/items/show/episodes/server-episode",
      mimeType: "audio/mpeg",
      duration: nil,
      publishedAt: nil)
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem(episodes: [matchingEpisode])))
    )

    let result = await coordinator.save(feedId: command.feedId, episodeId: command.episodeId)

    #expect(result == .alreadyPresent(attemptID: 1, serverItemID: "show"))
    #expect(await writer.counts() == (0, 0))
  }

  @Test func preflightNeverMatchesTitleOrServerContentURL() async throws {
    let command = makeCommand(guid: nil, enclosureURL: "https://media.example/episode.mp3")
    let fixture = try await SaveFixture.make(command: command)
    let nonMatchingEpisode = PodcastEpisode(
      id: "server-episode",
      title: command.episodeTitle,
      guid: nil,
      enclosureURL: nil,
      contentUrl: command.enclosureURL.absoluteString,
      mimeType: "audio/mpeg",
      duration: nil,
      publishedAt: nil)
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem(episodes: [nonMatchingEpisode])))
    )

    let result = await coordinator.save(feedId: command.feedId, episodeId: command.episodeId)

    #expect(result == .accepted(attemptID: 1, serverItemID: "show"))
    #expect(await writer.counts() == (0, 1))
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1)?.preflightPresence == .absentBeforeRequest)
  }

  /// A source GUID that fails to match by equality must not fall back to URL matching: a server
  /// row that independently reuses the same hosting URL under a different GUID is a different
  /// episode, not a re-import of this one.
  @Test func preflightRejectsConflictingServerGUIDWithMatchingEnclosureURL() async throws {
    let fixture = try await SaveFixture.make()
    let conflictingEpisode = PodcastEpisode(
      id: "server-episode",
      title: "Unrelated title",
      guid: "a-different-guid",
      enclosureURL: fixture.command.enclosureURL.absoluteString,
      contentUrl: "/api/items/show/episodes/server-episode",
      mimeType: "audio/mpeg",
      duration: nil,
      publishedAt: nil)
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem(episodes: [conflictingEpisode])))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .accepted(attemptID: 1, serverItemID: "show"))
    #expect(await writer.counts() == (0, 1))
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1)?.preflightPresence == .absentBeforeRequest)
  }

  /// Two server rows carrying the source GUID prove the episode is already there, just not which
  /// row is ours. Asking the server to download it again would add a third copy, so the save stops
  /// before any mutating send and records no presence.
  @Test func preflightStopsOnDuplicateMatchingServerGUIDCandidates() async throws {
    let fixture = try await SaveFixture.make()
    let candidates = [
      PodcastEpisode(
        id: "server-episode-a", title: "Candidate A", guid: fixture.command.episodeGUID,
        enclosureURL: nil, contentUrl: "/api/items/show/episodes/server-episode-a",
        mimeType: "audio/mpeg", duration: nil, publishedAt: nil),
      PodcastEpisode(
        id: "server-episode-b", title: "Candidate B", guid: fixture.command.episodeGUID,
        enclosureURL: nil, contentUrl: "/api/items/show/episodes/server-episode-b",
        mimeType: "audio/mpeg", duration: nil, publishedAt: nil),
    ]
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem(episodes: candidates)))
    )

    let result = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .failed(attemptID: 1, state: .failed, category: .incompleteEpisodeList))
    #expect(await writer.counts() == (0, 0))
    let record = try #require(try await fixture.baseStore.fetchAttemptAsync(id: 1))
    #expect(record.state == .failed)
    #expect(record.preflightPresence == nil)
  }

  /// A server row without a GUID is a partial re-import the folder watcher can create after a
  /// restart; URL-only equality must never treat it as the source episode.
  @Test func preflightRejectsServerEpisodeWithNullGUIDViaEnclosureURLFallback() async throws {
    let command = makeCommand(guid: nil, enclosureURL: "https://media.example/episode.mp3")
    let fixture = try await SaveFixture.make(command: command)
    let nullGUIDEpisode = PodcastEpisode(
      id: "server-episode",
      title: "Unrelated title",
      guid: nil,
      enclosureURL: "https://media.example/episode.mp3",
      contentUrl: "/api/items/show/episodes/server-episode",
      mimeType: "audio/mpeg",
      duration: nil,
      publishedAt: nil)
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem(episodes: [nullGUIDEpisode])))
    )

    let result = await coordinator.save(feedId: command.feedId, episodeId: command.episodeId)

    #expect(result == .accepted(attemptID: 1, serverItemID: "show"))
    #expect(await writer.counts() == (0, 1))
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1)?.preflightPresence == .absentBeforeRequest)
  }

  /// Two server episodes that both qualify for the same enclosure URL are ambiguous; picking
  /// either one arbitrarily would risk attaching provenance to the wrong episode.
  @Test func preflightRejectsAmbiguousEnclosureURLCandidates() async throws {
    let command = makeCommand(guid: nil, enclosureURL: "https://media.example/episode.mp3")
    let fixture = try await SaveFixture.make(command: command)
    let candidateA = PodcastEpisode(
      id: "server-episode-a",
      title: "Candidate A",
      guid: "guid-a",
      enclosureURL: "https://media.example/episode.mp3",
      contentUrl: "/api/items/show/episodes/server-episode-a",
      mimeType: "audio/mpeg",
      duration: nil,
      publishedAt: nil)
    let candidateB = PodcastEpisode(
      id: "server-episode-b",
      title: "Candidate B",
      guid: "guid-b",
      enclosureURL: "https://media.example/episode.mp3",
      contentUrl: "/api/items/show/episodes/server-episode-b",
      mimeType: "audio/mpeg",
      duration: nil,
      publishedAt: nil)
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem(episodes: [candidateA, candidateB])))
    )

    let result = await coordinator.save(feedId: command.feedId, episodeId: command.episodeId)

    #expect(result == .accepted(attemptID: 1, serverItemID: "show"))
    #expect(await writer.counts() == (0, 1))
    #expect(try await fixture.baseStore.fetchAttemptAsync(id: 1)?.preflightPresence == .absentBeforeRequest)
  }

  @Test(arguments: [
    (
      APIError.badRequest, NativeEpisodeServerSaveErrorCategory.invalidDestination,
      NativeEpisodeServerSaveAttemptState.failed
    ),
    (
      APIError.forbidden, NativeEpisodeServerSaveErrorCategory.permissionChanged,
      NativeEpisodeServerSaveAttemptState.failed
    ),
    (APIError.notFound, NativeEpisodeServerSaveErrorCategory.staleIdentity, NativeEpisodeServerSaveAttemptState.failed),
    (
      APIError.serverFailure(statusCode: 500), NativeEpisodeServerSaveErrorCategory.serverFailure,
      NativeEpisodeServerSaveAttemptState.uncertain
    ),
    (APIError.transport, NativeEpisodeServerSaveErrorCategory.transport, NativeEpisodeServerSaveAttemptState.uncertain),
  ])
  func enqueueErrorMapsToSanitizedState(
    error: APIError,
    category: NativeEpisodeServerSaveErrorCategory,
    state: NativeEpisodeServerSaveAttemptState
  ) async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(
      trace: fixture.trace,
      enqueuePlan: .failure(.api(error)))
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    if state == .uncertain {
      #expect(result == .uncertain(attemptID: 1, state: state, category: category))
    } else {
      #expect(result == .failed(attemptID: 1, state: .failed, category: category))
    }
    #expect(await writer.counts() == (0, 1))
  }

  @Test func cancellationBeforeEnqueueIsOrdinaryFailureWithoutSend() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.cancelled)
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .failed(attemptID: 1, state: .failed, category: .cancelled))
    #expect(await writer.counts() == (0, 0))
  }

  @Test func cancellationAfterEnqueueIsUncertain() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(
      trace: fixture.trace,
      enqueuePlan: .failure(.cancelled))
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .uncertain(attemptID: 1, state: .uncertain, category: .cancelled))
    #expect(await writer.counts() == (0, 1))
  }

  @Test func uncertainOutcomeIsNotAutomaticallyRetried() async throws {
    let fixture = try await SaveFixture.make()
    let writer = StubPodcastWriter(
      trace: fixture.trace,
      enqueuePlan: .failure(.api(.transport)))
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let first = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    let second = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(first == .uncertain(attemptID: 1, state: .uncertain, category: .transport))
    #expect(second == first)
    #expect(await writer.counts() == (0, 1))
  }

  @Test func concurrentDuplicateSavesCoalesceToOneFlightAndOneEnqueue() async throws {
    let fixture = try await SaveFixture.make()
    let gate = BlockingGate()
    let writer = StubPodcastWriter(
      trace: fixture.trace,
      enqueueGate: gate)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let firstTask = Task {
      await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    }
    await gate.waitUntilEntered()
    let secondTask = Task {
      await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    }
    await gate.release()

    let first = await firstTask.value
    let second = await secondTask.value
    #expect(first == .accepted(attemptID: 1, serverItemID: "show"))
    #expect(second == first)
    #expect(await writer.counts() == (0, 1))
  }

  /// A coalesced flight's task must survive one departing waiter as long as another is still
  /// attached: only the last waiter's departure may cancel the shared work. Exercised on the
  /// primitive, as racing two `save()` calls cannot deterministically observe actor-level
  /// coalescing from outside the actor.
  @Test func flightTaskCancelsOnlyOnceTheLastWaiterHasLeft() async throws {
    // `Task.isCancelled` is a metadata flag decoupled from the task's own progress, so the body
    // needs no sleep to stand in for "still running". Only `FlightTask`'s waiter bookkeeping is
    // under test here.
    let task = Task<NativeEpisodeServerSaveOutcome, Never> {
      .failed(attemptID: nil, state: .failed, category: .cancelled)
    }
    let flight = NativeEpisodeServerSaveCoordinator.FlightTask(id: 1, task: task)

    flight.addWaiter()
    flight.addWaiter()
    flight.removeWaiterCancellingIfAbandoned()
    #expect(task.isCancelled == false)

    flight.removeWaiterCancellingIfAbandoned()
    #expect(task.isCancelled)
  }

  @Test func accountReplacementWithSameRowIDCannotCompleteFlight() async throws {
    let fixture = try await SaveFixture.make()
    let replacement = try await fixture.replacementAccount(clientUUID: "replacement-client")
    let hook: @Sendable () async -> Void = {
      try? await fixture.database.writeAsync { db in
        try db.execute(
          sql: "UPDATE account SET clientUUID = ? WHERE id = ?",
          arguments: [replacement.clientUUID, fixture.accountID])
      }
      await fixture.accountReader.replace(replacement)
    }
    let writer = StubPodcastWriter(trace: fixture.trace)
    let detail = StubItemDetailReader(.success(completeItem()), beforeReturn: hook)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: detail
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .failed(attemptID: 1, state: .preparing, category: .accountReplaced))
    #expect(await writer.counts() == (0, 0))
  }

  /// `NativeEpisodeServerSaveFlightKey` is only `{feedID, episodeID}`, so a save issued under the replacement account is
  /// queued behind the flight started under the old one instead of reading its own account first.
  /// While that flight is held, the first caller's account is replaced. Neither caller may report
  /// success, and the replacement account must not cause a server write.
  @Test func accountReplacementWhileAFlightIsHeldNeverLetsTheSecondCallerSucceed() async throws {
    let fixture = try await SaveFixture.make()
    let replacement = try await fixture.replacementAccount(clientUUID: "replacement-client")
    let reachedDetailRead = BlockingGate()
    let releaseFlight = BlockingGate()
    let hold: @Sendable () async -> Void = {
      await reachedDetailRead.markEntered()
      await releaseFlight.waitUntilReleased()
    }
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()), beforeReturn: hold)
    )

    let firstTask = Task {
      await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    }
    await reachedDetailRead.waitUntilEntered()
    try await fixture.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE account SET clientUUID = ? WHERE id = ?",
        arguments: [replacement.clientUUID, fixture.accountID])
    }
    await fixture.accountReader.replace(replacement)

    // Issued while the first flight is held. Whether it reaches the coordinator before the release
    // (and waits on the held flight) or after (and finds the map empty), `startSerializedFlight`
    // then runs its own save under the replacement account, so the outcome below holds for both
    // interleavings; the test deliberately does not depend on which one occurs.
    let secondTask = Task {
      await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    }
    await releaseFlight.release()

    let first = await firstTask.value
    let second = await secondTask.value

    // The held flight fails closed before any request. The second caller then re-runs under the
    // replacement account, but the still-active `.preparing` attempt row carries the old account's
    // fence, so the attempt store refuses to resume it before any send.
    #expect(first == .failed(attemptID: 1, state: .preparing, category: .accountReplaced))
    #expect(second == .failed(attemptID: nil, state: .failed, category: .accountReplaced))
    #expect(await writer.counts() == (0, 0))
  }

  @Test func sameServerReauthenticationDoesNotInvalidateTheFence() async throws {
    let fixture = try await SaveFixture.make()
    let hook: @Sendable () async -> Void = {
      try? await fixture.database.writeAsync { db in
        try db.execute(
          sql: "UPDATE account SET serverVersion = ? WHERE id = ?",
          arguments: ["next-version", fixture.accountID])
      }
    }
    let writer = StubPodcastWriter(trace: fixture.trace)
    let detail = StubItemDetailReader(.success(completeItem()), beforeReturn: hook)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: detail
    )

    let result = await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .accepted(attemptID: 1, serverItemID: "show"))
    #expect(await writer.counts() == (0, 1))
  }

  @Test func outcomeDiagnosticsContainNoSourceURLPathOrCredential() async throws {
    let command = makeCommand(
      guid: nil,
      enclosureURL: "https://private-media.example/episode.mp3?token=secret")
    let fixture = try await SaveFixture.make(command: command)
    let writer = StubPodcastWriter(
      trace: fixture.trace,
      enqueuePlan: .failure(.api(.transport)))
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()))
    )

    let result = await coordinator.save(feedId: command.feedId, episodeId: command.episodeId)
    let diagnostics = result.description + String(reflecting: result)

    #expect(diagnostics.contains("private-media.example") == false)
    #expect(diagnostics.contains("episode.mp3") == false)
    #expect(diagnostics.contains("secret") == false)
    #expect(diagnostics.contains("/api/") == false)

    let errors = [
      NativeEpisodeServerSaveCommandReaderError.invalidEnclosureURL(.credentialsNotAllowed)
        .description,
      String(reflecting: PodcastWriteError.credentialedURL),
      APIError.transport.description,
    ]
    for error in errors {
      #expect(error.contains("private-media.example") == false)
      #expect(error.contains("episode.mp3") == false)
      #expect(error.contains("secret") == false)
      #expect(error.contains("/api/") == false)
    }
  }

  /// A fence failure at the checkpoint immediately before a durable write aborts that write: the
  /// preflight presence is never recorded, and no request follows it. Only the account reader is
  /// replaced, so the store's own account fence cannot mask a write the coordinator should not
  /// have attempted.
  @Test func fenceFailureAtThePreflightCheckpointAbortsTheWriteAndTheEnqueue() async throws {
    let fixture = try await SaveFixture.make()
    let replacement = try await fixture.replacementAccount(clientUUID: "replacement-client")
    let hook: @Sendable () async -> Void = {
      await fixture.accountReader.replace(replacement)
    }
    let writer = StubPodcastWriter(trace: fixture.trace)
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: writer,
      detail: StubItemDetailReader(.success(completeItem()), beforeReturn: hook)
    )

    let result = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)

    #expect(result == .failed(attemptID: 1, state: .preparing, category: .accountReplaced))
    #expect(await writer.counts() == (0, 0))
    let record = try #require(try await fixture.baseStore.fetchAttemptAsync(id: 1))
    #expect(record.state == .preparing)
    #expect(record.preflightPresence == nil)
  }

  // MARK: - Construction

  /// Tests opt out of the foreground convergence schedule by default: its retries would keep
  /// touching a fixture after the assertion that ended the test.
  func makeCoordinator(
    fixture: SaveFixture,
    capability: any ServerPodcastMutationCapabilityReading,
    destination: any NativeEpisodeServerSaveDestinationResolving,
    writer: any NativeEpisodeServerSavePodcastWriting,
    detail: any NativeEpisodeServerSaveItemDetailReading,
    foregroundConvergenceDelays: [Duration] = []
  ) -> NativeEpisodeServerSaveCoordinator {
    NativeEpisodeServerSaveCoordinator(
      accountReader: fixture.accountReader,
      capabilityReader: capability,
      commandReader: fixture.commandReader,
      destinationResolver: destination,
      podcastWriter: writer,
      itemDetailReader: detail,
      attemptStore: fixture.attemptStore,
      nativeSubscriptions: fixture.subscriptions,
      foregroundConvergenceDelays: foregroundConvergenceDelays)
  }
}

@Suite(.timeLimit(.minutes(1))) struct NativeEpisodeServerSaveForegroundConvergenceTests {
  /// The server answers the enqueue before it has downloaded anything, so the first look after
  /// acceptance finds the list without the episode. The schedule keeps looking until the episode
  /// lands and the row is confirmed, all without a relaunch.
  @Test func acceptedAttemptConvergesToConfirmedOnALaterForegroundLook() async throws {
    let fixture = try await SaveFixture.make()
    let landed = PodcastEpisode(
      id: "server-episode",
      title: "Native Episode",
      guid: fixture.command.episodeGUID,
      enclosureURL: nil,
      contentUrl: "/api/items/show/episodes/server-episode",
      mimeType: "audio/mpeg",
      duration: nil,
      publishedAt: nil)
    // Preflight, the immediate post-accept look, and one scheduled look all see an empty
    // list; the second scheduled look sees the episode.
    let detail = SequencedItemDetailReader(
      [completeItem(), completeItem(), completeItem(), completeItem(episodes: [landed])])
    let coordinator = makeCoordinator(
      fixture: fixture,
      capability: FixedCapabilityReader(canSave: true),
      destination: StubDestinationResolver(.reuse(serverItemID: "show")),
      writer: StubPodcastWriter(trace: fixture.trace),
      detail: detail,
      foregroundConvergenceDelays: [.zero, .zero, .zero, .zero])

    let result = await coordinator.save(
      feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    #expect(result == .accepted(attemptID: 1, serverItemID: "show"))

    // The convergence has ended once its task has, so what it left is final.
    await coordinator.lastConvergence?.value
    let record = try await fixture.baseStore.fetchAttemptAsync(id: 1)
    #expect(record?.state == .confirmed)
    #expect(record?.serverEpisodeId == "server-episode")
    // The schedule stops at confirmation rather than spending its remaining looks.
    #expect(await detail.callCount() == 4)
  }

  @Test func foregroundConvergenceStopsOnConfirmationAndOnOutcomesALaterLookCannotChange() {
    typealias Coordinator = NativeEpisodeServerSaveCoordinator
    #expect(
      Coordinator.foregroundConvergenceContinues(
        after: .confirmed(attemptID: 1, state: .confirmed, serverEpisodeID: "e")) == false)
    #expect(Coordinator.foregroundConvergenceContinues(after: .absent(attemptID: 1, state: .accepted)))
    #expect(
      Coordinator.foregroundConvergenceContinues(after: .absent(attemptID: 1, state: .uncertain))
        == false)
    #expect(
      Coordinator.foregroundConvergenceContinues(
        after: .inconclusive(attemptID: 1, state: .accepted, category: .transport)))
    #expect(
      Coordinator.foregroundConvergenceContinues(
        after: .inconclusive(attemptID: 1, state: .accepted, category: .incompleteEpisodeList)))
    for category in [
      NativeEpisodeServerSaveErrorCategory.accountReplaced, .unsubscribed,
      .missingEpisode, .staleIdentity, .permissionChanged, .cancelled,
    ] {
      #expect(
        Coordinator.foregroundConvergenceContinues(
          after: .inconclusive(attemptID: 1, state: .accepted, category: category)) == false,
        "\(category)")
    }
  }

  private func makeCoordinator(
    fixture: SaveFixture,
    capability: any ServerPodcastMutationCapabilityReading,
    destination: any NativeEpisodeServerSaveDestinationResolving,
    writer: any NativeEpisodeServerSavePodcastWriting,
    detail: any NativeEpisodeServerSaveItemDetailReading,
    foregroundConvergenceDelays: [Duration]
  ) -> NativeEpisodeServerSaveCoordinator {
    NativeEpisodeServerSaveCoordinator(
      accountReader: fixture.accountReader,
      capabilityReader: capability,
      commandReader: fixture.commandReader,
      destinationResolver: destination,
      podcastWriter: writer,
      itemDetailReader: detail,
      attemptStore: fixture.attemptStore,
      nativeSubscriptions: fixture.subscriptions,
      foregroundConvergenceDelays: foregroundConvergenceDelays)
  }

}
