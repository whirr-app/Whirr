import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Save Show to Audiobookshelf… as the model sees it: when the menu item is offered, which
/// episode selection opens with, the mark that rides one batch, and the single write that turns
/// automatic downloads on for a show the batch created.
@MainActor
@Suite("Save Show to Audiobookshelf", .timeLimit(.minutes(1)))
struct PodcastShowSaveShowTests {
  private static let create = ServerPodcastSaveChoice.libraryAndFolder(
    libraryID: "lib", folderID: "folder")
  private static let existing = ServerPodcastSaveChoice.existing(serverItemID: "candidate")
  private static let prompt = NativeEpisodeServerSaveChoicePrompt.libraryAndFolder(libraries: [])
  private static let notTurnedOn = NativeEpisodeServerSaveCopy.automaticDownloadsNotTurnedOn
  private static let fingerprint = "fingerprint-a"
  private static let confirmed = ServerPodcastAutomationSettingsOutcome.confirmed(
    PodcastAutomationSettingsResult(autoDownloadEpisodes: true), refresh: .notAttempted)

  // MARK: Item presence

  @Test("offered for a saving account on a credential-free feed with no server copy")
  func offeredWhenEligible() async {
    let h = await makeHarness()
    #expect(h.model.serverSave.isCredentialReadCompleteWithNoCredential)
    #expect(h.model.serverSave.offersSaveShow)
  }

  @Test("not offered when the account cannot save")
  func notOfferedWithoutCapability() async {
    let h = await makeHarness(canSave: false, awaitCapability: false)
    await waitUntil("copies known") { h.model.serverSave.showSave.serverCopyItemIDs != nil }
    #expect(h.model.serverSave.offersSaveShow == false)
  }

  @Test("not offered while the credential read is pending, then offered once it finds none")
  func credentialPending() async {
    let h = await makeHarness(credential: .pending, awaitCredential: false)
    await waitUntil("capability") { h.model.serverSave.serverMutationCapability.canSave }
    await waitUntil("credential read started") { h.credential.reads >= 1 }
    #expect(h.model.serverSave.isCredentialReadCompleteWithNoCredential == false)
    #expect(h.model.serverSave.offersSaveShow == false)

    h.credential.credentialReadGate.release()
    await waitUntil("item offered") { h.model.serverSave.offersSaveShow }
  }

  @Test("not offered when the credential read failed, or found a credential")
  func credentialFailedOrHeld() async {
    let failed = await makeHarness(credential: .failing, awaitCredential: false)
    await waitUntil("failed read finished") { failed.credential.reads >= 1 }
    await waitUntil("capability") { failed.model.serverSave.serverMutationCapability.canSave }
    await Task.yield()
    #expect(failed.model.serverSave.isCredentialReadCompleteWithNoCredential == false)
    #expect(failed.model.serverSave.offersSaveShow == false)
    #expect(failed.reading.observedFingerprints.isEmpty, "a feed with an unknown credential never reads copies")

    let held = await makeHarness(credential: .configured, awaitCredential: false)
    await waitUntil("held read finished") { held.credential.reads >= 1 }
    await waitUntil("capability") { held.model.serverSave.serverMutationCapability.canSave }
    await Task.yield()
    #expect(held.model.serverSave.isCredentialReadCompleteWithNoCredential == false)
    #expect(held.model.serverSave.offersSaveShow == false)
    #expect(held.reading.observedFingerprints.isEmpty)
  }

  @Test("not offered while a server copy exists, and offered again when it is gone")
  func serverCopy() async {
    let h = await makeHarness(copies: ["server-item"])
    #expect(h.model.serverSave.offersSaveShow == false)

    h.reading.pushServerCopies([], fingerprint: Self.fingerprint)
    await waitUntil("copy gone") { h.model.serverSave.offersSaveShow }

    h.reading.pushServerCopies(["a", "b"], fingerprint: Self.fingerprint)
    await waitUntil("several copies") { h.model.serverSave.offersSaveShow == false }
  }

  @Test("not offered before the copy read has answered")
  func copyUnknown() async {
    let h = await makeHarness(copies: nil, awaitCopies: false)
    await waitUntil("fingerprint observed") { h.reading.observedFingerprints.isEmpty == false }
    #expect(h.model.serverSave.showSave.serverCopyItemIDs == nil)
    #expect(h.model.serverSave.offersSaveShow == false)
  }

  @Test("a feed with no fingerprint has no copy to find, so the item is offered")
  func noFingerprint() async {
    let h = await makeHarness(fingerprint: nil)
    #expect(h.reading.observedFingerprints.isEmpty)
    #expect(h.model.serverSave.offersSaveShow)
  }

  @Test("hidden when any episode of the feed has a server-save status")
  func anyEpisodeStatus() async {
    let h = await makeHarness()
    #expect(h.model.serverSave.offersSaveShow)

    // The last episode of the feed, not the first: the check covers the whole feed.
    h.model.serverSave.serverSaveStatuses["10"] = .requested
    #expect(h.model.serverSave.offersSaveShow == false)
    h.model.serverSave.serverSaveStatuses["10"] = NativeEpisodeServerSaveStatus.none
    #expect(h.model.serverSave.offersSaveShow)
  }

