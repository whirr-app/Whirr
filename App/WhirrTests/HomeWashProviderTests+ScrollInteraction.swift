import ABSApi
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import TestSupport
import Testing

@testable import Whirr

extension HomeWashProviderTests {

  // MARK: - Scroll interaction defers publication

  @Test("every moving scroll phase defers publication; only idle publishes")
  func scrollPhasePublicationPolicy() {
    #expect(HomeWashProvider.shouldDeferPublication(for: .tracking))
    #expect(HomeWashProvider.shouldDeferPublication(for: .interacting))
    #expect(HomeWashProvider.shouldDeferPublication(for: .decelerating))
    #expect(HomeWashProvider.shouldDeferPublication(for: .animating))
    #expect(HomeWashProvider.shouldDeferPublication(for: .idle) == false)
  }

  @Test("each scroll phase applies the provider's publication policy")
  func eachScrollPhaseAppliesPublicationPolicy() async {
    let phases: [(ScrollPhase, Bool)] = [
      (.tracking, true), (.interacting, true), (.decelerating, true), (.animating, true),
      (.idle, false),
    ]

    for (phase, shouldDefer) in phases {
      let fixtures = EditorialWashTestFixtures()
      let observer = EditorialWashBatchObserver()
      let provider = HomeWashProvider(
        service: fixtures.service(), displaySize: HomeView.cardCoverSize,
        displayScale: EditorialWashTestFixtures.cardScale,
        onBatchResolved: observer.receive)
      provider.setScrollInteractionActive(
        phase,
        source: HomeWashProvider.ScrollSource(id: .homeOuter, generation: UUID()))
      provider.request(washesFor: [fixtures.itemID], intent: .bulk)
      _ = await observer.nextBatch()

      #expect(provider.washes.isEmpty == shouldDefer)
    }
  }

  @Test("resolved washes wait for the scroll to settle at idle")
  func resolvedWashesWaitForDirectScrollInteractionToEnd() async {
    let fixtures = EditorialWashTestFixtures()
    let observer = EditorialWashBatchObserver()
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record,
      onBatchResolved: observer.receive)
    let source = HomeWashProvider.ScrollSource(id: .homeOuter, generation: UUID())
    provider.setScrollInteractionActive(.tracking, source: source)
    provider.setScrollInteractionActive(.tracking, source: source)
    provider.request(washesFor: [fixtures.itemID, "show-2"], intent: .bulk)
    _ = await awaitCondition(
      "both scroll-deferred washes resolve",
      observing: { "resolved=\(observer.resolvedCount)/2" },
      until: { observer.resolvedCount >= 2 })
    let allResolved = observer.resolvedWashes

    #expect(allResolved.count == 2)
    #expect(provider.washes.isEmpty)
    #expect(mutationObserver.count == 0)

    provider.setScrollInteractionActive(.decelerating, source: source)
    provider.setScrollInteractionActive(.decelerating, source: source)

    #expect(provider.washes.isEmpty)
    #expect(mutationObserver.count == 0)

    provider.setScrollInteractionActive(.idle, source: source)
    #expect(provider.washes.count == 2)
    #expect(mutationObserver.count == 1)

