import ABSApi
import XCTest

@testable import Whirr

/// Fast artwork scrolling, then idle, and the same run after a simulated memory warning.
///
/// A finger cannot be automated, so this drives many distinct keys through `ArtworkImagePipeline`
/// (fetch, decode, land in `PreparedArtworkCache`), the allocating path to watch.
///
/// Advisory, relative numbers from a Debug simulator build: compare one commit against another
/// for the same case, not the two cases below (see `testSettledFootprintAfterMemoryWarning`).
/// Release-device runs are the evidence of record.
final class ArtworkScrollMemoryTests: MemoryScenarioCase {

  /// Larger than `PreparedArtworkCache.defaultCountLimit` (300), so the run exercises eviction. A
  /// cache that never evicts would look stable here while growing without bound in the app.
  private static let keyCount = 400

  func testScrollingThroughFourHundredCoversThenSettling() {
    let keys = MemoryScenarioFixtures.artworkKeys(count: Self.keyCount)

    measure(metrics: Self.metrics, options: Self.options) {
      // Fresh cache and fetcher per iteration. A shared cache makes the first iteration cold and
      // the rest warm, which reads as an improvement that is only ordering. A shared fetcher makes
      // the work guard below cumulative, so iterations could no-op and still pass it.
      let fetcher = InMemoryArtworkFetcher()
      let cache = PreparedArtworkCache()
      let pipeline = ArtworkImagePipeline(cache: cache, decoder: UtilityCoverImageDecoder())

      Self.scroll(pipeline: pipeline, keys: keys, client: fetcher, on: self)

      // A measurement that stops exercising its subject reports a flat line. The check is per
      // iteration and exact, so one good iteration cannot satisfy it.
      XCTAssertEqual(
        fetcher.count, Self.keyCount, "this iteration decoded nothing - it is measuring noise")
    }
  }

  /// Scroll, then the memory warning: does the settled footprint return near baseline once the
  /// decoded tier is dropped? `RootView`'s warning handler clears this same cache.
  ///
  /// Uses `MemoryProbe`, not `measure`: `XCTMemoryMetric`'s peak is monotonic within the block,
  /// so a closing purge cannot lower it.
  func testSettledFootprintAfterMemoryWarning() {
    let keys = MemoryScenarioFixtures.artworkKeys(count: Self.keyCount)

    for iteration in 0..<Self.iterationCount {
      let fetcher = InMemoryArtworkFetcher()
      let cache = PreparedArtworkCache()
      let pipeline = ArtworkImagePipeline(cache: cache, decoder: UtilityCoverImageDecoder())

      MemoryProbe.settle()
      let baseline = MemoryProbe.physicalFootprintBytes()

      Self.scroll(pipeline: pipeline, keys: keys, client: fetcher, on: self)
      XCTAssertEqual(
        fetcher.count, Self.keyCount, "this iteration decoded nothing - it is measuring noise")

      MemoryProbe.settle()
      let scrolled = MemoryProbe.physicalFootprintBytes()

      cache.removeAll()
      MemoryProbe.settle()
      let purged = MemoryProbe.physicalFootprintBytes()

      // Tagged so the CI step can grep this line out of an xcodebuild log next to the
      // `measured [...]` lines.
      print(
        """
        WHIRRMEM scenario7 iteration=\(iteration) \
        baseline=\(MemoryProbe.megabytes(baseline)) \
        scrolled=\(MemoryProbe.megabytes(scrolled)) \
        purged=\(MemoryProbe.megabytes(purged)) \
        reclaimed=\(MemoryProbe.megabytes(scrolled - purged)) \
        overBaseline=\(MemoryProbe.megabytes(purged - baseline))
        """)

      // The warning handler's contract, and the only claim robust enough to gate on: after the
      // purge the decoded tier is empty. The footprint figures are advisory. A threshold on them
      // would be a coin flip on a shared machine, so the gate is a release-device run.
      XCTAssertNil(
        cache.image(for: keys[Self.keyCount - 1]),
        "the memory-warning purge left decoded artwork behind")
      XCTAssertLessThanOrEqual(
        purged, scrolled, "the footprint grew across a purge that only releases")
    }
  }

  // MARK: - Shared driver

  /// Drives every key concurrently, as a fast scroll does. Sequential driving keeps the decode
  /// queue at depth one and never exercises `ArtworkImagePipeline`'s coalescing.
  private static func scroll(
    pipeline: ArtworkImagePipeline,
    keys: [ArtworkKey],
    client: InMemoryArtworkFetcher,
    on testCase: XCTestCase
  ) {
    let expectation = testCase.expectation(description: "covers decoded")
    Task {
      await withTaskGroup(of: Void.self) { group in
        for key in keys {
          group.addTask { _ = await pipeline.image(for: key, priority: .visible, client: client) }
        }
      }
      expectation.fulfill()
    }
    testCase.wait(for: [expectation], timeout: 120)
  }
}