  @Test("never offered for a server show")
  func serverShow() async {
    let h = await makeHarness(itemID: "server-item-1")
    await Task.yield()
    #expect(h.model.serverSave.isCredentialReadCompleteWithNoCredential == false)
    #expect(h.model.serverSave.offersSaveShow == false)
  }

  // MARK: Pre-selection

  @Test("pre-selects the first saveable episode of the unfiltered list")
  func preselectNewest() async {
    let h = await makeHarness(episodes: [episode("9"), episode("10")])
    #expect(h.model.serverSave.showSavePreselectedEpisodeID == "9")
  }

  @Test("pre-selects within the current filter and leaves the filter alone")
  func preselectUnderFilter() async {
    let h = await makeHarness(episodes: [episode("9", played: true), episode("10")])
    h.model.filter = .unplayed
    h.model.episodeQuery = ""

    #expect(h.model.serverSave.showSavePreselectedEpisodeID == "10")
    #expect(h.model.filter == .unplayed)
  }

  @Test("skips an episode the save action does not accept")
  func preselectSkipsUnsaveable() async {
    let h = await makeHarness(episodes: [episode("9"), episode("10")])
    h.model.serverSave.serverSaveStatuses["9"] = .requested

    #expect(h.model.serverSave.showSavePreselectedEpisodeID == "10")
  }

  @Test("pre-selects nothing when nothing in the list is saveable")
  func preselectNothing() async {
    let h = await makeHarness(episodes: [episode("9"), episode("10")])
    h.model.serverSave.serverSaveStatuses["9"] = .saved
    h.model.serverSave.serverSaveStatuses["10"] = .requested
    #expect(h.model.serverSave.showSavePreselectedEpisodeID == nil)

    let hidden = await makeHarness(episodes: [episode("9")])
    hidden.model.filter = .played
    #expect(hidden.model.serverSave.showSavePreselectedEpisodeID == nil)
  }

  // MARK: The mark

  @Test("the mark is armed by the entry and consumed by the batch that starts")
  func markConsumed() async {
    let h = await makeHarness()
    #expect(h.model.serverSave.isShowSaveArmed == false)
    h.model.serverSave.armShowSave()
    #expect(h.model.serverSave.isShowSaveArmed)

    h.model.serverSave.beginBatchServerSave(episodeIDs: ["9"])

    #expect(h.model.serverSave.batchServerSave?.isShowSave == true)
    #expect(h.model.serverSave.isShowSaveArmed == false)
  }

  @Test("a batch begun without the mark is an ordinary save")
  func noMark() async {
    let h = await makeHarness()
    h.model.serverSave.beginBatchServerSave(episodeIDs: ["9"])
    #expect(h.model.serverSave.batchServerSave?.isShowSave == false)
  }

  @Test("leaving selection disarms the mark")
  func disarmedOnLeavingSelection() async {
    let h = await makeHarness()
    h.model.serverSave.armShowSave()
    h.model.serverSave.disarmShowSave()
    h.model.serverSave.beginBatchServerSave(episodeIDs: ["9"])
    #expect(h.model.serverSave.batchServerSave?.isShowSave == false)
  }

  @Test("another selection action disarms the mark")
  func disarmedByAnotherAction() async {
    let h = await makeHarness()
    h.model.serverSave.armShowSave()
    await h.model.performSelectedAction(.saveForLater, episodeIDs: ["9"])
    #expect(h.model.serverSave.isShowSaveArmed == false)
  }

  @Test("show(itemID:) disarms the mark and the new show starts afresh")
  func disarmedByTeardown() async {
    let h = await makeHarness()
    h.model.serverSave.armShowSave()
    h.model.show(itemID: "rss:8")

    #expect(h.model.serverSave.isShowSaveArmed == false)
    // Reset synchronously: the new show's credential read has not been asked yet.
    #expect(h.model.serverSave.isCredentialReadCompleteWithNoCredential == false)
    #expect(h.model.serverSave.offersSaveShow == false)
    h.model.serverSave.beginBatchServerSave(episodeIDs: ["9"])
    #expect(h.model.serverSave.batchServerSave?.isShowSave != true)
  }

  @Test("dismissing the destination sheet leaves a second Save an ordinary one")
  func dismissalThenSecondSave() async {
    let h = await makeHarness(batches: [Self.needsChoiceBatch(notAttempted: [])])
    h.model.serverSave.armShowSave()
    h.model.serverSave.beginBatchServerSave(episodeIDs: ["9"])
    await waitUntil("prompt") { h.model.serverSave.pendingServerSaveChoice != nil }
    #expect(h.model.serverSave.batchServerSave?.isShowSave == true)

    h.model.serverSave.dismissServerSaveFeedback()
    #expect(h.model.serverSave.batchServerSave == nil)
    #expect(h.model.serverSave.isShowSaveArmed == false)

    h.model.serverSave.beginBatchServerSave(episodeIDs: ["9"])
    #expect(h.model.serverSave.batchServerSave?.isShowSave == false)
  }

