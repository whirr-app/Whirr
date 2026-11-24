import TestSupport
import Testing

@testable import Whirr

@MainActor
@Suite("Seek feedback state")
struct SeekFeedbackStateTests {
  private let firstIdentity = SeekFeedbackState.Identity(itemID: "book", episodeID: "one")

  @Test("a single record shows its signed delta")
  func singleRecord() {
    let driver = ExpiryDriver()
    let state = makeState(driver: driver)

    state.recordSkip(delta: -15, identity: firstIdentity)

    #expect(state.skipDeltaSeconds == -15)
  }

  @Test("same-identity records accumulate algebraically")
  func accumulatesSameDirection() {
    let driver = ExpiryDriver()
    let state = makeState(driver: driver)

    state.recordSkip(delta: 30, identity: firstIdentity)
    state.recordSkip(delta: 30, identity: firstIdentity)
    state.recordSkip(delta: 30, identity: firstIdentity)

    #expect(state.skipDeltaSeconds == 90)
  }

  @Test("opposing records retain their non-zero total")
  func accumulatesOpposingDirections() {
    let driver = ExpiryDriver()
    let state = makeState(driver: driver)

    state.recordSkip(delta: 30, identity: firstIdentity)
    state.recordSkip(delta: -15, identity: firstIdentity)

    #expect(state.skipDeltaSeconds == 15)
  }

  @Test("opposing records that total zero remain visible")
  func zeroIsStillAnEpisode() {
    let driver = ExpiryDriver()
    let state = makeState(driver: driver)

    state.recordSkip(delta: 30, identity: firstIdentity)
    state.recordSkip(delta: -30, identity: firstIdentity)

    #expect(state.skipDeltaSeconds == 0)
  }

  @Test("expiry clears after the latest record")
  func expiryClearsLatestEpisode() {
    let driver = ExpiryDriver()
    let state = makeState(driver: driver)

    state.recordSkip(delta: 10, identity: firstIdentity)
    state.recordSkip(delta: 20, identity: firstIdentity)
    driver.fire(0)
    // The two taps accumulate, so the first tap's expiry is stale and must not clear them.
    #expect(state.skipDeltaSeconds == 30)

    driver.fire(1)
    #expect(state.skipDeltaSeconds == nil)
  }

  @Test("a stale expiry cannot clear a newer record")
  func staleGenerationIsHarmless() {
    let driver = ExpiryDriver()
    let state = makeState(driver: driver)

    state.recordSkip(delta: 10, identity: firstIdentity)
    state.recordSkip(delta: 20, identity: firstIdentity)
    driver.fire(0)

    #expect(state.skipDeltaSeconds == 30)
  }

  @Test("a different identity starts a fresh episode")
  func differentIdentityResets() {
    let driver = ExpiryDriver()
    let state = makeState(driver: driver)
    let otherIdentity = SeekFeedbackState.Identity(itemID: "book-2", episodeID: nil)

    state.recordSkip(delta: 30, identity: firstIdentity)
    state.recordSkip(delta: -15, identity: otherIdentity)

    #expect(state.skipDeltaSeconds == -15)
  }

  @Test("cancellation clears immediately and stale expiry remains harmless")
  func cancellationInvalidatesExpiry() {
    let driver = ExpiryDriver()
    let state = makeState(driver: driver)

    state.recordSkip(delta: 30, identity: firstIdentity)
    state.cancelSkipEpisode()
    driver.fire(0)

    #expect(state.skipDeltaSeconds == nil)
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
