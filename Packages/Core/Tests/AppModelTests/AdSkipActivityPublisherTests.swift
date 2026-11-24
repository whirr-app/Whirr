import Foundation
import Persistence
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// `AdSkipSettledState`'s status rule and `AdSkipActivityPublisher`'s settle
/// Covers the ladder the card and the player share, when the settled state speaks at all, and that
/// a change reaches the tiles once it has held and not before.
@Suite struct AdSkipActivityPublisherTests {
  typealias Harness = AdSkipCoordinatorTests.Harness
  typealias Tests = AdSkipCoordinatorTests

  private func state(
    activity: Set<AdSkipEpisodeIdentity>? = nil, isEnabled: Bool = true,
    hasAllowedSignal: Bool = true, isAllowed: Bool = false, isDeferred: Bool = false,
    priority: AdSkipEpisodeIdentity? = nil, isGrantActive: Bool = false
  ) -> AdSkipSettledState {
    AdSkipSettledState(
      activity: activity.map { AdSkipAnalysisActivity(identities: $0) }, isEnabled: isEnabled,
      hasAllowedSignal: hasAllowedSignal, isAllowed: isAllowed, isDeferred: isDeferred,
      priority: priority, isGrantActive: isGrantActive)
  }

  // MARK: - The status rule

  @Test func theStandingIsTheLadderTheCardAndThePlayerShare() {
    let a = Harness.identity("a")
    let b = Harness.identity("b")
    #expect(state(activity: [a]).standing(of: a) == .checking)
    #expect(state(isDeferred: true).standing(of: a) == .waiting(.speechModel))
    #expect(state(isAllowed: true).standing(of: a) == .queued)
    #expect(state(isAllowed: true, priority: a).standing(of: a) == .checking)
    #expect(state(priority: a, isGrantActive: true).standing(of: a) == .checking)
    #expect(state(priority: a, isGrantActive: true).standing(of: b) == .waiting(.conditions))
    #expect(state(isGrantActive: true).standing(of: a) == .waiting(.conditions))
    #expect(state().standing(of: a) == .waiting(.conditions))
    // A unit under analysis is checking even while the speech model defers it.
    #expect(state(activity: [a], isDeferred: true).standing(of: a) == .checking)
  }

  @Test func theSettledStateSpeaksOnlyWhenAnalysisMayRunForACoveredEpisode() {
    #expect(state(isEnabled: false).speaks(about: true) == false)
    #expect(state(hasAllowedSignal: false).speaks(about: true) == false)
    #expect(state().speaks(about: false) == false)
    #expect(state().speaks(about: true))
  }

  // MARK: - The settle

  @Test func aChangeUndoneBeforeTheSettlePublishesNothing() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.setActivitySettle(.seconds(60))
    let signals = Mutex(0)
    let listening = Task {
      for await _ in coordinator.analysisStatusChanges() {
        signals.withLock { $0 += 1 }
      }
    }
    // A change of priority alone: back to the settled state before the settle can elapse.
    await coordinator.prioritize(Harness.identity("a"))
    #expect(await coordinator.hasPendingSettle)
    await coordinator.prioritize(nil)
    #expect(await coordinator.hasPendingSettle == false)
    #expect(
      await awaitQuiescence("no publish", of: { "\(signals.withLock { $0 })" }) == .observed)
    #expect(signals.withLock { $0 } == 0)
    listening.cancel()
  }

  @Test func aHeldChangePublishesOnce() async throws {
    let harness = try Harness(wholeFiles: true)
    let coordinator = harness.coordinator
    await coordinator.setActivitySettle(.zero)
    let a = harness.episode("a", transcript: Tests.withAd("a"))
    harness.transcriber.hold(a.fileURL)
    let published = Mutex<[AdSkipAnalysisActivity]>([])
    let listening = Task {
      for await activity in coordinator.analysisActivityUpdates() {
        if let activity { published.withLock { $0.append(activity) } }
      }
    }
    await coordinator.setLocalEpisodes([a])
    await coordinator.setAllowed(true)
    await coordinator.setEnabled(true)
    #expect(
      await waitUntil("a is the published activity") {
        published.withLock { activities in
          activities.contains { activity in
            activity.includes(itemID: a.identity.itemID, episodeID: a.identity.episodeID)
          }
        }
      })
    #expect(published.withLock { $0.count } == 1)
    harness.transcriber.release()
    await coordinator.waitUntilIdle()
    listening.cancel()
  }
}