  @Test("more than 50 selected shows the limit message, and the mark survives for a retry")
  func overFifty() async {
    let ids = (0..<51).map { "e\($0)" }
    let h = await makeHarness(episodes: ids.map { episode($0) })

    h.model.serverSave.armShowSave()
    h.model.serverSave.beginBatchServerSave(episodeIDs: Set(ids))

    #expect(
      h.model.serverSave.serverSaveBannerMessage == NativeEpisodeServerSaveBatchCopy.limitExceeded(selected: 51))
    #expect(h.model.serverSave.batchServerSave == nil)
    #expect(h.model.serverSave.isShowSaveArmed, "no batch began, so nothing consumed the mark")
  }

  // MARK: Turning downloads on

  @Test("a created show with an accepted episode turns downloads on once, whatever the stop")
  func enablesForEachStop() async {
    let stops: [(String, ShowScript)] = [
      ("completed", Self.resumed(.completed, outcomes: [Self.accepted(9)])),
      (
        "cancelled",
        Self.resumed(.cancelled, outcomes: [Self.accepted(9)], notAttempted: [10])
      ),
      (
        "failed",
        Self.resumed(
          .failed(episodeId: 10, category: .unknown),
          outcomes: [
            Self.accepted(9),
            .init(
              episodeId: 10, outcome: .failed(attemptID: 2, state: .failed, category: .unknown)),
          ])
      ),
      (
        "uncertain",
        Self.resumed(
          .uncertain(episodeId: 10, attemptID: 2, category: .transport),
          outcomes: [
            Self.accepted(9),
            .init(
              episodeId: 10,
              outcome: .uncertain(attemptID: 2, state: .failed, category: .transport)),
          ])
      ),
    ]
    for (name, resumed) in stops {
      let h = await makeHarness(
        batches: [Self.needsChoiceBatch(notAttempted: [10]), resumed])
      await h.runShowSave(choice: Self.create)

      let calls = await h.writer.calls
      #expect(calls.count == 1, Comment(rawValue: name))
      #expect(calls.first?.itemID == "created", Comment(rawValue: name))
      #expect(calls.first?.change == PodcastAutomationSettingsRequest(autoDownloadEpisodes: true))
      #expect(calls.first?.confirmation == .responseOnly, "no local row exists yet")
      #expect(h.model.serverSave.serverSaveBannerMessage != Self.notTurnedOn, Comment(rawValue: name))
      #expect(h.model.serverSave.batchServerSave == nil)
    }
  }

  @Test("a created show's banner says the show was saved and when it will appear")
  func createdShowBanner() async {
    let h = await makeHarness(batches: [
      Self.needsChoiceBatch(notAttempted: [10]),
      Self.resumed(.completed, outcomes: [Self.accepted(9), Self.accepted(10)]),
    ])
    await h.runShowSave(choice: Self.create)
    #expect(
      h.model.serverSave.serverSaveBannerMessage
        == "Show saved to Audiobookshelf. Requested 2 episodes. "
        + "It will appear in your library shortly.")
  }

  @Test("an ordinary create, or a show save into an existing show, keeps the plain summary")
  func plainSummaryOtherwise() async {
    for (choice, armed) in [(Self.create, false), (Self.existing, true)] {
      let h = await makeHarness(batches: [
        Self.needsChoiceBatch(notAttempted: [10]),
        Self.resumed(.completed, outcomes: [Self.accepted(9), Self.accepted(10)]),
      ])
      await h.runShowSave(choice: choice, armed: armed)
      #expect(h.model.serverSave.serverSaveBannerMessage == "Requested 2 episodes")
    }
  }

  @Test("the library sync is requested at the first accepted episode, once, not at the batch's end")
  func syncAtFirstAcceptedEpisode() async {
    let hold = BatchGate()
    let h = await makeHarness(batches: [
      Self.needsChoiceBatch(notAttempted: [10]),
      ShowScript(
        NativeEpisodeServerSaveBatchResult(
          outcomes: [Self.accepted(9), Self.accepted(10)], stop: .completed, notAttempted: [],
          serverItemID: "created"),
        holdBeforeReturn: hold),
    ])
    h.model.serverSave.armShowSave()
    h.model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
    await waitUntil("prompt") { h.model.serverSave.pendingServerSaveChoice != nil }
    let chosen = Task { await h.model.serverSave.chooseSaveDestination(Self.create) }

    await waitUntil("sync requested mid-batch") { await h.sync.count == 1 }
    #expect(h.model.serverSave.batchServerSave != nil, "the batch has not returned yet")

    await hold.open()
    await chosen.value
    await awaitQuiescence("sync request count") { String(await h.sync.count) }
    #expect(await h.sync.count == 1)
  }

  @Test("zero accepted episodes send nothing")
  func zeroAccepted() async {
    let h = await makeHarness(batches: [
      Self.needsChoiceBatch(notAttempted: [10]),
      Self.resumed(
        .completed,
        outcomes: [
          .init(episodeId: 9, outcome: .failed(attemptID: 1, state: .failed, category: .unknown))
        ]),
    ])
    await h.runShowSave(choice: Self.create)
    #expect(await h.writer.calls.isEmpty)
    #expect(h.model.serverSave.serverSaveBannerMessage != Self.notTurnedOn)
  }

  @Test("an ordinary batch that creates a show sends nothing")
  func ordinaryCreateSendsNothing() async {
    let h = await makeHarness(batches: [
      Self.needsChoiceBatch(notAttempted: [10]),
      Self.resumed(.completed, outcomes: [Self.accepted(9)]),
    ])
    await h.runShowSave(choice: Self.create, armed: false)
    #expect(await h.writer.calls.isEmpty)
  }

  @Test("choosing an existing show sends nothing and shows no line")
  func existingChoiceSendsNothing() async {
    let h = await makeHarness(
      batches: [
        Self.needsChoiceBatch(notAttempted: [10]),
        Self.resumed(.completed, outcomes: [Self.accepted(9)]),
      ],
      writerOutcome: .failed)
    await h.runShowSave(choice: Self.existing)
    #expect(await h.writer.calls.isEmpty)
    #expect(h.model.serverSave.serverSaveBannerMessage != Self.notTurnedOn)
  }

  @Test("a show that already existed (no prompt at all) sends nothing")
  func reuseWithoutPromptSendsNothing() async {
    let h = await makeHarness(
      batches: [Self.resumed(.completed, outcomes: [Self.accepted(9), Self.accepted(10)])],
      writerOutcome: .failed)
    h.model.serverSave.armShowSave()
    h.model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
    await waitUntil("batch ended") { h.model.serverSave.batchServerSave == nil }
    await Task.yield()
    #expect(await h.writer.calls.isEmpty)
    #expect(h.model.serverSave.serverSaveBannerMessage != Self.notTurnedOn)
  }

  @Test("a failed or unconfirmed enable shows a second banner and the save stands")
  func enableFailures() async {
    let outcomes: [ServerPodcastAutomationSettingsOutcome] = [
      .unconfirmed(PodcastAutomationSettingsResult(), refresh: .notAttempted),
      .notPermitted, .invalidRequest, .forbidden, .notFound, .rejected, .uncertain, .failed,
    ]
    for outcome in outcomes {
      let h = await makeHarness(
        batches: [
          Self.needsChoiceBatch(notAttempted: [10]),
          Self.resumed(.completed, outcomes: [Self.accepted(9)]),
        ],
        writerOutcome: outcome)
      await h.runShowSave(choice: Self.create)

      #expect(h.model.serverSave.serverSaveBannerMessage == Self.notTurnedOn, Comment(rawValue: "\(outcome)"))
      #expect(h.model.serverSave.serverSaveStatuses["9"] == .requested, "the save itself stands")
      #expect(h.model.serverSave.batchServerSave == nil)
      #expect(await h.writer.calls.count == 1)
    }
  }

  @Test("an account replaced before the enable lands shows no banner")
  func accountReplaced() async {
    for outcome in [ServerPodcastAutomationSettingsOutcome.accountChanged, .cancelled] {
      let h = await makeHarness(
        batches: [
          Self.needsChoiceBatch(notAttempted: [10]),
          Self.resumed(.completed, outcomes: [Self.accepted(9)]),
        ],
        writerOutcome: outcome)
      await h.runShowSave(choice: Self.create)

      #expect(await h.writer.calls.count == 1)
      #expect(h.model.serverSave.serverSaveBannerMessage != Self.notTurnedOn, Comment(rawValue: "\(outcome)"))
    }
  }

  @Test("the enable follows the batch's own summary and never holds it back")
  func enableFollowsTheSummary() async {
    let gate = WriterGate()
    let h = await makeHarness(
      batches: [
        Self.needsChoiceBatch(notAttempted: [10]),
        Self.resumed(.completed, outcomes: [Self.accepted(9)]),
      ],
      writerOutcome: .failed, writerGate: gate)
    h.model.serverSave.armShowSave()
    h.model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
    await waitUntil("prompt") { h.model.serverSave.pendingServerSaveChoice != nil }
    let chosen = Task { await h.model.serverSave.chooseSaveDestination(Self.create) }

    await waitUntil("writer entered") { await h.writer.calls.count == 1 }
    // The write is still in flight: the batch is over, its summary is up, the second banner is not.
    #expect(h.model.serverSave.batchServerSave == nil)
    #expect(h.model.serverSave.serverSaveBannerMessage != nil)
    #expect(h.model.serverSave.serverSaveBannerMessage != Self.notTurnedOn)
    let summary = h.model.serverSave.serverSaveBannerMessage

    await gate.open()
    await chosen.value
    #expect(summary != Self.notTurnedOn)
    #expect(h.model.serverSave.serverSaveBannerMessage == Self.notTurnedOn)
  }

  @Test("show(itemID:) between the create and the batch's end sends nothing")
  func teardownBeforeTheEnable() async {
    let gate = BatchGate()
    let h = await makeHarness(batches: [
      Self.needsChoiceBatch(notAttempted: [10]),
      Self.resumed(.completed, outcomes: [Self.accepted(9)], gate: gate),
    ])
    h.model.serverSave.armShowSave()
    h.model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
    await waitUntil("prompt") { h.model.serverSave.pendingServerSaveChoice != nil }
    let chosen = Task { await h.model.serverSave.chooseSaveDestination(Self.create) }
    await waitUntil("create in flight") { await h.saving.requests.count == 2 }

    h.model.show(itemID: "rss:8")
    await gate.open()
    await chosen.value

    #expect(await h.writer.calls.isEmpty)
    #expect(h.model.serverSave.serverSaveBannerMessage != Self.notTurnedOn)
  }

  @Test("an account teardown while the enable is in flight drops its banner")
  func teardownDuringTheEnable() async {
    let gate = WriterGate()
    let h = await makeHarness(
      batches: [
        Self.needsChoiceBatch(notAttempted: [10]),
        Self.resumed(.completed, outcomes: [Self.accepted(9)]),
      ],
      writerOutcome: .failed, writerGate: gate)
    h.model.serverSave.armShowSave()
    h.model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
    await waitUntil("prompt") { h.model.serverSave.pendingServerSaveChoice != nil }
    let chosen = Task { await h.model.serverSave.chooseSaveDestination(Self.create) }
    await waitUntil("writer entered") { await h.writer.calls.count == 1 }

    h.model.show(itemID: "rss:8")
    await gate.open()
    await chosen.value

    #expect(h.model.serverSave.serverSaveBannerMessage != Self.notTurnedOn)
  }

  // MARK: Wiring

  @Test("the root factory hands the show model the settings writer and the shows reading")
  func rootFactoryWiring() async {
    let writer = ShowSaveWriter(outcome: Self.confirmed)
    let shows = makeShowSaveShows(fingerprint: Self.fingerprint)
    let saving = ShowSaveBatches([
      Self.needsChoiceBatch(notAttempted: [10]),
      Self.resumed(.completed, outcomes: [Self.accepted(9)]),
    ])
    let dependencies = AppDependencies(
      account: FakeAccountLifecycle(),
      sync: FakeSyncCoordinating(),
      library: FakeLibraryReading(),
      player: FakePlaybackControlling(),
      playbackSync: FakePlaybackSyncing(),
      reader: FakeEPUBRendering(),
      networkConditions: FakeNetworkConditions(),
      appLifecycle: FakeAppLifecycle(),
      diagnostics: FakeDiagnosticsRecording(),
      downloadReading: NoOpDownloadReading(),
      storageReading: NoOpStorageReading(),
      rssDownloadsReading: NoOpRSSDownloadsReading(),
      deviceStorageCapacityReading: NoOpDeviceStorageCapacityReading(),
      downloadIntents: NoOpDownloadIntents(),
      itemProgressIntents: NoOpItemProgressIntents(),
      downloadPreferences: NoOpDownloadPreferences(),
      artworkCacheAccess: NoOpArtworkCacheAccess(),
      resolutionCenterAccess: NoOpResolutionCenterAccess(),
      extrasAccess: NoOpItemDetailExtrasAccess(),
      historyAccess: NoOpListeningHistoryProviding(),
      listeningStatsAccess: NoOpListeningStatsProviding(),
      audioBookmarkIntents: NoOpAudioBookmarkIntents(),
      homeReading: NoOpHomeReading(),
      nativeLatestPodcastEpisodesReading: NoOpNativeLatestPodcastEpisodesReading(),
      nativeContinueListeningReading: NoOpNativeContinueListeningReading(),
      playbackBookmarkStoring: NoOpPlaybackBookmarkStoring(),
      podcastReading: makeShowSaveReading(
        episodes: [episode("9"), episode("10")], copies: [], fingerprint: Self.fingerprint),
      podcastRefreshing: NoOpPodcastRefreshing(),
      rssFeedRefreshCoordinator: NoOpRSSFeedRefreshCoordinator(),
      listeningQueueReading: NoOpListeningQueueStore(),
      listeningQueueStoring: NoOpListeningQueueStore(),
      savedShelfStoring: NoOpSavedShelfStore(),
      itemPlaybackSettingsReading: NoOpItemPlaybackSettingsAccess(),
      itemPlaybackSettingsWriting: NoOpItemPlaybackSettingsAccess(),
      playbackPreferences: NoOpPlaybackPreferences(),
      podcastSettingsReading: NoOpPodcastSettingsAccess(),
      podcastSettingsWriting: NoOpPodcastSettingsAccess(),
      podcastShowOrdering: NoOpPodcastShowOrdering(),
      carPlayBrowseSources: .empty,
      searchReading: NoOpSearchReading(),
      recentSearchStore: NoOpRecentSearchStoring(),
      authorSeriesReading: NoOpAuthorSeriesReading(),
      libraryCollections: .unavailable,
      serverAccountReading: NoOpServerAccountReading(),
      librarySelectionReading: NoOpLibrarySelectionStore(),
      nativePodcastSubscriptionsReading: NoOpNativePodcastSubscriptionsReading(),
      accountIdentityReading: NoOpAccountIdentityReading(),
      nativePodcastSubscriptionsWriting: NoOpNativePodcastSubscriptionsWriting(),
      nativeEpisodeServerSaving: NoOpNativeEpisodeServerSaving(),
      nativeEpisodeServerSaveBatchSaving: saving,
      nativeEpisodeServerSaveRecovering: NoOpNativeEpisodeServerSaveRecovering(),
      nativeEpisodeServerSaveStatusReading: NoOpNativeEpisodeServerSaveStatusReading(),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["9": 9, "10": 10]),
      serverPodcastMutationCapabilityReading: makeShowSaveCapability(canSave: true),
      serverPodcastAutomationSettingsWriting: writer,
      ebookDelivery: NoOpEbookDelivering(),
      notificationIntentReading: DisabledRSSNotificationIntent(),
      notificationIntentWriting: DisabledRSSNotificationIntent(),
      localNotificationAuthorizer: NoOpRSSLocalNotificationAuthorizer(),
      rssNotificationLifecycle: NoOpRSSNotificationLifecycle(),
      nativePodcastShowsReading: shows,
      nativeFeedRecoveryReading: NoOpNativeFeedRecoveryReading(),
      librarySelectionWriting: NoOpLibrarySelectionStore(),
      librarySelectionDiscovery: NoOpLibrarySelectionDiscovery(),
      nativeFeedFollowing: NoOpNativeFeedFollowing(),
      nativeFeedManaging: NoOpNativeFeedManaging(),
      nativeSubscriptionOPMLExporter: NoOpNativeSubscriptionOPMLExporter(),
      nativePodcastShowOrdering: NoOpNativePodcastShowOrdering())
    let model = RootModel(dependencies: dependencies).makePodcastShowModel(itemID: "rss:7")

    await waitUntil("item offered through the factory's seams") { model.serverSave.offersSaveShow }
    #expect(shows.observedItemIDs.contains("rss:7"))

    model.serverSave.armShowSave()
    model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
    await waitUntil("prompt") { model.serverSave.pendingServerSaveChoice != nil }
    await model.serverSave.chooseSaveDestination(Self.create)
    #expect(await writer.calls.count == 1)
  }

  // MARK: Helpers

  private func episode(_ id: String, played: Bool = false) -> PodcastEpisodeSummary {
    PodcastEpisodeSummary(
      id: id, title: id, subtitle: nil, episodeDescription: nil, seasonNumber: nil,
      episodeNumber: nil, episodeType: nil, durationSeconds: 120, sizeBytes: nil,
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000), progressSeconds: 0,
      isPlayed: played, isFinished: played, downloadStatus: .notDownloaded,
      isAvailableOnServer: true)
  }

  private static func accepted(_ row: Int64) -> NativeEpisodeServerSaveBatchEpisodeOutcome {
    .init(episodeId: row, outcome: .accepted(attemptID: row, serverItemID: "created"))
  }

  /// The first run: the coordinator asks for a destination for the first episode.
  private static func needsChoiceBatch(notAttempted: [Int64]) -> ShowScript {
    ShowScript(
      NativeEpisodeServerSaveBatchResult(
        outcomes: [.init(episodeId: 9, outcome: .needsChoice(attemptID: 1, prompt: prompt))],
        stop: .needsChoice(episodeId: 9, attemptID: 1, prompt: prompt),
        notAttempted: notAttempted, serverItemID: nil))
  }

  private static func resumed(
    _ stop: NativeEpisodeServerSaveBatchStop,
    outcomes: [NativeEpisodeServerSaveBatchEpisodeOutcome],
    notAttempted: [Int64] = [],
    gate: BatchGate? = nil
  ) -> ShowScript {
    ShowScript(
      NativeEpisodeServerSaveBatchResult(
        outcomes: outcomes, stop: stop, notAttempted: notAttempted, serverItemID: "created"),
      gate: gate)
  }

  private func makeHarness(
    itemID: String = "rss:7",
    episodes: [PodcastEpisodeSummary]? = nil,
    canSave: Bool = true,
    credential: ShowSaveCredentialState = .none,
    fingerprint: String? = fingerprint,
    copies: [String]? = [],
    batches: [ShowScript] = [],
    writerOutcome: ServerPodcastAutomationSettingsOutcome = confirmed,
    writerGate: WriterGate? = nil,
    awaitCapability: Bool = true,
    awaitCredential: Bool = true,
    awaitCopies: Bool = true
  ) async -> Harness {
    let list = episodes ?? [episode("9"), episode("10")]
    let reading = makeShowSaveReading(episodes: list, copies: copies, fingerprint: fingerprint)
    let shows = makeShowSaveShows(fingerprint: fingerprint)
    let writer = ShowSaveWriter(outcome: writerOutcome, gate: writerGate)
    let saving = ShowSaveBatches(batches)
    let sync = ShowSaveSyncRequester()
    let credentials = makeShowSaveCredentials(credential, feedID: 7)
    let resolved = Dictionary(
      uniqueKeysWithValues: list.enumerated().map { pair in
        (pair.element.id, Int64(Int(pair.element.id) ?? (pair.offset + 100)))
      })
    let model = PodcastShowModel(
      itemID: itemID, reading: reading,
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(resolved),
      nativeFeedManaging: credentials,
      nativeEpisodeServerSaveBatchSaving: saving,
      serverPodcastMutationCapabilityReading: makeShowSaveCapability(canSave: canSave),
      librarySyncRequester: sync,
      nativeShowsReading: shows,
      serverPodcastAutomationSettingsWriting: writer)
    await waitUntil("episodes") { model.episodes.count == list.count }
    if awaitCapability && itemID.hasPrefix("rss:") {
      await waitUntil("capability") { model.serverSave.serverMutationCapability.canSave == canSave }
    }
    if awaitCredential && itemID.hasPrefix("rss:") && credential == .none {
      await waitUntil("credential read") { model.serverSave.isCredentialReadCompleteWithNoCredential }
    }
    if awaitCopies && copies != nil && credential == .none && itemID.hasPrefix("rss:") {
      await waitUntil("copies known") { model.serverSave.showSave.serverCopyItemIDs != nil }
    }
    return Harness(
      model: model, reading: reading, writer: writer, saving: saving, credential: credentials,
      sync: sync)
  }

  @MainActor
  private struct Harness {
    let model: PodcastShowModel
    let reading: FakePodcastReading
    let writer: ShowSaveWriter
    let saving: ShowSaveBatches
    let credential: FakeNativeFeedManaging
    let sync: ShowSaveSyncRequester

    /// Selection opens with the mark armed, the user saves two episodes, the first run asks for a
    /// destination, the user picks `choice`, and the resumed run ends. Returns once the choice has
    /// been fully handled, including any enable.
    func runShowSave(choice: ServerPodcastSaveChoice, armed: Bool = true) async {
      if armed { model.serverSave.armShowSave() }
      model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
      await waitUntil("prompt") { model.serverSave.pendingServerSaveChoice != nil }
      await model.serverSave.chooseSaveDestination(choice)
    }
  }
}

