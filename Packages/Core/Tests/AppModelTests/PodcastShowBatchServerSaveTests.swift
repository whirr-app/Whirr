import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite(.timeLimit(.minutes(1)))
struct PodcastShowBatchServerSaveTests {
  @MainActor
  @Test func batchUsesEligibleEpisodesInFilteredOrderAndShowsProgress() async {
    let saving = RecordingBatchSaving(
      scripts: [
        .init(
          outcomes: [],
          stop: .completed,
          notAttempted: [])
      ])
    let model = makeModel(
      episodes: [summary("9"), summary("10"), summary("11")],
      resolver: StaticNativeEpisodeIDResolving(["9": 9, "10": 10, "11": 11]),
      saving: saving)
    await waitUntil { model.episodes.count == 3 && model.serverSave.serverMutationCapability.canSave }

    model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10", "11"])

    #expect(model.serverSave.batchServerSave?.isWorking == true)
    #expect(model.serverSave.batchServerSave?.progressText == "Saving 0 of 3 to Audiobookshelf\u{2026}")
    #expect(model.serverSave.isBatchServerSaveMember("9"))
    #expect(model.serverSave.isBatchServerSaveMember("10"))
    #expect(model.serverSave.isBatchServerSaveMember("11"))
    #expect(await waitUntil { await saving.requests.count == 1 })
    #expect(await saving.requests.first?.episodeIds == [9, 10, 11])
    #expect(await saving.requests.first?.choice == nil)
  }

  @MainActor
  @Test func requestedAndUncertainEpisodesAreExcludedFromTargets() async {
    let saving = RecordingBatchSaving(
      scripts: [.init(outcomes: [], stop: .completed, notAttempted: [])])
    let model = makeModel(
      episodes: [summary("9"), summary("10"), summary("11")],
      resolver: StaticNativeEpisodeIDResolving(["9": 9, "10": 10, "11": 11]),
      saving: saving)
    await waitUntil { model.episodes.count == 3 && model.serverSave.serverMutationCapability.canSave }
    model.serverSave.serverSaveStatuses["10"] = .requested
    model.serverSave.serverSaveStatuses["11"] = .uncertain(.transport, phase: .save)
    model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10", "11"])

    #expect(await waitUntil { await saving.requests.count == 1 })
    #expect(await saving.requests.first?.episodeIds == [9])
  }

  @MainActor
  @Test func outcomesUpdateOnlyThePerEpisodeMapsAndCompletionSummary() async {
    let saving = RecordingBatchSaving(
      scripts: [
        .init(
          outcomes: [
            .init(
              episodeId: 9,
              outcome: .accepted(attemptID: 4, serverItemID: "show")),
            .init(
              episodeId: 10,
              outcome: .accepted(attemptID: 5, serverItemID: "show")),
            .init(
              episodeId: 11,
              outcome: .failed(
                attemptID: nil, state: .failed, category: .missingEpisode)),
          ],
          stop: .completed,
          notAttempted: [])
      ])
    let model = makeModel(
      episodes: [summary("9"), summary("10"), summary("11")],
      resolver: StaticNativeEpisodeIDResolving(["9": 9, "10": 10, "11": 11]),
      saving: saving)
    await waitUntil { model.episodes.count == 3 && model.serverSave.serverMutationCapability.canSave }
    model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10", "11"])

    #expect(
      await waitUntil {
        model.serverSave.batchServerSave == nil && model.serverSave.batchServerSaveCompletionVersion == 1
      })
    #expect(model.serverSave.serverSaveStatus(for: "9") == .requested)
    #expect(model.serverSave.serverSaveStatus(for: "10") == .requested)
    #expect(model.serverSave.serverSaveStatus(for: "11") == .failed(.missingEpisode, phase: .save))
    #expect(model.serverSave.serverSaveAttemptID(for: "9") == 4)
    #expect(model.serverSave.serverSaveAttemptID(for: "10") == 5)
    #expect(model.serverSave.serverSaveStatus == .none)
    #expect(model.serverSave.serverSaveFeedbackMessage == nil)
    #expect(model.serverSave.serverSaveBannerMessage == "Requested 2; 1 skipped")
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test func needsChoiceRetainsTheBatchAndResumesItsRemainingRows() async {
    let prompt = NativeEpisodeServerSaveChoicePrompt.libraryAndFolder(libraries: [])
    let saving = RecordingBatchSaving(
      scripts: [
        .init(
          outcomes: [
            .init(episodeId: 9, outcome: .needsChoice(attemptID: 5, prompt: prompt))
          ],
          stop: .needsChoice(episodeId: 9, attemptID: 5, prompt: prompt),
          notAttempted: [10, 11]),
        .init(
          outcomes: [
            .init(
              episodeId: 9,
              outcome: .accepted(attemptID: 6, serverItemID: "show")),
            .init(
              episodeId: 10,
              outcome: .accepted(attemptID: 7, serverItemID: "show")),
            .init(
              episodeId: 11,
              outcome: .accepted(attemptID: 8, serverItemID: "show")),
          ],
          stop: .completed,
          notAttempted: []),
      ])
    let model = makeModel(
      episodes: [summary("9"), summary("10"), summary("11")],
      resolver: StaticNativeEpisodeIDResolving(["9": 9, "10": 10, "11": 11]),
      saving: saving)
    await waitUntil { model.episodes.count == 3 && model.serverSave.serverMutationCapability.canSave }
    model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10", "11"])

    #expect(
      await waitUntil {
        model.serverSave.pendingServerSaveChoice?.batchID == model.serverSave.batchServerSave?.id
      })
    #expect(model.serverSave.pendingServerSaveChoice?.episodeCount == 3)
    #expect(model.serverSave.serverSaveStatus(for: "9") == .preparing)
    #expect(model.serverSave.batchServerSave?.phase == .awaitingChoice)
    #expect(model.serverSave.batchServerSaveCompletionVersion == 0)

