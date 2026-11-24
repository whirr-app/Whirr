import Foundation
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Table-driven coverage for the progress clock and deterministic conflict rules.
struct ProgressMergePolicyTests {

  // MARK: - Fixtures

  private let deviceKey = "11111111-1111-1111-1111-111111111111"

  private func current(
    currentTime: TimeInterval,
    isFinished: Bool = false,
    serverUpdatedAt: Date? = nil,
    localSequence: Int64 = 10,
    originKey: String = ProgressMergePolicy.serverOriginKey,
    hasUnacknowledgedLocalOperation: Bool = false
  ) -> ProgressMergePolicy.CurrentState {
    ProgressMergePolicy.CurrentState(
      currentTime: currentTime,
      isFinished: isFinished,
      serverUpdatedAt: serverUpdatedAt,
      localSequence: localSequence,
      originKey: originKey,
      hasUnacknowledgedLocalOperation: hasUnacknowledgedLocalOperation
    )
  }

  private func serverPull(
    currentTime: TimeInterval,
    isFinished: Bool = false,
    serverUpdatedAt: Date?,
    signalsExplicitResetOrUnfinished: Bool = false
  ) -> ProgressMergePolicy.IncomingObservation {
    ProgressMergePolicy.IncomingObservation(
      currentTime: currentTime,
      isFinished: isFinished,
      serverUpdatedAt: serverUpdatedAt,
      originKey: ProgressMergePolicy.serverOriginKey,
      signalsExplicitResetOrUnfinished: signalsExplicitResetOrUnfinished
    )
  }

  private func sameDeviceTick(
    currentTime: TimeInterval,
    isFinished: Bool = false,
    localSequence: Int64,
    originKey: String? = nil
  ) -> ProgressMergePolicy.IncomingObservation {
    ProgressMergePolicy.IncomingObservation(
      currentTime: currentTime,
      isFinished: isFinished,
      serverUpdatedAt: nil,
      originKey: originKey ?? deviceKey,
      localSequence: localSequence
    )
  }

  // MARK: - Unacknowledged local operation wins by localSequence

  @Test func unacknowledgedLocalOperationKeepsLocalOverNewerServerPull() {
    let policy = ProgressMergePolicy()
    let local = current(
      currentTime: 500,
      serverUpdatedAt: Date(timeIntervalSince1970: 1000),
      originKey: deviceKey,
      hasUnacknowledgedLocalOperation: true
    )
    let incoming = serverPull(currentTime: 900, serverUpdatedAt: Date(timeIntervalSince1970: 2000))

    #expect(policy.resolve(current: local, incoming: incoming) == .keepLocal)
  }

  @Test func newerSameDeviceSequenceSupersedesUnacknowledgedLocalWrite() {
    let policy = ProgressMergePolicy()
    let local = current(
      currentTime: 500,
      localSequence: 10,
      originKey: deviceKey,
      hasUnacknowledgedLocalOperation: true
    )
    let incoming = sameDeviceTick(currentTime: 550, localSequence: 11)

    #expect(policy.resolve(current: local, incoming: incoming) == .applyServer)
  }

  // MARK: - Stale same-device tick rejected

