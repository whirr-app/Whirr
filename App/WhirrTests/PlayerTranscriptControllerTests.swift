import AppModel
import Foundation
import Persistence
import Synchronization
import TestSupport
import Testing

@testable import Whirr

/// What choosing Transcript in the player's menu does: open the sheet on a transcript that exists
/// or is under way, and otherwise start one, asking first only on battery.
@MainActor
@Suite("Player transcript menu action")
struct PlayerTranscriptControllerTests {

  @Test("an episode with text or work under way just opens the sheet")
  func existingWorkOpensTheSheet() {
    for state: EpisodeTranscriptModel.State in [
      .loading, .ready, .generating(fraction: 0.2), .held(.queued, fraction: 0),
      .needsAsset(fraction: 0),
    ] {
      #expect(
        PlayerTranscriptController.showAction(
          for: state, skipsConfirmation: false, isOnExternalPower: false) == .present)
    }
  }

  @Test("with no transcript, battery asks first")
  func batteryAsksFirst() {
    for state: EpisodeTranscriptModel.State in [.offer(fraction: 0), .offer(fraction: 0.4), .failed] {
      #expect(
        PlayerTranscriptController.showAction(
          for: state, skipsConfirmation: false, isOnExternalPower: false) == .confirm)
    }
  }

  @Test("on external power, or once told not to ask, it starts straight away")
  func powerOrStopAskingStartsAtOnce() {
    #expect(
      PlayerTranscriptController.showAction(
        for: .offer(fraction: 0), skipsConfirmation: false, isOnExternalPower: true)
        == .transcribeAndPresent)
    #expect(
      PlayerTranscriptController.showAction(
        for: .offer(fraction: 0), skipsConfirmation: true, isOnExternalPower: false)
        == .transcribeAndPresent)
  }

  @Test("the kept model still follows status after the page's tracking restarts")
  func modelFollowsStatusAcrossARestart() async {
    let status = FakeStatus()
    let identity = AdSkipEpisodeIdentity(source: .abs, accountId: 1, itemID: "item", episodeID: "ep")
    let controller = PlayerTranscriptController(
      defaults: UserDefaults(suiteName: UUID().uuidString)!, isOnExternalPower: { true })
    let makeModel: (AdSkipEpisodeIdentity) -> EpisodeTranscriptModel = { _ in
      EpisodeTranscriptModel(source: status.source, seek: { _ in })
    }

    let (firstIdentities, firstFeed) = AsyncStream<AdSkipEpisodeIdentity?>.makeStream()
    let first = Task { await controller.track(identities: firstIdentities, makeModel: makeModel) }
    firstFeed.yield(identity)
    _ = await awaitCondition("first run", until: { controller.model?.state == .offer(fraction: 0) })
    first.cancel()
    await first.value

    let (secondIdentities, secondFeed) = AsyncStream<AdSkipEpisodeIdentity?>.makeStream()
    let second = Task { await controller.track(identities: secondIdentities, makeModel: makeModel) }
    secondFeed.yield(identity)
    status.send(.generating(covered: 0.1))

    _ = await awaitCondition(
      "follows after restart", observing: { "\(String(describing: controller.model?.state))" },
      until: { controller.model?.state == .generating(fraction: 0.1) })
    second.cancel()
    await second.value
  }

  @Test("a list menu's request decides once the chosen episode's status is known")
  func listRequestWaitsForTheEpisode() async {
    let status = FakeStatus()
    status.send(.notStarted)
    let identity = AdSkipEpisodeIdentity(source: .abs, accountId: 1, itemID: "item", episodeID: "ep")
    let controller = PlayerTranscriptController(
      defaults: UserDefaults(suiteName: UUID().uuidString)!, isOnExternalPower: { false })
    controller.open(itemID: "item", episodeID: "ep")
    #expect(controller.isConfirmingOnBattery == false)

    let (identities, feed) = AsyncStream<AdSkipEpisodeIdentity?>.makeStream()
    let tracking = Task {
      await controller.track(
        identities: identities,
        makeModel: { _ in EpisodeTranscriptModel(source: status.source, seek: { _ in }) })
    }
    feed.yield(identity)

    _ = await awaitCondition(
      "asks on battery", observing: { "\(String(describing: controller.model?.state))" },
      until: { controller.isConfirmingOnBattery })
    #expect(controller.isPresented == false)
    tracking.cancel()
    await tracking.value
  }

  @Test("a list menu's request for an episode that cannot be transcribed says so")
  func listRequestForAnIneligibleEpisode() async {
    let controller = PlayerTranscriptController(
      defaults: UserDefaults(suiteName: UUID().uuidString)!, isOnExternalPower: { true })
    controller.open(itemID: "item", episodeID: "ep")

    let (identities, feed) = AsyncStream<AdSkipEpisodeIdentity?>.makeStream()
    let tracking = Task {
      await controller.track(
        identities: identities,
        makeModel: { _ in
          Issue.record("no model for an ineligible episode")
          return EpisodeTranscriptModel(source: FakeStatus().source, seek: { _ in })
        })
    }
    feed.yield(nil)

    _ = await awaitCondition("says unavailable", until: { controller.isUnavailablePresented })
    #expect(controller.isPresented == false)
    tracking.cancel()
    await tracking.value
  }
}

/// A status source that, like the coordinator, gives each new subscriber the status now.
private final class FakeStatus: Sendable {
  private struct State {
    var current: EpisodeTranscriptStatus = .notStarted
    var continuations: [AsyncStream<EpisodeTranscriptStatus>.Continuation] = []
  }
  private let state = Mutex(State())

  func send(_ status: EpisodeTranscriptStatus) {
    state.withLock {
      $0.current = status
      for continuation in $0.continuations { continuation.yield(status) }
    }
  }

  var source: EpisodeTranscriptModel.Source {
    EpisodeTranscriptModel.Source(
      statusChanges: { [self] in
        let (stream, continuation) = AsyncStream<EpisodeTranscriptStatus>.makeStream()
        state.withLock {
          continuation.yield($0.current)
          $0.continuations.append(continuation)
        }
        return stream
      },
      transcript: { nil }, request: {}, cancel: {}, retry: {})
  }
}