// MARK: - Presentation: the sheet's line

@Suite("Save Show destination sheet line")
struct ShowSaveDestinationLineTests {
  private static let line = "New episodes will download automatically. Change this in Show Settings."
  private let podcasts = NativeEpisodeServerSaveLibraryChoice(
    libraryID: "lib-1", displayName: "Podcasts",
    folders: [NativeEpisodeServerSaveFolderChoice(folderID: "f-1", displayName: "Podcasts")])
  private let second = NativeEpisodeServerSaveLibraryChoice(
    libraryID: "lib-2", displayName: "More",
    folders: [NativeEpisodeServerSaveFolderChoice(folderID: "f-2", displayName: "More")])

  @Test("the copy is the specified sentence")
  func copy() {
    #expect(NativeEpisodeServerSaveCopy.showSaveDestinationLine == Self.line)
    #expect(
      NativeEpisodeServerSaveCopy.automaticDownloadsNotTurnedOn
        == "Automatic downloads were not turned on. Turn them on in Show Settings.")
  }

  @Test("sole destination: the line replaces the future-episodes footer")
  func soleDestination() {
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]), podcastName: "Night Vale", savesShow: true)

    #expect(presentation.soleDestinationFooter == Self.line)
    #expect(presentation.explanation.contains("Future episodes") == false)
    let runs = presentation.soleDestinationRuns?.map(\.text).joined() ?? ""
    #expect(runs + " " + (presentation.soleDestinationFooter ?? "") == presentation.explanation)
    #expect(presentation.pickerFooter == nil)
  }

  @Test("picker: the line is the footer")
  func picker() {
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts, second]), podcastName: "Night Vale",
      savesShow: true)

    guard case .chooseDestination = presentation.layout else {
      Issue.record("Expected the picker, got \(presentation.layout)")
      return
    }
    #expect(presentation.pickerFooter == Self.line)
    #expect(presentation.soleDestinationFooter == nil)
  }

  @Test("unavailable: nothing is shown, and choosing an existing show says nothing about downloads")
  func unavailableAndExisting() {
    let unavailable = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: []), podcastName: "Night Vale", savesShow: true)
    #expect(unavailable.pickerFooter == nil)
    #expect(unavailable.soleDestinationFooter == nil)
    #expect(unavailable.explanation.contains("New episodes will download") == false)

    let existing = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .existing(candidates: [
        NativeEpisodeServerSaveExistingChoice(serverItemID: "a", displayName: "A"),
        NativeEpisodeServerSaveExistingChoice(serverItemID: "b", displayName: "B"),
      ]), podcastName: "Night Vale", savesShow: true)
    #expect(existing.pickerFooter == nil)
    #expect(existing.soleDestinationFooter == nil)
  }

  @Test("off by default: the episode card draws exactly what it always did")
  func offByDefault() {
    for prompt in [
      NativeEpisodeServerSaveChoicePrompt.libraryAndFolder(libraries: [podcasts]),
      .libraryAndFolder(libraries: [podcasts, second]),
      .libraryAndFolder(libraries: []),
    ] {
      let defaulted = NativeEpisodeServerSaveDestinationPresentation(
        prompt: prompt, podcastName: "Night Vale")
      let explicit = NativeEpisodeServerSaveDestinationPresentation(
        prompt: prompt, podcastName: "Night Vale", savesShow: false)
      #expect(defaulted == explicit)
      #expect(defaulted.savesShow == false)
      #expect(defaulted.pickerFooter == nil)
      #expect(defaulted.explanation.contains(Self.line) == false)
    }
    let sole = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]), podcastName: "Night Vale")
    #expect(sole.soleDestinationFooter == NativeEpisodeServerSaveCopy.futureEpisodesHint)
    #expect(sole.description == sole.debugDescription)
  }
}

