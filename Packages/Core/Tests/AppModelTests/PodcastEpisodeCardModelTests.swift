import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite struct PodcastEpisodeCardModelTests {
  /// The identity key the suite's native episode carries, mapped to the row id the coordinator sees.
  private static let resolver = StaticNativeEpisodeIDResolving(["9": 9])

  @MainActor
  @Test func loadPopulatesPresentation() async {
    let reading = FakePodcastReading()
    let context = Self.context(episodeID: "episode-1")
    reading.setEpisode(context, itemID: "show-1", episodeID: "episode-1")
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: reading)

    reading.tick(itemID: "show-1")
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded(PodcastEpisodeCardPresentation(context: context)))
  }

  @MainActor
  @Test func isSavedIsNilWithoutAStoreOrBeforeItsFirstEmission() {
    let reading = FakePodcastReading()
    let withoutStore = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: reading)
    #expect(withoutStore.isSaved == nil)

    let savedReading = FakeSavedShelfReading()
    let savedStatus = SavedStatusStore(savedShelf: savedReading)
    let beforeEmission = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: reading,
      savedStatus: savedStatus)
    #expect(beforeEmission.isSaved == nil)
  }

  @MainActor
  @Test func isSavedFlipsWithPushedEpisodeMembership() async {
    let savedReading = FakeSavedShelfReading()
    let savedStatus = SavedStatusStore(savedShelf: savedReading)
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: FakePodcastReading(),
      savedStatus: savedStatus)
    let identity = SavedShelfIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1")

    savedReading.pushSavedIdentities([identity])
    #expect(await waitUntil { model.isSaved == true })

    savedReading.pushSavedIdentities([])
    #expect(await waitUntil { model.isSaved == false })
  }

  @MainActor
  @Test func savedFeedbackCoversSaveRemoveAndOtherActions() async {
    let intents = FakePodcastEpisodeIntents(saveOutcome: .alreadySaved)
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: FakePodcastReading(),
      episodeIntents: intents)

    await model.performAction(.saveForLater)
    #expect(model.savedFeedbackMessage == SavedForLaterCopy.alreadySaved)

    intents.stubSaveOutcome(.saved)
    await model.performAction(.saveForLater)
    #expect(model.savedFeedbackMessage == SavedForLaterCopy.saved)

    await model.performAction(.removeFromSaved)
    #expect(model.savedFeedbackMessage == SavedForLaterCopy.removed)

    await model.performAction(.playPause)
    #expect(model.savedFeedbackMessage == nil)

    await model.performAction(.saveForLater)
    model.dismissSavedFeedback()
    #expect(model.savedFeedbackMessage == nil)
  }

  @MainActor
  @Test func queueFeedbackCoversBothUpNextActionsAndCanBeDismissed() async {
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: FakePodcastReading(),
      episodeIntents: FakePodcastEpisodeIntents())

    await model.performAction(.playNext)
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.playingNext)

    await model.performAction(.addToUpNext)
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.addedToUpNext)

    model.dismissQueueFeedback()
    #expect(model.queueFeedbackMessage == nil)
  }

  @MainActor
  @Test func loadMissingEpisodeYieldsMissingState() async {
    let reading = FakePodcastReading()
    // No stub registered for this ref: the store has nothing (stale index, purged show).
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-ghost", reading: reading)

    reading.tick(itemID: "show-1")
    await waitUntil { model.state != .loading }

    #expect(model.state == .missing)
  }

  @MainActor
  @Test func playInvokesEpisodeIntentWithBothIDs() async {
    let reading = FakePodcastReading()
    let intents = FakePodcastEpisodeIntents()
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: reading, episodeIntents: intents)

    await model.play()

    #expect(intents.calls == [.play("show-1", "episode-1")])
  }

  @MainActor
  @Test("server-save actions use the native RSS identity and coordinator seam")
  func serverSaveActionsUseNativeIdentity() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 8, serverItemID: "server-item")])
    let model = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: saving)

    await model.performAction(.saveToServer)

    #expect(model.serverSaveStatus == .requested)
    #expect(model.serverSaveFeedbackMessage == NativeEpisodeServerSaveCopy.requested)
    #expect(saving.calls == [.save(feedID: 7, episodeID: 9, choice: nil)])
  }

  @MainActor
  @Test("non-native cards do not call the server coordinator")
  func nonNativeCardHidesServerActionsAndDoesNotCallCoordinator() async {
    let saving = FakeNativeEpisodeServerSaving()
    let model = PodcastEpisodeCardModel(
      itemID: "abs-show", episodeID: "9", reading: FakePodcastReading(),
      nativeEpisodeServerSaving: saving)

    await model.performAction(.saveToServer)
    await model.performAction(.removeFromServer)

    #expect(saving.saveCalls.isEmpty)
    #expect(saving.removeCalls.isEmpty)
  }

  @MainActor
  @Test("lifecycle teardown clears an unsent choice for every trigger")
  func lifecycleTeardownClearsUnsentChoice() async {
    let prompt = NativeEpisodeServerSaveChoicePrompt.existing(candidates: [
      NativeEpisodeServerSaveExistingChoice(serverItemID: "candidate", displayName: "Candidate")
    ])
    for trigger in [
      NativeEpisodeServerSaveLifecycleTrigger.nativeSubscriptionsDisabled,
      .accountUnavailable,
      .accountReplaced,
    ] {
      let saving = FakeNativeEpisodeServerSaving(
        saveOutcomes: [.needsChoice(attemptID: 5, prompt: prompt)])
      let model = PodcastEpisodeCardModel(
        itemID: "rss:7", episodeID: "9", reading: FakePodcastReading(),
        nativeEpisodeIDResolving: Self.resolver,
        nativeEpisodeServerSaving: saving)

      await model.saveEpisodeToServer()
      #expect(model.pendingServerSaveChoice != nil)
      model.clearServerSavePresentation(for: trigger)

      #expect(model.pendingServerSaveChoice == nil)
      #expect(model.serverSaveStatus == .none)
      #expect(model.serverSaveFeedbackMessage == nil)
      #expect(saving.saveCalls.count == 1)
    }
  }

  @MainActor
  @Test("lifecycle teardown hides a sent presentation without a revocation call")
  func lifecycleTeardownLeavesSentOperationUntouched() async {
    for trigger in [
      NativeEpisodeServerSaveLifecycleTrigger.nativeSubscriptionsDisabled,
      .accountUnavailable,
      .accountReplaced,
    ] {
      let saving = FakeNativeEpisodeServerSaving(
        saveOutcomes: [.accepted(attemptID: 8, serverItemID: "server-item")])
      let model = PodcastEpisodeCardModel(
        itemID: "rss:7", episodeID: "9", reading: FakePodcastReading(),
        nativeEpisodeIDResolving: Self.resolver,
        nativeEpisodeServerSaving: saving)

      await model.saveEpisodeToServer()
      model.clearServerSavePresentation(for: trigger)

      #expect(model.serverSaveStatus == .none)
      #expect(model.serverSaveFeedbackMessage == nil)
      #expect(saving.saveCalls.count == 1)
      #expect(saving.removeCalls.isEmpty)
    }
  }

  @MainActor
  @Test("native subscriptions turning off hides card capability and turning on reloads it")
  func nativeSubscriptionsToggleHidesAndReloadsCardCapability() async {
    let subscriptions = FakeNativePodcastSubscriptionsReading()
    let reading = FakePodcastReading()
    reading.setEpisode(Self.context(episodeID: "9"), itemID: "rss:7", episodeID: "9")
    let model = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9", reading: reading,
      nativeEpisodeIDResolving: Self.resolver,
      serverPodcastMutationCapabilityReading: grantingCapabilityReading(),
      nativePodcastSubscriptionsReading: subscriptions)
    reading.tick(itemID: "rss:7")
    #expect(await waitUntil { model.serverMutationCapability.canSave })
    await waitUntil { subscriptions.observeEnabledCallCount > 0 }

    subscriptions.stubEnabled(false)
    #expect(await waitUntil { model.serverMutationCapability.canSave == false })

    subscriptions.stubEnabled(true)
    #expect(await waitUntil { model.serverMutationCapability.canSave })
  }

  @MainActor
  @Test("an account baseline does not clear an accepted presentation")
  func accountBaselinePreservesServerSavePresentation() async {
    let accountReading = ControllableAccountIdentityReading()
    let model = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: FakeNativeEpisodeServerSaving(
        saveOutcomes: [.accepted(attemptID: 8, serverItemID: "server-item")]),
      serverPodcastMutationCapabilityReading: grantingCapabilityReading(),
      accountIdentityReading: accountReading)
    await waitUntil { accountReading.hasObserver }

    let identity = AccountIdentity(
      id: 1, clientUUID: "client-a", serverIdentityFingerprint: "fingerprint-a")
    accountReading.push(identity)
    await model.saveEpisodeToServer()

    #expect(model.serverSaveStatus == .requested)
    #expect(model.serverSaveFeedbackMessage == NativeEpisodeServerSaveCopy.requested)
  }

  @MainActor
  @Test("pushed account logout clears card server-save presentation")
  func accountUnavailableClearsServerSavePresentation() async {
    let accountReading = ControllableAccountIdentityReading()
    let capability = grantingCapabilityReading()
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 8, serverItemID: "server-item")])
    let model = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: capability,
      accountIdentityReading: accountReading)
    await waitUntil { accountReading.hasObserver }
    accountReading.push(
      AccountIdentity(id: 1, clientUUID: "client-a", serverIdentityFingerprint: "fingerprint-a"))
    await model.saveEpisodeToServer()
    accountReading.push(nil)

    #expect(
      await waitUntil {
        let invalidationCount = capability.invalidationCount
        return model.serverSaveStatus == .none && model.serverSaveFeedbackMessage == nil
          && model.serverMutationCapability == .none
          && invalidationCount == 1
      })
    #expect(saving.removeCalls.isEmpty)
  }

  @MainActor
  @Test("a pushed account replacement clears card server-save presentation")
  func accountReplacementClearsServerSavePresentation() async {
    let accountReading = ControllableAccountIdentityReading()
    let capability = grantingCapabilityReading()
    let model = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: FakeNativeEpisodeServerSaving(
        saveOutcomes: [.accepted(attemptID: 8, serverItemID: "server-item")]),
      serverPodcastMutationCapabilityReading: capability,
      accountIdentityReading: accountReading)
    await waitUntil { accountReading.hasObserver }
    accountReading.push(
      AccountIdentity(id: 1, clientUUID: "client-a", serverIdentityFingerprint: "fingerprint-a"))
    await model.saveEpisodeToServer()
    accountReading.push(
      AccountIdentity(id: 2, clientUUID: "client-b", serverIdentityFingerprint: "fingerprint-b"))

    #expect(
      await waitUntil {
        let invalidationCount = capability.invalidationCount
        return model.serverSaveStatus == .none && model.serverSaveFeedbackMessage == nil
          && model.serverMutationCapability == .none
          && invalidationCount == 1
      })
  }

  @MainActor
  @Test("an equal pushed account identity leaves card presentation unchanged")
  func equalAccountIdentityDoesNotClearServerSavePresentation() async {
    let accountReading = ControllableAccountIdentityReading()
    let capability = grantingCapabilityReading()
    let model = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: FakeNativeEpisodeServerSaving(
        saveOutcomes: [.accepted(attemptID: 8, serverItemID: "server-item")]),
      serverPodcastMutationCapabilityReading: capability,
      accountIdentityReading: accountReading)
    await waitUntil { accountReading.hasObserver }
    let identity = AccountIdentity(
      id: 1, clientUUID: "client-a", serverIdentityFingerprint: "fingerprint-a")
    accountReading.push(identity)
    await model.saveEpisodeToServer()
    accountReading.push(identity)
    await awaitQuiescence(
      "equal account identity lifecycle",
      of: {
        let invalidationCount = capability.invalidationCount
        return "\(model.serverSaveStatus)-\(invalidationCount)"
      })

    #expect(model.serverSaveStatus == .requested)
    #expect(model.serverSaveFeedbackMessage == NativeEpisodeServerSaveCopy.requested)
    #expect(capability.invalidationCount == 0)
  }

  @MainActor
  @Test func downloadActionRoutesByCurrentStatus() async {
    let reading = FakePodcastReading()
    let intents = FakePodcastEpisodeIntents()
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: reading, episodeIntents: intents)

    reading.setEpisode(
      Self.context(episodeID: "episode-1", status: .downloading(progressFraction: 0.5)),
      itemID: "show-1", episodeID: "episode-1")
    reading.tick(itemID: "show-1")
    await waitUntil {
      if case .loaded(let presentation) = model.state {
        return presentation.primaryDeviceAction == .pauseDownload
      }
      return false
    }

    // Dispatch the action the presentation computed, not a literal.
    guard case .loaded(let downloading) = model.state,
      let pauseAction = downloading.primaryDeviceAction
    else {
      Issue.record("expected a loaded presentation carrying a primary device action")
      return
    }
    await model.performAction(pauseAction)
    #expect(intents.calls == [.pauseDownload("show-1", "episode-1")])

    intents.reset()
    reading.setEpisode(
      Self.context(episodeID: "episode-1", status: .paused),
      itemID: "show-1", episodeID: "episode-1")
    reading.tick(itemID: "show-1")
    await waitUntil {
      if case .loaded(let presentation) = model.state {
        return presentation.primaryDeviceAction == .resumeDownload
      }
      return false
    }

    guard case .loaded(let paused) = model.state,
      let resumeAction = paused.primaryDeviceAction
    else {
      Issue.record("expected a loaded presentation carrying a primary device action")
      return
    }
    await model.performAction(resumeAction)
    #expect(intents.calls == [.resumeDownload("show-1", "episode-1")])
  }

  @MainActor
  @Test func storeChangeRefreshesPresentation() async {
    let reading = FakePodcastReading()
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: reading)

    reading.setEpisode(
      Self.context(episodeID: "episode-1", status: .notDownloaded),
      itemID: "show-1", episodeID: "episode-1")
    reading.tick(itemID: "show-1")
    await waitUntil {
      if case .loaded(let presentation) = model.state {
        return presentation.deviceDownloadText == ItemDownloadCopy.text(for: .notDownloaded)
      }
      return false
    }

    // Simulate a download completing while the card is up: the show model's own signal ticks
    // again and the card re-reads by ref rather than trusting stale state.
    reading.setEpisode(
      Self.context(episodeID: "episode-1", status: .completed),
      itemID: "show-1", episodeID: "episode-1")
    reading.tick(itemID: "show-1")

    await waitUntil {
      if case .loaded(let presentation) = model.state {
        return presentation.deviceDownloadText == ItemDownloadCopy.text(for: .completed)
      }
      return false
    }
  }

  @MainActor
  @Test func stoppingObservationSuppressesAnInFlightReload() async {
    let reading = FakePodcastReading()
    let initial = Self.context(episodeID: "episode-1", status: .notDownloaded)
    let updated = Self.context(episodeID: "episode-1", status: .completed)
    reading.setEpisode(initial, itemID: "show-1", episodeID: "episode-1")
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: reading)

    reading.tick(itemID: "show-1")
    await waitUntil {
      if case .loaded(let presentation) = model.state {
        return presentation.deviceDownloadText == ItemDownloadCopy.text(for: .notDownloaded)
      }
      return false
    }

    reading.episodeReadGate.hold()
    reading.setEpisode(updated, itemID: "show-1", episodeID: "episode-1")
    reading.tick(itemID: "show-1")
    #expect(await reading.episodeReadGate.waitUntilParked().isObserved)

    model.stopObserving()
    reading.episodeReadGate.release()
    await awaitQuiescence("the stopped episode observation to settle", of: { "\(model.state)" })

    if case .loaded(let presentation) = model.state {
      #expect(presentation.deviceDownloadText == ItemDownloadCopy.text(for: .notDownloaded))
    } else {
      Issue.record("stopping observation should keep the current loaded presentation")
    }
  }

  @MainActor
  @Test("the card re-reads its episode only when its own quantized fraction changes")
  func progressChangesForThisEpisodeReloadTheCard() async {
    let reading = FakePodcastReading()
    let downloading = Self.context(
      episodeID: "episode-1", status: .downloading(progressFraction: 0.37))
    reading.setEpisode(downloading, itemID: "show-1", episodeID: "episode-1")
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: reading)

    reading.tick(itemID: "show-1")
    await waitUntil { model.state != .loading }
    let readsAfterLoad = reading.episodeReadCount

    // A neighbour's progress, and a repeat of this episode's own bucket, must not re-read.
    reading.pushDownloadProgress(["episode-2": 0.5], itemID: "show-1")
    reading.pushDownloadProgress(["episode-2": 0.52], itemID: "show-1")
    await awaitQuiescence("unrelated progress to settle", of: { "\(reading.episodeReadCount)" })
    #expect(reading.episodeReadCount == readsAfterLoad)

    reading.pushDownloadProgress(["episode-1": 0.36, "episode-2": 0.52], itemID: "show-1")
    await waitUntil { reading.episodeReadCount == readsAfterLoad + 1 }
    reading.pushDownloadProgress(["episode-1": 0.36], itemID: "show-1")
    await awaitQuiescence("a repeated bucket to settle", of: { "\(reading.episodeReadCount)" })
    #expect(reading.episodeReadCount == readsAfterLoad + 1)

    // Leaving the map (the transfer finished) is itself a change worth one re-read.
    reading.pushDownloadProgress([:], itemID: "show-1")
    await waitUntil { reading.episodeReadCount == readsAfterLoad + 2 }

    model.stopObserving()
    reading.pushDownloadProgress(["episode-1": 0.9], itemID: "show-1")
    await awaitQuiescence("progress after stop to settle", of: { "\(reading.episodeReadCount)" })
    #expect(reading.episodeReadCount == readsAfterLoad + 2)
  }

  private static let plug = "Join our newsletter for weekly extras."
  private static let recurringHistory = (0..<5).map {
    "<p>Episode \($0) stands alone here.</p><p>\(plug)</p>"
  }

  @MainActor
  @Test("paragraphs the show repeats fold, read once per list change and never on byte progress")
  func recurringParagraphsFoldFromNeighbourDescriptions() async {
    let reading = FakePodcastReading()
    reading.stubRecentDescriptions(Self.recurringHistory)
    reading.setEpisode(
      Self.context(
        episodeID: "episode-1", status: .downloading(progressFraction: 0.1),
        description: "<p>The episode.</p><p>\(Self.plug)</p>"),
      itemID: "show-1", episodeID: "episode-1")
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: reading)

    reading.tick(itemID: "show-1")
    await waitUntil {
      if case .loaded(let presentation) = model.state {
        return presentation.supplementaryNotes == Self.plug
      }
      return false
    }
    if case .loaded(let presentation) = model.state {
      #expect(presentation.notes == "The episode.")
    }
    #expect(reading.descriptionReadCount == 1)

    let readsBefore = reading.episodeReadCount
    reading.pushDownloadProgress(["episode-1": 0.5], itemID: "show-1")
    await waitUntil { reading.episodeReadCount == readsBefore + 1 }
    await awaitQuiescence("the progress reload to settle", of: { "\(model.state)" })
    #expect(reading.descriptionReadCount == 1)
    if case .loaded(let presentation) = model.state {
      #expect(presentation.supplementaryNotes == Self.plug)
    }

    reading.tick(itemID: "show-1")
    await waitUntil { reading.descriptionReadCount == 2 }
  }

  @MainActor
  @Test("a failed neighbour read leaves the single-episode fold in place")
  func failedNeighbourReadKeepsSingleEpisodeFold() async {
    let reading = FakePodcastReading()
    reading.stubRecentDescriptions(Self.recurringHistory, error: CancellationError())
    reading.setEpisode(
      Self.context(
        episodeID: "episode-1",
        description: "<p>The episode.</p><p>\(Self.plug)</p><p>____</p><p>Credits.</p>"),
      itemID: "show-1", episodeID: "episode-1")
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: reading)

    reading.tick(itemID: "show-1")
    await waitUntil { model.state != .loading }
    await awaitQuiescence("the card to settle", of: { "\(model.state)" })
    if case .loaded(let presentation) = model.state {
      #expect(presentation.notes == "The episode.\n\n\(Self.plug)")
      #expect(presentation.supplementaryNotes == "Credits.")
    } else {
      Issue.record("expected a loaded card")
    }
  }

  @MainActor
  @Test func stoppingAndRestartingObservationResumesUpdates() async {
    let reading = FakePodcastReading()
    let initial = Self.context(episodeID: "episode-1", status: .notDownloaded)
    let updated = Self.context(episodeID: "episode-1", status: .completed)
    reading.setEpisode(initial, itemID: "show-1", episodeID: "episode-1")
    let model = PodcastEpisodeCardModel(
      itemID: "show-1", episodeID: "episode-1", reading: reading)

    reading.tick(itemID: "show-1")
    await waitUntil {
      if case .loaded(let presentation) = model.state {
        return presentation.deviceDownloadText == ItemDownloadCopy.text(for: .notDownloaded)
      }
      return false
    }

    model.stopObserving()
    reading.setEpisode(updated, itemID: "show-1", episodeID: "episode-1")
    reading.tick(itemID: "show-1")
    await awaitQuiescence("the stopped episode observation to settle", of: { "\(model.state)" })
    if case .loaded(let presentation) = model.state {
      #expect(presentation.deviceDownloadText == ItemDownloadCopy.text(for: .notDownloaded))
    } else {
      Issue.record("stopping observation should keep the current loaded presentation")
    }

    model.startObserving()
    reading.tick(itemID: "show-1")
    await waitUntil {
      if case .loaded(let presentation) = model.state {
        return presentation.deviceDownloadText == ItemDownloadCopy.text(for: .completed)
      }
      return false
    }
  }

  @MainActor
  @Test("a feed identity key is resolved to the row id before the coordinator is called")
  func identityKeyIsResolvedBeforeTheCoordinatorIsCalled() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 8, serverItemID: "server-item")])
    let model = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "guid:abc", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["guid:abc": 42]),
      nativeEpisodeServerSaving: saving)

    await model.performAction(.saveToServer)

    #expect(model.serverSaveStatus == .requested)
    #expect(saving.calls == [.save(feedID: 7, episodeID: 42, choice: nil)])
  }

  @MainActor
  @Test("an identity key with no row is a missing episode and never reaches the coordinator")
  func unresolvedIdentityKeyIsAMissingEpisode() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 8, serverItemID: "server-item")])
    let model = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9", reading: FakePodcastReading(),
      nativeEpisodeServerSaving: saving)

    // "9" would parse as a row id; the inert resolver is what decides, not the key's spelling.
    await model.performAction(.saveToServer)
    #expect(model.serverSaveStatus == .failed(.missingEpisode, phase: .save))
    #expect(
      model.actionErrorMessage == NativeEpisodeServerSaveCopy.disabledReason(.missingEpisode))

    await model.removeEpisodeFromServer()
    #expect(saving.saveCalls.isEmpty)
    #expect(saving.removeCalls.isEmpty)
  }

  @MainActor
  @Test("the card projection reads its status by resolved row id, not by the identity key")
  func cardProjectionResolvesTheIdentityKeyBeforeReadingStatus() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: NativeEpisodeServerSaveStatusSnapshot(status: .saved, attemptID: 3))
    let reading = FakePodcastReading()
    reading.setEpisode(
      Self.context(episodeID: "guid:abc"), itemID: "rss:7", episodeID: "guid:abc")
    let model = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "guid:abc", reading: reading,
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["guid:abc": 42]),
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: grantingCapabilityReading())
    reading.tick(itemID: "rss:7")

    #expect(await waitUntil { model.serverSaveStatus == .saved })
    #expect(statuses.calls == [.observeStatuses(feedID: 7, episodeIDs: [42])])
  }

  @MainActor
  @Test("a server episode card offers Remove for the confirmed Whirr-created copy behind its id")
  func serverEpisodeCardRemovesTheConfirmedWhirrCreatedCopy() async {
    let saving = FakeNativeEpisodeServerSaving()
    let statuses = FakeNativeEpisodeServerSaveStatusReading(serverItemStatuses: [
      "server-episode": .init(
        status: .saved, attemptID: 21, preflightPresence: .absentBeforeRequest)
    ])
    let reading = FakePodcastReading()
    reading.setEpisode(
      Self.context(episodeID: "server-episode"), itemID: "abs-show", episodeID: "server-episode")
    let model = PodcastEpisodeCardModel(
      itemID: "abs-show", episodeID: "server-episode", reading: reading,
      nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: grantingCapabilityReading())
    reading.tick(itemID: "abs-show")

    #expect(await waitUntil { model.serverSaveStatus == .saved })
    #expect(statuses.observedServerItemIDs == ["abs-show"])
    #expect(model.hostsServerSaveRemoval)
    #expect(model.isNativeFeed == false)
    #expect(model.serverSavePreflightPresence == .absentBeforeRequest)

    await model.performAction(.removeFromServer)
    #expect(saving.removeCalls == [21])
    #expect(saving.saveCalls.isEmpty)
  }

  /// The card's menu already offers Remove for a stalled removal (`removeAvailability`); the tap
  /// must reach the coordinator rather than end in "unavailable".
  @MainActor
  @Test("a native card retries a stalled removal through the coordinator")
  func nativeCardRetriesAStalledRemoval() async {
    for status: NativeEpisodeServerSaveStatus in [
      .uncertain(.transport, phase: .remove), .failed(.transport, phase: .remove),
    ] {
      let saving = FakeNativeEpisodeServerSaving()
      let model = PodcastEpisodeCardModel(
        itemID: "rss:7", episodeID: "9", reading: FakePodcastReading(),
        nativeEpisodeIDResolving: Self.resolver,
        nativeEpisodeServerSaving: saving,
        nativeEpisodeServerSaveStatusReading: FakeNativeEpisodeServerSaveStatusReading(
          snapshot: .init(status: status, attemptID: 12, preflightPresence: .absentBeforeRequest)))

      await model.performAction(.removeFromServer)

      #expect(saving.removeCalls == [12], "\(status)")
    }
  }

  @MainActor
  @Test("a server episode card retries a stalled removal through the coordinator")
  func serverEpisodeCardRetriesAStalledRemoval() async {
    for status: NativeEpisodeServerSaveStatus in [
      .uncertain(.transport, phase: .remove), .failed(.transport, phase: .remove),
    ] {
      let saving = FakeNativeEpisodeServerSaving()
      let statuses = FakeNativeEpisodeServerSaveStatusReading(serverItemStatuses: [
        "server-episode": .init(
          status: status, attemptID: 21, preflightPresence: .absentBeforeRequest)
      ])
      let reading = FakePodcastReading()
      reading.setEpisode(
        Self.context(episodeID: "server-episode"), itemID: "abs-show",
        episodeID: "server-episode")
      let model = PodcastEpisodeCardModel(
        itemID: "abs-show", episodeID: "server-episode", reading: reading,
        nativeEpisodeServerSaving: saving,
        nativeEpisodeServerSaveStatusReading: statuses,
        serverPodcastMutationCapabilityReading: grantingCapabilityReading())
      reading.tick(itemID: "abs-show")
      #expect(await waitUntil { model.serverSaveStatus == status }, "\(status)")

      await model.performAction(.removeFromServer)

      #expect(saving.removeCalls == [21], "\(status)")
    }
  }

  @MainActor
  @Test("an accepted save raises the card banner and its dismissal leaves the status alone")
  func acceptedSaveRaisesTheCardBanner() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 8, serverItemID: "server-item")])
    let model = PodcastEpisodeCardModel(
      itemID: "rss:7", episodeID: "9", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: saving)

    await model.performAction(.saveToServer)
    #expect(model.serverSaveBannerMessage == NativeEpisodeServerSaveCopy.requested)

    model.dismissServerSaveBanner()
    #expect(model.serverSaveBannerMessage == nil)
    #expect(model.serverSaveStatus == .requested)
    #expect(model.serverSaveFeedbackMessage == NativeEpisodeServerSaveCopy.requested)
  }

  private static func context(
    episodeID: String,
    status: ItemDownloadStatus = .notDownloaded,
    isAvailableOnServer: Bool = true,
    description: String? = nil
  ) -> PodcastEpisodeContext {
    PodcastEpisodeContext(
      episode: PodcastEpisodeSummary(
        id: episodeID, title: "Episode", subtitle: nil, episodeDescription: description,
        seasonNumber: nil, episodeNumber: nil, episodeType: nil,
        durationSeconds: 120, sizeBytes: nil, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        progressSeconds: 0, isPlayed: false, isFinished: false,
        downloadStatus: status, isAvailableOnServer: isAvailableOnServer),
      showTitle: "The Rest Is Politics: US", showAuthor: "Goalhanger",
      artworkURL: nil, artworkFeedURL: nil)
  }
}

