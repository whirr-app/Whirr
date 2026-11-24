import Foundation
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Pins the one server-save policy the show and the episode card share: the outcome switch, the
/// generation fence around the await, the fence ordering and the failure mapping. Presentation
/// state itself belongs to the sink, so every test reads what the sink was told.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct NativeEpisodeServerSavePresenterTests {
  @MainActor
  @Test("a save publishes preparing, then the accepted outcome, and the fence follows the await")
  func savePublishesTheAcceptedOutcome() async {
    let sink = RecordingServerSaveSink()
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 4, serverItemID: "server-item")])
    let presenter = makePresenter(saving: saving)

    await presenter.save(feedID: 7, episodeID: "9", choice: nil, sink: sink)

    #expect(sink.statuses.map(\.1) == [.preparing, .requested])
    #expect(sink.attempts.map(\.1) == [4])
    #expect(sink.banners == [NativeEpisodeServerSaveCopy.requested])
    #expect(sink.errors.isEmpty)
    #expect(sink.acceptedWithoutChoiceCount == 1)
    #expect(
      sink.events == [
        "begin:9:true", "status:preparing", "end:9", "record", "attempt:4", "status:requested",
        "banner", "accept",
      ])

    #expect(saving.calls == [.save(feedID: 7, episodeID: 9, choice: nil)])
  }

  @MainActor
  @Test("a teardown while the save is in flight drops the outcome and leaves the fence alone")
  func teardownMidFlightDropsTheOutcome() async {
    let sink = RecordingServerSaveSink()
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 4, serverItemID: "server-item")])
    saving.saveGate.hold()
    let presenter = makePresenter(saving: saving)

    let save = Task {
      await presenter.save(feedID: 7, episodeID: "9", choice: nil, sink: sink)
    }
    #expect(await saving.saveGate.waitUntilParked() == .observed)
    sink.bumpGeneration()
    saving.saveGate.release()
    await save.value

    #expect(sink.statuses.map(\.1) == [.preparing])
    #expect(sink.attempts.isEmpty)
    #expect(sink.events == ["begin:9:true", "status:preparing"])
  }

  @MainActor
  @Test("a teardown mid-flight still requests the library sync a created show needs")
  func teardownMidFlightKeepsTheLibrarySyncRequest() async {
    let sink = RecordingServerSaveSink()
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 4, serverItemID: "server-item")])
    saving.saveGate.hold()
    let sync = CountingLibrarySync()
    let presenter = makePresenter(saving: saving, librarySyncRequester: sync)

    let save = Task {
      await presenter.save(
        feedID: 7, episodeID: "9",
        choice: .libraryAndFolder(libraryID: "lib", folderID: "folder"), sink: sink)
    }
    #expect(await saving.saveGate.waitUntilParked() == .observed)
    sink.bumpGeneration()
    saving.saveGate.release()
    await save.value

    #expect(await waitUntil { await sync.count == 1 })
  }

  @MainActor
  @Test("a remove begins without clearing the removal fence and maps its outcome")
  func removeKeepsTheRemovalFence() async {
    let sink = RecordingServerSaveSink()
    let saving = FakeNativeEpisodeServerSaving(
      removeOutcomes: [.inProgress(attemptID: 12, state: .removed, serverItemID: nil)])
    let presenter = makePresenter(saving: saving)

    await presenter.remove(episodeID: "9", attemptID: 12, sink: sink)

    #expect(sink.statuses.map(\.1) == [.removing, .removed])
    #expect(sink.banners == [NativeEpisodeServerSaveCopy.removed])
    #expect(sink.errors.isEmpty)
    #expect(
      sink.events == [
        "begin:9:false", "status:removing", "end:9", "record", "attempt:12", "status:removed",
        "banner",
      ])
    #expect(saving.calls == [.remove(attemptID: 12)])
  }

  @MainActor
  @Test("a destination choice clears the error and presents the choice")
  func needsChoicePresentsTheChoiceAndClearsTheError() async {
    let sink = RecordingServerSaveSink()
    let prompt = NativeEpisodeServerSaveChoicePrompt.existing(candidates: [
      NativeEpisodeServerSaveExistingChoice(serverItemID: "candidate", displayName: "Candidate")
    ])
    let saving = FakeNativeEpisodeServerSaving(saveOutcomes: [.needsChoice(attemptID: 5, prompt: prompt)])
    let presenter = makePresenter(saving: saving)

    await presenter.save(feedID: 7, episodeID: "9", choice: nil, sink: sink)

    #expect(sink.statuses.map(\.1) == [.preparing, .preparing])
    #expect(sink.attempts.map(\.1) == [5])
    #expect(sink.choices.count == 1)
    #expect(sink.choices.first?.episodeID == "9")
    #expect(sink.choices.first?.attemptID == 5)
    #expect(sink.choices.first?.prompt == prompt)
    #expect(sink.errors == [nil])
    #expect(sink.banners.isEmpty)
  }

  @MainActor
  @Test("an already-present save is a banner and a saved status")
  func alreadyPresentPublishesSaved() async {
    let sink = RecordingServerSaveSink()
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.alreadyPresent(attemptID: 6, serverItemID: "server-item")])
    let presenter = makePresenter(saving: saving)

    await presenter.save(feedID: 7, episodeID: "9", choice: nil, sink: sink)

    #expect(sink.statuses.map(\.1) == [.preparing, .saved])
    #expect(sink.attempts.map(\.1) == [6])
    #expect(sink.banners == [NativeEpisodeServerSaveCopy.saved])
    #expect(sink.acceptedWithoutChoiceCount == 1)
  }

  @MainActor
  @Test("an in-progress outcome only raises a banner once it reaches removed or saved")
  func inProgressBannersOnlyForTerminalStates() async {
    let requestedSink = RecordingServerSaveSink()
    let requestedPresenter = makePresenter(
      saving: FakeNativeEpisodeServerSaving(
        saveOutcomes: [
          .inProgress(attemptID: 3, state: .requestingDownload, serverItemID: nil)
        ]))
    await requestedPresenter.save(feedID: 7, episodeID: "9", choice: nil, sink: requestedSink)
    #expect(requestedSink.statuses.map(\.1) == [.preparing, .requested])
    #expect(requestedSink.banners.isEmpty)

    let removedSink = RecordingServerSaveSink()
    let removedPresenter = makePresenter(
      saving: FakeNativeEpisodeServerSaving(
        removeOutcomes: [.inProgress(attemptID: 3, state: .removed, serverItemID: nil)]))
    await removedPresenter.remove(episodeID: "9", attemptID: 3, sink: removedSink)
    #expect(removedSink.banners == [NativeEpisodeServerSaveCopy.removed])
  }

  @MainActor
  @Test("uncertain stays out of the error channel and keeps its phase")
  func uncertainClearsTheError() async {
    let sink = RecordingServerSaveSink()
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.uncertain(attemptID: 8, state: .createUncertain, category: .transport)])
    let presenter = makePresenter(saving: saving)

    await presenter.save(feedID: 7, episodeID: "9", choice: nil, sink: sink)

    #expect(sink.statuses.map(\.1) == [.preparing, .uncertain(.transport, phase: .save)])
    #expect(sink.attempts.map(\.1) == [8])
    #expect(sink.errors == [nil])
    #expect(sink.banners.isEmpty)
  }

  @MainActor
  @Test("a failed remove publishes its phase and the reason copy")
  func failedRemovePublishesTheReason() async {
    let sink = RecordingServerSaveSink()
    let saving = FakeNativeEpisodeServerSaving(
      removeOutcomes: [
        .failed(attemptID: 9, state: .deleteFailed, category: .permissionChanged)
      ])
    let presenter = makePresenter(saving: saving)

    await presenter.remove(episodeID: "9", attemptID: 9, sink: sink)

    #expect(
      sink.statuses.map(\.1) == [.removing, .failed(.permissionChanged, phase: .remove)])
    #expect(sink.errors == [NativeEpisodeServerSaveCopy.disabledReason(.permissionChanged)])
    #expect(sink.banners.isEmpty)
  }

  @MainActor
  @Test("an identity key with no row fails as a missing episode and never reaches the coordinator")
  func missingEpisodeNeverReachesTheCoordinator() async {
    let sink = RecordingServerSaveSink()
    let saving = FakeNativeEpisodeServerSaving()
    let presenter = NativeEpisodeServerSavePresenter(
      saving: saving,
      resolving: StaticNativeEpisodeIDResolving([:]),
      librarySyncRequester: NoOpLibrarySyncRequester())

    await presenter.save(feedID: 7, episodeID: "9", choice: nil, sink: sink)

    #expect(sink.statuses.map(\.1) == [.failed(.missingEpisode, phase: .save)])
    #expect(sink.attempts.map(\.1) == [Int64?.none])
    #expect(sink.errors == [NativeEpisodeServerSaveCopy.disabledReason(.missingEpisode)])
    #expect(sink.events == ["attempt:nil", "status:failed", "error"])
    #expect(saving.calls.isEmpty)
  }

  private func makePresenter(
    saving: FakeNativeEpisodeServerSaving,
    librarySyncRequester: any LibrarySyncRequesting = NoOpLibrarySyncRequester()
  ) -> NativeEpisodeServerSavePresenter {
    NativeEpisodeServerSavePresenter(
      saving: saving,
      resolving: StaticNativeEpisodeIDResolving(["9": 9]),
      librarySyncRequester: librarySyncRequester)
  }
}

