import Foundation
import GRDB
import Testing

@testable import Persistence

/// The phone's desired set for the active Watch: requests, revisions, publisher transitions and
/// inventory reconciliation.
@Suite struct RSSWatchCopyStoreTests {

  // MARK: - Requests

  @Test func requestingAnEpisodePutsItInTheOffer() async throws {
    let fixture = try await Fixture()

    let copy = try await fixture.store.request(
      episodeId: fixture.episodeID(0), now: Fixture.date(10))

    #expect(copy.state == .wanted)
    #expect(copy.revision == 1)
    #expect(copy.requestedAt == Fixture.date(10))
    #expect(try await fixture.store.setState().generation == 1)
  }

  /// The Watch fetches the enclosure itself (ADR 0020 Decision 1), so a phone download is neither
  /// required nor consulted.
  @Test func requestingAnEpisodeWithNoPhoneDownloadIsWanted() async throws {
    let fixture = try await Fixture()

    let copy = try await fixture.store.request(
      episodeId: fixture.episodeID(1), now: Fixture.date(10))

    #expect(copy.state == .wanted)
    #expect(try await fixture.store.desiredEpisodes().map(\.episodeId) == [fixture.episodeID(1)])
  }

  @Test func anActiveRequestKeepsItsRevisionAndDoesNotDoubleCountTheGeneration() async throws {
    let fixture = try await Fixture()
    try fixture.completeDownload(episode: fixture.episodes[0])
    let episodeId = fixture.episodeID(0)

    let first = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(10))
    let second = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(20))

    #expect(first.revision == 1)
    #expect(second.revision == 1)
    #expect(second.requestedAt == Fixture.date(10), "an active request is not re-ordered")
    #expect(try await fixture.store.setState().generation == 1)
  }

  @Test(arguments: [
    RSSWatchCopyState.removed, RSSWatchCopyState.declined, RSSWatchCopyState.failed,
    RSSWatchCopyState.delivered,
  ])
  func reRequestingAfterATerminalStateBumpsTheRevision(state: RSSWatchCopyState) async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    try await fixture.moveToTerminal(episodeId: episodeId, state: state)
    let generationBefore = try await fixture.store.setState().generation

    let copy = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(100))

    #expect(copy.state == .wanted)
    #expect(copy.revision == 2)
    #expect(copy.removedBy == nil)
    #expect(copy.declineReason == nil)
    #expect(copy.failedAt == nil)
    #expect(try await fixture.store.setState().generation == generationBefore + 1)
  }

  @Test func requestingAnUnknownEpisodeThrows() async throws {
    let fixture = try await Fixture()

    await #expect(throws: RSSWatchCopyStoreError.episodeNotFound) {
      try await fixture.store.request(episodeId: 9_999, now: Fixture.date(10))
    }
  }

  @Test func aNewRowStartsAtRevisionOne() async throws {
    let fixture = try await Fixture()
    try fixture.completeDownload(episode: fixture.episodes[2])

    let copy = try await fixture.store.request(
      episodeId: fixture.episodeID(2), now: Fixture.date(10))

    #expect(copy.revision == 1)
    #expect(copy.sourceBytes == nil)
  }

  // MARK: - Removal

  @Test func removingFromThePhoneWritesAPhoneTombstoneAndBumpsTheGeneration() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    _ = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(10))
    let generation = try await fixture.store.setState().generation

    let copy = try #require(
      try await fixture.store.removeFromWatch(episodeId: episodeId, now: Fixture.date(20)))

    #expect(copy.state == .removed)
    #expect(copy.removedBy == .phone)
    #expect(try await fixture.store.setState().generation == generation + 1)
    #expect(try await fixture.store.desiredEpisodes().isEmpty)
  }

  @Test func aRepeatedPhoneRemovalDoesNotBumpTheGenerationAgain() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    _ = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(10))
    _ = try await fixture.store.removeFromWatch(episodeId: episodeId, now: Fixture.date(20))
    let generation = try await fixture.store.setState().generation

    _ = try await fixture.store.removeFromWatch(episodeId: episodeId, now: Fixture.date(30))

    #expect(try await fixture.store.setState().generation == generation)
  }

  @Test func removingAnEpisodeWithNoCopyIsANoOp() async throws {
    let fixture = try await Fixture()

    #expect(
      try await fixture.store.removeFromWatch(
        episodeId: fixture.episodeID(0), now: Fixture.date(10)) == nil)
  }

  // MARK: - Publisher transitions

  @Test func aStaleRevisionCannotMoveANewerRequest() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    _ = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(10))
    _ = try await fixture.store.transition(
      episodeId: episodeId, revision: 1, to: .sending, now: Fixture.date(20))
    _ = try await fixture.store.transition(
      episodeId: episodeId, revision: 1, to: .failed, now: Fixture.date(30))
    _ = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(40))
    #expect(try await fixture.store.copy(episodeId: episodeId)?.revision == 2)

    let applied = try await fixture.store.transition(
      episodeId: episodeId, revision: 1, to: .sending, now: Fixture.date(50))

    #expect(applied == false)
    let copy = try #require(try await fixture.store.copy(episodeId: episodeId))
    #expect(copy.state == .wanted)
    #expect(copy.revision == 2)
  }

  @Test func aSendingCopyCannotGoBackToWanted() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    _ = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(10))
    _ = try await fixture.store.transition(
      episodeId: episodeId, revision: 1, to: .sending, now: Fixture.date(20))
    let generation = try await fixture.store.setState().generation

    #expect(
      try await fixture.store.transition(
        episodeId: episodeId, revision: 1, to: .wanted, now: Fixture.date(30)) == false)

    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .sending)
    #expect(try await fixture.store.setState().generation == generation)
  }

  /// Delivery truth carries the admitted copy's own byte count, so a delivered row records what
  /// the Watch holds even when the phone never downloaded the episode.
  @Test func aReadyEntryStoresTheAdmittedByteCountOnTheRow() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try await fixture.sendSomewhere(episodeId: episodeId)

    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .ready, committedBytes: 4_321)
        ]), now: Fixture.date(40))

    let copy = try #require(try await fixture.store.copy(episodeId: episodeId))
    #expect(copy.state == .delivered)
    #expect(copy.sourceBytes == 4_321)
  }

  /// A Watch can only acknowledge a generation the phone issued. A higher value means the phone's
  /// database was reset while the Watch kept its copies, so the phone steps past it and the
  /// inventory's omissions prove nothing.
  @Test func anAcknowledgementBeyondThePhoneGenerationStepsPastIt() async throws {
    let fixture = try await Fixture()
    for episode in fixture.episodes {
      try fixture.completeDownload(episode: episode)
    }
    for index in 0..<3 {
      _ = try await fixture.store.request(
        episodeId: fixture.episodeID(index), now: Fixture.date(TimeInterval(index)))
    }
    #expect(try await fixture.store.setState().generation == 3)
    let deliveredID = fixture.episodeID(0)
    _ = try await fixture.store.transition(
      episodeId: deliveredID, revision: 1, to: .sending, now: Fixture.date(10))
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 3,
        entries: [
          .init(episodeId: deliveredID, revision: 1, state: .ready, committedBytes: 100)
        ]), now: Fixture.date(20))
    #expect(try await fixture.store.copy(episodeId: deliveredID)?.state == .delivered)

    _ = try await fixture.store.applyInventory(
      fixture.inventory(sequence: 2, acknowledged: 50, entries: []), now: Fixture.date(30))

    let set = try await fixture.store.setState()
    #expect(set.acknowledgedGeneration == 50)
    #expect(set.generation == 51)
    #expect(
      try await fixture.store.copy(episodeId: deliveredID)?.state == .delivered,
      "the omission rule cannot fire against a generation the inventory predates")
  }

  @Test func aMoveTheStateMachineDoesNotAllowIsIgnored() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    _ = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(10))

    #expect(
      try await fixture.store.transition(
        episodeId: episodeId, revision: 1, to: .delivered, now: Fixture.date(20)) == false)
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .wanted)
  }

  // MARK: - Inventory

  @Test func anInventoryReadyEntryIsTheOnlyWayToDelivered() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    try await fixture.sendSomewhere(episodeId: episodeId)

    let outcome = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .ready)
        ]), now: Fixture.date(40))

    #expect(outcome.changedEpisodeIds == [episodeId])
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .delivered)
    #expect(try await fixture.store.setState().acceptsCopies == true)
    #expect(try await fixture.store.setState().lastInventoryAt == Fixture.date(35))
  }

  @Test func aReceivingEntryKeepsSendingAndNeverRegressesDelivered() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try await fixture.sendSomewhere(episodeId: episodeId)

    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .receiving)
        ]), now: Fixture.date(40))
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .sending)

    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 2, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .ready)
        ]), now: Fixture.date(41))
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .delivered)

    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 3, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .receiving)
        ]), now: Fixture.date(42))
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .delivered)
  }

  @Test func aStorageDeclineStaysInTheOfferAndMovesOnWhenTheWatchTakesItBack() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    try await fixture.sendSomewhere(episodeId: episodeId)
    let generation = try await fixture.store.setState().generation

    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(
            episodeId: episodeId, revision: 1, state: .declined,
            declineReason: .storageFull, committedBytes: 0)
        ]), now: Fixture.date(40))

    let copy = try #require(try await fixture.store.copy(episodeId: episodeId))
    #expect(copy.state == .declined)
    #expect(copy.declineReason == .storageFull)
    #expect(try await fixture.store.setState().generation == generation)
    #expect(try await fixture.store.desiredEpisodes().map(\.episodeId) == [episodeId])

    // The Watch found room and took it back at the same revision.
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 2, acknowledged: 1,
        entries: [.init(episodeId: episodeId, revision: 1, state: .receiving)]),
      now: Fixture.date(41))
    let sending = try #require(try await fixture.store.copy(episodeId: episodeId))
    #expect(sending.state == .sending)
    #expect(sending.declineReason == nil)

    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 3, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .ready, committedBytes: 57_790_052)
        ]), now: Fixture.date(42))
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .delivered)
  }

  @Test func anInvalidDeclineLeavesTheDesiredSetAndBumpsTheGeneration() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try await fixture.sendSomewhere(episodeId: episodeId)
    let generation = try await fixture.store.setState().generation

    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .declined, declineReason: .invalid)
        ]), now: Fixture.date(40))

    #expect(try await fixture.store.copy(episodeId: episodeId)?.declineReason == .invalid)
    #expect(try await fixture.store.setState().generation == generation + 1)
    #expect(try await fixture.store.desiredEpisodes().isEmpty)
    // An invalid decline is final at this revision: a later report cannot revive it.
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 2, acknowledged: 1,
        entries: [.init(episodeId: episodeId, revision: 1, state: .receiving)]),
      now: Fixture.date(41))
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .declined)
  }

  @Test func aWatchRemovalIsATombstoneThatLeavesTheDesiredSet() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    try await fixture.sendSomewhere(episodeId: episodeId)

    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .removed)
        ]), now: Fixture.date(40))

    let copy = try #require(try await fixture.store.copy(episodeId: episodeId))
    #expect(copy.state == .removed)
    #expect(copy.removedBy == .watch)
    #expect(try await fixture.store.desiredEpisodes().isEmpty)
  }

  @Test func anEntryWithAnOlderRevisionIsIgnored() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    _ = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(10))
    _ = try await fixture.store.transition(
      episodeId: episodeId, revision: 1, to: .sending, now: Fixture.date(20))
    _ = try await fixture.store.transition(
      episodeId: episodeId, revision: 1, to: .failed, now: Fixture.date(30))
    _ = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(40))

    let outcome = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .ready)
        ]), now: Fixture.date(50))

    #expect(outcome.changedEpisodeIds.isEmpty)
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .wanted)
  }

  @Test func aLateInventorySequenceForTheSameInstallIsIgnored() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    try await fixture.sendSomewhere(episodeId: episodeId)
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 5, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .ready)
        ]), now: Fixture.date(40))
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .delivered)

    let duplicate = try await fixture.store.applyInventory(
      fixture.inventory(sequence: 5, acknowledged: 1, entries: []), now: Fixture.date(50))

    #expect(duplicate.changedEpisodeIds.isEmpty)
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .delivered)
  }

  /// A sequence below the stored one is a late report for the same install, so it must return
  /// before any move and before the replacement delete: reconciling it again would undo the
  /// membership the set already has (and a wipe would leave the Watch owing every copy).
  @Test func aStaleInventorySequenceLeavesEveryRowAsItWas() async throws {
    let fixture = try await Fixture()
    let deliveredID = fixture.episodeID(0)
    let sendingID = fixture.episodeID(1)
    _ = try await fixture.store.request(episodeId: deliveredID, now: Fixture.date(1))
    _ = try await fixture.store.request(episodeId: sendingID, now: Fixture.date(2))
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 5, acknowledged: 0,
        entries: [
          .init(episodeId: deliveredID, revision: 1, state: .ready),
          .init(episodeId: sendingID, revision: 1, state: .receiving),
        ]), now: Fixture.date(10))
    #expect(try await fixture.store.setState().generation == 2)

    // `acknowledged: 5` would step past the generation and prove both omissions if it ran.
    let outcome = try await fixture.store.applyInventory(
      fixture.inventory(sequence: 3, acknowledged: 5, entries: []), now: Fixture.date(20))

    #expect(outcome.changedEpisodeIds.isEmpty)
    #expect(outcome.installReplaced == false)
    #expect(try await fixture.store.copies().count == 2, "a late sequence must not wipe the set")
    #expect(try await fixture.store.copy(episodeId: deliveredID)?.state == .delivered)
    #expect(try await fixture.store.copy(episodeId: sendingID)?.state == .sending)
    let set = try await fixture.store.setState()
    #expect(set.inventorySequence == 5)
    #expect(set.acknowledgedGeneration == 0)
    #expect(set.generation == 2)
  }

  @Test func aDifferentInstallReplacesTheWholeDesiredSet() async throws {
    let fixture = try await Fixture()
    let firstEpisodeId = fixture.episodeID(0)
    let secondEpisodeId = fixture.episodeID(1)
    try fixture.completeDownload(episode: fixture.episodes[0])
    try fixture.completeDownload(episode: fixture.episodes[1])
    _ = try await fixture.store.request(episodeId: firstEpisodeId, now: Fixture.date(10))
    _ = try await fixture.store.request(episodeId: secondEpisodeId, now: Fixture.date(11))
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        installID: "watch-a", sequence: 1, acknowledged: 1,
        entries: [.init(episodeId: firstEpisodeId, revision: 1, state: .receiving)]),
      now: Fixture.date(20))
    let generation = try await fixture.store.setState().generation

    let outcome = try await fixture.store.applyInventory(
      fixture.inventory(installID: "watch-b", sequence: 1, acknowledged: 0, entries: []),
      now: Fixture.date(30))

    #expect(outcome.installReplaced)
    #expect(outcome.changedEpisodeIds == [firstEpisodeId, secondEpisodeId])
    #expect(try await fixture.store.copies().isEmpty)
    let set = try await fixture.store.setState()
    #expect(set.watchInstallID == "watch-b")
    #expect(set.generation == generation + 1)
    #expect(set.inventorySequence == 1)
  }

  @Test func aMissingCopyTheWatchAcknowledgesComesBackAsWanted() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    try await fixture.sendSomewhere(episodeId: episodeId)
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .ready)
        ]), now: Fixture.date(40))

    let outcome = try await fixture.store.applyInventory(
      fixture.inventory(sequence: 2, acknowledged: 1, entries: []), now: Fixture.date(50))

    #expect(outcome.changedEpisodeIds == [episodeId])
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .wanted)
  }

  /// A Watch that reports a copy it no longer holds because it is signed out keeps it in the
  /// desired set, so it is re-sent after sign-in rather than forgotten.
  @Test func aMissingCopyOnASignedOutWatchWaitsForTheWatch() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    try await fixture.sendSomewhere(episodeId: episodeId)
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .ready)
        ]), now: Fixture.date(40))

    _ = try await fixture.store.applyInventory(
      // A signed-out Watch reports no entries and acknowledges no generation.
      fixture.inventory(sequence: 2, acknowledged: 0, acceptsCopies: false, entries: []),
      now: Fixture.date(50))

    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .waitingForWatch)
    #expect(try await fixture.store.desiredEpisodes().count == 1)
    #expect(try await fixture.store.setState().acknowledgedGeneration == 0)

    // Signed in again: the Watch takes copies but has not applied the set yet.
    _ = try await fixture.store.applyInventory(
      fixture.inventory(sequence: 3, acknowledged: 0, entries: []), now: Fixture.date(60))
    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .wanted)
  }

  @Test func theAcknowledgedGenerationIsStored() async throws {
    let fixture = try await Fixture()
    try fixture.completeDownload(episode: fixture.episodes[0])
    _ = try await fixture.store.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    _ = try await fixture.store.applyInventory(
      fixture.inventory(sequence: 1, acknowledged: 0, entries: []), now: Fixture.date(20))
    #expect(try await fixture.store.setState().acknowledgedGeneration == 0)
    #expect(try await fixture.store.setState().generation == 1)

    _ = try await fixture.store.applyInventory(
      fixture.inventory(sequence: 2, acknowledged: 1, entries: []), now: Fixture.date(30))
    #expect(try await fixture.store.setState().acknowledgedGeneration == 1)
  }

  @Test func anInventoryThatHasNotAcknowledgedTheSetCannotProveACopyIsGone() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    try await fixture.sendSomewhere(episodeId: episodeId)
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .ready)
        ]), now: Fixture.date(40))

    _ = try await fixture.store.applyInventory(
      fixture.inventory(sequence: 2, acknowledged: 0, entries: []), now: Fixture.date(50))

    #expect(try await fixture.store.copy(episodeId: episodeId)?.state == .delivered)
  }

  /// The omission rule is judged against the generation after the entry moves have bumped it. An
  /// invalid decline leaves the offer and moves the generation past the acknowledged one, so this
  /// inventory cannot prove the omitted delivered row is gone. A generation captured before the
  /// entries ran would re-send that row.
  @Test func anOmissionIsJudgedAgainstTheGenerationAfterTheMoves() async throws {
    let fixture = try await Fixture()
    let deliveredID = fixture.episodeID(0)
    let declinedID = fixture.episodeID(1)
    _ = try await fixture.store.request(episodeId: deliveredID, now: Fixture.date(1))
    _ = try await fixture.store.request(episodeId: declinedID, now: Fixture.date(2))
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 0,
        entries: [
          .init(episodeId: deliveredID, revision: 1, state: .ready),
          .init(episodeId: declinedID, revision: 1, state: .receiving),
        ]), now: Fixture.date(10))
    #expect(try await fixture.store.copy(episodeId: deliveredID)?.state == .delivered)
    #expect(try await fixture.store.setState().generation == 2)

    let outcome = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 2, acknowledged: 2,
        entries: [
          .init(episodeId: declinedID, revision: 1, state: .declined, declineReason: .invalid)
        ]), now: Fixture.date(20))

    #expect(outcome.changedEpisodeIds == [declinedID])
    #expect(
      try await fixture.store.copy(episodeId: deliveredID)?.state == .delivered,
      "the decline moved the generation past the acknowledgement")
    let set = try await fixture.store.setState()
    #expect(set.generation == 3)
    #expect(set.acknowledgedGeneration == 2)
  }

  // MARK: - Reads

  @Test func desiredEpisodesAreNewestRequestFirstAndLeaveTerminalRowsOut() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.store.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    _ = try await fixture.store.request(episodeId: fixture.episodeID(1), now: Fixture.date(20))
    _ = try await fixture.store.request(episodeId: fixture.episodeID(2), now: Fixture.date(30))
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(episodeId: fixture.episodeID(1), revision: 1, state: .declined)
        ]), now: Fixture.date(40))
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 2, acknowledged: 2,
        entries: [
          .init(episodeId: fixture.episodeID(2), revision: 1, state: .ready)
        ]), now: Fixture.date(50))

    #expect(
      try await fixture.store.desiredEpisodes().map(\.episodeId)
        == [fixture.episodeID(2), fixture.episodeID(0)],
      "a declined row leaves the offer; a delivered row stays a member")
  }

  /// The Watch ignores an offer at or below the generation it last applied, so the generation the
  /// next (empty) offer carries must be above it.
  @Test func clearForAccountChangeEmptiesRowsAndMovesTheGenerationOn() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    _ = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(10))
    _ = try await fixture.store.applyInventory(
      fixture.inventory(sequence: 3, acknowledged: 1, entries: []), now: Fixture.date(20))
    let before = try await fixture.store.setState()

    try await fixture.store.clearForAccountChange()

    #expect(try await fixture.store.copies().isEmpty)
    let after = try await fixture.store.setState()
    #expect(after.generation == before.generation + 1)
    #expect(after.generation > after.acknowledgedGeneration)
    #expect(after.watchInstallID == before.watchInstallID)
    #expect(after.inventorySequence == before.inventorySequence)

    try await fixture.store.clearForAccountChange()
    #expect(try await fixture.store.setState().generation == after.generation, "nothing to drop")
  }

  // MARK: - Unfollow

  @Test func unfollowingACascadeDeletesTheCopiesAndBumpsTheGeneration() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    _ = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(10))
    let generation = try await fixture.store.setState().generation

    try await RSSFeedStore(database: fixture.database).unsubscribe(feedId: fixture.feedID)

    #expect(try await fixture.store.copies().isEmpty, "the episode FK cascades the copy")
    #expect(try await fixture.store.setState().generation == generation + 1)
  }

  // MARK: - Observation

  @Test func observationEmitsTheInitialValueThenRequestsAndRemovals() async throws {
    let fixture = try await Fixture()
    var iterator = fixture.store.observe().makeAsyncIterator()

    let initial = try #require(await iterator.next())
    #expect(initial.copies.isEmpty)
    #expect(initial.set.generation == 0)

    _ = try await fixture.store.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let afterRequest = try #require(await iterator.next())
    #expect(afterRequest.copies.map(\.episodeId) == [fixture.episodeID(0)])
    #expect(afterRequest.copies.first?.state == .wanted)
    #expect(afterRequest.set.generation == 1)

    _ = try await fixture.store.removeFromWatch(
      episodeId: fixture.episodeID(0), now: Fixture.date(20))
    let afterRemoval = try #require(await iterator.next())
    #expect(afterRemoval.copies.first?.state == .removed)
    #expect(afterRemoval.set.generation == 2)
  }

  // MARK: - Schema and cloud classification

  @Test func v104CreatesBothTablesWithTheirConstraints() async throws {
    let database = try AppDatabase.inMemory()
    try await database.readAsync { db in
      #expect(try db.tableExists("rssWatchCopy"))
      #expect(try db.tableExists("rssWatchCopySet"))

      #expect(
        Set(try db.columns(in: "rssWatchCopy").map(\.name)) == [
          "episodeId", "watchInstallID", "revision", "state", "removedBy", "declineReason",
          "sourceBytes", "requestedAt", "updatedAt", "failedAt",
        ])
      // v106 adds the Audiobookshelf columns to this shared row, pinned with the v106
      // migration; v104's own columns must all survive it.
      #expect(
        Set(try db.columns(in: "rssWatchCopySet").map(\.name)).isSuperset(of: [
          "id", "watchInstallID", "generation", "acknowledgedGeneration", "inventorySequence",
          "acceptsCopies", "budgetTotalBytes", "budgetUsedBytes", "lastInventoryAt",
        ]))
      #expect(try db.primaryKey("rssWatchCopy").columns == ["episodeId"])
      #expect(try db.primaryKey("rssWatchCopySet").columns == ["id"])
      #expect(
        try db.indexes(on: "rssWatchCopy").contains {
          $0.name == "index_rssWatchCopy_on_state" && $0.columns == ["state"]
        })

      let episodeForeignKey = try #require(
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(rssWatchCopy)")
          .first { ($0["table"] as String) == "rssEpisode" })
      #expect((episodeForeignKey["on_delete"] as String).uppercased() == "CASCADE")
      #expect(
        try db.foreignKeys(on: "rssWatchCopy").allSatisfy { $0.destinationTable != "account" })
      #expect(
        try db.foreignKeys(on: "rssWatchCopySet").allSatisfy { $0.destinationTable != "account" })

      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssWatchCopySet") == 1)
    }
  }

  /// Both tables are device-owned and unsynced: a write must not reach the cloud dirty log, and no
  /// trigger may be registered against them.
  @Test func watchCopyWritesNeverQueueCloudSync() async throws {
    let fixture = try await Fixture()
    let episodeId = fixture.episodeID(0)
    try fixture.completeDownload(episode: fixture.episodes[0])
    try await fixture.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM podcastCloudDirty")
    }

    _ = try await fixture.store.request(episodeId: episodeId, now: Fixture.date(10))
    _ = try await fixture.store.applyInventory(
      fixture.inventory(
        sequence: 1, acknowledged: 1,
        entries: [
          .init(episodeId: episodeId, revision: 1, state: .ready)
        ]), now: Fixture.date(20))

    let entries = try await fixture.database.readAsync { db in
      try PodcastCloudDirtyLog.entries(in: db)
    }
    #expect(entries.isEmpty)
    let triggers = try await fixture.database.readAsync { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'trigger' AND tbl_name IN ('rssWatchCopy', 'rssWatchCopySet')
          """)
    }
    #expect(triggers.isEmpty)
  }

  // MARK: - Fixture

  private struct Fixture {
    let database: AppDatabase
    let feedID: Int64
    let episodes: [RSSEpisodeRecord]
    let store: RSSWatchCopyStore
    private let downloads: RSSDownloadStore

    init() async throws {
      let database = try AppDatabase.inMemory()
      self.database = database
      let feedID = try await RSSFeedStore(database: database).subscribe(
        feedURL: URL(string: "https://feeds.invalid/watch.xml")!, title: "Watch Show",
        author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Self.date(0))
      self.feedID = feedID
      _ = try await RSSEpisodeStore(database: database).applyRefresh(
        feedId: feedID,
        episodes: (1...3).map { index in
          RSSEpisodeUpsert(
            identityKey: "episode-\(index)", guid: "episode-\(index)",
            title: "Episode \(index)",
            enclosureURL: URL(string: "https://cdn.invalid/\(index).mp3")!,
            enclosureType: "audio/mpeg", declaredBytes: 100,
            publishedAt: Self.date(TimeInterval(index * 10)))
        })
      self.episodes = try await database.readAsync { db in
        try RSSEpisodeRecord.fetchAll(
          db, sql: "SELECT * FROM rssEpisode WHERE feedId = ? ORDER BY publishedAt",
          arguments: [feedID])
      }
      self.store = RSSWatchCopyStore(database: database)
      self.downloads = try RSSDownloadStore(database: database)
    }

    func episodeID(_ index: Int) -> Int64 {
      episodes[index].id!
    }

    func completeDownload(episode: RSSEpisodeRecord, actualBytes: Int64 = 100) throws {
      let episodeId = try #require(episode.id)
      let row = try downloads.claimOrCreate(
        episodeId: episodeId, origin: .manual, decidedStamp: Self.date(0))
      let downloadID = try #require(row.id)
      _ = try downloads.transition(downloadId: downloadID, to: .downloading)
      _ = try downloads.complete(downloadId: downloadID, actualBytes: actualBytes)
    }

    /// Offers an episode and records that the Watch is downloading it.
    func sendSomewhere(episodeId: Int64) async throws {
      _ = try await store.request(episodeId: episodeId, now: Self.date(10))
      _ = try await store.transition(
        episodeId: episodeId, revision: 1, to: .sending, now: Self.date(20))
    }

    func moveToTerminal(episodeId: Int64, state: RSSWatchCopyState) async throws {
      switch state {
      case .removed:
        _ = try await store.request(episodeId: episodeId, now: Self.date(10))
        _ = try await store.removeFromWatch(episodeId: episodeId, now: Self.date(20))
      case .declined:
        try await sendSomewhere(episodeId: episodeId)
        _ = try await store.applyInventory(
          inventory(
            sequence: 1, acknowledged: 1,
            entries: [
              .init(
                episodeId: episodeId, revision: 1, state: .declined, declineReason: .invalid)
            ]), now: Self.date(30))
      case .failed:
        _ = try await store.request(episodeId: episodeId, now: Self.date(10))
        _ = try await store.transition(
          episodeId: episodeId, revision: 1, to: .sending, now: Self.date(20))
        _ = try await store.transition(
          episodeId: episodeId, revision: 1, to: .failed, now: Self.date(30))
      case .delivered:
        try await sendSomewhere(episodeId: episodeId)
        _ = try await store.applyInventory(
          inventory(
            sequence: 1, acknowledged: 1,
            entries: [
              .init(episodeId: episodeId, revision: 1, state: .ready)
            ]), now: Self.date(30))
      default:
        Issue.record("not a terminal state: \(state)")
      }
    }

    func inventory(
      installID: String = "watch-1",
      sequence: UInt64,
      acknowledged: UInt64,
      acceptsCopies: Bool = true,
      entries: [RSSWatchInventory.Entry]
    ) -> RSSWatchInventory {
      RSSWatchInventory(
        watchInstallID: installID, sequence: sequence,
        acknowledgedGeneration: acknowledged, acceptsCopies: acceptsCopies, entries: entries,
        budgetTotalBytes: 2_000_000_000, budgetUsedBytes: 100, observedAt: Self.date(35))
    }

    static func date(_ offset: TimeInterval) -> Date {
      Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }
  }
}
