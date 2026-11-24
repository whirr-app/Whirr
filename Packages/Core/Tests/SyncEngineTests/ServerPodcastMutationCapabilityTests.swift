import ABSApi
import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite struct ServerPodcastMutationCapabilityTests {
  @Test func adminAndRootWithUpdateCanSave() {
    for type in ["admin", "root", " ADMIN ", "\nRoOt\t"] {
      let capability = ServerPodcastMutationCapability.derive(
        from: profile(type: type, update: true, delete: false))

      #expect(capability.canSave)
      #expect(capability.canRemove == false)
    }
  }

  @Test func rootWithUpdateAndDeleteCanSaveAndRemove() {
    let capability = ServerPodcastMutationCapability.derive(
      from: profile(type: "root", update: true, delete: true))

    #expect(capability == ServerPodcastMutationCapability(canSave: true, canRemove: true))
  }

  @Test func defaultAdminCannotRemoveWithoutDeletePermission() {
    for deletePermission in [false, nil] {
      let capability = ServerPodcastMutationCapability.derive(
        from: profile(type: "admin", update: true, delete: deletePermission))

      #expect(capability.canSave)
      #expect(capability.canRemove == false)
    }
  }

  @Test func unknownOrInactiveProfilesFailClosed() {
    let types: [String?] = ["user", "guest", nil, "", "operator", " admin-user "]
    for type in types {
      #expect(
        ServerPodcastMutationCapability.derive(
          from: profile(type: type, update: true, delete: true)) == .none)
    }

    #expect(
      ServerPodcastMutationCapability.derive(
        from: profile(type: "admin", active: false, update: true, delete: true)) == .none)
    #expect(
      ServerPodcastMutationCapability.derive(
        from: profile(type: "root", active: nil, update: true, delete: true)) == .none)
    #expect(
      ServerPodcastMutationCapability.derive(
        from: profile(type: "admin", update: nil, delete: true)) == .none)
  }

  @Test func noOpReaderReturnsNone() async {
    let reader = NoOpServerPodcastMutationCapabilityReading()

    #expect(await reader.capability() == .none)
    await reader.invalidate()
    #expect(await reader.capability() == .none)
  }

  @Test func serviceCachesSuccessAndInvalidateForcesARefetch() async throws {
    let database = try databaseWithAccount()
    let stub = ProfileStub(profile: profile(type: "admin", update: true, delete: false))
    let service = ServerPodcastMutationCapabilityService(client: stub, database: database)

    #expect(await service.capability().canSave)
    #expect(await service.capability().canRemove == false)
    #expect(await stub.fetchCount == 1)

    await service.invalidate()
    #expect(await service.capability().canSave)
    #expect(await stub.fetchCount == 2)
  }

  @Test func serviceCoalescesConcurrentProfileReads() async throws {
    let database = try databaseWithAccount()
    let gate = TestGate<Void>(label: "profile fetch", ignoresCancellation: true)
    gate.hold()
    let stub = ProfileStub(
      profile: profile(type: "root", update: true, delete: true), gate: gate)
    let service = ServerPodcastMutationCapabilityService(client: stub, database: database)

    let first = Task { await service.capability() }
    _ = await awaitCondition("the first capability read reaches the profile stub") {
      await stub.fetchCount > 0
    }
    let second = Task { await service.capability() }
    // The second caller must not raise the count. Nothing signals "a request that never happens",
    // so the count is watched until it settles rather than polled for a value.
    _ = await awaitQuiescence("the coalesced profile fetch count") { String(await stub.fetchCount) }

    #expect(await stub.fetchCount == 1)
    gate.release()
    #expect(await first.value == ServerPodcastMutationCapability(canSave: true, canRemove: true))
    #expect(await second.value == ServerPodcastMutationCapability(canSave: true, canRemove: true))
    #expect(await stub.fetchCount == 1)
  }

  @Test func failedProfileReadReturnsNoneAndIsNotCachedAsAGrant() async throws {
    let database = try databaseWithAccount()
    let stub = ProfileStub(
      profile: profile(type: "root", update: true, delete: true), shouldFail: true)
    let service = ServerPodcastMutationCapabilityService(client: stub, database: database)

    #expect(await service.capability() == .none)
    #expect(await service.capability() == .none)
    #expect(await stub.fetchCount == 2)
  }

  @Test func missingOrMalformedPersistedAccountReturnsNoneWithoutProfileRequest() async throws {
    let emptyDatabase = try AppDatabase.inMemory()
    let emptyStub = ProfileStub(profile: profile(type: "admin", update: true, delete: true))
    let emptyService = ServerPodcastMutationCapabilityService(
      client: emptyStub, database: emptyDatabase)
    #expect(await emptyService.capability() == .none)
    #expect(await emptyStub.fetchCount == 0)

    let malformedDatabase = try AppDatabase.inMemory()
    _ = try AccountDAO(database: malformedDatabase).save(
      AccountRecord(
        clientUUID: "client-fixture",
        serverBaseURL: "not a server identity",
        serverUserId: "user_fixture",
        serverVersion: "2.35.1"))
    let malformedStub = ProfileStub(profile: profile(type: "admin", update: true, delete: true))
    let malformedService = ServerPodcastMutationCapabilityService(
      client: malformedStub, database: malformedDatabase)

    #expect(await malformedService.capability() == .none)
    #expect(await malformedStub.fetchCount == 0)
  }

  private func profile(
    type: String?,
    active: Bool? = true,
    update: Bool? = nil,
    delete: Bool? = nil
  ) -> UserProfile {
    UserProfile(
      id: "profile-fixture",
      username: "fixture-user",
      type: type,
      isActive: active,
      isLocked: false,
      librariesAccessible: [],
      permissionsUpdate: update,
      permissionsDelete: delete)
  }

  private func databaseWithAccount() throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "client-fixture",
        serverBaseURL: "https://books.example.test",
        serverUserId: "user_fixture",
        serverVersion: "2.35.1"))
    return database
  }

}

private struct ProfileStubError: Error, Sendable {}

private actor ProfileStub: ServerPodcastMutationCapabilityProfileReading {
  private let profile: UserProfile
  private let gate: TestGate<Void>?
  private let shouldFail: Bool
  private(set) var fetchCount = 0

  init(
    profile: UserProfile,
    gate: TestGate<Void>? = nil,
    shouldFail: Bool = false
  ) {
    self.profile = profile
    self.gate = gate
    self.shouldFail = shouldFail
  }

  func fetchUserProfile(account: TokenAccount) async throws -> UserProfile {
    fetchCount += 1
    if let gate {
      await gate.pass()
    }
    if shouldFail {
      throw ProfileStubError()
    }
    return profile
  }
}
