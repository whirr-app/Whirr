import AdSkip
import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

/// The library recompute under the analysis conditions: one that is
/// owed waits while analysis is held and stops when it becomes held, staying owed. What the
/// listener asked for, an Undo or Forget Learned Ads, runs whatever the power state.
extension AdSkipCoordinatorTests {

  /// Holds the next recompute at its start until `release()`.
  final class HoldingMeasurement: AdSkipMatchingMeasuring {
    private let gate = TestGate<Void>(
      label: "HoldingMeasurement recompute", ignoresCancellation: true)

    init() { gate.hold() }

    var holding: Bool { gate.parkedCount > 0 }

    /// Holds the next recompute again.
    func arm() { gate.hold() }

    func release() { gate.release() }

    func willStart(_ unit: AdSkipMatchingUnit) async {
      guard unit == .recompute else { return }
      await gate.pass()
    }

    func didFinish(_ unit: AdSkipMatchingUnit, _ detail: AdSkipMatchingDetail) async {}
  }

  /// Two analysed episodes sharing an ad, stopped, with every row left on an older rules revision:
  /// a relaunch owes one recompute and no analysis.
  private func staleLibrary() async throws -> (Harness, [AdSkipLocalEpisode]) {
    let harness = try Harness()
    let library = ["a", "b"].map { harness.episode($0, transcript: Self.withAd($0)) }
    await harness.run(library)
    await harness.coordinator.stop()
    for var row in try await harness.episodes.allEpisodes() {
      row.rulesRevision = AdSkipRules.revision - 1
      _ = try await harness.episodes.save(row, ranges: [])
    }
    return (harness, library)
  }

  private func isRescored(_ harness: Harness) async throws -> Bool {
    try await harness.episodes.allEpisodes().allSatisfy { $0.rulesRevision == AdSkipRules.revision }
  }

  @Test func anOwedRecomputeWaitsUntilAnalysisIsAllowed() async throws {
    let (harness, library) = try await staleLibrary()
    let restarted = try Harness(reusing: harness)
    await restarted.run(library, allowed: false)
    #expect(try await isRescored(restarted) == false)
    #expect(await restarted.coordinator.isRecomputePending)

    await restarted.coordinator.setAllowed(true)
    await restarted.coordinator.waitUntilIdle()
    #expect(try await isRescored(restarted))
    #expect(try await restarted.ranges("a").count == 1)
  }

  @Test func theOvernightExpiryStopsARecomputeAndLeavesItOwed() async throws {
    let (harness, library) = try await staleLibrary()
    let measurement = HoldingMeasurement()
    let restarted = try Harness(reusing: harness, measurement: measurement)
    await restarted.coordinator.setLocalEpisodes(library)
    await restarted.coordinator.setAllowed(true)
    await restarted.coordinator.setEnabled(true)
    #expect(await waitUntil("the recompute is held") { measurement.holding })

    await restarted.coordinator.suspendForExpiry()
    measurement.release()
    await restarted.coordinator.waitUntilIdle()
    #expect(try await isRescored(restarted) == false)
    #expect(await restarted.coordinator.isRecomputePending)

    await restarted.coordinator.setAllowed(true)
    await restarted.coordinator.waitUntilIdle()
    #expect(try await isRescored(restarted))
  }

  @Test func aMoveToBatteryStopsARecomputeAndLeavesItOwed() async throws {
    let (harness, library) = try await staleLibrary()
    let measurement = HoldingMeasurement()
    let restarted = try Harness(reusing: harness, measurement: measurement)
    await restarted.coordinator.setLocalEpisodes(library)
    await restarted.coordinator.setAllowed(true)
    await restarted.coordinator.setEnabled(true)
    #expect(await waitUntil("the recompute is held") { measurement.holding })

    await restarted.coordinator.setAllowed(false)
    measurement.release()
    await restarted.coordinator.waitUntilIdle()
    #expect(try await isRescored(restarted) == false)
    #expect(await restarted.coordinator.isRecomputePending)

    await restarted.coordinator.setAllowed(true)
    await restarted.coordinator.waitUntilIdle()
    #expect(try await isRescored(restarted))
  }

  @Test func anUndoOnBatteryStillTrimsTheRangesStraightAway() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let skipped = try #require(await harness.coordinator.skipRanges(for: Self.request(b)).first)
    await harness.coordinator.setAllowed(false)

    await harness.coordinator.undoSkip(skipped, for: Self.request(b))
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.ranges("b").isEmpty)
  }

  @Test func forgettingLearnedAdsOnBatteryStillClearsTheirRanges() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    await harness.coordinator.setLocalEpisodes([b])
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").count == 1)
    await harness.coordinator.setAllowed(false)

    await harness.coordinator.forgetLearnedAds()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").isEmpty)
  }

  @Test func theOvernightExpiryStopsAnUndosRecomputeUntilAnalysisIsAllowed() async throws {
    let measurement = HoldingMeasurement()
    let harness = try Harness(measurement: measurement)
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.coordinator.setLocalEpisodes([a, b])
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.setEnabled(true)
    // The backlog's first recompute is the one held; the undo's follows unheld until re-armed.
    #expect(await waitUntil("the first recompute is held") { measurement.holding })
    measurement.release()
    await harness.coordinator.waitUntilIdle()
    let skipped = try #require(await harness.coordinator.skipRanges(for: Self.request(b)).first)
    await harness.coordinator.setAllowed(false)

    measurement.arm()
    await harness.coordinator.undoSkip(skipped, for: Self.request(b))
    #expect(await waitUntil("the undo's recompute is held") { measurement.holding })
    await harness.coordinator.suspendForExpiry()
    measurement.release()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").count == 1)
    #expect(await harness.coordinator.isRecomputePending)

    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").isEmpty)
  }
}
