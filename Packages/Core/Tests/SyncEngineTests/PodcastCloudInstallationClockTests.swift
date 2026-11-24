import Foundation
import Persistence
import Testing

@testable import SyncEngine

/// The property the whole mechanism exists for. A restored device must not emit a stamp that loses
/// to state its own backup already contained, and the only thing standing between it and that is
/// carrying the counter forward across the re-mint.
@Suite struct PodcastCloudInstallationClockTests {

  @Test func aReMintedIdentityStillSortsAfterTheSourceDevicesLastStamp() throws {
    let source = UUID()
    // The source device published stamps up to (1_000, 5) before its backup was taken.
    let restored = PodcastCloudClockFields(
      installationUUID: source.uuidString.lowercased(), physicalMilliseconds: 1_000,
      logicalCounter: 5)
    let published = try PodcastCloudMutationStamp(
      physicalMilliseconds: 1_000, logicalCounter: 5, installationUUID: source,
      mutationUUID: UUID())

    // What the store's re-mint produces: a fresh identity over unchanged numeric state.
    // `carryingForward` is internal to `Persistence`; what it produces is asserted there. This
    // states the same shape directly, which is what the ordering property actually rests on.
    let reMinted = PodcastCloudClockFields(
      installationUUID: UUID().uuidString.lowercased(),
      physicalMilliseconds: restored.physicalMilliseconds,
      logicalCounter: restored.logicalCounter)
    var clock = PodcastCloudClock(state: try PodcastCloudClockState(reMinted))
    // A wall clock that has not yet passed the restored physical time is the hard case: ordering
    // rests entirely on the counter, not on elapsed time.
    let next = try clock.generate(wallClockMilliseconds: 900)

    #expect(published < next)
    #expect(next.physicalMilliseconds == 1_000)
    #expect(next.logicalCounter == 6)
    #expect(next.installationUUID != source)
  }

  /// The failure a counter reset would produce, asserted directly so the reason for the rule is
  /// recorded rather than remembered.
  @Test func resettingTheCounterWouldSortBeforeThePublishedStamp() throws {
    let source = UUID()
    let published = try PodcastCloudMutationStamp(
      physicalMilliseconds: 1_000, logicalCounter: 5, installationUUID: source,
      mutationUUID: UUID())
    var reset = PodcastCloudClock(
      state: try PodcastCloudClockState(installationUUID: UUID(), physicalMilliseconds: 1_000))
    let next = try reset.generate(wallClockMilliseconds: 900)
    #expect(next.logicalCounter == 1)
    #expect(next < published, "this is what carrying the counter forward prevents")
  }

  @Test func mappingRoundTripsEveryField() throws {
    let record = PodcastCloudClockFields(
      installationUUID: UUID().uuidString.lowercased(), physicalMilliseconds: 9_000,
      logicalCounter: 42, anchorServerMilliseconds: 8_500,
      lastAdmittedPhysicalMilliseconds: 8_900, lastAdmittedLogicalCounter: 3,
      repairRequired: true)
    let state = try PodcastCloudClockState(record)
    #expect(PodcastCloudClockFields(state) == record)
  }
}
