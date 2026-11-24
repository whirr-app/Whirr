import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// A save that created a server show requests one library sync, so the show's item row and
/// fingerprint land without a relaunch. Choosing an existing show, or a save that accepted nothing,
/// requests none.
@MainActor
@Suite("Library sync after a save that created a show", .timeLimit(.minutes(1)))
struct ServerSaveLibrarySyncTests {
  private static let create = ServerPodcastSaveChoice.libraryAndFolder(
    libraryID: "lib", folderID: "folder")
  private static let reuse = ServerPodcastSaveChoice.existing(serverItemID: "candidate")
  private static let prompt = NativeEpisodeServerSaveChoicePrompt.libraryAndFolder(libraries: [])
  private static let accepted = NativeEpisodeServerSaveOutcome.accepted(
    attemptID: 1, serverItemID: "created")

  // MARK: Show screen, single episode

  private func showModel(
    saving: SyncSaveScript, sync: CountingSyncRequester
  ) async -> PodcastShowModel {
    let model = PodcastShowModel(
      itemID: "rss:7", reading: syncSaveReading(),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["9": 9, "10": 10]),
      nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveBatchSaving: saving,
      serverPodcastMutationCapabilityReading: syncSaveCapability(),
      librarySyncRequester: sync)
    await waitUntil { model.episodes.count == 2 && model.serverSave.serverMutationCapability.canSave }
    return model
  }

  @Test("single save: the chosen create requests exactly one sync")
  func singleCreate() async {
    let sync = CountingSyncRequester()
    let saving = SyncSaveScript(single: [
      .needsChoice(attemptID: 1, prompt: Self.prompt), Self.accepted,
    ])
    let model = await showModel(saving: saving, sync: sync)

    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    #expect(await requests(sync) == 0, "a choice prompt created nothing")
    await model.serverSave.chooseSaveDestination(Self.create)

    #expect(await requests(sync, expecting: 1) == 1)
    #expect(await saving.singleChoices == [nil, Self.create])
  }

  @Test("single save: choosing an existing show, or a failed create, requests none")
  func singleNoCreate() async {
    let sync = CountingSyncRequester()
    let reuseModel = await showModel(
      saving: SyncSaveScript(single: [.needsChoice(attemptID: 1, prompt: Self.prompt), Self.accepted]),
      sync: sync)
    await reuseModel.serverSave.saveEpisodeToServer(episodeID: "9")
    await reuseModel.serverSave.chooseSaveDestination(Self.reuse)

    let failedModel = await showModel(
      saving: SyncSaveScript(single: [
        .needsChoice(attemptID: 1, prompt: Self.prompt),
        .failed(attemptID: 1, state: .failed, category: .unknown),
      ]),
      sync: sync)
    await failedModel.serverSave.saveEpisodeToServer(episodeID: "9")
    await failedModel.serverSave.chooseSaveDestination(Self.create)

    #expect(await requests(sync) == 0)
  }

  // MARK: Show screen, batch

  @Test("batch: a create that accepted episodes requests exactly one sync")
  func batchCreate() async {
    let sync = CountingSyncRequester()
    let saving = SyncSaveScript(batches: [
      .init(
        outcomes: [.init(episodeId: 9, outcome: Self.needsChoice)],
        stop: .needsChoice(episodeId: 9, attemptID: 1, prompt: Self.prompt),
        notAttempted: [10], serverItemID: nil),
      .init(
        outcomes: [
          .init(episodeId: 9, outcome: Self.accepted),
          .init(episodeId: 10, outcome: .accepted(attemptID: 2, serverItemID: "created")),
        ],
        stop: .completed, notAttempted: [], serverItemID: "created"),
    ])
    let model = await showModel(saving: saving, sync: sync)

    model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
    await waitUntil { model.serverSave.pendingServerSaveChoice != nil }
    #expect(await requests(sync) == 0)
    await model.serverSave.chooseSaveDestination(Self.create)
    await waitUntil { model.serverSave.batchServerSave == nil }

    #expect(await requests(sync, expecting: 1) == 1)
  }

  @Test("batch: an existing show, or no accepted episode, requests none")
  func batchNoCreate() async {
    let sync = CountingSyncRequester()
    let reuse = await showModel(
      saving: SyncSaveScript(batches: [
        .init(
          outcomes: [.init(episodeId: 9, outcome: Self.needsChoice)],
          stop: .needsChoice(episodeId: 9, attemptID: 1, prompt: Self.prompt),
          notAttempted: [10], serverItemID: nil),
        .init(
          outcomes: [.init(episodeId: 9, outcome: Self.accepted)], stop: .completed,
          notAttempted: [], serverItemID: "candidate"),
      ]),
      sync: sync)
    reuse.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
    await waitUntil { reuse.serverSave.pendingServerSaveChoice != nil }
    await reuse.serverSave.chooseSaveDestination(Self.reuse)
    await waitUntil { reuse.serverSave.batchServerSave == nil }

    let none = await showModel(
      saving: SyncSaveScript(batches: [
        .init(
          outcomes: [.init(episodeId: 9, outcome: Self.needsChoice)],
          stop: .needsChoice(episodeId: 9, attemptID: 1, prompt: Self.prompt),
          notAttempted: [10], serverItemID: nil),
        .init(
          outcomes: [
            .init(
              episodeId: 9,
              outcome: .failed(attemptID: 1, state: .failed, category: .unknown))
          ],
          stop: .completed, notAttempted: [], serverItemID: nil),
      ]),
      sync: sync)
    none.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
    await waitUntil { none.serverSave.pendingServerSaveChoice != nil }
    await none.serverSave.chooseSaveDestination(Self.create)
    await waitUntil { none.serverSave.batchServerSave == nil }

    #expect(await requests(sync) == 0)
  }

  // MARK: Episode card

  private func cardModel(
    saving: SyncSaveScript, sync: CountingSyncRequester
  ) -> PodcastEpisodeCardModel {
    PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9", reading: syncSaveReading(),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["9": 9]),
      nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: syncSaveCapability(),
      librarySyncRequester: sync)
  }

  @Test("card: a chosen create requests one sync; an existing show or a failure requests none")
  func cardSave() async {
    let sync = CountingSyncRequester()
    let create = cardModel(
      saving: SyncSaveScript(single: [.needsChoice(attemptID: 1, prompt: Self.prompt), Self.accepted]),
      sync: sync)
    await create.saveEpisodeToServer()
    #expect(await requests(sync) == 0)
    await create.chooseSaveDestination(Self.create)
    #expect(await requests(sync, expecting: 1) == 1)

    let reuse = cardModel(
      saving: SyncSaveScript(single: [.needsChoice(attemptID: 1, prompt: Self.prompt), Self.accepted]),
      sync: sync)
    await reuse.saveEpisodeToServer()
    await reuse.chooseSaveDestination(Self.reuse)

    let failed = cardModel(
      saving: SyncSaveScript(single: [
        .needsChoice(attemptID: 1, prompt: Self.prompt),
        .failed(attemptID: 1, state: .failed, category: .unknown),
      ]),
      sync: sync)
    await failed.saveEpisodeToServer()
    await failed.chooseSaveDestination(Self.create)

    #expect(await requests(sync, expecting: 1) == 1, "only the create counted")
  }

  @Test("the coordinator requester forwards to the existing refresh entry")
  func requesterUsesRefresh() async {
    let sync = FakeSyncCoordinating()
    await CoordinatorLibrarySyncRequester(sync: sync).requestLibrarySync()
    #expect(sync.refreshCount == 1)
  }

  private static let needsChoice = NativeEpisodeServerSaveOutcome.needsChoice(
    attemptID: 1, prompt: prompt)
}