    provider.setScrollInteractionActive(.tracking, source: source)
    provider.setScrollInteractionActive(.idle, source: source)
    #expect(mutationObserver.count == 1)
  }

  @Test("overlapping scroll sources wait for the last idle source")
  func overlappingScrollSourcesWaitForTheLastIdleSource() async {
    let fixtures = EditorialWashTestFixtures()
    let observer = EditorialWashBatchObserver()
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record,
      onBatchResolved: observer.receive)
    let outer = HomeWashProvider.ScrollSource(id: .homeOuter, generation: UUID())
    let rail = HomeWashProvider.ScrollSource(
      id: .homeRail(.recentlyAdded), generation: UUID())
    provider.setScrollInteractionActive(.tracking, source: outer)
    provider.setScrollInteractionActive(.decelerating, source: rail)
    provider.request(washesFor: [fixtures.itemID], intent: .bulk)
    _ = await observer.nextBatch()

    #expect(provider.washes.isEmpty)
    provider.setScrollInteractionActive(.idle, source: outer)
    #expect(provider.washes.isEmpty)
    #expect(mutationObserver.count == 0)

    provider.setScrollInteractionActive(.idle, source: rail)
    #expect(provider.washes.count == 1)
    #expect(mutationObserver.count == 1)
    provider.setScrollInteractionActive(.idle, source: rail)
    #expect(mutationObserver.count == 1)
  }

  @Test("preload completing during tracking publishes only at idle")
  func preloadCompletingDuringTrackingPublishesOnlyAtIdle() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record)
    let source = HomeWashProvider.ScrollSource(id: .homeOuter, generation: UUID())

    provider.setScrollInteractionActive(.tracking, source: source)
    let preload = Task { await provider.preloadCachedWashes(for: [fixtures.itemID]) }
    await preload.value

    #expect(provider.washes.isEmpty)
    #expect(mutationObserver.count == 0)
    provider.setScrollInteractionActive(.idle, source: source)
    #expect(provider.washes.count == 1)
    #expect(mutationObserver.count == 1)
  }

  // MARK: - Scroll source lifecycle

  @Test("screen retirement clears abandoned scroll sources")
  func screenRetirementClearsAbandonedScrollSources() async {
    let fixtures = EditorialWashTestFixtures()
    let observer = EditorialWashBatchObserver()
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record,
      onBatchResolved: observer.receive)
    let retired = HomeWashProvider.ScrollSource(id: .homeOuter, generation: UUID())
    let reused = HomeWashProvider.ScrollSource(id: .homeOuter, generation: UUID())
    provider.setScrollInteractionActive(.tracking, source: retired)
    provider.request(washesFor: [fixtures.itemID], intent: .bulk)
    _ = await observer.nextBatch()
    provider.retireScrollSource(retired)
    #expect(provider.washes.count == 1)
    #expect(mutationObserver.count == 1)

    let secondItemID = "show-reused"
    provider.setScrollInteractionActive(.tracking, source: reused)
    provider.request(washesFor: [secondItemID], intent: .bulk)
    _ = await observer.nextBatch()

    // An idle callback from the retired generation cannot settle the recreated host.
    provider.setScrollInteractionActive(.idle, source: retired)
    #expect(provider.washes.count == 1)
    provider.retireAllScrollSources()
    #expect(provider.washes.count == 2)
    #expect(mutationObserver.count == 2)
    provider.retireAllScrollSources()
    #expect(mutationObserver.count == 2)
  }

  @Test("a scroll source is stable while live and fresh after retirement")
  func scrollSourceIsStableWhileLiveAndFreshAfterRetirement() {
    let fixtures = EditorialWashTestFixtures()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale)

    let first = provider.scrollSource(for: .homeRail(.recentlyAdded))
    #expect(provider.scrollSource(for: .homeRail(.recentlyAdded)) == first)
    #expect(provider.scrollSource(for: .homeOuter) != first)

    provider.retireScrollSource(first)
    let second = provider.scrollSource(for: .homeRail(.recentlyAdded))
    #expect(second.id == first.id)
    #expect(second.generation != first.generation)

    provider.retireAllScrollSources()
    #expect(provider.scrollSource(for: .homeRail(.recentlyAdded)).generation != second.generation)
  }

  @Test("a late retire from a replaced rail instance cannot silence its successor")
  func lateRetireFromReplacedRailInstanceCannotSilenceSuccessor() async {
    let fixtures = EditorialWashTestFixtures()
    let observer = EditorialWashBatchObserver()
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record,
      onBatchResolved: observer.receive)
    let first = provider.scrollSource(for: .homeRail(.recentlyAdded))
    provider.retireScrollSource(first)
    let successor = provider.scrollSource(for: .homeRail(.recentlyAdded))

    provider.setScrollInteractionActive(.tracking, source: successor)
    provider.request(washesFor: [fixtures.itemID], intent: .bulk)
    _ = await observer.nextBatch()

    // The replaced instance's onDisappear fires after its successor started moving.
    provider.retireScrollSource(first)
    #expect(provider.washes.isEmpty)
    #expect(mutationObserver.count == 0)
    // The successor's generation survives the stale retire: its own idle still settles it.
    #expect(provider.scrollSource(for: .homeRail(.recentlyAdded)) == successor)

    provider.setScrollInteractionActive(.idle, source: successor)
    #expect(provider.washes.count == 1)
    #expect(mutationObserver.count == 1)
  }
}