    let choice = ServerPodcastSaveChoice.libraryAndFolder(libraryID: "library", folderID: "folder")
    await model.serverSave.chooseSaveDestination(choice)
    #expect(
      await waitUntil {
        model.serverSave.batchServerSave == nil && model.serverSave.batchServerSaveCompletionVersion == 1
      })
    let requests = await saving.requests
    #expect(requests.count == 2)
    #expect(requests[1].episodeIds == [9, 10, 11])
    #expect(requests[1].choice == choice)
    #expect(model.serverSave.serverSaveBannerMessage == "Requested 3 episodes")
  }

  @MainActor
  @Test func dismissingChoiceDropsTheBatchWithoutCompletion() async {
    let prompt = NativeEpisodeServerSaveChoicePrompt.existing(candidates: [])
    let saving = RecordingBatchSaving(
      scripts: [
        .init(
          outcomes: [
            .init(episodeId: 9, outcome: .needsChoice(attemptID: 5, prompt: prompt))
          ],
          stop: .needsChoice(episodeId: 9, attemptID: 5, prompt: prompt),
          notAttempted: [10, 11])
      ])
    let model = makeModel(
      episodes: [summary("9"), summary("10"), summary("11")],
      resolver: StaticNativeEpisodeIDResolving(["9": 9, "10": 10, "11": 11]),
      saving: saving)
    await waitUntil { model.episodes.count == 3 && model.serverSave.serverMutationCapability.canSave }
    model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10", "11"])
    #expect(await waitUntil { model.serverSave.pendingServerSaveChoice != nil })

    model.serverSave.dismissServerSaveFeedback()

    #expect(model.serverSave.pendingServerSaveChoice == nil)
    #expect(model.serverSave.batchServerSave == nil)
    #expect(model.serverSave.serverSaveStatus(for: "9") == .none)
    #expect(model.serverSave.serverSaveBannerMessage == nil)
    #expect(model.serverSave.batchServerSaveCompletionVersion == 0)
    #expect(await saving.requests.count == 1)
  }

  @MainActor
  @Test func cancellationKeepsInFlightEpisodeAndCountsNotAttemptedRows() async {
    let gate = TestGate<Void>(label: "RecordingBatchSaving saveBatch", ignoresCancellation: true)
    gate.hold()
    let saving = RecordingBatchSaving(
      scripts: [
        .init(
          outcomes: [
            .init(
              episodeId: 9,
              outcome: .accepted(attemptID: 4, serverItemID: "show"))
          ],
          stop: .cancelled,
          notAttempted: [10, 11],
          gate: gate)
      ])
    let model = makeModel(
      episodes: [summary("9"), summary("10"), summary("11")],
      resolver: StaticNativeEpisodeIDResolving(["9": 9, "10": 10, "11": 11]),
      saving: saving)
    await waitUntil { model.episodes.count == 3 && model.serverSave.serverMutationCapability.canSave }
    model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10", "11"])
    #expect(await waitUntil { await saving.requests.count == 1 })

    model.serverSave.cancelBatchServerSave()
    #expect(model.serverSave.batchServerSave?.phase == .cancelling)
    #expect(model.serverSave.batchServerSaveCancellation?.isCancelled == true)
    gate.release()
    #expect(
      await waitUntil {
        model.serverSave.batchServerSave == nil && model.serverSave.batchServerSaveCompletionVersion == 1
      })
    #expect(model.serverSave.serverSaveBannerMessage == "Cancelled: requested 1; 2 not attempted")
  }

  @MainActor
  @Test func limitAndSelectedActionAreNoOpsForTheBatchExecutor() async {
    let saving = RecordingBatchSaving(scripts: [])
    let model = makeModel(
      episodes: (0..<51).map { summary("\($0)") },
      resolver: StaticNativeEpisodeIDResolving(
        Dictionary(uniqueKeysWithValues: (0..<51).map { ("\($0)", Int64($0)) })),
      saving: saving)
    await waitUntil { model.episodes.count == 51 && model.serverSave.serverMutationCapability.canSave }

    model.serverSave.beginBatchServerSave(episodeIDs: Set((0..<51).map(String.init)))
    #expect(
      model.actionErrorMessage
        == NativeEpisodeServerSaveBatchCopy.limitExceeded(selected: 51))
    #expect(model.serverSave.batchServerSave == nil)
    #expect(await saving.requests.isEmpty)
    await model.performSelectedAction(.saveToServer, episodeIDs: Set(["0"]))
    #expect(await saving.requests.isEmpty)
    #expect(model.serverSave.batchServerSave == nil)
  }

  @MainActor
  @Test func laterConfirmationsOfBatchAttemptsCoalesceIntoOneBanner() async {
    let saving = RecordingBatchSaving(
      scripts: [
        .init(
          outcomes: [
            .init(episodeId: 9, outcome: .accepted(attemptID: 4, serverItemID: "show")),
            .init(episodeId: 10, outcome: .accepted(attemptID: 5, serverItemID: "show")),
          ],
          stop: .completed,
          notAttempted: [])
      ])
    let statuses = FakeNativeEpisodeServerSaveStatusReading()
    let model = makeModel(
      episodes: [summary("9"), summary("10")],
      resolver: StaticNativeEpisodeIDResolving(["9": 9, "10": 10]),
      saving: saving,
      statuses: statuses)
    await waitUntil { model.episodes.count == 2 && model.serverSave.serverMutationCapability.canSave }
    model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
    #expect(await waitUntil { model.serverSave.batchServerSaveCompletionVersion == 1 })
    #expect(model.serverSave.serverSaveBannerMessage == "Requested 2 episodes")

    statuses.pushStatuses([
      9: .init(status: .saved, attemptID: 4),
      10: .init(status: .requested, attemptID: 5),
    ])
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "9") == .saved })
    #expect(model.serverSave.serverSaveStatus(for: "10") == .requested)
    #expect(model.serverSave.serverSaveBannerMessage == "Requested 2 episodes")

    statuses.pushStatuses([
      9: .init(status: .saved, attemptID: 4),
      10: .init(status: .saved, attemptID: 5),
    ])
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "10") == .saved })
    #expect(model.serverSave.serverSaveBannerMessage == "Saved 2 episodes on server")
  }

  @MainActor
  @Test func singleSaveConfirmationOutsideTheBatchKeepsItsOwnBanner() async {
    let saving = RecordingBatchSaving(
      scripts: [
        .init(
          outcomes: [
            .init(episodeId: 9, outcome: .accepted(attemptID: 4, serverItemID: "show"))
          ],
          stop: .completed,
          notAttempted: [])
      ])
    let statuses = FakeNativeEpisodeServerSaveStatusReading()
    let model = makeModel(
      episodes: [summary("9"), summary("10")],
      resolver: StaticNativeEpisodeIDResolving(["9": 9, "10": 10]),
      saving: saving,
      statuses: statuses)
    await waitUntil { model.episodes.count == 2 && model.serverSave.serverMutationCapability.canSave }
    model.serverSave.beginBatchServerSave(episodeIDs: ["9"])
    #expect(await waitUntil { model.serverSave.batchServerSaveCompletionVersion == 1 })
    model.serverSave.serverSaveStatuses["10"] = .requested
    model.serverSave.serverSaveAttemptIDs["10"] = 7

    statuses.pushStatuses([
      9: .init(status: .requested, attemptID: 4),
      10: .init(status: .saved, attemptID: 7),
    ])
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "10") == .saved })
    #expect(model.serverSave.serverSaveBannerMessage == NativeEpisodeServerSaveCopy.saved)
    // Attempt 4 belongs to the batch and is still unconfirmed, so it stays Requested.
    #expect(model.serverSave.serverSaveStatus(for: "9") == .requested)
  }

  @MainActor
  @Test func showingAnotherShowMidBatchCancelsTheTokenAndDropsLateOutcomes() async {
    let gate = TestGate<Void>(label: "RecordingBatchSaving saveBatch", ignoresCancellation: true)
    gate.hold()
    let saving = RecordingBatchSaving(
      scripts: [
        .init(
          outcomes: [
            .init(episodeId: 9, outcome: .accepted(attemptID: 4, serverItemID: "show"))
          ],
          stop: .completed,
          notAttempted: [],
          gate: gate)
      ])
    let model = makeModel(
      episodes: [summary("9")],
      resolver: StaticNativeEpisodeIDResolving(["9": 9]),
      saving: saving)
    await waitUntil { model.episodes.count == 1 && model.serverSave.serverMutationCapability.canSave }
    model.serverSave.beginBatchServerSave(episodeIDs: ["9"])
    #expect(await waitUntil { await saving.requests.count == 1 })

    model.show(itemID: "rss:8")
    #expect(model.serverSave.batchServerSave == nil)
    #expect(model.serverSave.isBatchServerSaveMember("9") == false)
    let token = await saving.tokens.first
    #expect(token?.isCancelled == true)

    gate.release()
    await waitUntil { await saving.finishedCount == 1 }
    #expect(model.serverSave.serverSaveStatus(for: "9") == .none)
    #expect(model.serverSave.serverSaveAttemptID(for: "9") == nil)
    #expect(model.serverSave.batchServerSaveCompletionVersion == 0)
    #expect(model.serverSave.serverSaveBannerMessage == nil)
  }

  // MARK: - The fence's latest attempt

  /// A stale attempt for 9 beside a live marker for 10. Once the marker lands the stale row has
  /// been decided, so the test can read 9 without waiting on a negative.
  private static let staleAttemptBesideMarker: [Int64: NativeEpisodeServerSaveStatusSnapshot] = [
    9: .init(status: .saved, attemptID: 4),
    10: .init(status: .saved, attemptID: 1),
  ]

  @MainActor
  @Test func aBatchFailureThatNamesNoAttemptKeepsTheLatestAttempt() async {
    let saving = RecordingBatchSaving(
      scripts: [
        .init(
          outcomes: [
            .init(
              episodeId: 9,
              outcome: .failed(attemptID: nil, state: .failed, category: .permissionChanged))
          ],
          stop: .completed,
          notAttempted: [])
      ])
    let statuses = FakeNativeEpisodeServerSaveStatusReading()
    let model = makeModel(
      episodes: [summary("9"), summary("10")],
      resolver: StaticNativeEpisodeIDResolving(["9": 9, "10": 10]),
      saving: saving,
      statuses: statuses)
    await waitUntil { model.episodes.count == 2 && model.serverSave.serverMutationCapability.canSave }
    statuses.pushStatuses([
      9: .init(status: .failed(.transport, phase: .save), attemptID: 5),
      10: .init(status: .none),
    ])
    #expect(
      await waitUntil { model.serverSave.serverSaveStatus(for: "9") == .failed(.transport, phase: .save) })

    model.serverSave.beginBatchServerSave(episodeIDs: ["9"])
    #expect(await waitUntil { model.serverSave.batchServerSaveCompletionVersion == 1 })
    #expect(model.serverSave.serverSaveStatus(for: "9") == .failed(.permissionChanged, phase: .save))

    statuses.pushStatuses(Self.staleAttemptBesideMarker)
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "10") == .saved })
    #expect(model.serverSave.serverSaveStatus(for: "9") == .failed(.permissionChanged, phase: .save))
  }

  @MainActor
  @Test func dismissingABatchChoiceKeepsTheLatestAttempt() async {
    let prompt = NativeEpisodeServerSaveChoicePrompt.existing(candidates: [])
    let saving = RecordingBatchSaving(
      scripts: [
        .init(
          outcomes: [
            .init(episodeId: 9, outcome: .needsChoice(attemptID: 5, prompt: prompt))
          ],
          stop: .needsChoice(episodeId: 9, attemptID: 5, prompt: prompt),
          notAttempted: [])
      ])
    let statuses = FakeNativeEpisodeServerSaveStatusReading()
    let model = makeModel(
      episodes: [summary("9"), summary("10")],
      resolver: StaticNativeEpisodeIDResolving(["9": 9, "10": 10]),
      saving: saving,
      statuses: statuses)
    await waitUntil { model.episodes.count == 2 && model.serverSave.serverMutationCapability.canSave }
    model.serverSave.beginBatchServerSave(episodeIDs: ["9"])
    #expect(await waitUntil { model.serverSave.pendingServerSaveChoice != nil })

    model.serverSave.dismissServerSaveFeedback()
    #expect(model.serverSave.serverSaveStatus(for: "9") == .none)

    statuses.pushStatuses(Self.staleAttemptBesideMarker)
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "10") == .saved })
    #expect(model.serverSave.serverSaveStatus(for: "9") == .none)
  }

  @MainActor
  private func makeModel(
    episodes: [PodcastEpisodeSummary],
    resolver: any NativeEpisodeIDResolving,
    saving: any NativeEpisodeServerSaveBatchSaving,
    statuses: any NativeEpisodeServerSaveStatusReading = NoOpNativeEpisodeServerSaveStatusReading()
  ) -> PodcastShowModel {
    PodcastShowModel(
      itemID: "rss:7",
      reading: FakePodcastReading(episodes: episodes),
      nativeEpisodeIDResolving: resolver,
      nativeEpisodeServerSaveBatchSaving: saving,
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: false))
  }

  private func summary(_ id: String) -> PodcastEpisodeSummary {
    PodcastEpisodeSummary(
      id: id, title: id, subtitle: nil, episodeDescription: nil, seasonNumber: nil,
      episodeNumber: nil, episodeType: nil, durationSeconds: 120, sizeBytes: nil,
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000), progressSeconds: 0,
      isPlayed: false, isFinished: false, downloadStatus: .notDownloaded,
      isAvailableOnServer: true)
  }
}

