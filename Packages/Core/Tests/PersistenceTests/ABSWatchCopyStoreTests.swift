import Foundation
import GRDB
import Testing

@testable import Persistence

/// The signed-in account's desired set of Audiobookshelf titles for the active Watch: requests,
/// phone removals, inventory reconciliation, re-adoption and the account boundary (ADR 0021).
@Suite struct ABSWatchCopyStoreTests {
  private static let install = "11111111-1111-4111-8111-111111111111"
  private static let book = ABSWatchCopyKey(itemId: "book-1", episodeId: nil)
  private static let episode = ABSWatchCopyKey(itemId: "show-1", episodeId: "episode-1")

  // MARK: Schema

  /// Library sync may prune an item the Watch still plays, so the row names no item; the account
  /// owns it, so sign-out removes it.
  @Test func copiesCascadeFromTheAccountAndNameNoItem() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(absWatchCopy)")
      #expect(foreignKeys.count == 1)
      #expect((foreignKeys.first?["table"] as String?) == "account")
      #expect((foreignKeys.first?["on_delete"] as String?)?.uppercased() == "CASCADE")
      #expect(try db.primaryKey("absWatchCopy").columns == ["accountId", "itemId", "episodeId"])
    }
  }

  // MARK: Requests

  @Test func requestingATitlePutsItInTheOffer() async throws {
    let fixture = try await Fixture()

    let copy = try await fixture.request(Self.book, at: 10)

    #expect(copy.state == .wanted)
    #expect(copy.revision == 1)
    #expect(copy.key == Self.book)
    #expect(copy.episodeId == "", "a book is stored with an empty episode key")
    #expect(try await fixture.store.desired().map(\.key) == [Self.book])
    #expect(try await fixture.store.setState().generation == 1)
  }

  @Test func anActiveRequestKeepsItsRevisionAndGeneration() async throws {
    let fixture = try await Fixture()

    _ = try await fixture.request(Self.episode, at: 10)
    let again = try await fixture.request(Self.episode, at: 20)

    #expect(again.revision == 1)
    #expect(again.requestedAt == Fixture.date(10))
    #expect(try await fixture.store.setState().generation == 1)
  }

  @Test func reRequestingARemovedTitleBumpsItsRevision() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)
    _ = try await fixture.store.removeFromWatch(
      Self.book, title: "Book", subtitle: nil, now: Fixture.date(20))

    let copy = try await fixture.request(Self.book, at: 30)

    #expect(copy.state == .wanted)
    #expect(copy.revision == 2)
    #expect(copy.removedBy == nil)
    #expect(copy.removalGeneration == nil)
    #expect(try await fixture.store.pendingRemovals().isEmpty)
    #expect(try await fixture.store.setState().generation == 3)
  }

  // MARK: Phone removals

  @Test func removingAPhoneSentTitleRecordsTheGenerationThatCarriesIt() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)

    let removed = try #require(
      try await fixture.store.removeFromWatch(
        Self.book, title: "Book", subtitle: nil, now: Fixture.date(20)))

    #expect(removed.state == .removed)
    #expect(removed.removedBy == .phone)
    #expect(removed.removalGeneration == 2)
    #expect(try await fixture.store.desired().isEmpty)
    #expect(try await fixture.store.pendingRemovals().map(\.key) == [Self.book])
  }

  /// A download started on the wrist has no row; the phone's removal makes one that was never a
  /// member of the offer.
  @Test func removingAWatchStartedTitleMakesARemovalRow() async throws {
    let fixture = try await Fixture()

    let removed = try #require(
      try await fixture.store.removeFromWatch(
        Self.episode, title: "Episode", subtitle: "Show", now: Fixture.date(20)))

    #expect(removed.state == .removed)
    #expect(removed.title == "Episode")
    #expect(removed.removalGeneration == 1)
    #expect(try await fixture.store.desired().isEmpty)
    #expect(try await fixture.store.pendingRemovals().map(\.key) == [Self.episode])
  }

  @Test func removingTwiceDoesNotMoveTheGeneration() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.store.removeFromWatch(
      Self.book, title: "Book", subtitle: nil, now: Fixture.date(10))
    _ = try await fixture.store.removeFromWatch(
      Self.book, title: "Book", subtitle: nil, now: Fixture.date(20))

    #expect(try await fixture.store.setState().generation == 1)
  }

  /// The listener downloaded it again on the wrist after the first removal was acknowledged; a
  /// second Remove must reach the Watch, not stop at the old tombstone.
  @Test func removingAgainAfterAnAcknowledgedRemovalSendsANewOne() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.store.removeFromWatch(
      Self.book, title: "Book", subtitle: nil, now: Fixture.date(10))
    _ = try await fixture.apply(sequence: 1, acknowledged: 1, [])
    #expect(try await fixture.store.pendingRemovals().isEmpty)

    let again = try #require(
      try await fixture.store.removeFromWatch(
        Self.book, title: "Book", subtitle: nil, now: Fixture.date(20)))

    #expect(again.removalGeneration == 2)
    #expect(try await fixture.store.pendingRemovals().map(\.key) == [Self.book])
  }

  /// The generation acknowledges the removal; the selection may still be present because the
  /// listener downloaded it again on the wrist after the offer, and that copy must survive.
  @Test func anInventoryAcknowledgingTheGenerationEndsTheRemoval() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.store.removeFromWatch(
      Self.book, title: "Book", subtitle: nil, now: Fixture.date(10))

    _ = try await fixture.apply(sequence: 1, acknowledged: 0, [fixture.watchOrigin(Self.book)])
    #expect(try await fixture.store.pendingRemovals().map(\.key) == [Self.book])

    _ = try await fixture.apply(sequence: 2, acknowledged: 1, [fixture.watchOrigin(Self.book)])
    #expect(try await fixture.store.pendingRemovals().isEmpty)
    #expect(try await fixture.store.copy(Self.book)?.state == .removed)
  }

  // MARK: Inventory

  @Test func aReadyEntryDeliversTheCopyWithItsBytes() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)

    let outcome = try await fixture.apply(
      sequence: 1, acknowledged: 1, [fixture.phone(Self.book, revision: 1, .ready, bytes: 900)])

    let copy = try #require(try await fixture.store.copy(Self.book))
    #expect(outcome.applied)
    #expect(outcome.changedKeys == [Self.book])
    #expect(copy.state == .delivered)
    #expect(copy.sourceBytes == 900)
    #expect(copy.watchInstallID == Self.install)
  }

  @Test func aLateSequenceFromTheSameInstallIsIgnored() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)
    _ = try await fixture.apply(sequence: 5, acknowledged: 1, [fixture.phone(Self.book, revision: 1, .receiving)])

    let late = try await fixture.apply(
      sequence: 4, acknowledged: 1, [fixture.phone(Self.book, revision: 1, .ready)])

    #expect(late.applied == false)
    #expect(try await fixture.store.copy(Self.book)?.state == .sending)
  }

  @Test func anEntryForAnotherRevisionIsIgnored() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)

    _ = try await fixture.apply(sequence: 1, acknowledged: 1, [fixture.phone(Self.book, revision: 7, .ready)])

    #expect(try await fixture.store.copy(Self.book)?.state == .wanted)
  }

  @Test func aFailureKeepsTheCopyInTheOfferAndAReceivingEntryResumesIt() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)

    _ = try await fixture.apply(
      sequence: 1, acknowledged: 1, [fixture.phone(Self.book, revision: 1, .failed, failure: .itemMissing)])
    var copy = try #require(try await fixture.store.copy(Self.book))
    #expect(copy.state == .failed)
    #expect(copy.failureReason == .itemMissing)
    #expect(try await fixture.store.desired().map(\.key) == [Self.book])
    #expect(try await fixture.store.setState().generation == 1)

    _ = try await fixture.apply(sequence: 2, acknowledged: 1, [fixture.phone(Self.book, revision: 1, .receiving)])
    copy = try #require(try await fixture.store.copy(Self.book))
    #expect(copy.state == .sending)
    #expect(copy.failureReason == nil)
  }

  /// A phone-origin group the listener deletes on the wrist is reported `removed`.
  @Test func aRemovalOnTheWatchLeavesTheOfferAndMovesTheGeneration() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)

    _ = try await fixture.apply(sequence: 1, acknowledged: 1, [fixture.phone(Self.book, revision: 1, .removed)])

    let copy = try #require(try await fixture.store.copy(Self.book))
    #expect(copy.state == .removed)
    #expect(copy.removedBy == .watch)
    #expect(copy.removalGeneration == nil)
    #expect(try await fixture.store.desired().isEmpty)
    #expect(try await fixture.store.setState().generation == 2)
  }

  @Test func aDeclineRecordsItsReason() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)

    _ = try await fixture.apply(
      sequence: 1, acknowledged: 1, [fixture.phone(Self.book, revision: 1, .declined, decline: .storageFull)])

    let copy = try #require(try await fixture.store.copy(Self.book))
    #expect(copy.state == .declined)
    #expect(copy.declineReason == .storageFull)
  }

  @Test func anAcknowledgingInventoryThatOmitsACopySendsItAgain() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)
    _ = try await fixture.apply(sequence: 1, acknowledged: 1, [fixture.phone(Self.book, revision: 1, .ready)])

    _ = try await fixture.apply(sequence: 2, acknowledged: 1, [])

    #expect(try await fixture.store.copy(Self.book)?.state == .wanted)
  }

  @Test func anInventoryBehindTheGenerationDoesNotResend() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)
    _ = try await fixture.apply(sequence: 1, acknowledged: 1, [fixture.phone(Self.book, revision: 1, .ready)])
    _ = try await fixture.request(Self.episode, at: 20)

    _ = try await fixture.apply(sequence: 2, acknowledged: 1, [])

    #expect(try await fixture.store.copy(Self.book)?.state == .delivered)
  }

  @Test func aGenerationThePhoneNeverIssuedIsSteppedPast() async throws {
    let fixture = try await Fixture()

    _ = try await fixture.apply(sequence: 1, acknowledged: 40, [])

    let set = try await fixture.store.setState()
    #expect(set.acknowledgedGeneration == 40)
    #expect(set.generation == 41)
  }

  @Test func aNewWatchInstallReplacesTheSet() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)
    _ = try await fixture.apply(sequence: 9, acknowledged: 1, [fixture.phone(Self.book, revision: 1, .ready)])

    let outcome = try await fixture.apply(
      install: "22222222-2222-4222-8222-222222222222", sequence: 1, acknowledged: 0, [])

    #expect(outcome.installReplaced)
    #expect(outcome.changedKeys == [Self.book])
    #expect(try await fixture.store.copies().isEmpty)
    let set = try await fixture.store.setState()
    #expect(set.watchInstallID == "22222222-2222-4222-8222-222222222222")
    #expect(set.inventorySequence == 1)
  }

  // MARK: Account boundary

  /// After the listener signs back in, the phone's rows are gone but the Watch still holds what the
  /// phone sent. The first matching inventory re-adopts those, and never what the Watch started.
  @Test func phoneOriginEntriesWithNoRowAreReadoptedAndWatchOriginOnesAreNot() async throws {
    let fixture = try await Fixture()

    _ = try await fixture.apply(
      sequence: 3, acknowledged: 6,
      [
        fixture.phone(Self.book, revision: 2, .ready, bytes: 500),
        fixture.watchOrigin(Self.episode),
        fixture.phone(ABSWatchCopyKey(itemId: "gone", episodeId: nil), revision: 1, .removed),
      ])

    let copies = try await fixture.store.copies()
    #expect(copies.map(\.key) == [Self.book])
    let adopted = try #require(copies.first)
    #expect(adopted.state == .delivered)
    #expect(adopted.revision == 2)
    #expect(adopted.title == "Title of book-1")
    #expect(adopted.sourceBytes == 500)
    let set = try await fixture.store.setState()
    #expect(set.inventoryAccountHash == "account-hash")
    #expect(set.generation > set.acknowledgedGeneration, "the next offer lists the adopted row")
  }

  @Test func theAccountBoundaryForgetsTheInventoryAccountAndKeepsTheWatch() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.apply(sequence: 3, acknowledged: 0, [])

    try await fixture.store.forgetInventoryAccount()

    let set = try await fixture.store.setState()
    #expect(set.inventoryAccountHash == nil)
    #expect(set.watchInstallID == Self.install)
    #expect(set.inventorySequence == 3)
  }

  /// The rows go with the account, and so does the inventory's account, in the same transaction:
  /// signing back in must wait for a new inventory before any offer.
  @Test func removingTheAccountDeletesItsCopiesAndForgetsTheInventoryAccount() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)
    _ = try await fixture.apply(sequence: 3, acknowledged: 1, [])
    #expect(try await fixture.store.setState().inventoryAccountHash == "account-hash")

    try AccountRemover(database: fixture.database).removeAccount(accountId: fixture.accountId)

    let remaining = try await fixture.database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM absWatchCopy")
    }
    #expect(remaining == 0)
    let set = try await fixture.store.setState()
    #expect(set.generation == 1)
    #expect(set.inventoryAccountHash == nil)
    #expect(set.watchInstallID == Self.install)
    #expect(set.inventorySequence == 3)
  }

  @Test func anotherAccountsRowsAreNotVisible() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.request(Self.book, at: 10)
    let other = ABSWatchCopyStore(database: fixture.database, accountId: try await fixture.addAccount("other"))

    #expect(try await other.copies().isEmpty)
    #expect(try await other.copy(Self.book) == nil)
  }

  /// RSS and Audiobookshelf share the set row, and neither store's writes touch the other's half.
  @Test func theRSSHalfOfTheSetRowIsLeftAlone() async throws {
    let fixture = try await Fixture()
    try await fixture.database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE rssWatchCopySet SET generation = 7, acknowledgedGeneration = 5,
            budgetTotalBytes = 2000, budgetUsedBytes = 500 WHERE id = 1
          """)
    }

    _ = try await fixture.request(Self.book, at: 10)
    _ = try await fixture.apply(sequence: 1, acknowledged: 1, [])

    let rss = try await RSSWatchCopyStore(database: fixture.database).setState()
    #expect(rss.generation == 7)
    #expect(rss.acknowledgedGeneration == 5)
    let abs = try await fixture.store.setState()
    #expect(abs.budgetTotalBytes == 2000)
    #expect(abs.budgetUsedBytes == 500)
  }

  // MARK: Fixture

  private struct Fixture {
    let database: AppDatabase
    let accountId: Int64
    let store: ABSWatchCopyStore

    init() async throws {
      let database = try AppDatabase.inMemory()
      self.database = database
      let accountId = try await Self.insertAccount(database, user: "listener")
      self.accountId = accountId
      self.store = ABSWatchCopyStore(database: database, accountId: accountId)
    }

    static func date(_ seconds: TimeInterval) -> Date {
      Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    func addAccount(_ user: String) async throws -> Int64 {
      try await Self.insertAccount(database, user: user)
    }

    func request(_ key: ABSWatchCopyKey, at seconds: TimeInterval) async throws -> ABSWatchCopy {
      try await store.request(
        key, title: "Title of \(key.itemId)", subtitle: "Author", declaredBytes: 1_000,
        now: Self.date(seconds))
    }

    func apply(
      install: String = ABSWatchCopyStoreTests.install, sequence: UInt64, acknowledged: UInt64,
      _ entries: [ABSWatchInventory.Entry]
    ) async throws -> ABSWatchCopyInventoryOutcome {
      try await store.applyInventory(
        ABSWatchInventory(
          watchInstallID: install, sequence: sequence, accountIdentityHash: "account-hash",
          acknowledgedGeneration: acknowledged, entries: entries),
        now: Self.date(1_000))
    }

    func phone(
      _ key: ABSWatchCopyKey, revision: Int64, _ state: ABSWatchInventory.Entry.State,
      bytes: Int64? = nil, decline: RSSWatchDeclineReason? = nil, failure: ABSWatchFailureReason? = nil
    ) -> ABSWatchInventory.Entry {
      ABSWatchInventory.Entry(
        key: key, revision: revision, state: state, declineReason: decline, failureReason: failure,
        committedBytes: bytes, title: "Title of \(key.itemId)")
    }

    func watchOrigin(_ key: ABSWatchCopyKey) -> ABSWatchInventory.Entry {
      ABSWatchInventory.Entry(key: key, revision: nil, state: .ready, title: "Watch title")
    }

    private static func insertAccount(_ database: AppDatabase, user: String) async throws -> Int64 {
      try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: "abs-watch-\(user)", serverBaseURL: "https://example.com",
          serverUserId: user, serverVersion: "2.35.1")
        try account.insert(db)
        return try #require(account.id)
      }
    }
  }
}