/// The card model has no `observeEpisodes` array of its own to inspect. It uses the show model's
/// signal as a "something changed" tick and re-reads by ref, so an empty array is all it needs.
extension FakePodcastReading {
  fileprivate func tick(itemID: String) {
    pushEpisodes([], itemID: itemID)
  }

  /// The context carries its own episode id, which is the id the read is keyed by.
  fileprivate func setEpisode(
    _ context: PodcastEpisodeContext, itemID: String, episodeID: String
  ) {
    stubEpisode(context, itemID: itemID)
  }

  fileprivate var episodeReadCount: Int {
    calls.filter { call in
      if case .episode = call { return true }
      return false
    }.count
  }

  fileprivate var descriptionReadCount: Int {
    calls.filter { call in
      if case .recentEpisodeDescriptions = call { return true }
      return false
    }.count
  }
}

extension FakeNativeEpisodeServerSaving {
  fileprivate var saveCalls: [Call] {
    calls.filter { call in
      if case .save = call { return true }
      return false
    }
  }

  fileprivate var removeCalls: [Int64] {
    calls.compactMap { call -> Int64? in
      if case .remove(let attemptID) = call { return attemptID }
      return nil
    }
  }
}

extension FakeNativeEpisodeServerSaveStatusReading {
  fileprivate var observedServerItemIDs: [String] {
    calls.compactMap { call -> String? in
      if case .observeServerItemStatuses(let serverItemID) = call { return serverItemID }
      return nil
    }
  }
}

/// The capability a card with every server action available reads.
private func grantingCapabilityReading() -> FakeServerPodcastMutationCapabilityReading {
  FakeServerPodcastMutationCapabilityReading(canSave: true, canRemove: true)
}

private final class ControllableAccountIdentityReading:
  AccountIdentityReading, @unchecked Sendable
{
  private let lock = NSLock()
  private var continuation: AsyncStream<AccountIdentity?>.Continuation?
  private var hasObserverValue = false

  var hasObserver: Bool { lock.withLock { hasObserverValue } }

  func observeAccountIdentity() -> AsyncStream<AccountIdentity?> {
    AsyncStream { continuation in
      lock.withLock {
        self.continuation = continuation
        self.hasObserverValue = true
      }
    }
  }

  func push(_ identity: AccountIdentity?) {
    lock.withLock { continuation }?.yield(identity)
  }
}