private struct BatchScript: Sendable {
  let outcomes: [NativeEpisodeServerSaveBatchEpisodeOutcome]
  let stop: NativeEpisodeServerSaveBatchStop
  let notAttempted: [Int64]
  let gate: TestGate<Void>?

  init(
    outcomes: [NativeEpisodeServerSaveBatchEpisodeOutcome],
    stop: NativeEpisodeServerSaveBatchStop,
    notAttempted: [Int64],
    gate: TestGate<Void>? = nil
  ) {
    self.outcomes = outcomes
    self.stop = stop
    self.notAttempted = notAttempted
    self.gate = gate
  }
}

private actor RecordingBatchSaving: NativeEpisodeServerSaveBatchSaving {
  private var scripts: [BatchScript]
  private(set) var requests: [NativeEpisodeServerSaveBatchRequest] = []
  private(set) var tokens: [NativeEpisodeServerSaveBatchCancellationToken] = []
  private(set) var finishedCount = 0

  init(scripts: [BatchScript]) {
    self.scripts = scripts
  }

  func saveBatch(
    _ request: NativeEpisodeServerSaveBatchRequest,
    cancellation: NativeEpisodeServerSaveBatchCancellationToken,
    onEpisodeOutcome: @escaping @Sendable (NativeEpisodeServerSaveBatchEpisodeOutcome) async -> Void
  ) async -> NativeEpisodeServerSaveBatchResult {
    requests.append(request)
    tokens.append(cancellation)
    let script = scripts.removeFirst()
    if let gate = script.gate {
      await gate.pass()
    }
    for outcome in script.outcomes {
      await onEpisodeOutcome(outcome)
    }
    finishedCount += 1
    return NativeEpisodeServerSaveBatchResult(
      outcomes: script.outcomes,
      stop: script.stop,
      notAttempted: script.notAttempted,
      serverItemID: "show")
  }
}
