import Foundation
import GRDB
import ReaderCore
import Testing

@testable import Persistence

@Suite struct ReaderPreferencesStoreTests {

  @Test("reader preferences round-trip every ReaderCore field")
  func roundTripsEveryField() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await Self.seedAccount(database, suffix: "round-trip")
    let store = ReaderPreferencesStore(database: database, accountId: accountId)
    let original = ReaderPreferences(
      theme: .sepia,
      fontFamily: .monospaced,
      fontSizeStep: 8,
      lineSpacingStep: 4,
      marginsStep: 3,
      readingMode: .scroll,
      reflowable: false
    )

    try await store.writePreferencesJSON(Self.json(for: original))

    let restored = try Self.decode(try #require(await store.fetchPreferencesJSON()))
    #expect(restored == original)
  }

  @Test("a first read uses the documented ReaderCore defaults")
  func firstReadUsesDefaults() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await Self.seedAccount(database, suffix: "defaults")
    let store = ReaderPreferencesStore(database: database, accountId: accountId)

    let raw = try await store.fetchPreferencesJSON(defaultingTo: Self.json(for: ReaderPreferences()))
    let restored = try Self.decode(raw)

    #expect(restored == ReaderPreferences())
    #expect(restored.theme == .system)
    #expect(restored.fontFamily == .publisherDefault)
    #expect(restored.fontSizeStep == ReaderPreferences.defaultFontSizeStep)
    #expect(restored.lineSpacingStep == ReaderPreferences.defaultLineSpacingStep)
    #expect(restored.marginsStep == ReaderPreferences.defaultMarginsStep)
    #expect(restored.readingMode == .paginated)
    #expect(restored.reflowable)
  }

  @Test("reader preferences are isolated per account")
  func accountIsolation() async throws {
    let database = try AppDatabase.inMemory()
    let firstAccount = try await Self.seedAccount(database, suffix: "first")
    let secondAccount = try await Self.seedAccount(database, suffix: "second")
    let firstStore = ReaderPreferencesStore(database: database, accountId: firstAccount)
    let secondStore = ReaderPreferencesStore(database: database, accountId: secondAccount)
    let first = ReaderPreferences(theme: .dark, readingMode: .scroll)
    let second = ReaderPreferences(theme: .light, fontFamily: .serif, fontSizeStep: 2)

    try await firstStore.writePreferencesJSON(Self.json(for: first))
    try await secondStore.writePreferencesJSON(Self.json(for: second))

    #expect(try Self.decode(try #require(await firstStore.fetchPreferencesJSON())) == first)
    #expect(try Self.decode(try #require(await secondStore.fetchPreferencesJSON())) == second)
  }

  @Test("removing an account cascades its reader preferences row")
  func accountRemovalCascadesReaderPreferences() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await Self.seedAccount(database, suffix: "removed")
    let store = ReaderPreferencesStore(database: database, accountId: accountId)

    try await store.writePreferencesJSON(Self.json(for: ReaderPreferences(theme: .sepia)))
    try AccountRemover(database: database).removeAccount(accountId: accountId)

    #expect(try await store.fetchPreferencesJSON() == nil)
    let rows = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM readerPreferences") ?? -1
    }
    #expect(rows == 0)
  }

  @Test("an older preference field set survives as a ReaderCore-compatible payload")
  func olderFieldSetRemainsDecodable() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await Self.seedAccount(database, suffix: "older")
    let store = ReaderPreferencesStore(database: database, accountId: accountId)
    let olderPayload =
      #"{"theme":"dark","fontFamily":"sansSerif","fontSizeStep":2,"lineSpacingStep":1,"marginsStep":3,"readingMode":"scroll","futureReaderPreference":"ignored"}"#

    try await store.writePreferencesJSON(olderPayload)

    let restored = try Self.decode(try #require(await store.fetchPreferencesJSON()))
    #expect(
      restored
        == ReaderPreferences(
          theme: .dark,
          fontFamily: .sansSerif,
          fontSizeStep: 2,
          lineSpacingStep: 1,
          marginsStep: 3,
          readingMode: .scroll,
          publisherStyles: false,
          reflowable: true))
  }

  @Test("a stored payload without alignment defaults to publisher-controlled text alignment")
  func preRV1PayloadLoadsWithPublisherControlledTextAlignment() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await Self.seedAccount(database, suffix: "pre-rv1")
    let store = ReaderPreferencesStore(database: database, accountId: accountId)
    let legacyPayload =
      #"{"theme":"light","fontFamily":"serif","fontSizeStep":3,"lineSpacingStep":2,"marginsStep":1,"readingMode":"scroll","reflowable":false}"#

    try await store.writePreferencesJSON(legacyPayload)

    let restored = try Self.decode(try #require(await store.fetchPreferencesJSON()))
    let expected = ReaderPreferences(
      theme: .light,
      fontFamily: .serif,
      fontSizeStep: 3,
      lineSpacingStep: 2,
      marginsStep: 1,
      readingMode: .scroll,
      publisherStyles: false,
      reflowable: false)

    #expect(restored == expected)
    #expect(restored.textAlignment == .publisherDefault)
  }

  private static func json(for preferences: ReaderPreferences) throws -> String {
    String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
  }

  private static func decode(_ json: String) throws -> ReaderPreferences {
    try JSONDecoder().decode(ReaderPreferences.self, from: Data(json.utf8))
  }

  @discardableResult
  private static func seedAccount(_ database: AppDatabase, suffix: String) async throws -> Int64 {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-reader-preferences-\(suffix)",
        serverBaseURL: "https://example.com",
        serverUserId: "reader-preferences-\(suffix)",
        serverVersion: "2.35.1")
      try account.insert(db)
      return try #require(account.id)
    }
  }
}
