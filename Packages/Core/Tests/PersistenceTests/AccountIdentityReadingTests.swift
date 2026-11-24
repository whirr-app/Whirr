import Testing

@testable import Persistence

@Suite struct AccountIdentityReadingTests {
  @Test func observesAccountIdentityChangesAndSuppressesUnchangedProjection() async throws {
    let database = try AppDatabase.inMemory()
    let accountDAO = AccountDAO(database: database)
    let reading = DefaultAccountIdentityReading(database: database)
    var iterator = reading.observeAccountIdentity().makeAsyncIterator()

    #expect(await iterator.next() == .some(nil))

    let firstRecord = try accountDAO.save(
      AccountRecord(
        clientUUID: "client-a",
        serverBaseURL: "https://identity-a.invalid",
        serverUserId: "user-a",
        serverVersion: "1",
        defaultLibraryId: "library-a"))
    let first = try #require(AccountIdentity(record: firstRecord))
    #expect(await iterator.next() == first)

    var unchangedRecord = firstRecord
    unchangedRecord.serverVersion = "2"
    unchangedRecord.defaultLibraryId = "library-b"
    _ = try accountDAO.save(unchangedRecord)

    var changedRecord = unchangedRecord
    changedRecord.clientUUID = "client-b"
    let savedChangedRecord = try accountDAO.save(changedRecord)
    let changed = try #require(AccountIdentity(record: savedChangedRecord))
    #expect(await iterator.next() == changed)
    #expect(changed.clientUUID == "client-b")
    #expect(changed.serverIdentityFingerprint == first.serverIdentityFingerprint)

    try accountDAO.delete()
    #expect(await iterator.next() == .some(nil))

    let replacementRecord = try accountDAO.save(
      AccountRecord(
        clientUUID: "client-c",
        serverBaseURL: "https://identity-a.invalid",
        serverUserId: "user-b",
        serverVersion: "1",
        defaultLibraryId: "library-a"))
    let replacement = try #require(AccountIdentity(record: replacementRecord))
    #expect(await iterator.next() == replacement)
    #expect(replacement != first)

    var reauthenticatedRecord = replacementRecord
    reauthenticatedRecord.serverVersion = "3"
    let resaved = try accountDAO.save(reauthenticatedRecord)
    #expect(AccountIdentity(record: resaved) == replacement)
  }

  @Test func identityUsesTheSameOpaqueFingerprintAsTheAttemptFence() throws {
    let record = AccountRecord(
      id: 42,
      clientUUID: "client-a",
      serverBaseURL: "https://identity-a.invalid",
      serverUserId: "user-a",
      serverVersion: "1")

    let identity = try #require(AccountIdentity(record: record))
    #expect(
      identity.serverIdentityFingerprint
        == record.serverIdentityFingerprint)
  }

  @Test func changingActiveEndpointDoesNotChangeIdentityButUserDoes() throws {
    let record = AccountRecord(
      id: 42,
      clientUUID: "client-a",
      serverBaseURL: "https://identity-a.invalid",
      serverUserId: "user-a",
      serverVersion: "1")
    let identity = try #require(AccountIdentity(record: record))

    var changedEndpoint = record
    changedEndpoint.serverBaseURL = "https://identity-b.invalid"
    #expect(AccountIdentity(record: changedEndpoint) == identity)

    var changedUser = changedEndpoint
    changedUser.serverUserId = "user-b"
    #expect(AccountIdentity(record: changedUser) != identity)
  }
}
