import Foundation
import Persistence
import Testing
import WatchProtocol

@testable import Whirr

/// The account-bound Audiobookshelf sender (ADR 0021).
@MainActor
@Suite("Watch Audiobookshelf send publisher", .serialized)
struct ABSWatchSendPublisherTests {
  private typealias Fixture = ABSWatchSendFixture

  // MARK: - The account gate

  /// An offer sent before the Watch reports for this account would list an empty or partial set,
  /// and the Watch would remove every phone-sent title by omission.
  @Test func nothingIsOfferedBeforeAnInventoryForThisAccount() async throws {
    let fixture = try Fixture()
    try await fixture.request(Fixture.book, at: 10)
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()
    #expect(fixture.sent.isEmpty)

    try await fixture.applyStoreInventory(sequence: 4, acknowledged: 0)
    publisher.refresh()
    await publisher.settle()

    let offer = try #require(try fixture.offers().last)
    #expect(offer.entries.map(\.selection) == [try Fixture.selection(Fixture.book)])
    #expect(offer.accountStamp == fixture.stamp)
    #expect(offer.watchInstallID == Fixture.install)
    #expect(offer.inventorySequence == 4, "the Watch removes by omission only from a matched offer")
    #expect(offer.entries.first?.title == "Title of book-1")
    #expect(offer.entries.first?.subtitle == "Author")
    #expect(offer.entries.first?.declaredBytes == 1_000)
  }

  @Test func anInventoryForAnotherAccountKeepsTheGateShut() async throws {
    let fixture = try Fixture()
    try await fixture.request(Fixture.book, at: 10)
    try await fixture.applyStoreInventory(sequence: 1, acknowledged: 0, accountIdentityHash: "another")
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    #expect(fixture.sent.isEmpty)
  }

  // MARK: - Offers

  @Test func anAcknowledgedGenerationIsNotSentAgain() async throws {
    let fixture = try Fixture()
    try await fixture.request(Fixture.book, at: 10)
    try await fixture.applyStoreInventory(sequence: 1, acknowledged: 1)
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    #expect(fixture.sent.isEmpty)
  }

  @Test func anUnchangedOfferIsQueuedOnceUntilTheWatchIsInstalledAgain() async throws {
    let fixture = try Fixture()
    try await fixture.request(Fixture.book, at: 10)
    try await fixture.applyStoreInventory(sequence: 1, acknowledged: 0)
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()
    publisher.refresh()
    await publisher.settle()
    #expect(fixture.sent.count == 1)

    publisher.watchBecameAvailable()
    await publisher.settle()
    #expect(fixture.sent.count == 2)
  }

  @Test func nothingIsQueuedWithoutTheWatchApp() async throws {
    let fixture = try Fixture()
    fixture.isWatchInstalled = false
    try await fixture.request(Fixture.book, at: 10)
    try await fixture.applyStoreInventory(sequence: 1, acknowledged: 0)
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    #expect(fixture.sent.isEmpty)
  }

  /// A removal rides every offer until an inventory acknowledges its generation.
  @Test func aRemovalIsOfferedApartFromTheMembers() async throws {
    let fixture = try Fixture()
    try await fixture.request(Fixture.book, at: 10)
    try await fixture.request(Fixture.otherBook, at: 20)
    try await fixture.applyStoreInventory(sequence: 1, acknowledged: 2)
    _ = try await fixture.store.removeFromWatch(
      Fixture.book, title: "Title of book-1", subtitle: nil, now: Fixture.date(30))
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    let offer = try #require(try fixture.offers().last)
    #expect(offer.removals == [try Fixture.selection(Fixture.book)])
    #expect(offer.entries.map(\.selection) == [try Fixture.selection(Fixture.otherBook)])
  }

  @Test func stoppingSendsNothingMore() async throws {
    let fixture = try Fixture()
    try await fixture.request(Fixture.book, at: 10)
    try await fixture.applyStoreInventory(sequence: 1, acknowledged: 0)
    let publisher = fixture.publisher()

    publisher.stop()
    publisher.refresh()
    await publisher.settle()

    #expect(fixture.sent.isEmpty)
  }

