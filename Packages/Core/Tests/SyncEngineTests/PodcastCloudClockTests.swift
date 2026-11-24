import Foundation
import Testing

@testable import SyncEngine

@Suite struct PodcastCloudClockTests {
  let installation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

  @Test func monotonicAndBackwardWallClock() throws {
    var clock = PodcastCloudClock(state: try PodcastCloudClockState(installationUUID: installation))
    let a = try clock.generate(wallClockMilliseconds: 1000, mutationUUID: installation)
    let b = try clock.generate(wallClockMilliseconds: 900, mutationUUID: installation)
    #expect(a < b)
    #expect(b.physicalMilliseconds == 1000)
  }

  @Test func futureRemoteIsQuarantinedWithoutAdvancing() throws {
    var clock = PodcastCloudClock(state: try PodcastCloudClockState(installationUUID: installation))
    let remote = try PodcastCloudMutationStamp(
      physicalMilliseconds: 90_000_000,
      logicalCounter: 3, installationUUID: installation, mutationUUID: installation)
    #expect(throws: PodcastCloudClock.Error.quarantined) {
      try clock.observe(remote, serverModificationMilliseconds: 0)
    }
    #expect(clock.state.physicalMilliseconds == 0)
  }

  @Test func sameRemoteAdmissionIsImmutableAndIdempotent() throws {
    var clock = PodcastCloudClock(state: try PodcastCloudClockState(installationUUID: installation))
    let remote = try PodcastCloudMutationStamp(
      physicalMilliseconds: 1000, logicalCounter: 2,
      installationUUID: installation, mutationUUID: installation)
    try clock.observe(remote, serverModificationMilliseconds: 1000)
    let first = clock.state
    try clock.observe(remote, serverModificationMilliseconds: 1000)
    #expect(clock.state == first)
  }

  @Test func restartWithAnchorAndNoMonotonicDoesNotJump() throws {
    var clock = PodcastCloudClock(
      state: try PodcastCloudClockState(
        installationUUID: installation, physicalMilliseconds: 5000, logicalCounter: 2,
        anchorServerMilliseconds: 5000))
    let stamp = try clock.generate(wallClockMilliseconds: 99_000_000, mutationUUID: installation)
    #expect(stamp.physicalMilliseconds == 5000)
    #expect(stamp.logicalCounter == 3)
  }

  @Test func counterOverflowIsRejected() throws {
    var clock = PodcastCloudClock(
      state: try PodcastCloudClockState(
        installationUUID: installation, physicalMilliseconds: 5, logicalCounter: .max))
    #expect(throws: PodcastCloudClock.Error.counterOverflow) {
      try clock.generate(wallClockMilliseconds: 5, mutationUUID: installation)
    }
  }

  @Test func decodingRejectsNegativePersistedClock() throws {
    let state = try PodcastCloudClockState(installationUUID: installation)
    let encoded = try JSONEncoder().encode(state)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["physicalMilliseconds"] = -1
    let invalid = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: PodcastCloudClock.Error.invalidState) {
      try JSONDecoder().decode(PodcastCloudClockState.self, from: invalid)
    }
  }

  @Test func rejectsClockBehindItsAdmittedRemoteTuple() throws {
    #expect(throws: PodcastCloudClock.Error.invalidState) {
      try PodcastCloudClockState(
        installationUUID: installation, physicalMilliseconds: 1000, logicalCounter: 2,
        lastAdmittedPhysicalMilliseconds: 1001, lastAdmittedLogicalCounter: 0)
    }
    #expect(throws: PodcastCloudClock.Error.invalidState) {
      try PodcastCloudClockState(
        installationUUID: installation, physicalMilliseconds: 1000, logicalCounter: 2,
        lastAdmittedPhysicalMilliseconds: 1000, lastAdmittedLogicalCounter: 3)
    }
  }

  @Test func restartDoesNotReuseMonotonicTimeFromAnEarlierProcess() throws {
    var clock = PodcastCloudClock(
      state: try PodcastCloudClockState(
        installationUUID: installation, physicalMilliseconds: 5000, logicalCounter: 2,
        anchorServerMilliseconds: 5000))
    let stamp = try clock.generate(
      wallClockMilliseconds: 99_000_000, monotonicMilliseconds: 10_000, mutationUUID: installation)
    #expect(stamp.physicalMilliseconds == 5000)
    #expect(stamp.logicalCounter == 3)
  }

  @Test func localFutureClockRequiresExplicitRepairAcrossRelaunch() throws {
    var clock = PodcastCloudClock(state: try PodcastCloudClockState(installationUUID: installation))
    _ = try clock.generate(wallClockMilliseconds: 99_000_000)
    let remote = try PodcastCloudMutationStamp(
      physicalMilliseconds: 1000, logicalCounter: 2,
      installationUUID: UUID(), mutationUUID: UUID())
    #expect(throws: PodcastCloudClock.Error.quarantined) {
      try clock.observe(remote, serverModificationMilliseconds: 1000)
    }
    let persisted = try JSONEncoder().encode(clock.state)
    clock = PodcastCloudClock(state: try JSONDecoder().decode(PodcastCloudClockState.self, from: persisted))
    #expect(throws: PodcastCloudClock.Error.quarantined) {
      try clock.generate(wallClockMilliseconds: 1000)
    }
    try clock.repair(wallClockMilliseconds: 1000)
    try clock.observe(remote, serverModificationMilliseconds: 1000)
    let generated = try clock.generate(wallClockMilliseconds: 1000)
    #expect(generated > remote)
    #expect(generated.physicalMilliseconds == 1000)
  }
  @Test func anchoredClockUsesMonotonicAndIgnoresWallJump() throws {
    var clock = PodcastCloudClock(state: try PodcastCloudClockState(installationUUID: installation))
    let remote = try PodcastCloudMutationStamp(
      physicalMilliseconds: 1_000, logicalCounter: 0, installationUUID: installation, mutationUUID: installation)
    try clock.observe(remote, serverModificationMilliseconds: 1_000, monotonicMilliseconds: 50)
    let stamp = try clock.generate(
      wallClockMilliseconds: 99_000_000, monotonicMilliseconds: 150, mutationUUID: installation)
    #expect(stamp.physicalMilliseconds == 1_100)
  }
}
