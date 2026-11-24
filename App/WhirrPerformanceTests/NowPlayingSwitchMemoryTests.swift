import ABSApi
import PlayerCore
import UIKit
import XCTest

@testable import Whirr

/// Switches through 50 playable items with lock-screen artwork enabled.
///
/// The memory half of the single-artwork check: `WhirrTests` pins `retainedArtworkCountForTesting
/// == 1`, but a leak through the `MPMediaItemArtwork` request closure passes that while the
/// footprint grows. Advisory and relative (see `ArtworkScrollMemoryTests`).
final class NowPlayingSwitchMemoryTests: MemoryScenarioCase {

  private static let itemCount = 50

  @MainActor
  func testSwitchingThroughFiftyItemsWithArtwork() {
    // `XCTMemoryMetric` reports the whole test host, and idle `Whirr.app` is most of it. The peak
    // is around 85 MB, of which only a few MB belong to the scenario. Print the idle baseline so
    // the figure reads as "baseline plus N", not as the cost of fifty switches. Retaining all fifty
    // artworks would add about 70 MB, which is unmissable.
    MemoryProbe.settle()
    let idle = MemoryProbe.physicalFootprintBytes()
    defer {
      MemoryProbe.settle()
      let settled = MemoryProbe.physicalFootprintBytes()
      print(
        """
        WHIRRMEM scenario4 idleHost=\(MemoryProbe.megabytes(idle)) \
        settled=\(MemoryProbe.megabytes(settled)) \
        retained=\(MemoryProbe.megabytes(settled - idle))
        """)
    }

    measure(metrics: Self.metrics, options: Self.options) {
      let controller = StubPlaybackControlling()
      controller.state = Self.playerState(itemID: "perf-item-0")
      let adapter = NowPlayingMetadataAdapter(
        sink: StubNowPlayingInfoSink(),
        controller: controller,
        itemInfoProvider: StubNowPlayingItemInfoProviding(),
        coverImageClient: StubCoverImageClientFactory.make(),
        displayScale: 3,
        // Bypasses transport; this measures what the adapter retains across switches.
        //
        // Decode a fresh bitmap on every call: fifty references to one shared `UIImage` cost
        // nothing (the footprint was identical every iteration). A fresh ~1.4 MB bitmap makes
        // fifty retained artworks cost about 70 MB, so a regression shows.
        artworkImageLoader: { _, _ in
          guard let image = UIImage(data: MemoryScenarioFixtures.coverData)?.preparingForDisplay()
          else {
            return .unavailable
          }
          return .image(image)
        })

      let observed = SwitchCounter()
      let expectation = expectation(description: "fifty switches settled")
      Task { @MainActor in
        for index in 0..<Self.itemCount {
          let itemID = "perf-item-\(index)"
          controller.state = Self.playerState(itemID: itemID)
          controller.emit(
            PlaybackProgressEvent(
              sequence: index, itemId: itemID, phase: .playing,
              currentTime: 10, listenedDelta: 0))
          // The adapter handles `progressEvents` on its own task, so the switch is not observed
          // synchronously. `waitForPendingArtworkForTesting()` alone returns instantly until that
          // task drains the event, which measures a scenario that never ran. Wait until the
          // retained item is this one.
          if try await Self.settle(adapter: adapter, untilRetained: itemID) { observed.increment() }
        }
        expectation.fulfill()
      }
      wait(for: [expectation], timeout: 120)

      // A measurement that stops exercising its subject reports a flat line. Every switch is
      // counted, not just the last, so a `settle` that gave up mid-run cannot pass the final
      // checks.
      XCTAssertEqual(
        observed.count, Self.itemCount, "not every switch was observed reaching the adapter")
      XCTAssertEqual(
        adapter.retainedArtworkItemIDForTesting, "perf-item-\(Self.itemCount - 1)",
        "the scenario did not actually switch through every item")
      XCTAssertEqual(adapter.retainedArtworkCountForTesting, 1, "the adapter retains a single artwork")
    }
  }

  /// Returns whether the adapter reached `itemID` before the deadline.
  ///
  /// Bounded by a clock, not a `Task.yield()` budget. A yield budget limits how often this task
  /// reschedules, which says nothing about the adapter's own task. That mistake made
  /// `NowPlayingMetadataTests` flaky under load.
  @MainActor
  private static func settle(
    adapter: NowPlayingMetadataAdapter, untilRetained itemID: String
  ) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      await adapter.waitForPendingArtworkForTesting()
      if adapter.retainedArtworkItemIDForTesting == itemID { return true }
      try await Task.sleep(for: .milliseconds(2))
    }
    return false
  }

  private static func playerState(itemID: String) -> PlayerState {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 150)])
    return PlayerState(
      phase: .playing,
      item: PlayerItem(id: itemID, episodeID: nil, timeline: timeline, chapters: PlaybackChapterMap(chapters: [])),
      currentTrackIndex: 0,
      globalPosition: 10,
      rate: 1)
  }
}

// MARK: - Minimal doubles
//
// `WhirrTests`'s fakes are not visible here. These record nothing, as that would accumulate
// memory and skew results.

@MainActor
private final class SwitchCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

private final class StubPlaybackControlling: PlaybackControlling, @unchecked Sendable {
  private let lock = NSLock()
  private var storedState: PlayerState
  private let continuation: AsyncStream<PlaybackProgressEvent>.Continuation
  let progressEvents: AsyncStream<PlaybackProgressEvent>

  init() {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 150)])
    storedState = PlayerState(
      phase: .idle,
      item: PlayerItem(
        id: "perf-item-0", episodeID: nil, timeline: timeline, chapters: PlaybackChapterMap(chapters: [])),
      currentTrackIndex: 0,
      globalPosition: 0,
      rate: 1)
    var continuation: AsyncStream<PlaybackProgressEvent>.Continuation!
    progressEvents = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  var state: PlayerState {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedState
    }
    set {
      lock.lock()
      storedState = newValue
      lock.unlock()
    }
  }

  func send(_ intent: PlayerIntent) {}

  func emit(_ event: PlaybackProgressEvent) {
    continuation.yield(event)
  }
}

private final class StubNowPlayingInfoSink: NowPlayingInfoSink {
  var nowPlayingInfo: [String: Any]?
}

private final class StubNowPlayingItemInfoProviding: NowPlayingItemInfoProviding {
  func nowPlayingItemInfo(forItemID itemID: String) -> NowPlayingItemInfo? {
    NowPlayingItemInfo(title: "Performance Fixture", author: "Performance Author")
  }

  func nowPlayingItemInfo(forItemID itemID: String, episodeID: String?) -> NowPlayingItemInfo? {
    nowPlayingItemInfo(forItemID: itemID)
  }
}
