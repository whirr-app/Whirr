import Foundation
import Persistence
import Testing
import WatchProtocol

@testable import Whirr

/// The Audiobookshelf half of one Watch inventory (ADR 0021).
@MainActor
@Suite("Watch Audiobookshelf inventory inbox", .serialized)
struct ABSWatchInventoryInboxTests {
  private typealias Fixture = ABSWatchSendFixture

  /// A Watch that predates Audiobookshelf sends says nothing about its account.
  @Test func anInventoryWithNoAudiobookshelfHalfSaysNothing() async throws {
    let fixture = try Fixture()
    let inbox = fixture.inbox()
    var matches: [ABSWatchInventoryInbox.AccountMatch] = []
    inbox.onAccountMatch = { matches.append($0) }

    let outcome = await inbox.receive(
      try fixture.wireInventory(sequence: 1, nil), now: Fixture.date(400))

    #expect(outcome == nil)
    #expect(matches.isEmpty)
  }

  /// Entries stamped with another account, or with none, are not read at all.
  @Test func anotherAccountsOrASignedOutWatchsEntriesApplyNothing() async throws {
    let fixture = try Fixture()
    let other = try WatchAccountStamp(accountIdentityHash: "another", serverIdentityHash: "server")
    let inbox = fixture.inbox()
    var matches: [ABSWatchInventoryInbox.AccountMatch] = []
    inbox.onAccountMatch = { matches.append($0) }
    let entry = try Fixture.wireEntry(Fixture.book, revision: 2, origin: .phone)

    for stamp in [other, nil] as [WatchAccountStamp?] {
      let outcome = await inbox.receive(
        try fixture.wireInventory(sequence: 1, stamp: .some(stamp), [entry]), now: Fixture.date(400))
      #expect(outcome == nil)
    }

    #expect(matches == [.mismatch, .mismatch])
    #expect(try await fixture.store.copies().isEmpty)
    #expect(try await fixture.store.setState().inventoryAccountHash == nil)
  }

  /// After a re-sign-in the account's rows are gone; the first matching inventory brings back what
  /// the phone sent, titled from the library, and opens the offer gate.
  @Test func phoneOriginEntriesAreReadoptedWithLibraryTitles() async throws {
    let fixture = try Fixture()
    fixture.books[Fixture.book.itemId] = .fixture(
      serverItemId: Fixture.book.itemId, title: "The Book", author: "An Author")
    let inbox = fixture.inbox()
    var matches: [ABSWatchInventoryInbox.AccountMatch] = []
    inbox.onAccountMatch = { matches.append($0) }

    let outcome = await inbox.receive(
      try fixture.wireInventory(
        sequence: 3, [try Fixture.wireEntry(Fixture.book, revision: 2, origin: .phone)]),
      now: Fixture.date(400))

    #expect(outcome?.applied == true)
    #expect(matches == [.matching])
    let copy = try #require(try await fixture.store.copy(Fixture.book))
    #expect(copy.revision == 2)
    #expect(copy.state == .delivered)
    #expect(copy.title == "The Book")
    #expect(copy.subtitle == "An Author")
    #expect(try await fixture.store.setState().inventoryAccountHash == fixture.stamp.accountIdentityHash)
  }

  /// A download the Watch started is shown, never adopted into the desired set.
  @Test func watchOriginGroupsAreSnapshottedNotAdopted() async throws {
    let fixture = try Fixture()
    let inbox = fixture.inbox()
    var applied: [ABSWatchInventoryRecord.Snapshot] = []
    inbox.onApplied = { applied.append($0) }
    let entry = try Fixture.wireEntry(
      Fixture.episode, revision: nil, origin: .watch, .downloading, tracks: 4, completed: 1)

    _ = await inbox.receive(try fixture.wireInventory(sequence: 1, [entry]), now: Fixture.date(400))

    #expect(try await fixture.store.copies().isEmpty)
    let snapshot = try #require(applied.last)
    let group = try #require(snapshot.groups.first)
    #expect(group.key == Fixture.episode)
    #expect(group.revision == nil)
    #expect(group.state == .downloading)
    #expect(group.trackCount == 4)
    #expect(group.completedTracks == 1)
    #expect(group.title == "Episode", "the library holds no such episode")
    #expect(
      fixture.record.load(watchInstallID: Fixture.install, accountIdentityHash: "account")
        == snapshot.withoutTitles)
  }

  /// The record is in the device backup, so it keeps no title; a relaunch reads them again.
  @Test func theSavedReportHoldsNoTitleAndIsRetitledFromTheLibrary() async throws {
    let fixture = try Fixture()
    fixture.books[Fixture.book.itemId] = .fixture(
      serverItemId: Fixture.book.itemId, title: "The Book", author: "An Author")
    let inbox = fixture.inbox()

    _ = await inbox.receive(
      try fixture.wireInventory(
        sequence: 1, [try Fixture.wireEntry(Fixture.book, revision: nil, origin: .watch)]),
      now: Fixture.date(400))

    let saved = try #require(
      fixture.record.load(watchInstallID: Fixture.install, accountIdentityHash: "account"))
    #expect(saved.groups.first?.title == "")
    #expect(saved.groups.first?.subtitle == nil)
    let restored = await saved.titled(by: fixture.resolver)
    #expect(restored.groups.first?.title == "The Book")
    #expect(restored.groups.first?.subtitle == "An Author")
  }

  /// A late or repeated sequence must not replace what the screen shows.
  @Test func aRepeatedSequenceKeepsTheSnapshot() async throws {
    let fixture = try Fixture()
    let inbox = fixture.inbox()
    var applied = 0
    inbox.onApplied = { _ in applied += 1 }
    let first = try Fixture.wireEntry(Fixture.book, revision: nil, origin: .watch)
    let second = try Fixture.wireEntry(Fixture.otherBook, revision: nil, origin: .watch)

    _ = await inbox.receive(try fixture.wireInventory(sequence: 2, [first]), now: Fixture.date(400))
    let repeated = await inbox.receive(
      try fixture.wireInventory(sequence: 2, [second]), now: Fixture.date(401))

    #expect(repeated?.applied == false)
    #expect(applied == 1)
    let saved = fixture.record.load(watchInstallID: Fixture.install, accountIdentityHash: "account")
    #expect(saved?.groups.map(\.key) == [Fixture.book])
  }

  /// The wire allows a revision on a Watch-origin entry only to ignore it.
  @Test func aWatchOriginEntrysRevisionIsIgnored() async throws {
    let fixture = try Fixture()
    let inbox = fixture.inbox()
    let valid = try Fixture.wireEntry(Fixture.book, revision: nil, origin: .watch)
    var object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
    object["revision"] = 5
    let entry = try JSONDecoder().decode(
      WatchABSInventoryEntry.self, from: try JSONSerialization.data(withJSONObject: object))

    _ = await inbox.receive(try fixture.wireInventory(sequence: 1, [entry]), now: Fixture.date(400))

    #expect(try await fixture.store.copies().isEmpty)
    #expect(
      fixture.record.load(watchInstallID: Fixture.install, accountIdentityHash: "account")?
        .groups.first?.revision == nil)
  }
}
