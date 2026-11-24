import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Pins how `PodcastShowServerSaveModel` is owned by `PodcastShowModel`: who holds whom, what the
/// parent hands it, and which teardown does what. Server-save behaviour itself is covered by
/// `PodcastShowServerSaveTests`, `PodcastShowBatchServerSaveTests` and `PodcastShowSaveShowTests`.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PodcastShowServerSaveModelTests {
  private static var canSaveAndRemove: FakeServerPodcastMutationCapabilityReading {
    FakeServerPodcastMutationCapabilityReading(canSave: true, canRemove: true)
  }

  @Test("a show switch during an in-flight save drops the late outcome")
  func showSwitchDuringInFlightSaveDropsItsOutcome() async {
    let saving = FakeNativeEpisodeServerSaving(
      saveOutcomes: [.accepted(attemptID: 8, serverItemID: "server-item")])
    saving.saveGate.hold()
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["9": 9]),
      nativeEpisodeServerSaving: saving,
      serverPodcastMutationCapabilityReading: Self.canSaveAndRemove)

    let saveTask = Task { await model.serverSave.saveEpisodeToServer(episodeID: "9") }
    await saving.recorder.waitUntil(count: 1)
    #expect(model.serverSave.serverSaveStatus(for: "9") == .preparing)

    model.show(itemID: "rss:8")
    saving.saveGate.release()
    await saveTask.value

    #expect(model.serverSave.serverSaveStatus == .none)
    #expect(model.serverSave.serverSaveFeedbackMessage == nil)
    #expect(model.serverSave.serverSaveBannerMessage == nil)
    #expect(model.serverSave.serverSaveStatus(for: "9") == .none)
    #expect(model.serverSave.serverSaveAttemptID(for: "9") == nil)
  }

  @Test("the child holds its host weakly and is inert without one")
  func childHoldsItsHostWeakly() async {
    let child = PodcastShowServerSaveModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      serverPodcastMutationCapabilityReading: Self.canSaveAndRemove)
    var host: StubServerSaveHost? = StubServerSaveHost(episodes: [summary("9")])
    weak let weakHost = host
    child.attach(host: host!)

    host = nil
    #expect(weakHost == nil)

    // No host means no visible episodes, so nothing is selected and no batch starts.
    child.beginBatchServerSave(episodeIDs: ["9"])
    #expect(child.batchServerSave == nil)
    #expect(child.showSavePreselectedEpisodeID == nil)
    // An error with nowhere to go is dropped, and the child's own status still records it.
    await child.saveEpisodeToServer(episodeID: "9")
    #expect(child.serverSaveStatus == .failed(.missingEpisode, phase: .save))
  }

  @Test("dropping the show releases its server-save model and ends its observations")
  func droppingTheShowReleasesTheChild() async {
    let subscriptions = FakeNativePodcastSubscriptionsReading()
    weak var weakParent: PodcastShowModel?
    weak var weakChild: PodcastShowServerSaveModel?
    do {
      let model = PodcastShowModel(
        itemID: "rss:7", reading: FakePodcastReading(),
        nativePodcastSubscriptionsReading: subscriptions)
      weakParent = model
      weakChild = model.serverSave
      await waitUntil { subscriptions.observeEnabledCallCount > 0 }
    }

    #expect(weakParent == nil)
    #expect(weakChild == nil)
    #expect(await waitUntil { subscriptions.terminatedObservationCount > 0 })
  }

  @Test("a teardown makes the next same-id emission project again")
  func teardownReopensProjectionForTheSameIDs() async {
    let statuses = FakeNativeEpisodeServerSaveStatusReading()
    let reading = FakePodcastReading()
    let model = PodcastShowModel(
      itemID: "rss:7", reading: reading,
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["a": 1]),
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: Self.canSaveAndRemove)

    reading.pushEpisodes([summary("a")])
    #expect(await waitUntil { statuses.batchCalls.count == 1 })
    reading.pushEpisodes([summary("a")])
    #expect(await waitUntil { model.episodes.count == 1 })

    model.serverSave.clearServerSavePresentation(for: .nativeSubscriptionsDisabled)
    reading.pushEpisodes([summary("a")])

    #expect(await waitUntil { statuses.batchCalls.count == 2 })
  }

  @Test("re-enabling subscriptions projects the parent's current episodes, prefix included")
  func reenableProjectsTheParentsCurrentEpisodes() async {
    let subscriptions = FakeNativePodcastSubscriptionsReading()
    let statuses = FakeNativeEpisodeServerSaveStatusReading()
    let reading = FakePodcastReading()
    reading.stubEpisodePrefix(PodcastEpisodePrefix(episodes: [summary("9")], isComplete: true))
    let model = PodcastShowModel(
      itemID: "rss:7", reading: reading,
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["9": 9]),
      nativeEpisodeServerSaveStatusReading: statuses,
      serverPodcastMutationCapabilityReading: Self.canSaveAndRemove,
      nativePodcastSubscriptionsReading: subscriptions)
    await waitUntil { subscriptions.observeEnabledCallCount > 0 }
    #expect(model.episodes.map(\.id) == ["9"])

    subscriptions.stubEnabled(false)
    subscriptions.stubEnabled(true)

    #expect(await waitUntil { statuses.batchCalls == [[9]] })
  }

  @Test("the parent's save-to-server targets are the child's batch targets")
  func selectionPredicateAgreesWithTheChild() async {
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(episodes: [summary("9"), summary("10")]),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["9": 9, "10": 10]),
      serverPodcastMutationCapabilityReading: Self.canSaveAndRemove)
    #expect(await waitUntil { model.serverSave.serverMutationCapability.canSave })
    model.serverSave.serverSaveStatuses["10"] = .requested

    let targets = model.selectedActionTargets(.saveToServer, episodeIDs: ["9", "10"])
    #expect(targets.map(\.id) == ["9"])
    #expect(model.serverSave.showSavePreselectedEpisodeID == "9")

    model.serverSave.beginBatchServerSave(episodeIDs: ["9", "10"])
    #expect(model.serverSave.batchServerSave?.total == 1)
  }

  @Test("server-save errors land in the show's one action-error channel")
  func serverSaveErrorsUseTheParentsChannel() async {
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      serverPodcastMutationCapabilityReading: Self.canSaveAndRemove)

    await model.serverSave.saveEpisodeToServer(episodeID: "9")
    #expect(
      model.actionErrorMessage
        == NativeEpisodeServerSaveCopy.disabledReason(for: .missingEpisode))

    model.serverSave.dismissServerSaveFeedback()
    #expect(model.actionErrorMessage == nil)
  }

  @Test("a show switch keeps capability and the presentation version; a lifecycle clear does not")
  func showSwitchIsNotALifecycleClear() async {
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(episodes: [summary("9")]),
      nativeEpisodeIDResolving: StaticNativeEpisodeIDResolving(["9": 9]),
      serverPodcastMutationCapabilityReading: Self.canSaveAndRemove)
    #expect(await waitUntil { model.serverSave.serverMutationCapability.canSave })
    let version = model.serverSave.serverSavePresentationVersion

    model.show(itemID: "rss:8")
    #expect(model.serverSave.serverSavePresentationVersion == version)
    #expect(model.serverSave.serverMutationCapability.canSave)

    model.serverSave.clearServerSavePresentation(for: .nativeSubscriptionsDisabled)
    #expect(model.serverSave.serverSavePresentationVersion == version + 1)
    #expect(model.serverSave.serverMutationCapability == .none)
  }
}

