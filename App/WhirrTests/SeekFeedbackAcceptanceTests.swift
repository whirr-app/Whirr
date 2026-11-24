import DesignSystem
import TestSupport
import Testing

@testable import Whirr

@MainActor
@Suite("Seek feedback acceptance")
struct SeekFeedbackAcceptanceTests {
  private let identity = SeekFeedbackState.Identity(itemID: "book", episodeID: "episode")

  @Test("the scrub bubble and left clock agree across every supported scope")
  func scrubBubbleMatchesScopedElapsedClock() {
    // These are the same kinds of windows exercised by PlayerTimeFormattingTests: a chapter
    // interior, a chapter boundary, no chapter, a podcast episode, and a value past one hour.
    let cases: [(displayedTime: Double, start: Double, expected: String)] = [
      (2_400, 1_200, "20:00"),  // chaptered audiobook, mid-chapter
      (4_560, 4_560, "00:00"),  // exactly at the next chapter's boundary
      (2_400, 0, "40:00"),  // chapterless audiobook
      (125, 0, "02:05"),  // podcast episode
      (3_665, 0, "1:01:05"),  // multi-hour position, h:mm:ss threshold
    ]

    for testCase in cases {
      let targetSeconds = testCase.displayedTime - testCase.start
      let leftClock = PlayerTimeFormatting.scopedElapsedClock(
        currentTime: testCase.displayedTime, start: testCase.start)

      #expect(leftClock == testCase.expected)
      #expect(
        SeekFeedbackPresentation.scrubLabel(targetSeconds: targetSeconds) == leftClock)
    }
  }

  @Test("transport and keyboard origins record the configured signed interval")
  func configuredIntervalsBecomeSignedReceipts() {
    // The transport and keyboard call-site wiring is gated by SeekFeedbackSourceScanTests. This
    // test drives the state with the exact values those two sighted origins are required to send.
    let configurations = [
      (storedBackward: 0, storedForward: 0),
      (storedBackward: 90, storedForward: 75),
    ]

    for configuration in configurations {
      let state = makeState(driver: ExpiryDriver())
      let backward = Double(
        SkipIntervalConfiguration.resolvedSeconds(configuration.storedBackward, forward: false))
      let forward = Double(
        SkipIntervalConfiguration.resolvedSeconds(configuration.storedForward, forward: true))

      state.recordSkip(delta: -backward, identity: identity)
      #expect(state.skipDeltaSeconds == -backward)

      state.cancelSkipEpisode()
      state.recordSkip(delta: forward, identity: identity)
      #expect(state.skipDeltaSeconds == forward)
    }
  }

  @Test("a configured tap burst accumulates and keeps a zero-total episode visible")
  func realisticTapBurstUsesRequestedAlgebraicTotal() {
    let driver = ExpiryDriver()
    let state = makeState(driver: driver)
    let forward = Double(SkipIntervalConfiguration.resolvedSeconds(30, forward: true))
    let backward = Double(SkipIntervalConfiguration.resolvedSeconds(15, forward: false))

    state.recordSkip(delta: forward, identity: identity)
    state.recordSkip(delta: forward, identity: identity)
    state.recordSkip(delta: forward, identity: identity)
    state.recordSkip(delta: -backward, identity: identity)
    #expect(state.skipDeltaSeconds == 3 * forward - backward)

    let zeroState = makeState(driver: ExpiryDriver())
    let zeroBackward = Double(SkipIntervalConfiguration.resolvedSeconds(90, forward: false))
    zeroState.recordSkip(delta: forward, identity: identity)
    zeroState.recordSkip(delta: forward, identity: identity)
    zeroState.recordSkip(delta: forward, identity: identity)
    zeroState.recordSkip(delta: -zeroBackward, identity: identity)
    #expect(zeroState.skipDeltaSeconds == 0)
  }

  @Test("expiry between taps opens a fresh visual episode with only the later delta")
  func retainedItemVisualEpisodeCanDivergeFromPlayerCoalescing() {
    let driver = ExpiryDriver()
    let state = makeState(driver: driver)

    state.recordSkip(delta: 30, identity: identity)
    driver.fire(0)
    #expect(state.skipDeltaSeconds == nil)

    // PlaybackModel can still coalesce both requests during retained-item preparation; the
    // visual 0.9-second episode cannot, so the later receipt starts at -15.
    state.recordSkip(delta: -15, identity: identity)
    #expect(state.skipDeltaSeconds == -15)
  }

  @Test("repeated back taps at zero retain the unclamped requested total")
  func backTapsDoNotClampTheFeedbackReceiptAtTimelineStart() {
    let driver = ExpiryDriver()
    let state = makeState(driver: driver)
    let backward = Double(
      SkipIntervalConfiguration.resolvedSeconds(
        SkipIntervalConfiguration.defaultBackwardSeconds, forward: false))

    state.recordSkip(delta: -backward, identity: identity)
    state.recordSkip(delta: -backward, identity: identity)
    state.recordSkip(delta: -backward, identity: identity)

    // PlaybackModel.skip clamps the landing position; this state stores the requested receipt.
    #expect(state.skipDeltaSeconds == -3 * backward)
  }

  private func makeState(driver: ExpiryDriver) -> SeekFeedbackState {
    SeekFeedbackState(expire: { duration, callback in
      driver.schedule(duration: duration, callback: callback)
    })
  }

  private nonisolated final class ExpiryDriver: @unchecked Sendable {
    private let callbacks = Locked<[@MainActor () -> Void]>([])

    func schedule(
      duration _: Duration,
      callback: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
      callbacks.withValue { $0.append(callback) }
      return Task {}
    }

    @MainActor
    func fire(_ index: Int) {
      callbacks.value[index]()
    }
  }
}