// MARK: - Fakes

/// The reading a show screen sees: `episodes` as the show's list and `copies` as the server copies
/// of `fingerprint`, both present from the first subscription. A nil `copies` is a copy read that
/// has not answered yet.
private func makeShowSaveReading(
  episodes: [PodcastEpisodeSummary], copies: [String]?, fingerprint: String?
) -> FakePodcastReading {
  let reading = FakePodcastReading(episodes: episodes)
  if let copies, let fingerprint { reading.pushServerCopies(copies, fingerprint: fingerprint) }
  return reading
}

/// A shows reading that answers every feed with a summary carrying `fingerprint`.
private func makeShowSaveShows(fingerprint: String?) -> FakeNativePodcastShowsReading {
  let shows = FakeNativePodcastShowsReading()
  shows.pushShow(
    ItemSummary(
      serverItemId: "feed", mediaKind: "podcast", title: "Feed", author: nil,
      durationSeconds: nil, category: .podcast, podcastFeedFingerprint: fingerprint))
  return shows
}

private enum ShowSaveCredentialState { case none, configured, pending, failing }

private func makeShowSaveCredentials(
  _ state: ShowSaveCredentialState, feedID: Int64
) -> FakeNativeFeedManaging {
  let credentials = FakeNativeFeedManaging(
    configuredFeedIDs: state == .configured ? [feedID] : [])
  switch state {
  case .none, .configured: break
  case .pending: credentials.credentialReadGate.hold()
  case .failing: credentials.stubReadFailure(PodcastFixtureError.offline)
  }
  return credentials
}

