import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite struct PodcastShowServerSaveTests {
  /// The identity key the suite's episodes carry, mapped to the row id the coordinator sees.
  private static let resolver = StaticNativeEpisodeIDResolving(["9": 9])

  @Test func serverActionsAreShowOnlyAndDisabledRemainsVisible() {
    let enabled = PodcastShowPresentation.episodeActions(
      status: .notDownloaded,
      isAvailableOnServer: true,
      surface: .show,
      serverSave: .enabled,
      serverRemove: .enabled)
    #expect(enabled.contains(.saveToServer))
    #expect(enabled.contains(.removeFromServer))

    let detail = PodcastShowPresentation.episodeActions(
      status: .notDownloaded,
      isAvailableOnServer: true,
      surface: .episodeDetail,
      serverSave: .enabled,
      serverRemove: .enabled)
    #expect(detail.contains(.saveToServer))
    #expect(detail.contains(.removeFromServer))

    for surface in [PodcastMenuSurface.episodeList, .card] {
      let actions = PodcastShowPresentation.episodeActions(
        status: .notDownloaded,
        isAvailableOnServer: true,
        surface: surface,
        serverSave: .enabled,
        serverRemove: .enabled)
      #expect(actions.contains(.saveToServer) == false)
      #expect(actions.contains(.removeFromServer) == false)
    }

    let disabled = PodcastShowPresentation.episodeActions(
      status: .notDownloaded,
      isAvailableOnServer: true,
      surface: .show,
      serverSave: .disabled(.credentialedFeed),
      serverRemove: .hidden)
    #expect(disabled.contains(.saveToServer))
    #expect(disabled.contains(.removeFromServer) == false)
  }

  @MainActor
  @Test func cancellingChoiceClearsPendingPresentationWithoutAnotherCoordinatorCall() async {
    let prompt = NativeEpisodeServerSaveChoicePrompt.existing(candidates: [
      NativeEpisodeServerSaveExistingChoice(serverItemID: "candidate-a", displayName: "Candidate A")
    ])
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.needsChoice(attemptID: 5, prompt: prompt)])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver, nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: false))

    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    model.serverSave.dismissServerSaveFeedback()

    #expect(model.serverSave.pendingServerSaveChoice == nil)
    #expect(model.serverSave.serverSaveStatus == .none)
    #expect(saving.saveCalls.count == 1)
  }

  @MainActor
  @Test func acceptedSaveIsRequestedAndNeverSaved() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 4, serverItemID: "server-item")])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver, nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: true))

    await model.serverSave.saveEpisodeToServer(episodeID: "9")

    #expect(model.serverSave.serverSaveStatus == .requested)
    #expect(model.serverSave.serverSaveFeedbackMessage == NativeEpisodeServerSaveCopy.requested)
    #expect(model.serverSave.serverSaveFeedbackMessage != NativeEpisodeServerSaveCopy.saved)
    let calls = saving.saveCalls
    #expect(calls.count == 1)
    #expect(calls.first?.0 == 7)
    #expect(calls.first?.1 == 9)
    #expect(calls.first?.2 == nil)
  }

  @MainActor
  @Test("an account baseline does not clear an accepted show presentation")
  func accountBaselinePreservesShowServerSavePresentation() async {
    let accountReading = ControllableShowAccountIdentityReading()
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: FakeNativeEpisodeServerSaving(
        saveOutcomes: [.accepted(attemptID: 4, serverItemID: "server-item")]),
      serverPodcastMutationCapabilityReading: fullCapabilityReading(),
      accountIdentityReading: accountReading)
    await waitUntil { accountReading.hasObserver }

    accountReading.push(
      AccountIdentity(id: 1, clientUUID: "client-a", serverIdentityFingerprint: "fingerprint-a"))
    await model.serverSave.saveEpisodeToServer(episodeID: "9")

    #expect(model.serverSave.serverSaveStatus == .requested)
    #expect(model.serverSave.serverSaveFeedbackMessage == NativeEpisodeServerSaveCopy.requested)
  }

  @MainActor
  @Test("pushed account logout clears show server-save presentation")
  func accountUnavailableClearsShowServerSavePresentation() async {
    let accountReading = ControllableShowAccountIdentityReading()
    let capability = FakeServerPodcastMutationCapabilityReading(canSave: true, canRemove: true)
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 4, serverItemID: "server-item")])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver, nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: capability,
      accountIdentityReading: accountReading)
    await waitUntil { accountReading.hasObserver }
    accountReading.push(
      AccountIdentity(id: 1, clientUUID: "client-a", serverIdentityFingerprint: "fingerprint-a"))
    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    accountReading.push(nil)

    #expect(
      await waitUntil {
        let invalidationCount = capability.invalidationCount
        return model.serverSave.serverSaveStatus == .none && model.serverSave.serverSaveFeedbackMessage == nil
          && model.serverSave.serverMutationCapability == .none
          && model.serverSave.serverSaveStatus(for: "9") == .none
          && invalidationCount == 1
      })
    #expect(saving.removeCalls.isEmpty)
  }

  @MainActor
  @Test("a pushed account replacement clears show server-save presentation")
  func accountReplacementClearsShowServerSavePresentation() async {
    let accountReading = ControllableShowAccountIdentityReading()
    let capability = FakeServerPodcastMutationCapabilityReading(canSave: true, canRemove: true)
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: FakeNativeEpisodeServerSaving(
        saveOutcomes: [.accepted(attemptID: 4, serverItemID: "server-item")]),
      serverPodcastMutationCapabilityReading: capability,
      accountIdentityReading: accountReading)
    await waitUntil { accountReading.hasObserver }
    accountReading.push(
      AccountIdentity(id: 1, clientUUID: "client-a", serverIdentityFingerprint: "fingerprint-a"))
    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    accountReading.push(
      AccountIdentity(id: 2, clientUUID: "client-b", serverIdentityFingerprint: "fingerprint-b"))

    #expect(
      await waitUntil {
        let invalidationCount = capability.invalidationCount
        return model.serverSave.serverSaveStatus == .none && model.serverSave.serverSaveFeedbackMessage == nil
          && model.serverSave.serverMutationCapability == .none
          && model.serverSave.serverSaveStatus(for: "9") == .none
          && invalidationCount == 1
      })
  }

  @MainActor
  @Test("an equal pushed account identity leaves show presentation unchanged")
  func equalAccountIdentityDoesNotClearShowServerSavePresentation() async {
    let accountReading = ControllableShowAccountIdentityReading()
    let capability = FakeServerPodcastMutationCapabilityReading(canSave: true, canRemove: true)
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: FakeNativeEpisodeServerSaving(
        saveOutcomes: [.accepted(attemptID: 4, serverItemID: "server-item")]),
      serverPodcastMutationCapabilityReading: capability,
      accountIdentityReading: accountReading)
    await waitUntil { accountReading.hasObserver }
    let identity = AccountIdentity(
      id: 1, clientUUID: "client-a", serverIdentityFingerprint: "fingerprint-a")
    accountReading.push(identity)
    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    accountReading.push(identity)
    await awaitQuiescence(
      "equal account identity lifecycle",
      of: {
        let invalidationCount = capability.invalidationCount
        return "\(model.serverSave.serverSaveStatus)-\(invalidationCount)"
      })

    #expect(model.serverSave.serverSaveStatus == .requested)
    #expect(model.serverSave.serverSaveFeedbackMessage == NativeEpisodeServerSaveCopy.requested)
    #expect(capability.invalidationCount == 0)
  }

  @MainActor
  @Test("native subscriptions turning off clears show server-save episode maps")
  func nativeSubscriptionsDisabledClearsShowServerSavePresentation() async {
    let subscriptions = FakeNativePodcastSubscriptionsReading()
    let prompt = NativeEpisodeServerSaveChoicePrompt.existing(candidates: [
      NativeEpisodeServerSaveExistingChoice(serverItemID: "candidate", displayName: "Candidate")
    ])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: FakeNativeEpisodeServerSaving(
        saveOutcomes: [.needsChoice(attemptID: 5, prompt: prompt)]),
      serverPodcastMutationCapabilityReading: fullCapabilityReading(),
      nativePodcastSubscriptionsReading: subscriptions)
    await waitUntil { subscriptions.observeEnabledCallCount > 0 }

    let versionBefore = model.serverSave.serverSavePresentationVersion
    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    #expect(model.serverSave.pendingServerSaveChoice != nil)
    #expect(model.serverSave.serverSaveStatus(for: "9") == .preparing)
    subscriptions.stubEnabled(false)

    #expect(
      await waitUntil {
        model.serverSave.pendingServerSaveChoice == nil
          && model.serverSave.serverSaveStatus == .none
          && model.serverSave.serverSaveStatus(for: "9") == .none
          && model.serverSave.serverSavePreflightPresence(for: "9") == nil
          && model.serverSave.serverSaveAttemptID(for: "9") == nil
          && model.serverSave.serverSavePresentationVersion == versionBefore + 1
      })
  }

  @MainActor
  @Test("a teardown during an in-flight show save drops the late outcome")
  func teardownDuringInFlightShowSaveDropsItsOutcome() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 8, serverItemID: "server-item")])
    saving.saveGate.hold()
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: fullCapabilityReading())

    let saveTask = Task { await model.serverSave.saveEpisodeToServer(episodeID: "9") }
    await saving.recorder.waitUntil(count: 1)
    #expect(model.serverSave.serverSaveStatus(for: "9") == .preparing)

    model.serverSave.clearServerSavePresentation(for: .accountUnavailable)
    saving.saveGate.release()
    await saveTask.value

    // The outcome still exists durably; only this presentation, which was torn down, ignores it.
    #expect(model.serverSave.serverSaveStatus == .none)
    #expect(model.serverSave.serverSaveFeedbackMessage == nil)
    #expect(model.serverSave.serverSaveStatus(for: "9") == .none)
    #expect(model.serverSave.serverSaveAttemptID(for: "9") == nil)
  }

  @MainActor
  @Test("native subscriptions turning off hides show capability and turning on reloads it")
  func nativeSubscriptionsToggleHidesAndReloadsShowCapability() async {
    let subscriptions = FakeNativePodcastSubscriptionsReading()
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(episodes: [summary("9")]),
      serverPodcastMutationCapabilityReading: fullCapabilityReading(),
      nativePodcastSubscriptionsReading: subscriptions)
    #expect(await waitUntil { model.serverSave.serverMutationCapability.canSave })
    await waitUntil { subscriptions.observeEnabledCallCount > 0 }

    subscriptions.stubEnabled(false)
    #expect(await waitUntil { model.serverSave.serverMutationCapability.canSave == false })

    subscriptions.stubEnabled(true)
    #expect(await waitUntil { model.serverSave.serverMutationCapability.canSave })
  }

  @MainActor
  @Test("opening a native show recovers its unsettled attempts behind the first projection read")
  func showProjectionRunsFeedRecoveryAndRereadsVisitedRows() async {
    let recovering = RecordingShowRecovering(visited: [1])
    // The first row read answers Requested; the re-read after recovery answers Saved.
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: NativeEpisodeServerSaveStatusSnapshot(
        status: .saved, attemptID: 1, preflightPresence: .absentBeforeRequest))
    statuses.enqueueSnapshots([
      NativeEpisodeServerSaveStatusSnapshot(status: .requested, attemptID: 1)
    ])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(episodes: [summary("9")]),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaveRecovering: recovering,
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: fullCapabilityReading())

    #expect(await waitUntil { recovering.feedIDs == [7] })
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "9") == .saved })
    #expect(model.serverSave.serverSaveAttemptID(for: "9") == 1)
  }

  @MainActor
  @Test func choicePromptDoesNotCommitUntilAChoiceIsSubmitted() async {
    let prompt = NativeEpisodeServerSaveChoicePrompt.existing(candidates: [
      NativeEpisodeServerSaveExistingChoice(serverItemID: "candidate-a", displayName: "Candidate A")
    ])
    let saving = FakeNativeEpisodeServerSaving(saveOutcomes: [
      .needsChoice(attemptID: 5, prompt: prompt),
      .accepted(attemptID: 6, serverItemID: "candidate-a"),
    ])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver, nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: false))

    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    #expect(model.serverSave.pendingServerSaveChoice?.prompt == prompt)
    #expect(model.serverSave.serverSaveStatus == .preparing)
    #expect(saving.saveCalls.count == 1)

    await model.serverSave.chooseSaveDestination(.existing(serverItemID: "candidate-a"))
    #expect(model.serverSave.pendingServerSaveChoice == nil)
    #expect(model.serverSave.serverSaveStatus == .requested)
    #expect(saving.saveCalls.count == 2)
  }

  @MainActor
  @Test("one matching server show saves directly, with no sheet and visible progress")
  func directReuseSavesWithoutAPrompt() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 4, serverItemID: "existing-show")])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver, nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: false))

    await model.serverSave.saveEpisodeToServer(episodeID: "9")

    #expect(model.serverSave.pendingServerSaveChoice == nil)
    #expect(model.serverSave.serverSaveStatus == .requested)
    #expect(model.serverSave.serverSaveStatus(for: "9") == .requested)
    #expect(model.serverSave.serverSaveFeedbackMessage == NativeEpisodeServerSaveCopy.requested)
    #expect(model.actionErrorMessage == nil)
    let calls = saving.saveCalls
    #expect(calls.count == 1)
    #expect(calls.first?.2 == nil)
  }

  @MainActor
  @Test("confirming the sole destination resubmits its opaque library and folder ids")
  func soleDestinationConfirmationSubmitsOpaqueIDs() async {
    let prompt = NativeEpisodeServerSaveChoicePrompt.libraryAndFolder(libraries: [
      NativeEpisodeServerSaveLibraryChoice(
        libraryID: "lib-1", displayName: "Podcasts",
        folders: [NativeEpisodeServerSaveFolderChoice(folderID: "folder-1", displayName: "Podcasts")])
    ])
    let saving = FakeNativeEpisodeServerSaving(saveOutcomes: [
      .needsChoice(attemptID: 5, prompt: prompt),
      .accepted(attemptID: 6, serverItemID: "created-show"),
    ])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver, nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: false))

    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    let pending = model.serverSave.pendingServerSaveChoice
    #expect(pending?.prompt == prompt)
    #expect(model.serverSave.serverSaveStatus == .preparing)

    // The sheet derives the one choice from the prompt and hands back only its ids.
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: pending?.prompt ?? prompt, podcastName: "Night Vale")
    let choice = presentation.soleDestinationChoice
    #expect(choice == .libraryAndFolder(libraryID: "lib-1", folderID: "folder-1"))
    await model.serverSave.chooseSaveDestination(choice ?? .existing(serverItemID: "wrong"))

    #expect(model.serverSave.pendingServerSaveChoice == nil)
    #expect(model.serverSave.serverSaveStatus == .requested)
    let calls = saving.saveCalls
    #expect(calls.count == 2)
    #expect(calls.last?.0 == 7)
    #expect(calls.last?.1 == 9)
    #expect(calls.last?.2 == .libraryAndFolder(libraryID: "lib-1", folderID: "folder-1"))
  }

  @MainActor
  @Test("cancelling the creation sheet calls no mutation")
  func cancellingTheCreationSheetCallsNoMutation() async {
    let prompt = NativeEpisodeServerSaveChoicePrompt.libraryAndFolder(libraries: [
      NativeEpisodeServerSaveLibraryChoice(
        libraryID: "lib-1", displayName: "Podcasts",
        folders: [NativeEpisodeServerSaveFolderChoice(folderID: "folder-1", displayName: "Podcasts")])
    ])
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.needsChoice(attemptID: 5, prompt: prompt)])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver, nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: false))

    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    #expect(model.serverSave.pendingServerSaveChoice != nil)
    model.serverSave.dismissServerSaveFeedback()

    #expect(model.serverSave.pendingServerSaveChoice == nil)
    #expect(model.serverSave.serverSaveStatus == .none)
    #expect(model.serverSave.serverSaveStatus(for: "9") == .none)
    #expect(saving.saveCalls.count == 1)
    #expect(saving.removeCalls.isEmpty)
  }

  @MainActor
  @Test func nonNativeShowNeverCallsTheServerCoordinator() async {
    let saving = FakeNativeEpisodeServerSaving()
    let model = PodcastShowModel(
      itemID: "server-show", reading: FakePodcastReading(), nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: true))

    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    await model.serverSave.removeEpisodeFromServer(episodeID: "9")
    #expect(saving.saveCalls.isEmpty)
    #expect(saving.removeCalls.isEmpty)
  }

  @MainActor
  @Test("a server show offers Remove for the confirmed Whirr-created copy the projection names")
  func serverShowRemovesTheConfirmedWhirrCreatedCopyByServerEpisodeID() async {
    let saving = FakeNativeEpisodeServerSaving(
      removeOutcomes: [.inProgress(attemptID: 21, state: .removed, serverItemID: "server-show")])
    let statuses = FakeNativeEpisodeServerSaveStatusReading(serverItemStatuses: [
      "server-episode": .init(
        status: .saved, attemptID: 21, preflightPresence: .absentBeforeRequest),
      "pre-existing": .init(status: .saved, attemptID: 22, preflightPresence: .preExisting),
    ])
    let model = PodcastShowModel(
      itemID: "server-show",
      reading: FakePodcastReading(episodes: [
        summary("server-episode"), summary("pre-existing"), summary("untouched"),
      ]),
      nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: true))

    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "server-episode") == .saved })
    #expect(statuses.observedServerItemIDs == ["server-show"])
    #expect(model.serverSave.hostsServerSaveRemoval)
    #expect(model.isNativeFeed == false)
    #expect(model.serverSave.serverMutationCapability.canRemove)
    #expect(
      NativeEpisodeServerSaveStatus.removeAvailability(
        capability: model.serverSave.serverMutationCapability,
        isNativeFeed: model.serverSave.hostsServerSaveRemoval,
        status: model.serverSave.serverSaveStatus(for: "server-episode"),
        preflightPresence: model.serverSave.serverSavePreflightPresence(for: "server-episode")) == .enabled)
    #expect(
      NativeEpisodeServerSaveStatus.removeAvailability(
        capability: model.serverSave.serverMutationCapability,
        isNativeFeed: model.serverSave.hostsServerSaveRemoval,
        status: model.serverSave.serverSaveStatus(for: "pre-existing"),
        preflightPresence: model.serverSave.serverSavePreflightPresence(for: "pre-existing")) == .hidden)
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: model.serverSave.serverMutationCapability,
        isNativeFeed: model.isNativeFeed,
        isCredentialedFeed: false,
        status: model.serverSave.serverSaveStatus(for: "untouched")) == .hidden)

    await model.serverSave.removeEpisodeFromServer(episodeID: "server-episode")

    #expect(saving.removeCalls == [21])
    #expect(model.serverSave.serverSaveStatus(for: "server-episode") == .removed)
    #expect(model.serverSave.serverSaveBannerMessage == NativeEpisodeServerSaveCopy.removed)

    // The pre-existing copy and an untouched row never reach the coordinator.
    await model.serverSave.removeEpisodeFromServer(episodeID: "pre-existing")
    await model.serverSave.removeEpisodeFromServer(episodeID: "untouched")
    #expect(saving.removeCalls == [21])
    #expect(saving.saveCalls.isEmpty)
  }

  @MainActor
  @Test("an accepted save raises the transient banner and its dismissal leaves the rest alone")
  func acceptedSaveRaisesABannerWhoseDismissalIsInert() async {
    let prompt = NativeEpisodeServerSaveChoicePrompt.existing(candidates: [
      NativeEpisodeServerSaveExistingChoice(serverItemID: "candidate-a", displayName: "Candidate A")
    ])
    let saving = FakeNativeEpisodeServerSaving(saveOutcomes: [
      .accepted(attemptID: 4, serverItemID: "server-item"),
      .needsChoice(attemptID: 5, prompt: prompt),
    ])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["9": 9, "10": 10]),
      nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: true))

    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    #expect(model.serverSave.serverSaveBannerMessage == NativeEpisodeServerSaveCopy.requested)

    model.serverSave.dismissServerSaveBanner()
    #expect(model.serverSave.serverSaveBannerMessage == nil)
    #expect(model.serverSave.serverSaveStatus == .requested)
    #expect(model.serverSave.serverSaveFeedbackMessage == NativeEpisodeServerSaveCopy.requested)

    // A destination sheet outlives the banner's timer: the banner clear must not cancel it.
    await model.serverSave.saveEpisodeToServer(episodeID: "10")
    #expect(model.serverSave.pendingServerSaveChoice?.attemptID == 5)
    #expect(model.serverSave.serverSaveBannerMessage == nil)
    model.serverSave.dismissServerSaveBanner()
    #expect(model.serverSave.pendingServerSaveChoice?.attemptID == 5)
  }

  @MainActor
  @Test("the confirmation landing from the stream after Requested raises the Saved banner")
  func confirmationFromTheStreamRaisesTheSavedBanner() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 4, serverItemID: "server-item")])
    let statuses = FakeNativeEpisodeServerSaveStatusReading()
    let model = PodcastShowModel(
      itemID: "rss:7",
      reading: FakePodcastReading(episodes: [summary("9")]),
      nativeEpisodeIDResolving: Self.resolver,
      nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: true))
    #expect(await waitUntil { statuses.statusSubscriberCount > 0 })

    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    #expect(model.serverSave.serverSaveBannerMessage == NativeEpisodeServerSaveCopy.requested)
    model.serverSave.dismissServerSaveBanner()

    statuses.pushStatuses([
      9: .init(status: .requested, attemptID: 4, preflightPresence: .absentBeforeRequest)
    ])
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "9") == .requested })
    #expect(model.serverSave.serverSaveBannerMessage == nil)

    statuses.pushStatuses([
      9: .init(status: .saved, attemptID: 4, preflightPresence: .absentBeforeRequest)
    ])
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "9") == .saved })
    #expect(model.serverSave.serverSaveBannerMessage == NativeEpisodeServerSaveCopy.saved)
  }

  @MainActor
  @Test func uncertainSaveIsPhaseSpecificAndNotRetried() async {
    let saving = FakeNativeEpisodeServerSaving(saveOutcomes: [
      .uncertain(attemptID: 8, state: .createUncertain, category: .transport)
    ])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver, nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: true))

    await model.serverSave.saveEpisodeToServer(episodeID: "9")

    #expect(model.serverSave.serverSaveStatus == .uncertain(.transport, phase: .save))
    #expect(model.serverSave.serverSaveFeedbackMessage == NativeEpisodeServerSaveCopy.saveUncertain)
    #expect(model.actionErrorMessage == nil)
    #expect(saving.saveCalls.count == 1)
  }

  @MainActor
  @Test func removeUsesOnlyConfirmedWhirrCreatedAttempt() async {
    let saving = FakeNativeEpisodeServerSaving(
      removeOutcomes: [.inProgress(attemptID: 12, state: .removed, serverItemID: nil)])
    let status = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: .init(status: .saved, attemptID: 12, preflightPresence: .absentBeforeRequest))
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: Self.resolver, nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveStatusReading: status,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: true))

    await model.serverSave.removeEpisodeFromServer(episodeID: "9")

    #expect(model.serverSave.serverSaveStatus == .removed)
    let calls = saving.removeCalls
    #expect(calls == [12])
  }

  @MainActor
  @Test("a stalled removal is retried through the coordinator rather than reported unavailable")
  func removeRetriesAStalledRemovalAttempt() async {
    for status: NativeEpisodeServerSaveStatus in [
      .uncertain(.transport, phase: .remove), .failed(.transport, phase: .remove),
    ] {
      let saving = FakeNativeEpisodeServerSaving(
        removeOutcomes: [.inProgress(attemptID: 12, state: .removed, serverItemID: nil)])
      let statusReading = FakeNativeEpisodeServerSaveStatusReading(
        snapshot: .init(status: status, attemptID: 12, preflightPresence: .absentBeforeRequest))
      let model = PodcastShowModel(
        itemID: "rss:7", reading: FakePodcastReading(),
        nativeEpisodeIDResolving: Self.resolver, nativeEpisodeServerSaving: saving,
        nativeEpisodeServerSaveStatusReading: statusReading,
        serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
          canSave: true, canRemove: true))

      await model.serverSave.removeEpisodeFromServer(episodeID: "9")

      #expect(model.serverSave.serverSaveStatus == .removed)
      #expect(model.actionErrorMessage == nil)
      #expect(saving.removeCalls == [12])
    }
  }

  @MainActor
  @Test("a feed identity key is resolved to the row id before the coordinator is called")
  func identityKeyIsResolvedBeforeTheCoordinatorIsCalled() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 4, serverItemID: "server-item")])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["guid:abc": 42]),
      nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: true))

    await model.serverSave.saveEpisodeToServer(episodeID: "guid:abc")

    #expect(model.serverSave.serverSaveStatus == .requested)
    #expect(model.serverSave.serverSaveStatus(for: "guid:abc") == .requested)
    let calls = saving.saveCalls
    #expect(calls.count == 1)
    #expect(calls.first?.0 == 7)
    #expect(calls.first?.1 == 42)
  }

  @MainActor
  @Test("an identity key with no row is a missing episode and never reaches the coordinator")
  func unresolvedIdentityKeyIsAMissingEpisode() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 4, serverItemID: "server-item")])
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(), nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: true))

    // "9" would parse as a row id; the inert resolver is what decides, not the key's spelling.
    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    #expect(model.serverSave.serverSaveStatus == .failed(.missingEpisode, phase: .save))
    #expect(
      model.actionErrorMessage == NativeEpisodeServerSaveCopy.disabledReason(.missingEpisode))

    await model.serverSave.removeEpisodeFromServer(episodeID: "9")
    #expect(saving.saveCalls.isEmpty)
    #expect(saving.removeCalls.isEmpty)
  }

  @MainActor
  @Test("the show projection reads statuses by resolved row id, not by the identity key")
  func showProjectionResolvesIdentityKeysBeforeReadingStatus() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: NativeEpisodeServerSaveStatusSnapshot(status: .saved, attemptID: 3))
    let model = PodcastShowModel(
      itemID: "rss:7",
      reading: FakePodcastReading(episodes: [summary("guid:abc"), summary("guid:missing")]),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["guid:abc": 42]),
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: fullCapabilityReading())

    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "guid:abc") == .saved })
    #expect(model.serverSave.serverSaveAttemptID(for: "guid:abc") == 3)
    #expect(model.serverSave.serverSaveStatus(for: "guid:missing") == .none)
    #expect(statuses.aggregateReads == [.observeStatuses(feedID: 7, episodeIDs: [42])])
  }
  @MainActor
  @Test("the show projection reads every listed status in one batched call")
  func showProjectionBatchesStatusReads() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: NativeEpisodeServerSaveStatusSnapshot(status: .saved, attemptID: 3))
    let model = PodcastShowModel(
      itemID: "rss:7",
      reading: FakePodcastReading(episodes: [summary("a"), summary("b"), summary("missing")]),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["a": 1, "b": 2]),
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: fullCapabilityReading())

    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "b") == .saved })
    #expect(model.serverSave.serverSaveStatus(for: "a") == .saved)
    #expect(model.serverSave.serverSaveStatus(for: "missing") == .none)
    #expect(statuses.aggregateReads == [.observeStatuses(feedID: 7, episodeIDs: [1, 2])])
    #expect(statuses.singleReadCount == 0)
  }

  @MainActor
  @Test("a re-emission with the same episode ids does not re-read statuses")
  func sameEpisodeIDsDoNotReReadStatuses() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading(
      snapshot: NativeEpisodeServerSaveStatusSnapshot(status: .saved, attemptID: 3))
    let reading = FakePodcastReading()
    let model = PodcastShowModel(
      itemID: "rss:7",
      reading: reading,
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["a": 1, "b": 2, "c": 3]),
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: fullCapabilityReading())

    reading.pushEpisodes([summary("a"), summary("b")])
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "b") == .saved })
    // A progress or download write re-emits the same ids; nothing about the projection changed.
    reading.pushEpisodes([summary("a"), summary("b")])
    reading.pushEpisodes([summary("a"), summary("b")])
    #expect(await waitUntil { model.episodes.count == 2 })
    // A refresh that adds an episode is a new id set, and reads again.
    reading.pushEpisodes([summary("a"), summary("b"), summary("c")])

    #expect(await waitUntil { statuses.aggregateReads.count == 2 })
    #expect(
      statuses.aggregateReads == [
        .observeStatuses(feedID: 7, episodeIDs: [1, 2]),
        .observeStatuses(feedID: 7, episodeIDs: [1, 2, 3]),
      ])
    // The read is recorded when the observation opens, before the model applies its first value.
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "c") == .saved })
  }
  // MARK: - The fence's latest attempt

  /// Rows 9 and 10: a stale attempt for 9 beside a live marker for 10. Once the marker lands the
  /// stale row has been decided, so the test can read 9 without waiting on a negative.
  private static let staleAttemptBesideMarker: [Int64: NativeEpisodeServerSaveStatusSnapshot] = [
    9: .init(status: .saved, attemptID: 4, preflightPresence: .absentBeforeRequest),
    10: .init(status: .saved, attemptID: 1, preflightPresence: .absentBeforeRequest),
  ]

  @MainActor
  private static func fenceModel(
    saving: some NativeEpisodeServerSaving, statuses: FakeNativeEpisodeServerSaveStatusReading
  ) -> PodcastShowModel {
    PodcastShowModel(
      itemID: "rss:7",
      reading: FakePodcastReading(episodes: [summary("9"), summary("10")]),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["9": 9, "10": 10]),
      nativeEpisodeServerSaving: saving,
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: FakeServerPodcastMutationCapabilityReading(
        canSave: true, canRemove: true))
  }

  @MainActor
  @Test("dismissing a destination choice does not reopen the row to an older attempt")
  func dismissedChoiceKeepsTheLatestAttempt() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.needsChoice(attemptID: 5, prompt: .existing(candidates: []))])
    let statuses = FakeNativeEpisodeServerSaveStatusReading()
    let model = Self.fenceModel(saving: saving, statuses: statuses)
    #expect(await waitUntil { statuses.statusSubscriberCount > 0 })

    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    #expect(model.serverSave.pendingServerSaveChoice?.attemptID == 5)
    model.serverSave.dismissServerSaveFeedback()
    #expect(model.serverSave.serverSaveStatus(for: "9") == .none)

    statuses.pushStatuses(Self.staleAttemptBesideMarker)
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "10") == .saved })
    #expect(model.serverSave.serverSaveStatus(for: "9") == .none)
  }

  @MainActor
  @Test("a failure that names no attempt does not reopen the row to an older attempt")
  func failureWithNoAttemptKeepsTheLatestAttempt() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.failed(attemptID: nil, state: .failed, category: .permissionChanged)])
    let statuses = FakeNativeEpisodeServerSaveStatusReading()
    let model = Self.fenceModel(saving: saving, statuses: statuses)
    #expect(await waitUntil { statuses.statusSubscriberCount > 0 })
    statuses.pushStatuses([9: .init(status: .failed(.transport, phase: .save), attemptID: 5)])
    #expect(
      await waitUntil { model.serverSave.serverSaveStatus(for: "9") == .failed(.transport, phase: .save) })

    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    #expect(model.serverSave.serverSaveStatus(for: "9") == .failed(.permissionChanged, phase: .save))

    statuses.pushStatuses(Self.staleAttemptBesideMarker)
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "10") == .saved })
    #expect(model.serverSave.serverSaveStatus(for: "9") == .failed(.permissionChanged, phase: .save))
  }

  /// Remove's pull read writes the row unfenced. It moves what the row shows, not what
  /// the fence has seen.
  @MainActor
  @Test("Remove's fresh read of an unremovable row does not reopen it to an older attempt")
  func unremovableReadKeepsTheLatestAttempt() async {
    let saving = FakeNativeEpisodeServerSaving()
    let statuses = FakeNativeEpisodeServerSaveStatusReading()
    let model = Self.fenceModel(saving: saving, statuses: statuses)
    #expect(await waitUntil { statuses.statusSubscriberCount > 0 })
    statuses.pushStatuses([
      9: .init(status: .saved, attemptID: 5, preflightPresence: .absentBeforeRequest)
    ])
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "9") == .saved })

    // This reader's pull read answers `.none` with no attempt.
    await model.serverSave.removeEpisodeFromServer(episodeID: "9")
    #expect(model.serverSave.serverSaveStatus(for: "9") == .none)
    #expect(saving.removeCalls.isEmpty)

    statuses.pushStatuses(Self.staleAttemptBesideMarker)
    #expect(await waitUntil { model.serverSave.serverSaveStatus(for: "10") == .saved })
    #expect(model.serverSave.serverSaveStatus(for: "9") == .none)
  }

}

