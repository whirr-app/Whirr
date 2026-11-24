import SyncEngine
import Testing

@testable import AppModel

@Suite struct NativeEpisodeServerSaveAttemptFenceTests {
  private typealias Fence = NativeEpisodeServerSaveAttemptFence

  // MARK: - Step 1: a mutation in flight

  @Test func aMutationInFlightRejectsEverySnapshot() {
    for clearingRemoval in [true, false] {
      var fence = Fence()
      fence.beginMutation(clearingRemoval: clearingRemoval)
      #expect(fence.isMutationInFlight)
      #expect(fence.accept(snapshot(.saved, 1)) == false)
      #expect(fence.accept(snapshot(.removed, 1)) == false)
      #expect(fence.accept(snapshot(.none, nil)) == false)
      #expect(fence.latestAttemptID == nil)

      fence.endMutation()
      #expect(fence.isMutationInFlight == false)
      #expect(fence.accept(snapshot(.saved, 1)) == true)
    }
  }

  // MARK: - Step 2: older than the latest

  @Test func anOlderAttemptThanTheLatestIsRejected() {
    var fence = Fence()
    #expect(fence.accept(snapshot(.saved, 5)) == true)
    #expect(fence.accept(snapshot(.saved, 4)) == false)
    #expect(fence.accept(snapshot(.requested, 5)) == true)
    #expect(fence.accept(snapshot(.saved, 6)) == true)
    #expect(fence.latestAttemptID == 6)
  }

  @Test func aSnapshotWithNoAttemptIsNotOlderThanTheLatest() {
    var fence = Fence()
    #expect(fence.accept(snapshot(.saved, 5)) == true)
    #expect(fence.accept(snapshot(.none, nil)) == true)
    #expect(fence.latestAttemptID == 5)
  }

  /// The projection orders by `updatedAt`, so a later-updated older attempt can become current
  /// there. At the fence it is still older.
  @Test func aLowerAttemptArrivingAfterAHigherOneIsRejectedWhateverItsStatus() {
    let statuses: [NativeEpisodeServerSaveStatus] = [
      .none, .preparing, .requested, .saved, .removing, .removed,
      .uncertain(.transport, phase: .save), .uncertain(.transport, phase: .remove),
      .failed(.transport, phase: .save), .failed(.transport, phase: .remove),
    ]
    for status in statuses {
      var fence = Fence()
      #expect(fence.accept(snapshot(.requested, 7)) == true)
      #expect(fence.accept(snapshot(status, 6)) == false, "\(status)")
    }
  }

  // MARK: - Step 3: no removal fence

  @Test func withNoRemovalFenceEverySnapshotIsAccepted() {
    var fence = Fence()
    #expect(fence.accept(snapshot(.none, nil)) == true)
    #expect(fence.accept(snapshot(.saved, nil)) == true)
    #expect(fence.accept(snapshot(.preparing, 1)) == true)
    #expect(fence.removedAttemptID == nil)
  }

  // MARK: - Step 4: a removal fence

  @Test func anAcceptedRemovalRecordsTheFence() {
    var fence = Fence()
    #expect(fence.accept(snapshot(.removed, 5)) == true)
    #expect(fence.removedAttemptID == 5)
    #expect(fence.latestAttemptID == 5)
  }

  @Test func anAcceptedRemovalWithNoAttemptRecordsNoFence() {
    var fence = Fence()
    #expect(fence.accept(snapshot(.removed, nil)) == true)
    #expect(fence.removedAttemptID == nil)
  }

  @Test func behindARemovalFenceARemovedSnapshotIsAcceptedUnlessOlder() {
    var fence = removed(at: 5)
    #expect(fence.accept(snapshot(.removed, nil)) == true)
    #expect(fence.accept(snapshot(.removed, 5)) == true)
    #expect(fence.accept(snapshot(.removed, 4)) == false)
    #expect(fence.removedAttemptID == 5)

    #expect(fence.accept(snapshot(.removed, 6)) == true)
    #expect(fence.removedAttemptID == 6)
  }

  @Test func behindARemovalFenceAnythingElseNeedsAStrictlyNewerAttempt() {
    var fence = removed(at: 5)
    #expect(fence.accept(snapshot(.saved, nil)) == false)
    #expect(fence.accept(snapshot(.none, nil)) == false)
    #expect(fence.accept(snapshot(.saved, 5)) == false)
    #expect(fence.removedAttemptID == 5)
  }

  @Test func aStrictlyNewerAttemptClearsTheRemovalFence() {
    var fence = removed(at: 5)
    #expect(fence.accept(snapshot(.requested, 6)) == true)
    #expect(fence.removedAttemptID == nil)
    #expect(fence.latestAttemptID == 6)
    #expect(fence.accept(snapshot(.none, nil)) == true)
  }

  // MARK: - beginMutation

  @Test func aSingleSaveClearsTheRemovalFenceAndARemoveKeepsIt() {
    var clearing = removed(at: 5)
    clearing.beginMutation(clearingRemoval: true)
    #expect(clearing.removedAttemptID == nil)

    var keeping = removed(at: 5)
    keeping.beginMutation(clearingRemoval: false)
    #expect(keeping.removedAttemptID == 5)
  }

