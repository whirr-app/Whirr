import Persistence
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PodcastEpisodeIntentExecutorTests {
  private static let itemID = "show-1"
  private static let episodeID = "episode-1"

  @Test("play/pause executes the play intent")
  func playPauseExecutesPlayIntent() async {
    await assertAction(.playPause, expected: .play(Self.itemID, Self.episodeID))
  }

  @Test("play next executes the front-of-queue intent")
  func playNextExecutesPlayNextIntent() async {
    await assertAction(.playNext, expected: .playNext(Self.itemID, Self.episodeID))
  }

  @Test("add to Up Next executes the append intent")
  func addToUpNextExecutesAppendIntent() async {
    await assertAction(.addToUpNext, expected: .addToUpNext(Self.itemID, Self.episodeID))
  }

  @Test("Save for Later executes the saved intent")
  func saveForLaterExecutesSavedIntent() async {
    await assertAction(
      .saveForLater,
      expected: .saveForLater(Self.itemID, Self.episodeID),
      expectedOutcome: .saved(.alreadySaved),
      saveOutcome: .alreadySaved)
  }

  @Test("Remove from Saved executes the remove intent")
  func removeFromSavedExecutesRemoveIntent() async {
    await assertAction(
      .removeFromSaved, expected: .removeFromSaved(Self.itemID, Self.episodeID))
  }

  @Test("download executes the device download intent")
  func downloadExecutesDownloadIntent() async {
    await assertAction(.download, expected: .download(Self.itemID, Self.episodeID))
  }

  @Test("pause download executes the pause intent")
  func pauseDownloadExecutesPauseIntent() async {
    await assertAction(.pauseDownload, expected: .pauseDownload(Self.itemID, Self.episodeID))
  }

  @Test("resume download executes the resume intent")
  func resumeDownloadExecutesResumeIntent() async {
    await assertAction(.resumeDownload, expected: .resumeDownload(Self.itemID, Self.episodeID))
  }

  @Test("remove download executes the purge intent")
  func removeDownloadExecutesRemoveIntent() async {
    await assertAction(.removeDownload, expected: .removeDownload(Self.itemID, Self.episodeID))
  }

  @Test("mark as finished passes the episode duration")
  func markAsFinishedPassesDuration() async {
    await assertAction(
      .markAsFinished,
      duration: 321,
      expected: .markAsFinished(Self.itemID, Self.episodeID, 321))
  }

  @Test("reset progress executes the reset intent")
  func resetProgressExecutesResetIntent() async {
    await assertAction(.resetProgress, expected: .resetProgress(Self.itemID, Self.episodeID))
  }

  @Test("an intent failure that provides copy uses its message")
  func providedIntentFailureUsesItsMessage() {
    let error = PodcastEpisodeIntentFailure(message: "Playback is unavailable.")
    #expect(
      PodcastEpisodeIntentExecutor.errorMessage(for: error) == "Playback is unavailable.")
  }

  @Test("an unrecognised intent failure uses the generic action copy")
  func unknownIntentFailureUsesGenericCopy() {
    #expect(
      PodcastEpisodeIntentExecutor.errorMessage(for: TestIntentError.generic)
        == PodcastCopy.actionFailed)
  }

  @Test("a stale successful action does not clear the current item's error")
  func staleSuccessLeavesCurrentItemErrorUntouched() async {
    let gate = TestGate<Void>(label: "play intent")
    let intents = Self.blockingIntents(gate: gate, failure: nil)
    let executor = PodcastEpisodeIntentExecutor(intents: intents)
    var currentItemID = Self.itemID
    var actionError: String? = "The current item's error."

    let task = Task { @MainActor in
      await executor.execute(
        action: .playPause,
        itemID: Self.itemID,
        episodeID: Self.episodeID,
        duration: nil,
        currentItemID: { currentItemID },
        onSuccess: { _ in actionError = nil },
        onFailure: { actionError = $0 })
    }
    await gate.waitUntilParked()
    currentItemID = "show-2"
    gate.release()
    await task.value

    #expect(actionError == "The current item's error.")
  }

  @Test("a stale failed action does not overwrite the current item's error")
  func staleFailureLeavesCurrentItemErrorUntouched() async {
    let gate = TestGate<Void>(label: "play intent")
    let intents = Self.blockingIntents(gate: gate, failure: .offline)
    let executor = PodcastEpisodeIntentExecutor(intents: intents)
    var currentItemID = Self.itemID
    var actionError: String? = "The current item's error."

    let task = Task { @MainActor in
      await executor.execute(
        action: .playPause,
        itemID: Self.itemID,
        episodeID: Self.episodeID,
        duration: nil,
        currentItemID: { currentItemID },
        onSuccess: { _ in actionError = nil },
        onFailure: { actionError = $0 })
    }
    await gate.waitUntilParked()
    currentItemID = "show-2"
    gate.release()
    await task.value

    #expect(actionError == "The current item's error.")
  }

  @Test("navigation actions stay out of the intent executor")
  func navigationActionsDoNotInvokeAnIntent() async {
    let intents = FakePodcastEpisodeIntents()
    let executor = PodcastEpisodeIntentExecutor(intents: intents)
    var success = false
    var failure: String?

    await executor.execute(
      action: .openShow,
      itemID: Self.itemID,
      episodeID: Self.episodeID,
      duration: nil,
      currentItemID: { Self.itemID },
      onSuccess: { _ in success = true },
      onFailure: { failure = $0 })

    #expect(intents.calls.isEmpty)
    #expect(success == false)
    #expect(failure == nil)
  }

  @Test("an unknown context action ID remains ignored")
  func unknownContextActionIDIsIgnored() {
    #expect(MediaItemAction(actionID: "not-an-episode-action") == nil)
  }

  @Test("saved context action IDs map to the canonical actions")
  func savedContextActionIDsMapToCanonicalActions() {
    #expect(MediaItemAction(actionID: "save-for-later") == .saveForLater)
    #expect(MediaItemAction(actionID: "remove-from-saved") == .removeFromSaved)
  }

  /// A play that parks on `gate` until released, then fails with `failure` (or succeeds).
  private static func blockingIntents(
    gate: TestGate<Void>, failure: TestIntentError?
  ) -> FakePodcastEpisodeIntents {
    gate.hold()
    let intents = FakePodcastEpisodeIntents()
    intents.stubBeforeCall { call in
      guard case .play = call else { return }
      await gate.pass()
      if let failure { throw failure }
    }
    return intents
  }

  private func assertAction(
    _ action: MediaItemAction,
    duration: Double? = nil,
    expected: FakePodcastEpisodeIntents.Call,
    expectedOutcome: PodcastEpisodeActionOutcome = .completed,
    saveOutcome: SavedShelfSaveOutcome = .saved
  ) async {
    let intents = FakePodcastEpisodeIntents(saveOutcome: saveOutcome)
    let executor = PodcastEpisodeIntentExecutor(intents: intents)
    var successOutcome: PodcastEpisodeActionOutcome?
    var failure: String?

    await executor.execute(
      action: action,
      itemID: Self.itemID,
      episodeID: Self.episodeID,
      duration: duration,
      currentItemID: { Self.itemID },
      onSuccess: { successOutcome = $0 },
      onFailure: { failure = $0 })

    #expect(intents.calls == [expected])
    #expect(successOutcome == expectedOutcome)
    #expect(failure == nil)
  }
}

private enum TestIntentError: Error {
  case generic
  case offline
}