@MainActor
private final class RecordingServerSaveSink: NativeEpisodeServerSaveSink {
  private(set) var generation = 0
  private(set) var statuses: [(String, NativeEpisodeServerSaveStatus)] = []
  private(set) var attempts: [(String, Int64?)] = []
  private(set) var banners: [String] = []
  private(set) var choices: [PendingServerSaveChoice] = []
  private(set) var errors: [String?] = []
  private(set) var acceptedWithoutChoiceCount = 0
  private(set) var events: [String] = []

  var serverSaveGeneration: Int { generation }

  func bumpGeneration() { generation += 1 }

  func beginServerSaveMutation(for episodeID: String, clearingRemoval: Bool) {
    events.append("begin:\(episodeID):\(clearingRemoval)")
  }

  func endServerSaveMutation(for episodeID: String) {
    events.append("end:\(episodeID)")
  }

  func recordServerSaveOutcome(_ outcome: NativeEpisodeServerSaveOutcome, for episodeID: String) {
    events.append("record")
  }

  func setServerSaveStatus(_ status: NativeEpisodeServerSaveStatus, for episodeID: String) {
    statuses.append((episodeID, status))
    events.append("status:\(status.label)")
  }

  func setServerSaveAttemptID(_ attemptID: Int64?, for episodeID: String) {
    attempts.append((episodeID, attemptID))
    events.append("attempt:\(attemptID.map(String.init) ?? "nil")")
  }

  func raiseServerSaveBanner(_ message: String) {
    banners.append(message)
    events.append("banner")
  }

  func presentServerSaveChoice(_ choice: PendingServerSaveChoice) {
    choices.append(choice)
  }

  func reportServerSaveError(_ message: String?) {
    errors.append(message)
    events.append("error")
  }

  func serverSaveDidAcceptWithoutChoice() {
    acceptedWithoutChoiceCount += 1
    events.append("accept")
  }
}

extension NativeEpisodeServerSaveStatus {
  fileprivate var label: String {
    switch self {
    case .none: return "none"
    case .preparing: return "preparing"
    case .requested: return "requested"
    case .saved: return "saved"
    case .removing: return "removing"
    case .removed: return "removed"
    case .uncertain: return "uncertain"
    case .failed: return "failed"
    }
  }
}

private actor CountingLibrarySync: LibrarySyncRequesting {
  private(set) var count = 0

  func requestLibrarySync() async {
    count += 1
  }
}