  /// The batch path keeps the removal fence where a single save clears it. Its outcome names a
  /// strictly newer attempt: stale snapshots of the removed one are older than that, and the first
  /// snapshot of the new one clears the fence, so every decision is the same either way.
  @Test func keepingTheRemovalFenceThroughASaveDecidesTheSameAsClearingIt() {
    let followUps: [NativeEpisodeServerSaveStatusSnapshot] = [
      snapshot(.removed, 5), snapshot(.saved, 5), snapshot(.requested, 6), snapshot(.none, nil),
      snapshot(.removed, 5), snapshot(.saved, 6), snapshot(.removed, 6),
    ]
    for outcome: NativeEpisodeServerSaveOutcome in [
      .accepted(attemptID: 6, serverItemID: "show"),
      .needsChoice(attemptID: 6, prompt: .existing(candidates: [])),
      .alreadyPresent(attemptID: 6, serverItemID: "show"),
    ] {
      var clearing = removed(at: 5)
      var keeping = removed(at: 5)
      clearing.beginMutation(clearingRemoval: true)
      keeping.beginMutation(clearingRemoval: false)
      clearing.endMutation()
      keeping.endMutation()
      clearing.record(outcome)
      keeping.record(outcome)
      for followUp in followUps {
        let clearingAccepts = clearing.accept(followUp)
        let keepingAccepts = keeping.accept(followUp)
        #expect(clearingAccepts == keepingAccepts, "\(outcome) \(followUp)")
      }
      #expect(clearing == keeping)
    }
  }

  /// The one decision the two differ on: a snapshot with no attempt, before the new attempt's
  /// first snapshot. The projection reports no attempt only for an episode with no attempt row,
  /// and the save outcome means the row exists.
  @Test func keepingTheRemovalFenceRejectsANoAttemptSnapshotUntilTheNewAttemptArrives() {
    var clearing = removed(at: 5)
    var keeping = removed(at: 5)
    clearing.beginMutation(clearingRemoval: true)
    keeping.beginMutation(clearingRemoval: false)
    clearing.endMutation()
    keeping.endMutation()
    clearing.record(.accepted(attemptID: 6, serverItemID: "show"))
    keeping.record(.accepted(attemptID: 6, serverItemID: "show"))
    #expect(clearing.accept(snapshot(.none, nil)) == true)
    #expect(keeping.accept(snapshot(.none, nil)) == false)
  }

  // MARK: - record(_:)

  @Test func everyOutcomeWithAnAttemptAdvancesTheLatest() {
    let outcomes: [NativeEpisodeServerSaveOutcome] = [
      .needsChoice(attemptID: 3, prompt: .existing(candidates: [])),
      .alreadyPresent(attemptID: 3, serverItemID: "show"),
      .accepted(attemptID: 3, serverItemID: "show"),
      .uncertain(attemptID: 3, state: .uncertain, category: .transport),
      .failed(attemptID: 3, state: .failed, category: .transport),
      .inProgress(attemptID: 3, state: .accepted, serverItemID: nil),
    ]
    for outcome in outcomes {
      var fence = Fence()
      fence.record(outcome)
      #expect(fence.latestAttemptID == 3, "\(outcome)")
      #expect(fence.removedAttemptID == nil, "\(outcome)")
    }
  }

  @Test func onlyARemovedInProgressOutcomeRecordsTheRemovalFence() {
    var fence = Fence()
    fence.record(.inProgress(attemptID: 4, state: .removed, serverItemID: nil))
    #expect(fence.removedAttemptID == 4)

    var deleting = Fence()
    deleting.record(.inProgress(attemptID: 4, state: .deleting, serverItemID: nil))
    #expect(deleting.removedAttemptID == nil)
  }

  // MARK: - A monotonic latest

  @Test func aFailureWithNoAttemptDoesNotLowerTheLatest() {
    var fence = Fence()
    #expect(fence.accept(snapshot(.saved, 5)) == true)
    fence.record(.failed(attemptID: nil, state: .failed, category: .permissionChanged))
    #expect(fence.latestAttemptID == 5)
    #expect(fence.accept(snapshot(.saved, 4)) == false)
  }

  @Test func anOutcomeNamingAnOlderAttemptDoesNotLowerTheLatest() {
    var fence = Fence()
    #expect(fence.accept(snapshot(.saved, 5)) == true)
    fence.record(.uncertain(attemptID: 2, state: .deleteUncertain, category: .transport))
    #expect(fence.latestAttemptID == 5)
    #expect(fence.accept(snapshot(.saved, 4)) == false)
  }

  @Test func aFreshFenceIsTheReset() {
    var fence = removed(at: 5)
    fence.beginMutation(clearingRemoval: false)
    fence = Fence()
    #expect(fence == Fence())
    #expect(fence.accept(snapshot(.saved, 1)) == true)
  }

  // MARK: - Helpers

  private func removed(at attemptID: Int64) -> Fence {
    var fence = Fence()
    _ = fence.accept(snapshot(.removed, attemptID))
    return fence
  }

  private func snapshot(
    _ status: NativeEpisodeServerSaveStatus, _ attemptID: Int64?
  ) -> NativeEpisodeServerSaveStatusSnapshot {
    NativeEpisodeServerSaveStatusSnapshot(status: status, attemptID: attemptID)
  }
}
