import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// How the Watch applies the phone's Audiobookshelf desired set against the groups it holds
/// (ADR 0021 Decisions 1–5).
@Suite("Watch ABS request ledger")
struct WatchABSRequestLedgerTests {
  private let installID = "11111111-1111-4111-8111-111111111111"
  private let sentAt = Date(timeIntervalSinceReferenceDate: 10_000)

  // MARK: Acceptance

  @Test func offersFromAnotherAccountOrInstallOrAnOlderGenerationAreIgnored() throws {
    var ledger = WatchABSRequestLedger()
    let other = try accountStamp(account: "other", server: "s")
    let foreign = try offer(generation: 2, account: other)
    #expect(ledger.accept(foreign, installID: installID, accountStamp: try stamp()) == .ignored(.foreignAccount))
    #expect(
      ledger.accept(
        try offer(generation: 2, install: "22222222-2222-4222-8222-222222222222"), installID: installID,
        accountStamp: try stamp()) == .ignored(.foreignInstall))
    #expect(ledger.accept(try offer(generation: 2), installID: installID, accountStamp: try stamp()) == .accepted)
    let repeated = try offer(generation: 2)
    #expect(ledger.accept(repeated, installID: installID, accountStamp: try stamp()) == .ignored(.staleGeneration))
    let stale = try offer(generation: 1)
    #expect(ledger.accept(stale, installID: installID, accountStamp: try stamp()) == .ignored(.staleGeneration))
    #expect(ledger.offer?.generation == 2)
    // An offer sent before the phone knew the install is still this Watch's.
    let unaddressed = try offer(generation: 3, install: nil)
    #expect(ledger.accept(unaddressed, installID: installID, accountStamp: try stamp()) == .accepted)
  }

  // MARK: Omission and removals

  @Test func aStaleOfferThatOmitsAWatchOriginGroupLeavesItInPlace() throws {
    var ledger = try accepted(offer(generation: 2, entries: [entry(2)], inventorySequence: 5))
    let plan = ledger.reconcile(groups: [try group(1, origin: .watch, state: .completed)])
    #expect(plan.actions == [.fetch(try entry(2))])
  }

  @Test func omissionRemovesAPhoneOriginGroup() throws {
    var ledger = try accepted(offer(generation: 2, entries: [], inventorySequence: 5))
    let plan = ledger.reconcile(groups: [try group(1, origin: .phone, revision: 1, state: .completed)])
    #expect(plan.actions == [.remove(try selection(1))])
  }

  /// A phone that lost its rows sends an empty set before it has seen a matching inventory. That
  /// set must not delete every book the phone sent.
  @Test func anEmptyFirstOfferWithoutAMatchingInventoryRemovesNothing() throws {
    var ledger = try accepted(offer(generation: 1, entries: [], inventorySequence: nil))
    let plan = ledger.reconcile(groups: [
      try group(1, origin: .phone, revision: 1, state: .completed),
      try group(2, origin: .phone, revision: 3, state: .downloading),
    ])
    #expect(plan.actions.isEmpty)
    #expect(plan.generation == 1)
  }

  @Test func aRemovalOfAGroupNotInTheStoreIsAcknowledgedAndIsNotAnError() throws {
    var ledger = try accepted(offer(generation: 3, removals: [selection(9)], inventorySequence: 5))
    let plan = ledger.reconcile(groups: [])
    #expect(plan.actions.isEmpty)
    #expect(plan.generation == 3)
    ledger.markApplied(generation: 3)
    #expect(ledger.acknowledgedGeneration == 3)
  }

  /// The phone keeps a removal in every offer until an inventory acknowledges it, so a later
  /// generation can still name a selection the listener has since downloaded again on the wrist.
  @Test func aRemovalAppliesOnceAndSparesADownloadStartedAfterItWasSent() throws {
    var ledger = try accepted(offer(generation: 3, removals: [selection(1), selection(2)], inventorySequence: 5))
    let groups = [
      try group(1, origin: .watch, state: .completed, createdAt: sentAt.addingTimeInterval(-60)),
      try group(2, origin: .watch, state: .completed, createdAt: sentAt.addingTimeInterval(60)),
    ]
    #expect(ledger.reconcile(groups: groups).actions == [.remove(try selection(1))])
    ledger.markApplied(generation: 3)
    #expect(ledger.reconcile(groups: groups).actions.isEmpty)
  }

  // MARK: Starts, adoption and retries

  @Test func anOfferForAWristDownloadAdoptsItWithoutFetchingAgain() throws {
    var ledger = try accepted(offer(generation: 2, entries: [entry(1, revision: 2)], inventorySequence: 5))
    let plan = ledger.reconcile(groups: [try group(1, origin: .watch, state: .completed)])
    #expect(plan.actions == [.adopt(try selection(1), revision: 2)])
  }

  @Test func aNewRevisionRetriesAHeldOrFailedPhoneGroup() throws {
    for state in [WatchDownloadState.failed, .queued] {
      let failure: WatchDownloadFailureReason = state == .failed ? .transport : .waitingForWiFi
      let held = try group(1, origin: .phone, revision: 1, state: state, failure: failure)

      var same = try accepted(offer(generation: 2, entries: [entry(1, revision: 1)], inventorySequence: 5))
      #expect(same.reconcile(groups: [held]).actions.isEmpty)

      var bumped = try accepted(offer(generation: 3, entries: [entry(1, revision: 2)], inventorySequence: 5))
      #expect(
        bumped.reconcile(groups: [held]).actions == [
          .adopt(try selection(1), revision: 2), .retry(try entry(1, revision: 2)),
        ])
    }
  }

  /// A launch that ended mid-plan leaves some tracks enqueued; the next reconcile plans the rest.
  @Test func aPartlyEnqueuedPhoneGroupIsFetchedAgain() throws {
    var ledger = try accepted(offer(generation: 2, entries: [entry(1, revision: 1)], inventorySequence: 5))
    let partial = try group(1, origin: .phone, revision: 1, state: .queued, tracks: 4)
    #expect(partial.state == .enqueuing)
    #expect(ledger.reconcile(groups: [partial]).actions == [.fetch(try entry(1, revision: 1))])
  }

  @Test func aFailureBeforeEnqueueIsNotRetriedOnTheSameRevisionButIsOnANewOne() throws {
    var ledger = try accepted(offer(generation: 2, entries: [entry(1, revision: 1)], inventorySequence: 5))
    ledger.record(.failed(.planInvalid), for: try selection(1), revision: 1)
    #expect(ledger.reconcile(groups: []).actions.isEmpty)
    #expect(ledger.reconcile(groups: [], retryNetworkFailures: true).actions.isEmpty)

    let raised = try offer(generation: 3, entries: [entry(1, revision: 2)], inventorySequence: 5)
    #expect(ledger.accept(raised, installID: installID, accountStamp: try stamp()) == .accepted)
    #expect(ledger.reconcile(groups: []).actions == [.fetch(try entry(1, revision: 2))])
    #expect(ledger.outcomes.isEmpty)
  }

  @Test func aNetworkFailureIsRetriedOnlyWhenTheNetworkReturns() throws {
    var ledger = try accepted(offer(generation: 2, entries: [entry(1, revision: 1)], inventorySequence: 5))
    ledger.record(.failed(.network), for: try selection(1), revision: 1)
    #expect(ledger.reconcile(groups: []).actions.isEmpty)
    #expect(ledger.reconcile(groups: [], retryNetworkFailures: true).actions == [.fetch(try entry(1, revision: 1))])
  }

  // MARK: Removed on the Watch

  @Test func aPhoneGroupRemovedOnTheWatchStaysRemovedUntilThePhoneSendsItAgain() throws {
    var ledger = try accepted(offer(generation: 2, entries: [entry(1, revision: 1)], inventorySequence: 5))
    ledger.recordRemoval(of: try group(1, origin: .phone, revision: 1, state: .completed))
    ledger.recordRemoval(of: try group(2, origin: .watch, state: .completed))
    #expect(ledger.tombstones.map(\.selection) == [try selection(1)])
    #expect(ledger.reconcile(groups: []).actions.isEmpty)
    let removed = try #require(ledger.inventoryEntries(groups: []).first)
    #expect(removed.state == .removed)
    #expect(removed.revision == 1)
    #expect(removed.origin == .phone)

    // Send Again bumps the revision.
    let sendAgain = try offer(generation: 3, entries: [entry(1, revision: 2)], inventorySequence: 5)
    _ = ledger.accept(sendAgain, installID: installID, accountStamp: try stamp())
    #expect(ledger.reconcile(groups: []).actions == [.fetch(try entry(1, revision: 2))])
    #expect(ledger.tombstones.isEmpty)
  }

  @Test func anOfferThatOmitsATombstoneAcknowledgesIt() throws {
    var ledger = try accepted(offer(generation: 2, entries: [entry(1, revision: 1)], inventorySequence: 5))
    ledger.recordRemoval(of: try group(1, origin: .phone, revision: 1, state: .completed))
    let omitting = try offer(generation: 3, entries: [], inventorySequence: 6)
    _ = ledger.accept(omitting, installID: installID, accountStamp: try stamp())
    _ = ledger.reconcile(groups: [])
    #expect(ledger.tombstones.isEmpty)
    #expect(ledger.inventoryEntries(groups: []).isEmpty)
  }

  // MARK: Inventory

  @Test func theInventoryNamesGroupsOutcomesAndRequestsNotYetStarted() throws {
    var ledger = try accepted(
      offer(
        generation: 2, entries: [entry(1, revision: 1), entry(2, revision: 4), entry(3, revision: 2)],
        inventorySequence: 5))
    ledger.record(.declined(.storageFull), for: try selection(2), revision: 4)
    let groups = [
      try group(1, origin: .phone, revision: 1, state: .downloading),
      try group(7, origin: .watch, state: .completed),
    ]
    let entries = Dictionary(
      uniqueKeysWithValues: ledger.inventoryEntries(groups: groups).map { ($0.selection, $0) })
    #expect(entries.count == 4)
    #expect(entries[try selection(1)]?.state == .downloading)
    #expect(entries[try selection(2)]?.state == .declined)
    #expect(entries[try selection(2)]?.revision == 4)
    #expect(entries[try selection(2)]?.declineReason == .storageFull)
    // Asked for and not yet planned: the Watch has it, and has not started it.
    #expect(entries[try selection(3)]?.state == .receiving)
    #expect(entries[try selection(3)]?.trackCount == 0)
    #expect(entries[try selection(7)]?.origin == .watch)
  }

  @Test func theLedgerSurvivesARoundTrip() throws {
    var ledger = try accepted(offer(generation: 2, entries: [entry(1)], removals: [selection(4)], inventorySequence: 5))
    ledger.record(.failed(.itemMissing), for: try selection(1), revision: 1)
    ledger.recordRemoval(of: try group(3, origin: .phone, revision: 2, state: .completed))
    ledger.markApplied(generation: 2)
    let decoded = try JSONDecoder().decode(WatchABSRequestLedger.self, from: JSONEncoder().encode(ledger))
    #expect(decoded == ledger)
  }

  // MARK: Fixtures

  private func stamp() throws -> WatchAccountStamp { try accountStamp(account: "a", server: "s") }

  private func selection(_ index: Int) throws -> WatchABSSelection {
    try WatchABSSelection(itemID: "item-\(index)", episodeID: nil)
  }

  private func entry(_ index: Int, revision: UInt64 = 1) throws -> WatchABSOfferEntry {
    try WatchABSOfferEntry(
      selection: selection(index), revision: revision, title: "Book \(index)", subtitle: "Author",
      declaredBytes: 1_000, position: nil)
  }

  private func offer(
    generation: UInt64, entries: [WatchABSOfferEntry] = [], removals: [WatchABSSelection] = [],
    account: WatchAccountStamp? = nil, install: String? = "11111111-1111-4111-8111-111111111111",
    inventorySequence: UInt64? = nil
  ) throws -> WatchABSSendOffer {
    try WatchABSSendOffer(
      generation: generation, watchInstallID: install, accountStamp: account ?? stamp(), entries: entries,
      removals: removals, sentAt: sentAt, inventorySequence: inventorySequence)
  }

  private func accepted(_ offer: WatchABSSendOffer) throws -> WatchABSRequestLedger {
    var ledger = WatchABSRequestLedger()
    #expect(ledger.accept(offer, installID: installID, accountStamp: try stamp()) == .accepted)
    return ledger
  }

  /// A one-file group, or the first of `tracks` files when the plan is not yet fully enqueued.
  private func group(
    _ index: Int, origin: WatchABSOrigin, revision: UInt64? = nil, state: WatchDownloadState,
    failure: WatchDownloadFailureReason? = nil, tracks: Int = 1, createdAt: Date? = nil
  ) throws -> WatchDownloadGroup {
    let manifest = WatchDownloadManifest(
      id: UUID(), accountStamp: try stamp(), selection: try selection(index).watchSelection,
      downloadGroupID: "item-\(index)", expectedTrackCount: tracks, fileID: "file", fileIndex: 1,
      startOffset: 0, duration: 60, expectedBytes: 1_000, expectedMIMEType: "audio/mpeg",
      destinationRelativePath: "item-\(index).mp3", state: state,
      receivedBytes: state == .completed ? 1_000 : 0, failureReason: failure,
      createdAt: createdAt ?? sentAt.addingTimeInterval(-600), updatedAt: sentAt, origin: origin,
      phoneRevision: revision)
    return try #require(WatchDownloadGroup.make([manifest]))
  }
}