private func makeShowSaveCapability(canSave: Bool) -> FakeServerPodcastMutationCapabilityReading {
  FakeServerPodcastMutationCapabilityReading(canSave: canSave, canRemove: false)
}

extension FakePodcastReading {
  fileprivate var observedFingerprints: [String] {
    calls.compactMap { call -> String? in
      if case .observeServerCopyItemIDs(let fingerprint) = call { return fingerprint }
      return nil
    }
  }
}

extension FakeNativeFeedManaging {
  fileprivate var reads: Int {
    calls.filter { call in
      if case .hasCredential = call { return true }
      return false
    }.count
  }
}

private actor WriterGate {
  // Closed until the test opens it; a held call runs to completion regardless of cancellation.
  private nonisolated let gate = TestGate<Void>(label: "WriterGate", ignoresCancellation: true)
  init() { gate.hold() }
  func wait() async { await gate.pass() }
  func open() { gate.release() }
}

private actor BatchGate {
  // Closed until the test opens it; a held call runs to completion regardless of cancellation.
  private nonisolated let gate = TestGate<Void>(label: "BatchGate", ignoresCancellation: true)
  init() { gate.hold() }
  func wait() async { await gate.pass() }
  func open() { gate.release() }
}

private actor ShowSaveWriter: ServerPodcastAutomationSettingsWriting {
  struct Call: Equatable {
    let itemID: String
    let change: PodcastAutomationSettingsRequest
    let confirmation: ServerPodcastAutomationConfirmation
  }
  private let outcome: ServerPodcastAutomationSettingsOutcome
  private let gate: WriterGate?
  private(set) var calls: [Call] = []

  init(outcome: ServerPodcastAutomationSettingsOutcome, gate: WriterGate? = nil) {
    self.outcome = outcome
    self.gate = gate
  }

  func update(
    itemID: String, change: PodcastAutomationSettingsRequest,
    confirmation: ServerPodcastAutomationConfirmation
  ) async -> ServerPodcastAutomationSettingsOutcome {
    calls.append(Call(itemID: itemID, change: change, confirmation: confirmation))
    if let gate { await gate.wait() }
    return outcome
  }
}