  @Test func staleSameDeviceTickIsRejected() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 500, localSequence: 10, originKey: deviceKey)
    let incoming = sameDeviceTick(currentTime: 495, localSequence: 9)

    #expect(policy.resolve(current: local, incoming: incoming) == .rejectStale)
  }

  // MARK: - A user reset moves backward legitimately

  @Test func userResetMovesBackwardLegitimately() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 3000, localSequence: 40, originKey: deviceKey)
    let resetOp = sameDeviceTick(currentTime: 0, isFinished: false, localSequence: 41)

    #expect(policy.resolve(current: local, incoming: resetOp) == .applyServer)
  }

  // MARK: - Otherwise server lastUpdate wins

  @Test func newerServerLastUpdateWins() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 100, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(currentTime: 200, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    #expect(policy.resolve(current: local, incoming: incoming) == .applyServer)
  }

  @Test func olderServerLastUpdateKeepsLocal() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 200, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))
    let incoming = serverPull(currentTime: 100, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))

    #expect(policy.resolve(current: local, incoming: incoming) == .keepLocal)
  }

  // MARK: - Zero-position guard

  @Test func zeroPositionGuardProtectsSubstantialLocalProgress() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 600, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    // Newer server timestamp, but a near-zero position with no explicit signal.
    let incoming = serverPull(currentTime: 2, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    #expect(policy.resolve(current: local, incoming: incoming, duration: 6_000) == .needsResolution)
  }

  @Test func zeroPositionGuardSkippedBelowPercentThresholdOfDuration() {
    let policy = ProgressMergePolicy()
    // > 60 s absolute, but well under 2% of a long audiobook's duration.
    let local = current(currentTime: 61, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(currentTime: 2, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    #expect(policy.resolve(current: local, incoming: incoming, duration: 144_000) == .applyServer)
  }

  @Test func zeroPositionGuardSkippedWithoutDurationStillProtectsAbsoluteFloor() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 600, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(currentTime: 2, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    #expect(policy.resolve(current: local, incoming: incoming, duration: nil) == .needsResolution)
  }

  @Test func zeroPositionGuardBypassedByExplicitResetSignal() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 600, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(
      currentTime: 0,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
      signalsExplicitResetOrUnfinished: true
    )

    #expect(policy.resolve(current: local, incoming: incoming, duration: 6_000) == .applyServer)
  }

  // Real durations are stored (`SyncEngine.mapItem`), so `applyProgress` passes a `duration:`.
  // The duration-relative fraction floor changes the outcome for the same local progress that
  // the absolute-floor-only (nil-duration) case above resolves differently.
  @Test func durationRelativeGuardResolvesDifferentlyFromTheNilDurationFallbackForTheSameLocalProgress() {
    let policy = ProgressMergePolicy()
    // 61s of local progress: just above the 60s absolute floor either way.
    let local = current(currentTime: 61, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(currentTime: 2, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    // Without a known duration the guard falls back to the absolute floor alone and fires.
    #expect(policy.resolve(current: local, incoming: incoming, duration: nil) == .needsResolution)
    // With a duration, the identical 61s is a negligible fraction of a long audiobook. The
    // fraction floor is not cleared, so the guard does not fire and the server pull applies.
    #expect(policy.resolve(current: local, incoming: incoming, duration: 144_000) == .applyServer)
  }

  @Test func zeroPositionGuardDoesNotApplyWhenLocalIsNotSubstantial() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 30, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(currentTime: 2, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    #expect(policy.resolve(current: local, incoming: incoming, duration: 6_000) == .applyServer)
  }

  // MARK: - Finished state comes from the flag, never currentTime == duration

  @Test func finishedStateComesFromFlagNotFromCurrentTimeEqualingDuration() {
    let policy = ProgressMergePolicy()
    // Equal server timestamps force the tie-break; both rows sit at the same currentTime as the
    // (irrelevant) duration, so only the explicit `isFinished` flag can distinguish them.
    let tiedTimestamp = Date(timeIntervalSince1970: 5_000)
    let local = current(
      currentTime: 1_000,
      isFinished: true,
      serverUpdatedAt: tiedTimestamp,
      originKey: ProgressMergePolicy.serverOriginKey
    )
    let incoming = serverPull(currentTime: 1_000, isFinished: false, serverUpdatedAt: tiedTimestamp)

    // Finished (local) outranks unfinished (incoming) at the same currentTime. No `duration` is
    // passed, so the policy cannot be using one.
    #expect(policy.resolve(current: local, incoming: incoming) == .keepLocal)
  }

  // MARK: - Deterministic tie-break (isFinished, currentTime, stable origin key)

  @Test func tieBreakResolvesIdenticallyRegardlessOfArgumentOrder() {
    let policy = ProgressMergePolicy()
    let tiedTimestamp = Date(timeIntervalSince1970: 42)

    let stateA = (currentTime: 100.0, isFinished: false, originKey: "aaaa-client-uuid")
    let stateB = (currentTime: 100.0, isFinished: false, originKey: "bbbb-client-uuid")

    let aAsCurrent = current(
      currentTime: stateA.currentTime,
      isFinished: stateA.isFinished,
      serverUpdatedAt: tiedTimestamp,
      originKey: stateA.originKey
    )
    let bAsIncoming = ProgressMergePolicy.IncomingObservation(
      currentTime: stateB.currentTime,
      isFinished: stateB.isFinished,
      serverUpdatedAt: tiedTimestamp,
      originKey: stateB.originKey
    )
    let bAsCurrent = current(
      currentTime: stateB.currentTime,
      isFinished: stateB.isFinished,
      serverUpdatedAt: tiedTimestamp,
      originKey: stateB.originKey
    )
    let aAsIncoming = ProgressMergePolicy.IncomingObservation(
      currentTime: stateA.currentTime,
      isFinished: stateA.isFinished,
      serverUpdatedAt: tiedTimestamp,
      originKey: stateA.originKey
    )

    let decisionABIncoming = policy.resolve(current: aAsCurrent, incoming: bAsIncoming)
    let decisionBAIncoming = policy.resolve(current: bAsCurrent, incoming: aAsIncoming)

    // "bbbb..." > "aaaa..." lexicographically, so B wins the tie-break either way it's argued:
    // as the incoming candidate (applyServer) or as the current row (keepLocal).
    #expect(decisionABIncoming == .applyServer)
    #expect(decisionBAIncoming == .keepLocal)
  }

  @Test func tieBreakIsStableAcrossASimulatedRelaunch() {
    let tiedTimestamp = Date(timeIntervalSince1970: 42)
    let local = current(
      currentTime: 100,
      serverUpdatedAt: tiedTimestamp,
      originKey: "aaaa-client-uuid"
    )
    let incoming = serverPull(currentTime: 100, serverUpdatedAt: tiedTimestamp)

    // A fresh policy instance, as after a relaunch, must reach the same outcome. The origin key
    // identity driving this decision is never regenerated (ARCHITECTURE.md §7).
    let beforeRelaunch = ProgressMergePolicy().resolve(current: local, incoming: incoming)
    let afterRelaunch = ProgressMergePolicy().resolve(current: local, incoming: incoming)

    #expect(beforeRelaunch == afterRelaunch)
  }

  // MARK: - Duplicate server progress rows for one identity

  private func serverRow(
    lastUpdate: Date?,
    currentTime: Double? = 42,
    isFinished: Bool = false,
    startedAt: Date? = nil,
    serverProgressID: String? = nil,
    hideFromContinueListening: Bool = false,
    duration: Double = 3_600,
    ebookProgress: Double? = nil,
    ebookLocation: String? = nil
  ) -> MediaProgress {
    MediaProgress(
      libraryItemID: "show", episodeID: "episode", mediaItemID: "media",
      mediaItemType: "episode", duration: duration, progress: 0.5, currentTime: currentTime,
      isFinished: isFinished, hideFromContinueListening: hideFromContinueListening,
      ebookLocation: ebookLocation, ebookProgress: ebookProgress, lastUpdate: lastUpdate,
      startedAt: startedAt, finishedAt: nil, serverProgressID: serverProgressID)
  }

  @Test func duplicateServerRowsResolveToOneDeterministicWinnerRegardlessOfOrder() {
    let policy = ProgressMergePolicy()
    let oldest = ProgressMergePolicy.DuplicateServerRow(
      serverRow(lastUpdate: Date(timeIntervalSince1970: 1_000), currentTime: 10))
    let middle = ProgressMergePolicy.DuplicateServerRow(
      serverRow(lastUpdate: Date(timeIntervalSince1970: 2_000), currentTime: 20))
    let newest = ProgressMergePolicy.DuplicateServerRow(
      serverRow(lastUpdate: Date(timeIntervalSince1970: 3_000), currentTime: 30))

    let winnerInOrder = policy.resolveDuplicateServerRows([oldest, middle, newest])
    let winnerReversed = policy.resolveDuplicateServerRows([newest, middle, oldest])
    let winnerShuffled = policy.resolveDuplicateServerRows([middle, newest, oldest])

    #expect(winnerInOrder?.row.lastUpdate == newest.row.lastUpdate)
    #expect(winnerReversed?.row.lastUpdate == newest.row.lastUpdate)
    #expect(winnerShuffled?.row.lastUpdate == newest.row.lastUpdate)
  }

  @Test func duplicateServerRowsWithEqualTimestampsResolveByRowIdentity() {
    let policy = ProgressMergePolicy()
    let tiedTimestamp = Date(timeIntervalSince1970: 5_000)
    let rowOne = ProgressMergePolicy.DuplicateServerRow(
      serverRow(lastUpdate: tiedTimestamp, serverProgressID: "row-a"))
    let rowTwo = ProgressMergePolicy.DuplicateServerRow(
      serverRow(lastUpdate: tiedTimestamp, serverProgressID: "row-b"))

    let forward = policy.resolveDuplicateServerRows([rowOne, rowTwo])
    let reverse = policy.resolveDuplicateServerRows([rowTwo, rowOne])

    #expect(forward?.row.serverProgressID == "row-b")
    #expect(reverse?.row.serverProgressID == "row-b")
  }

  /// `startedAt` feeds reset evidence, so a duplicate pair differing only in it must pick the
  /// same row in either wire order — not the first one the server sent.
  @Test func duplicateServerRowsDifferingOnlyInStartedAtPickOneWinnerInEitherOrder() {
    let policy = ProgressMergePolicy()
    let tiedTimestamp = Date(timeIntervalSince1970: 5_000)
    let earlier = ProgressMergePolicy.DuplicateServerRow(
      serverRow(
        lastUpdate: tiedTimestamp, startedAt: Date(timeIntervalSince1970: 100),
        serverProgressID: "row-a"))
    let later = ProgressMergePolicy.DuplicateServerRow(
      serverRow(
        lastUpdate: tiedTimestamp, startedAt: Date(timeIntervalSince1970: 200),
        serverProgressID: "row-b"))

    let forward = policy.resolveDuplicateServerRows([earlier, later])
    let reverse = policy.resolveDuplicateServerRows([later, earlier])

    #expect(forward == reverse)
    #expect(forward?.row.startedAt == later.row.startedAt)
  }

  @Test func resolveDuplicateServerRowsReturnsNilForEmptyInput() {
    let policy = ProgressMergePolicy()
    #expect(policy.resolveDuplicateServerRows([]) == nil)
  }

  /// The merge comparator's verdict through the entry point a pull uses. `nil` currentTime maps
  /// to zero exactly as `SyncEngine`'s pull mapping does.
  private func mergePrefers(
    _ incomingRow: MediaProgress,
    over currentRow: MediaProgress,
    policy: ProgressMergePolicy
  ) -> Bool {
    let current = ProgressMergePolicy.CurrentState(
      currentTime: currentRow.currentTime ?? 0,
      isFinished: currentRow.isFinished,
      serverUpdatedAt: currentRow.lastUpdate,
      localSequence: 0,
      originKey: ProgressMergePolicy.serverOriginKey)
    let incoming = ProgressMergePolicy.IncomingObservation(
      currentTime: incomingRow.currentTime ?? 0,
      isFinished: incomingRow.isFinished,
      serverUpdatedAt: incomingRow.lastUpdate,
      originKey: ProgressMergePolicy.serverOriginKey)
    return policy.resolve(current: current, incoming: incoming) == .applyServer
  }

  /// `DuplicateServerRow.Order`'s prefix is the comparator `resolve` uses; only the fields a merge
  /// never reads may extend it. Rows are grouped in ascending merge order: every row in a later
  /// group must beat every row in an earlier one in both orders, and rows sharing a group are a
  /// comparator tie that only the extension fields may separate. Changing either comparator
  /// without the other fails here.
  @Test func duplicateRowOrderAgreesWithTheMergeComparator() {
    let policy = ProgressMergePolicy()
    let earlier = Date(timeIntervalSince1970: 4_000)
    let tied = Date(timeIntervalSince1970: 5_000)
    let later = Date(timeIntervalSince1970: 6_000)

    let groups: [[MediaProgress]] = [
      [
        // The comparator maps an absent position to the pull path's zero, so these tie; `Order`
        // keeps the absent position below a reported zero.
        serverRow(lastUpdate: nil, currentTime: nil),
        serverRow(lastUpdate: nil, currentTime: 0),
      ],
      [serverRow(lastUpdate: nil, currentTime: 10)],
      [serverRow(lastUpdate: nil, currentTime: 30)],
      [serverRow(lastUpdate: earlier, currentTime: 30)],
      [serverRow(lastUpdate: tied, currentTime: 20)],
      [
        serverRow(lastUpdate: tied, currentTime: 40, serverProgressID: "row-a"),
        serverRow(lastUpdate: tied, currentTime: 40, serverProgressID: "row-b"),
      ],
      [
        serverRow(lastUpdate: tied, currentTime: 20, isFinished: true),
        serverRow(lastUpdate: tied, currentTime: 20, isFinished: true, ebookProgress: 0.1),
        serverRow(lastUpdate: tied, currentTime: 20, isFinished: true, ebookProgress: 0.2),
      ],
      [serverRow(lastUpdate: later, currentTime: 10)],
    ]

    func order(_ row: MediaProgress) -> ProgressMergePolicy.DuplicateServerRow.Order {
      ProgressMergePolicy.DuplicateServerRow(row).order
    }

    for lowerGroup in groups.indices {
      for higherGroup in groups.indices where higherGroup > lowerGroup {
        for lower in groups[lowerGroup] {
          for higher in groups[higherGroup] {
            let label = "group \(lowerGroup) < group \(higherGroup)"
            #expect(mergePrefers(higher, over: lower, policy: policy), "\(label): comparator")
            #expect(
              mergePrefers(lower, over: higher, policy: policy) == false,
              "\(label): comparator reverse")
            #expect(order(lower) < order(higher), "\(label): Order")
          }
        }
      }
    }

    for (groupIndex, group) in groups.enumerated() {
      for (index, first) in group.enumerated() {
        for second in group.dropFirst(index + 1) {
          let label = "group \(groupIndex) tie"
          #expect(mergePrefers(first, over: second, policy: policy) == false, "\(label): forward")
          #expect(mergePrefers(second, over: first, policy: policy) == false, "\(label): reverse")
          // A comparator tie still resolves to exactly one row through the extension fields.
          #expect(order(first) != order(second), "\(label): Order stays total")
        }
      }
    }

    let absentPosition = serverRow(lastUpdate: nil, currentTime: nil)
    let zeroPosition = serverRow(lastUpdate: nil, currentTime: 0)
    #expect(order(absentPosition) < order(zeroPosition))
  }

  /// The `/api/me` item path (`ProgressByIdentity`) and the show-refresh path
  /// (`PodcastRefreshCoordinator.progressObservations`) resolve duplicate episode rows with the
  /// same rule, so reset evidence cannot differ by which path applied the snapshot.
  @Test func bothProgressPathsChooseTheSameDuplicateRow() throws {
    let tiedTimestamp = Date(timeIntervalSince1970: 5_000)
    let rows = [
      serverRow(
        lastUpdate: tiedTimestamp, startedAt: Date(timeIntervalSince1970: 200),
        serverProgressID: "row-b"),
      serverRow(
        lastUpdate: tiedTimestamp, startedAt: Date(timeIntervalSince1970: 100),
        serverProgressID: "row-a"),
    ]

    let byIdentity = ProgressByIdentity(rows: rows)
    let byRefresh = PodcastRefreshCoordinator.progressObservations(
      rows, itemID: "show", policy: ProgressMergePolicy())

    let pulled = try #require(byIdentity.episodeByShowID["show"]?["episode"])
    let refreshed = try #require(byRefresh.observations.first)
    #expect(pulled.serverProgressID == refreshed.serverRow?.progressId)
    #expect(pulled.startedAt == refreshed.serverRow?.startedAt)
  }

  // MARK: - Reset evidence (ADR 0011)

  /// Evidence is loss of the server row this device last observed. An absent row has no server
  /// timestamp at all, so the evidence must apply without consulting the clock.
  @Test func resetEvidenceAppliesAZeroWithNoServerTimestampOverSubstantialLocalProgress() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 1_200, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(
      currentTime: 0, serverUpdatedAt: nil, signalsExplicitResetOrUnfinished: true)

    #expect(policy.resolve(current: local, incoming: incoming, duration: 6_000) == .applyServer)
    #expect(
      policy.resolveComposite(current: local, incoming: incoming, duration: 6_000)
        == .init(audioPosition: .applyServer, ebookPosition: .keepLocal, sharedFinish: .applyServer))
  }

  @Test func resetEvidenceAppliesEvenWhenTheServerTimestampIsOlder() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 1_200, serverUpdatedAt: Date(timeIntervalSince1970: 5_000))
    let incoming = serverPull(
      currentTime: 0, serverUpdatedAt: Date(timeIntervalSince1970: 1_000),
      signalsExplicitResetOrUnfinished: true)

    #expect(policy.resolve(current: local, incoming: incoming, duration: 6_000) == .applyServer)
  }

  /// A live session and an active offline session reach the policy through the same pending bit
  /// as an unacknowledged outbox write, so one case covers all three at this level.
  @Test func resetEvidenceNeverOutranksUnacknowledgedLocalWork() {
    let policy = ProgressMergePolicy()
    let local = current(
      currentTime: 1_200, serverUpdatedAt: Date(timeIntervalSince1970: 1_000),
      hasUnacknowledgedLocalOperation: true)
    let incoming = serverPull(
      currentTime: 0, serverUpdatedAt: nil, signalsExplicitResetOrUnfinished: true)

    #expect(policy.resolve(current: local, incoming: incoming, duration: 6_000) == .keepLocal)
    #expect(policy.resolveComposite(current: local, incoming: incoming).sharedFinish == .keepLocal)
  }

  @Test func resetEvidenceNeverOverridesTheSameDeviceSequence() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 1_200, localSequence: 10)
    var stale = sameDeviceTick(currentTime: 0, localSequence: 9)
    stale.signalsExplicitResetOrUnfinished = true

    #expect(policy.resolve(current: local, incoming: stale) == .rejectStale)
  }

  @Test func sharedFinishFollowsResetEvidence() {
    let policy = ProgressMergePolicy()
    let local = current(
      currentTime: 1_200, isFinished: true, serverUpdatedAt: Date(timeIntervalSince1970: 5_000))
    let incoming = serverPull(
      currentTime: 0, serverUpdatedAt: nil, signalsExplicitResetOrUnfinished: true)

    #expect(policy.resolveComposite(current: local, incoming: incoming).sharedFinish == .applyServer)
  }

  // MARK: - Unfinished transition

  /// The server forces `currentTime` to 0 when a finished row is marked not finished, so a
  /// deliberate "mark as not finished" elsewhere arrives as a near-zero, newer, unfinished row.
  @Test func acknowledgedFinishMarkedUnfinishedElsewhereAppliesWithoutAConflict() {
    let policy = ProgressMergePolicy()
    let local = current(
      currentTime: 5_990, isFinished: true, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(currentTime: 0, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    #expect(
      policy.resolveComposite(current: local, incoming: incoming, duration: 6_000)
        == .init(audioPosition: .applyServer, ebookPosition: .keepLocal, sharedFinish: .applyServer))
  }

  @Test func unfinishedTransitionIsNotEvidenceWhenTheLocalFinishIsUnacknowledged() {
    let policy = ProgressMergePolicy()
    let local = current(
      currentTime: 5_990, isFinished: true, serverUpdatedAt: Date(timeIntervalSince1970: 1_000),
      hasUnacknowledgedLocalOperation: true)
    let incoming = serverPull(currentTime: 0, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    #expect(
      policy.resolveComposite(current: local, incoming: incoming, duration: 6_000)
        == .init(audioPosition: .keepLocal, ebookPosition: .keepLocal, sharedFinish: .keepLocal))
  }

  @Test func unfinishedTransitionNeedsANewerServerTimestamp() {
    let policy = ProgressMergePolicy()
    let local = current(
      currentTime: 5_990, isFinished: true, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))
    let older = serverPull(currentTime: 0, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let undated = serverPull(currentTime: 0, serverUpdatedAt: nil)

    #expect(policy.resolve(current: local, incoming: older, duration: 6_000) == .needsResolution)
    #expect(policy.resolve(current: local, incoming: undated, duration: 6_000) == .needsResolution)
  }

  @Test func anUnfinishedLocalRowGetsNoTransitionEvidence() {
    let policy = ProgressMergePolicy()
    let local = current(currentTime: 1_200, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(currentTime: 0, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    #expect(policy.resolve(current: local, incoming: incoming, duration: 6_000) == .needsResolution)
  }
}
