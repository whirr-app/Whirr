import Foundation
import TestSupport
import Testing

@testable import SyncEngine

/// Production builds a clock per transaction from the persisted state, so these rebuild the clock
/// between observing and stamping, the way a transaction boundary does.
@Suite struct PodcastCloudMonotonicSourceTests {
  let installation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

  private func source(_ time: Locked<Int64>) -> PodcastCloudMonotonicSource {
    PodcastCloudMonotonicSource(nowMilliseconds: { time.value })
  }

  /// A clock anchored at server time 1 000, observed at monotonic 50.
  private func anchored(by source: PodcastCloudMonotonicSource, serverMilliseconds: Int64 = 1_000) throws
    -> PodcastCloudClockState
  {
    var clock = source.clock(try PodcastCloudClockState(installationUUID: installation))
    let remote = try PodcastCloudMutationStamp(
      physicalMilliseconds: 1_000, logicalCounter: 0, installationUUID: UUID(), mutationUUID: UUID())
    try clock.observe(
      remote, serverModificationMilliseconds: serverMilliseconds,
      monotonicMilliseconds: source.nowMilliseconds())
    source.remember(clock)
    return clock.state
  }

  @Test func aRebuiltClockAdvancesByElapsedTimeAndIgnoresAWallClockJump() throws {
    let time = Locked<Int64>(50)
    let source = source(time)
    let state = try anchored(by: source)

    time.value = 60_050
    var clock = source.clock(state)
    let stamp = try clock.generate(
      wallClockMilliseconds: 99_000_000, monotonicMilliseconds: source.nowMilliseconds())
    #expect(stamp.physicalMilliseconds == 61_000)
    #expect(stamp.logicalCounter == 0)

    // A wall clock set backwards changes nothing either.
    time.value = 120_050
    clock = source.clock(clock.state)
    let later = try clock.generate(wallClockMilliseconds: 0, monotonicMilliseconds: source.nowMilliseconds())
    #expect(later.physicalMilliseconds == 121_000)
  }

  @Test func aNewProcessHoldsItsPhysicalTimeUntilItObservesANewerAnchor() throws {
    let state = try anchored(by: source(Locked(50)))

    let relaunched = source(Locked(900_000))
    var clock = relaunched.clock(state)
    let stamp = try clock.generate(
      wallClockMilliseconds: 99_000_000, monotonicMilliseconds: relaunched.nowMilliseconds())
    #expect(stamp.physicalMilliseconds == 1_000)
    #expect(stamp.logicalCounter == 1)
  }

  /// The transaction that observed the newer anchor rolled back: the row still holds the older
  /// one, and elapsed time measured from the newer observation must not be applied to it.
  @Test func aPairingForAnAnchorTheRowNeverTookIsNotUsed() throws {
    let time = Locked<Int64>(50)
    let source = source(time)
    let committed = try anchored(by: source)
    _ = try anchored(by: source, serverMilliseconds: 5_000)

    time.value = 60_050
    var clock = source.clock(committed)
    let stamp = try clock.generate(
      wallClockMilliseconds: 99_000_000, monotonicMilliseconds: source.nowMilliseconds())
    #expect(stamp.physicalMilliseconds == 1_000)
  }
}