// MARK: - Fakes

/// The request is sent from an unawaited task, so wait for the expected count and then for the
/// count to stop changing before reading it.
private func requests(_ sync: CountingSyncRequester, expecting expected: Int = 0) async -> Int {
  if expected > 0 {
    await waitUntil("library sync requested") { await sync.count >= expected }
  }
  await awaitQuiescence("library sync request count") { String(await sync.count) }
  return await sync.count
}

private actor CountingSyncRequester: LibrarySyncRequesting {
  private(set) var count = 0
  func requestLibrarySync() async { count += 1 }
}

private func syncSaveReading() -> FakePodcastReading {
  FakePodcastReading(
    episodes: ["9", "10"].map {
      PodcastEpisodeSummary(
        id: $0, title: $0, subtitle: nil, episodeDescription: nil, seasonNumber: nil,
        episodeNumber: nil, episodeType: nil, durationSeconds: 120, sizeBytes: nil,
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000), progressSeconds: 0,
        isPlayed: false, isFinished: false, downloadStatus: .notDownloaded,
        isAvailableOnServer: true)
    })
}

private func syncSaveCapability() -> FakeServerPodcastMutationCapabilityReading {
  FakeServerPodcastMutationCapabilityReading(canSave: true, canRemove: false)
}

// Kept: one script serves both `NativeEpisodeServerSaving` and
// `NativeEpisodeServerSaveBatchSaving`, and no shared fake covers the batch protocol.
/// Plays back scripted single and batch outcomes in order, recording the choices it was given.
private actor SyncSaveScript: NativeEpisodeServerSaving, NativeEpisodeServerSaveBatchSaving {
  private var single: [NativeEpisodeServerSaveOutcome]
  private var batches: [NativeEpisodeServerSaveBatchResult]
  private(set) var singleChoices: [ServerPodcastSaveChoice?] = []
  private(set) var batchChoices: [ServerPodcastSaveChoice?] = []

  init(
    single: [NativeEpisodeServerSaveOutcome] = [],
    batches: [NativeEpisodeServerSaveBatchResult] = []
  ) {
    self.single = single
    self.batches = batches
  }

  func save(feedId: Int64, episodeId: Int64, choice: ServerPodcastSaveChoice?) async
    -> NativeEpisodeServerSaveOutcome
  {
    singleChoices.append(choice)
    return single.isEmpty
      ? .failed(attemptID: nil, state: .failed, category: .unknown) : single.removeFirst()
  }

  func remove(attemptID: Int64) async -> NativeEpisodeServerSaveOutcome {
    .failed(attemptID: attemptID, state: .failed, category: .unknown)
  }

  func saveBatch(
    _ request: NativeEpisodeServerSaveBatchRequest,
    cancellation: NativeEpisodeServerSaveBatchCancellationToken,
    onEpisodeOutcome: @escaping @Sendable (NativeEpisodeServerSaveBatchEpisodeOutcome) async -> Void
  ) async -> NativeEpisodeServerSaveBatchResult {
    batchChoices.append(request.choice)
    return batches.isEmpty
      ? NativeEpisodeServerSaveBatchResult(
        outcomes: [], stop: .completed, notAttempted: [], serverItemID: nil)
      : batches.removeFirst()
  }
}