/// Plays scripted batch results in order and records the requests it was given. A result's gate
/// holds that run until the test opens it.
private struct ShowScript: Sendable {
  let result: NativeEpisodeServerSaveBatchResult
  let gate: BatchGate?
  /// Holds the run after its outcomes were delivered and before it returns.
  let holdBeforeReturn: BatchGate?

  init(
    _ result: NativeEpisodeServerSaveBatchResult, gate: BatchGate? = nil,
    holdBeforeReturn: BatchGate? = nil
  ) {
    self.result = result
    self.gate = gate
    self.holdBeforeReturn = holdBeforeReturn
  }
}

private actor ShowSaveSyncRequester: LibrarySyncRequesting {
  private(set) var count = 0
  func requestLibrarySync() async { count += 1 }
}

private actor ShowSaveBatches: NativeEpisodeServerSaveBatchSaving {
  private var scripts: [ShowScript]
  private(set) var requests: [NativeEpisodeServerSaveBatchRequest] = []

  init(_ scripts: [ShowScript]) { self.scripts = scripts }

  func saveBatch(
    _ request: NativeEpisodeServerSaveBatchRequest,
    cancellation: NativeEpisodeServerSaveBatchCancellationToken,
    onEpisodeOutcome: @escaping @Sendable (NativeEpisodeServerSaveBatchEpisodeOutcome) async -> Void
  ) async -> NativeEpisodeServerSaveBatchResult {
    requests.append(request)
    guard scripts.isEmpty == false else {
      return NativeEpisodeServerSaveBatchResult(
        outcomes: [], stop: .completed, notAttempted: [], serverItemID: nil)
    }
    let script = scripts.removeFirst()
    if let gate = script.gate { await gate.wait() }
    for outcome in script.result.outcomes { await onEpisodeOutcome(outcome) }
    if let hold = script.holdBeforeReturn { await hold.wait() }
    return script.result
  }
}
