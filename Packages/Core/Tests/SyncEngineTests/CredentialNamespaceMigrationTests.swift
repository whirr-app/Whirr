import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite struct CredentialNamespaceMigrationTests {
  private let serverURL = URL(string: "https://books.example.test")!
  private let tokens = TokenPair(accessToken: "access", refreshToken: "refresh")

  private func fixture() throws -> (AppDatabase, AccountRecord, InMemoryTokenStore) {
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "migration-uuid",
        serverBaseURL: serverURL.absoluteString,
        serverUserId: "user-1",
        serverVersion: "2.36.0"
      ))
    return (database, account, InMemoryTokenStore())
  }

  @Test func migratesLegacyPairAndIsIdempotent() throws {
    let (database, account, store) = try fixture()
    let legacy = try TokenAccount(serverURL: serverURL, userID: account.serverUserId)
    let namespace = try account.credentialTokenAccount
    try store.save(tokens, for: legacy)

    #expect(
      CredentialNamespaceMigration.run(accountDAO: AccountDAO(database: database), tokenStore: store) == .migrated)
    #expect(try store.load(for: namespace) == tokens)
    #expect(try store.load(for: legacy) == nil)
    #expect(
      CredentialNamespaceMigration.run(accountDAO: AccountDAO(database: database), tokenStore: store)
        == .alreadyMigrated)
  }

  /// A legacy pair left behind by an earlier run whose clear and compensating clear both failed
  /// is swept on a later launch; only account removal would otherwise ever reach it.
  @Test func alreadyMigratedSweepsALeftoverLegacyItem() throws {
    let (database, account, store) = try fixture()
    let legacy = try TokenAccount(serverURL: serverURL, userID: account.serverUserId)
    try store.save(tokens, for: account.credentialTokenAccount)
    try store.save(tokens, for: legacy)

    #expect(
      CredentialNamespaceMigration.run(accountDAO: AccountDAO(database: database), tokenStore: store)
        == .alreadyMigrated)
    #expect(try store.load(for: legacy) == nil)
    #expect(try store.load(for: account.credentialTokenAccount) == tokens)
  }

  @Test func aFailedSweepStillReportsAlreadyMigrated() throws {
    let (database, account, _) = try fixture()
    let legacy = try TokenAccount(serverURL: serverURL, userID: account.serverUserId)
    let store = FakeTokenStoring()
    store.stubClearFailure(FakeTokenStoring.Failure(), for: legacy)
    try store.save(tokens, for: account.credentialTokenAccount)
    try store.save(tokens, for: legacy)

    #expect(
      CredentialNamespaceMigration.run(accountDAO: AccountDAO(database: database), tokenStore: store)
        == .alreadyMigrated)
    #expect(try store.load(for: account.credentialTokenAccount) == tokens)
  }

  @Test func reportsNothingToMigrateWhenLegacyItemIsAbsent() throws {
    let (database, _, store) = try fixture()

    #expect(
      CredentialNamespaceMigration.run(accountDAO: AccountDAO(database: database), tokenStore: store)
        == .nothingToMigrate)
  }

  @Test func reportsNoAccount() throws {
    let database = try AppDatabase.inMemory()
    #expect(
      CredentialNamespaceMigration.run(
        accountDAO: AccountDAO(database: database), tokenStore: InMemoryTokenStore()) == .noAccount)
  }

  @Test func saveFailureLeavesBothItemsUntouched() throws {
    let (database, account, _) = try fixture()
    let store = FakeTokenStoring(saveFailure: FakeTokenStoring.Failure())
    let legacy = try TokenAccount(serverURL: serverURL, userID: account.serverUserId)
    store.seed(tokens, for: legacy)

    #expect(
      CredentialNamespaceMigration.run(accountDAO: AccountDAO(database: database), tokenStore: store)
        == .failed(step: .save))
    #expect(try store.load(for: legacy) == tokens)
    #expect(try store.load(for: account.credentialTokenAccount) == nil)
  }

  @Test func clearFailureLeavesBothItemsUntouched() throws {
    let (database, account, _) = try fixture()
    let legacy = try TokenAccount(serverURL: serverURL, userID: account.serverUserId)
    let store = FakeTokenStoring()
    store.stubClearFailure(FakeTokenStoring.Failure(), for: legacy)
    try store.save(tokens, for: legacy)

    #expect(
      CredentialNamespaceMigration.run(accountDAO: AccountDAO(database: database), tokenStore: store)
        == .failed(step: .clearLegacy))
    #expect(try store.load(for: legacy) == tokens)
    #expect(try store.load(for: account.credentialTokenAccount) == nil)
  }
}