// MARK: - Doubles

@MainActor
private final class StubServerSaveHost: PodcastShowServerSaveHost {
  var episodes: [PodcastEpisodeSummary]
  var errors: [String?] = []

  init(episodes: [PodcastEpisodeSummary]) { self.episodes = episodes }

  var serverSaveEpisodes: [PodcastEpisodeSummary] { episodes }
  var serverSaveVisibleEpisodes: [PodcastEpisodeSummary] { episodes }
  func reportServerSaveActionError(_ message: String?) { errors.append(message) }
}

private func summary(_ id: String) -> PodcastEpisodeSummary {
  PodcastEpisodeSummary(
    id: id, title: id, subtitle: nil, episodeDescription: nil, seasonNumber: nil,
    episodeNumber: nil, episodeType: nil, durationSeconds: 120, sizeBytes: nil,
    publishedAt: Date(timeIntervalSince1970: 1_700_000_000), progressSeconds: 0,
    isPlayed: false, isFinished: false, downloadStatus: .notDownloaded,
    isAvailableOnServer: true)
}

extension FakeNativeEpisodeServerSaveStatusReading {
  /// The row ids of every non-empty aggregate read, whether by `statuses` or by an observation
  /// opening; a list with no rows asks nothing.
  fileprivate var batchCalls: [[Int64]] {
    calls.compactMap { call -> [Int64]? in
      switch call {
      case .statuses(_, let episodeIDs), .observeStatuses(_, let episodeIDs):
        episodeIDs.isEmpty ? nil : episodeIDs
      default: nil
      }
    }
  }
}