  // MARK: - Finished titles

  @Test func aTitleFinishedAfterItsRequestLeavesTheWatch() async throws {
    let fixture = try Fixture()
    try await fixture.request(Fixture.book, at: 10)
    try await fixture.applyStoreInventory(sequence: 1, acknowledged: 0)
    fixture.finished(Fixture.book, at: 20)
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    let offer = try #require(try fixture.offers().last)
    #expect(offer.entries.isEmpty)
    #expect(offer.removals == [try Fixture.selection(Fixture.book)])
    let copy = try #require(try await fixture.store.copy(Fixture.book))
    #expect(copy.state == .removed)
    #expect(copy.removedBy == .phone)
  }

  /// A deliberate re-send of a finished book stays: the finish predates the request.
  @Test func aTitleFinishedBeforeItsRequestStays() async throws {
    let fixture = try Fixture()
    fixture.finished(Fixture.book, at: 5)
    try await fixture.request(Fixture.book, at: 10)
    try await fixture.applyStoreInventory(sequence: 1, acknowledged: 0)
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    let offer = try #require(try fixture.offers().last)
    #expect(offer.entries.map(\.selection) == [try Fixture.selection(Fixture.book)])
    #expect(offer.removals.isEmpty)
  }

  @Test func theToggleOffKeepsAFinishedTitle() async throws {
    let fixture = try Fixture()
    fixture.removesFinished = false
    try await fixture.request(Fixture.book, at: 10)
    try await fixture.applyStoreInventory(sequence: 1, acknowledged: 0)
    fixture.finished(Fixture.book, at: 20)
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    #expect(try fixture.offers().last?.entries.map(\.selection) == [try Fixture.selection(Fixture.book)])
  }

  /// The phone has no row for a download the Watch started, so a finish never removes it.
  @Test func aWatchOriginTitleIsNeverRemovedForBeingFinished() async throws {
    let fixture = try Fixture()
    try await fixture.request(Fixture.otherBook, at: 10)
    try await fixture.applyStoreInventory(
      sequence: 1, acknowledged: 0,
      [ABSWatchInventory.Entry(key: Fixture.book, revision: nil, state: .ready, title: "Watch book")])
    fixture.finished(Fixture.book, at: 20)
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    let offer = try #require(try fixture.offers().last)
    #expect(offer.removals.isEmpty)
    #expect(try await fixture.store.copy(Fixture.book) == nil)
  }

  // MARK: - Wire text

  @Test func libraryTextIsFoldedToWhatTheWireTakes() {
    #expect(ABSWatchSendPublisher.wireText("  A\u{0}Title\n\tPart  1 ") == "A Title Part 1")
    #expect(ABSWatchSendPublisher.wireText("https://server.invalid/item") == nil)
    #expect(ABSWatchSendPublisher.wireText("file:///private/var") == nil)
    #expect(ABSWatchSendPublisher.wireText("/private/var") == nil)
    #expect(ABSWatchSendPublisher.wireText("  \n ") == nil)
    let long = String(repeating: "é", count: 400)
    let bounded = ABSWatchSendPublisher.wireText(long)
    #expect((bounded?.utf8.count ?? 0) <= WatchProtocolVersion.maxMetadataStringBytes)
    #expect(bounded?.isEmpty == false)
  }

  @Test func aRowTheWireCannotCarryKeepsItsPlaceholder() throws {
    let date = Fixture.date(10)
    let row = ABSWatchCopy(
      accountId: 1, key: Fixture.book, title: "https://server.invalid/x", state: .wanted,
      declaredBytes: WatchABSSendLimits.maxItemBytes + 1, requestedAt: date, updatedAt: date)

    let entry = try #require(ABSWatchSendPublisher.entry(row))
    #expect(entry.title == "Audiobook")
    #expect(entry.declaredBytes == nil, "a size the wire would refuse is sent as unknown")
  }
}
