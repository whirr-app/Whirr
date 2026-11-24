import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// `DiagnosticsStore`, the Persistence-owned `DiagnosticsRecording` conformance (ARCHITECTURE.md
/// D16). Structured event kinds only: category, timing, status class and an optional endpoint
/// template. Never a payload, token or concrete URL.
@Suite struct DiagnosticsStoreTests {

  @Test func recordsEachStructuredEventCategoryWithTimingAndOptionalEndpointTemplate() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = DiagnosticsStore(database: database)

    let cases: [(DiagnosticsCategory, EndpointTemplate?)] = [
      (.syncRun, EndpointTemplate("/api/libraries/:id/items")),
      (.outboxTransition, nil),
      (.decodeDiagnostic, EndpointTemplate("/api/items/:id")),
      (.clockSkew, nil),
    ]

    for (category, endpoint) in cases {
      await store.record(
        DiagnosticsEvent(
          category: category, statusClass: .success, durationMilliseconds: 42,
          endpointTemplate: endpoint),
        accountId: accountId)
    }

    let stored = try store.fetchAll(accountId: accountId)
    #expect(stored.count == cases.count)
    #expect(stored.map(\.category) == cases.map(\.0))
    #expect(stored.map { $0.endpointTemplate?.path } == cases.map { $0.1?.path })
    #expect(stored.allSatisfy { $0.durationMilliseconds == 42 })
  }

  @Test func endpointTemplateRejectsConcreteURLsQueryStringsAndTokens() {
    #expect(EndpointTemplate("https://example.com/api/items/1?token=CANARY-SECRET") == nil)
    #expect(EndpointTemplate("/api/items/1?token=CANARY-SECRET") == nil)
    #expect(EndpointTemplate("CANARY-SECRET-PAYLOAD") == nil)
    #expect(EndpointTemplate("/api/items/1 CANARY-SECRET") == nil)
    #expect(EndpointTemplate("eyJhbGciOiJIUzI1NiJ9.CANARY.SECRET") == nil)
    #expect(EndpointTemplate("") == nil)
    #expect(EndpointTemplate("/api/libraries/:id/items") != nil)
  }

  /// The canary: a payload/token/concrete-URL string is pushed through every available field.
  /// `category`/`statusClass` are closed enums (the compiler enforces that, not this test) and
  /// `durationMilliseconds` is numeric. The one free-text field, the endpoint template, rejects
  /// the canary at construction, so the stored row never carries it.
  @Test func recordNeverStoresACanaryPassedThroughAnyAvailableField() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = DiagnosticsStore(database: database)
    let canary = "CANARY-TOKEN-\(UUID().uuidString)"

    let smuggledEndpoint = EndpointTemplate(
      "https://evil.example.com/\(canary)?token=\(canary)")
    #expect(smuggledEndpoint == nil)

    await store.record(
      DiagnosticsEvent(
        category: .decodeDiagnostic, statusClass: .clientError, durationMilliseconds: 7,
        endpointTemplate: smuggledEndpoint),
      accountId: accountId)

    let stored = try store.fetchAll(accountId: accountId)
    #expect(stored.count == 1)
    #expect(stored[0].endpointTemplate == nil)
    #expect(String(describing: stored).contains(canary) == false)
  }

  @Test func rollingCapEvictsOldestRowsBeyondN() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = DiagnosticsStore(database: database, cap: 3)

    for index in 0..<5 {
      await store.record(
        DiagnosticsEvent(
          category: .syncRun, statusClass: .success, durationMilliseconds: Double(index)),
        accountId: accountId)
    }

    let stored = try store.fetchAll(accountId: accountId)
    #expect(stored.count == 3)
    #expect(stored.map(\.durationMilliseconds) == [2, 3, 4])
  }

  @Test func deleteAllEmptiesDiagnosticsForTheAccount() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = DiagnosticsStore(database: database)

    await store.record(
      DiagnosticsEvent(category: .syncRun, statusClass: .success, durationMilliseconds: 1),
      accountId: accountId)
    await store.record(
      DiagnosticsEvent(category: .clockSkew, statusClass: .success, durationMilliseconds: 2),
      accountId: accountId)

    try store.deleteAll(accountId: accountId)

    #expect(try store.fetchAll(accountId: accountId).isEmpty)
  }

  @Test func exportProducesATextSummaryWithNoIdentifierCanaries() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = DiagnosticsStore(database: database)
    let canary = "CANARY-EXPORT-\(UUID().uuidString)"

    let smuggledEndpoint = EndpointTemplate("/\(canary)?token=\(canary)")
    #expect(smuggledEndpoint == nil)

    await store.record(
      DiagnosticsEvent(
        category: .outboxTransition, statusClass: .serverError, durationMilliseconds: 99,
        endpointTemplate: EndpointTemplate("/api/me/progress/:id")),
      accountId: accountId)

    let export = try store.export(accountId: accountId)
    #expect(export.contains(canary) == false)
    #expect(export.contains("outboxTransition"))
    #expect(export.contains("/api/me/progress/:id"))
  }

  /// Exercises the `ON DELETE CASCADE` foreign key on `diagnosticsEvent.accountId` directly.
  /// Deleting the account row must remove its diagnostics rows with no diagnostics-specific
  /// cleanup code, which is what lets a schema-driven account sweep pick this table up for free.
  @Test func accountRemovalCascadesDiagnosticsRows() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = DiagnosticsStore(database: database)

    await store.record(
      DiagnosticsEvent(category: .syncRun, statusClass: .success, durationMilliseconds: 1),
      accountId: accountId)

    try await database.writeAsync { db in
      _ = try AccountRecord.deleteOne(db, key: accountId)
    }

    #expect(try store.fetchAll(accountId: accountId).isEmpty)
  }

}