private func fullCapabilityReading() -> FakeServerPodcastMutationCapabilityReading {
  FakeServerPodcastMutationCapabilityReading(canSave: true, canRemove: true)
}

private func summary(_ id: String) -> PodcastEpisodeSummary {
  PodcastEpisodeSummary(
    id: id, title: id, subtitle: nil, episodeDescription: nil, seasonNumber: nil,
    episodeNumber: nil, episodeType: nil, durationSeconds: 120, sizeBytes: nil,
    publishedAt: Date(timeIntervalSince1970: 1_700_000_000), progressSeconds: 0,
    isPlayed: false, isFinished: false, downloadStatus: .notDownloaded,
    isAvailableOnServer: true)
}

private final class RecordingShowRecovering: NativeEpisodeServerSaveRecovering, @unchecked Sendable {
  private let lock = NSLock()
  private let visited: [Int64]
  private var feedIDValues: [Int64?] = []

  init(visited: [Int64]) { self.visited = visited }

  var feedIDs: [Int64?] { lock.withLock { feedIDValues } }

  func recoverPendingAttempts(feedId: Int64?) async -> [Int64] {
    lock.withLock { feedIDValues.append(feedId) }
    return visited
  }
}

private final class ControllableShowAccountIdentityReading:
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

extension FakeNativeEpisodeServerSaveStatusReading {
  /// Every aggregate read that named rows, by `statuses` or by an observation opening; a list
  /// with no rows asks nothing.
  fileprivate var aggregateReads: [Call] {
    calls.filter { call in
      switch call {
      case .statuses(_, let episodeIDs), .observeStatuses(_, let episodeIDs):
        episodeIDs.isEmpty == false
      default: false
      }
    }
  }

  /// How many single-row `status` reads were made.
  fileprivate var singleReadCount: Int {
    calls.filter { call in
      if case .status = call { true } else { false }
    }.count
  }

  /// The server item of every `observeServerItemStatuses`.
  fileprivate var observedServerItemIDs: [String] {
    calls.compactMap { call -> String? in
      if case .observeServerItemStatuses(let serverItemID) = call { serverItemID } else { nil }
    }
  }
}

private typealias RecordedSave = (feedID: Int64, episodeID: Int64, choice: ServerPodcastSaveChoice?)

extension FakeNativeEpisodeServerSaving {
  /// Every `save` the fake saw, in order.
  fileprivate var saveCalls: [RecordedSave] {
    calls.compactMap { call -> RecordedSave? in
      if case .save(let feedID, let episodeID, let choice) = call {
        (feedID: feedID, episodeID: episodeID, choice: choice)
      } else {
        nil
      }
    }
  }

  /// The attempt of every `remove` the fake saw, in order.
  fileprivate var removeCalls: [Int64] {
    calls.compactMap { call -> Int64? in
      if case .remove(let attemptID) = call { attemptID } else { nil }
    }
  }
}
