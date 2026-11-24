import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite struct LibrarySelectionStoreTests {

  @Test("onboarding commits the mode and every flag atomically")
  func onboardingCommitIsAtomic() async throws {
    let fixture = try await Fixture(mode: .pending)
    try await fixture.insertLibrary("one", included: false)
    try await fixture.insertLibrary("two", included: false)

    await #expect(throws: LibrarySelectionStoreError.emptySelection) {
      try await fixture.store.completeOnboarding(includedIDs: [])
    }
    await #expect(throws: LibrarySelectionStoreError.libraryNotFound("missing")) {
      try await fixture.store.completeOnboarding(includedIDs: ["one", "missing"])
    }
    #expect(try await fixture.store.currentSelection().mode == .pending)
    #expect(try await fixture.inclusionFlags() == ["one": false, "two": false])

    try await fixture.store.completeOnboarding(includedIDs: ["one"])
    let snapshot = try await fixture.store.currentSelection()
    #expect(snapshot.mode == .selected)
    #expect(
      Dictionary(uniqueKeysWithValues: snapshot.libraries.map { ($0.serverLibraryID, $0.isIncluded) }) == [
        "one": true, "two": false,
      ])
  }

  @Test("the final live included library cannot be excluded")
  func refusingLastLiveLibraryKeepsStoredSelection() async throws {
    let fixture = try await Fixture(mode: .selected)
    try await fixture.insertLibrary("only", included: true)

    await #expect(throws: LibrarySelectionStoreError.lastLiveLibrary) {
      try await fixture.store.setIncluded(false, libraryID: "only")
    }
    #expect(try await fixture.inclusionFlags() == ["only": true])
  }

  @Test("unknown and another account's library IDs are rejected")
  func mutationsRejectUnknownAndWrongAccountIDs() async throws {
    let fixture = try await Fixture(mode: .selected)
    try await fixture.insertLibrary("mine", included: true)
    let otherAccountID = try await fixture.insertAnotherAccount()
    try await fixture.insertLibrary("theirs", accountID: otherAccountID, included: true)

    await #expect(throws: LibrarySelectionStoreError.libraryNotFound("missing")) {
      try await fixture.store.setIncluded(true, libraryID: "missing")
    }
    await #expect(throws: LibrarySelectionStoreError.libraryNotFound("theirs")) {
      try await fixture.store.setIncluded(false, libraryID: "theirs")
    }
    #expect(try await fixture.inclusionFlags() == ["mine": true])
  }

  @Test("the first settings mutation promotes an all-mode account")
  func firstSettingsMutationPromotesAllMode() async throws {
    let fixture = try await Fixture(mode: .all)
    try await fixture.insertLibrary("one", included: true)
    try await fixture.insertLibrary("two", included: true)

    try await fixture.store.setIncluded(false, libraryID: "two")

    #expect(try await fixture.store.currentSelection().mode == .selected)
    #expect(try await fixture.inclusionFlags() == ["one": true, "two": false])
  }

  @Test("selection observation emits a baseline and committed mutations")
  func observationEmitsBaselineAndEachMutation() async throws {
    let fixture = try await Fixture(mode: .all)
    try await fixture.insertLibrary("one", included: true)
    try await fixture.insertLibrary("two", included: true)
    let observations = PersistenceObservationCollector(fixture.store.observeSelection())

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.mode == .all && $0.libraries.count == 2 }
      })

    try await fixture.store.setIncluded(false, libraryID: "two")
    #expect(
      await TestSupport.waitUntil {
        observations.contains {
          $0.mode == .selected
            && Dictionary(uniqueKeysWithValues: $0.libraries.map { ($0.serverLibraryID, $0.isIncluded) })
              == ["one": true, "two": false]
        }
      })

    try await fixture.store.setIncluded(true, libraryID: "two")
    #expect(
      await TestSupport.waitUntil {
        observations.contains {
          $0.mode == .selected && $0.libraries.allSatisfy(\.isIncluded)
        }
      })

    try await fixture.store.completeOnboarding(includedIDs: ["one"])
    #expect(
      await TestSupport.waitUntil {
        observations.contains {
          $0.mode == .selected
            && Dictionary(uniqueKeysWithValues: $0.libraries.map { ($0.serverLibraryID, $0.isIncluded) })
              == ["one": true, "two": false]
        }
      })
  }

  private struct Fixture {
    let database: AppDatabase
    let store: LibrarySelectionStore
    let accountID: Int64

    init(mode: LibrarySelectionMode) async throws {
      database = try AppDatabase.inMemory()
      accountID = try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: "https://example.com", serverUserId: "user",
          serverVersion: "2.35", librarySelectionMode: mode)
        try account.insert(db)
        guard let accountID = account.id else { throw FixtureError.accountInsertFailed }
        return accountID
      }
      store = LibrarySelectionStore(database: database)
    }

    func insertLibrary(_ id: String, accountID: Int64? = nil, included: Bool, softDeleted: Bool = false)
      async throws
    {
      try await database.writeAsync { db in
        var library = LibraryRecord(
          accountId: accountID ?? self.accountID, serverLibraryId: id, mediaType: "book", name: id,
          softDeleted: softDeleted, isIncluded: included)
        try library.insert(db)
      }
    }

    func insertAnotherAccount() async throws -> Int64 {
      try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: "https://other.example.com",
          serverUserId: "other", serverVersion: "2.35")
        try account.insert(db)
        return try #require(account.id)
      }
    }

    func inclusionFlags() async throws -> [String: Bool] {
      try await database.readAsync { db in
        Dictionary(
          uniqueKeysWithValues:
            try LibraryRecord
            .filter(Column("accountId") == accountID)
            .fetchAll(db)
            .map { ($0.serverLibraryId, $0.isIncluded) })
      }
    }
  }

  private enum FixtureError: Error { case accountInsertFailed }
}
