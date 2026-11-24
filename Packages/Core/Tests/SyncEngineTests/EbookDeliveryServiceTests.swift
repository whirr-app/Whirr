import ABSApi
import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// The account-lifetime device cache and the single-flight send.
@Suite struct EbookDeliveryServiceTests {
  @Test func noOpOffersNoDevicesAndSendsNothing() async {
    let delivery = NoOpEbookDelivering()

    #expect(await delivery.ereaderDevices().isEmpty)
    #expect(
      await delivery.sendEbook(itemID: "li_fixture", deviceName: "Kindle")
        == .notSent(.signInRequired))
  }

  @Test func devicesAreReadOnceAndCachedWithinTheMaximumAge() async throws {
    let clock = TestClock()
    let client = DeliveryClientStub(devices: [kindleWire])
    let service = try makeService(client: client, clock: clock)

    #expect(await service.ereaderDevices() == [kindle])
    clock.advance(by: EbookDeliveryService.defaultMaximumDeviceAge - 1)
    #expect(await service.ereaderDevices() == [kindle])
    #expect(await client.fetchCount == 1)

    clock.advance(by: 1)
    #expect(await service.ereaderDevices() == [kindle])
    #expect(await client.fetchCount == 2)
  }

  @Test func concurrentDeviceReadsShareOneRequest() async throws {
    let gate = Gate()
    let client = DeliveryClientStub(devices: [kindleWire], fetchGate: gate)
    let service = try makeService(client: client)

    async let first = service.ereaderDevices()
    async let second = service.ereaderDevices()
    _ = await awaitCondition("the device read reaches the client") {
      await client.fetchCount >= 1
    }
    await gate.release()

    #expect(await first == [kindle])
    #expect(await second == [kindle])
    #expect(await client.fetchCount == 1)
  }

  @Test func aFailedReadIsEmptyAndNotCached() async throws {
    let client = DeliveryClientStub(devices: [kindleWire], failingFetches: 1)
    let service = try makeService(client: client)

    #expect(await service.ereaderDevices().isEmpty)
    #expect(await service.ereaderDevices() == [kindle])
    #expect(await client.fetchCount == 2)
  }

  @Test func withoutAnAccountNothingIsReadOrSent() async throws {
    let client = DeliveryClientStub(devices: [kindleWire])
    let service = EbookDeliveryService(client: client, database: try AppDatabase.inMemory())

    #expect(await service.ereaderDevices().isEmpty)
    #expect(
      await service.sendEbook(itemID: "li_fixture", deviceName: "Kindle")
        == .notSent(.signInRequired))
    #expect(await client.fetchCount == 0)
    #expect(await client.sends.isEmpty)
  }

  @Test func aSignedOutAccountDoesNotSeeTheCachedList() async throws {
    let database = try databaseWithAccount()
    let client = DeliveryClientStub(devices: [kindleWire])
    let service = EbookDeliveryService(client: client, database: database)
    #expect(await service.ereaderDevices() == [kindle])

    try AccountDAO(database: database).delete()

    #expect(await service.ereaderDevices().isEmpty)
  }

  @Test func aReplacedAccountReadsItsOwnList() async throws {
    let database = try databaseWithAccount()
    let client = DeliveryClientStub(devices: [kindleWire])
    let service = EbookDeliveryService(client: client, database: database)
    #expect(await service.ereaderDevices() == [kindle])

    let accounts = AccountDAO(database: database)
    try accounts.delete()
    _ = try accounts.save(accountRecord(userID: "user_second"))
    await client.setDevices([pocketBookWire])

    #expect(await service.ereaderDevices() == [pocketBook])
    #expect(await client.fetchCount == 2)
  }

  @Test func aSendReachesTheClientOnceWithTheAccount() async throws {
    let client = DeliveryClientStub(devices: [], sendResult: .sent)
    let service = try makeService(client: client)

    let result = await service.sendEbook(itemID: "li_fixture", deviceName: "Kindle")

    #expect(result == .sent)
    let sends = await client.sends
    #expect(sends.map(\.itemID) == ["li_fixture"])
    #expect(sends.map(\.deviceName) == ["Kindle"])
    #expect(sends.map(\.userID) == ["user_fixture"])
  }

  @Test(arguments: [
    (EbookDeliveryResult.uncertain, EbookDeliveryOutcome.uncertain),
    (.notSent(.unreachable), .notSent(.unreachable)),
    (.notSent(.rejectedByMailServer), .notSent(.rejectedByMailServer)),
  ])
  func noResultIsRetried(result: EbookDeliveryResult, outcome: EbookDeliveryOutcome) async throws {
    let client = DeliveryClientStub(devices: [], sendResult: result)
    let service = try makeService(client: client)

    #expect(await service.sendEbook(itemID: "li_fixture", deviceName: "Kindle") == outcome)
    #expect(await client.sends.count == 1)
  }

  @Test func everyWireResultHasAnOutcome() {
    let cases: [(EbookDeliveryResult, EbookDeliveryOutcome)] = [
      (.sent, .sent),
      (.uncertain, .uncertain),
      (.notSent(.serverEmailUnavailable), .notSent(.serverEmailUnavailable)),
      (.notSent(.rejectedByMailServer), .notSent(.rejectedByMailServer)),
      (.notSent(.notPermitted), .notSent(.notPermitted)),
      (.notSent(.deviceNotFound), .notSent(.deviceNotFound)),
      (.notSent(.noEbookFile), .notSent(.noEbookFile)),
      (.notSent(.unreachable), .notSent(.unreachable)),
      (.notSent(.signInRequired), .notSent(.signInRequired)),
      (.notSent(.refused), .notSent(.refused)),
      (.notSent(.invalidRequest), .notSent(.refused)),
    ]
    for (result, outcome) in cases {
      #expect(EbookDeliveryOutcome(result) == outcome)
    }
  }

  @Test func aDoubleTapSendsOneEmail() async throws {
    let gate = Gate()
    let client = DeliveryClientStub(devices: [], sendResult: .sent, sendGate: gate)
    let service = try makeService(client: client)

    async let first = service.sendEbook(itemID: "li_fixture", deviceName: "Kindle")
    async let second = service.sendEbook(itemID: "li_fixture", deviceName: "Kindle")
    _ = await awaitCondition("the first send reaches the client") {
      await client.sends.count >= 1
    }
    _ = await awaitCondition("the second tap joins the first send") {
      await service.joinedSendCount >= 1
    }
    await gate.release()

    #expect(await first == .sent)
    #expect(await second == .sent)
    #expect(await client.sends.count == 1)
  }

  @Test func differentDevicesAreSeparateSends() async throws {
    let gate = Gate()
    let client = DeliveryClientStub(devices: [], sendResult: .sent, sendGate: gate)
    let service = try makeService(client: client)

    async let first = service.sendEbook(itemID: "li_fixture", deviceName: "Kindle")
    async let second = service.sendEbook(itemID: "li_fixture", deviceName: "PocketBook")
    _ = await awaitCondition("both sends reach the client") {
      await client.sends.count >= 2
    }
    await gate.release()

    _ = await (first, second)
    #expect(await client.sends.count == 2)
  }

  @Test func aCompletedSendDoesNotAbsorbTheNextOne() async throws {
    let client = DeliveryClientStub(devices: [], sendResult: .sent)
    let service = try makeService(client: client)

    _ = await service.sendEbook(itemID: "li_fixture", deviceName: "Kindle")
    _ = await service.sendEbook(itemID: "li_fixture", deviceName: "Kindle")

    #expect(await client.sends.count == 2)
  }

  @Test func aMissingDeviceDropsTheCachedList() async throws {
    let client = DeliveryClientStub(devices: [kindleWire], sendResult: .notSent(.deviceNotFound))
    let service = try makeService(client: client)
    #expect(await service.ereaderDevices() == [kindle])
    await client.setDevices([pocketBookWire])

    #expect(
      await service.sendEbook(itemID: "li_fixture", deviceName: kindle.name)
        == .notSent(.deviceNotFound))

    #expect(await service.ereaderDevices() == [pocketBook])
    #expect(await client.fetchCount == 2)
  }

  @Test func aReadStartedBeforeInvalidationDoesNotRepopulateTheCache() async throws {
    let gate = Gate()
    let client = DeliveryClientStub(
      devices: [kindleWire], sendResult: .notSent(.deviceNotFound), fetchGate: gate)
    let service = try makeService(client: client)

    async let staleRead = service.ereaderDevices()
    _ = await awaitCondition("the device read reaches the client") {
      await client.fetchCount >= 1
    }
    _ = await service.sendEbook(itemID: "li_fixture", deviceName: kindle.name)
    await gate.release()
    _ = await staleRead

    await client.setDevices([pocketBookWire])
    #expect(await service.ereaderDevices() == [pocketBook])
  }

  // MARK: - Fixtures

  private let kindle = EbookDeliveryDevice(name: "Rhys's Kindle")
  private let pocketBook = EbookDeliveryDevice(name: "PocketBook")
  private let kindleWire = EreaderDevice(name: "Rhys's Kindle")
  private let pocketBookWire = EreaderDevice(name: "PocketBook")

  private func makeService(
    client: DeliveryClientStub, clock: TestClock = TestClock()
  ) throws -> EbookDeliveryService {
    EbookDeliveryService(
      client: client, database: try databaseWithAccount(), now: { clock.now })
  }

  private func databaseWithAccount() throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(accountRecord(userID: "user_fixture"))
    return database
  }

  private func accountRecord(userID: String) -> AccountRecord {
    AccountRecord(
      clientUUID: "client-\(userID)",
      serverBaseURL: "https://books.example.test",
      serverUserId: userID,
      serverVersion: "2.35.1")
  }
}

private actor Gate {
  // Closed until released, then open for every later call; ignores cancellation like the client.
  private nonisolated let gate = TestGate<Void>(label: "Gate", ignoresCancellation: true)

  init() { gate.hold() }

  func wait() async { await gate.pass() }

  func release() { gate.release() }
}

private struct DeliveryStubError: Error {}

private actor DeliveryClientStub: EbookDeliveryClient {
  struct Send: Sendable {
    let userID: String
    let itemID: String
    let deviceName: String
  }

  private var devices: [EreaderDevice]
  private var failingFetches: Int
  private let sendResult: EbookDeliveryResult
  private let fetchGate: Gate?
  private let sendGate: Gate?
  private(set) var fetchCount = 0
  private(set) var sends: [Send] = []

  init(
    devices: [EreaderDevice],
    failingFetches: Int = 0,
    sendResult: EbookDeliveryResult = .sent,
    fetchGate: Gate? = nil,
    sendGate: Gate? = nil
  ) {
    self.devices = devices
    self.failingFetches = failingFetches
    self.sendResult = sendResult
    self.fetchGate = fetchGate
    self.sendGate = sendGate
  }

  func setDevices(_ devices: [EreaderDevice]) {
    self.devices = devices
  }

  func fetchEreaderDevices(
    account: TokenAccount, diagnostics: DecodeDiagnostics?
  ) async throws -> [EreaderDevice] {
    fetchCount += 1
    let snapshot = devices
    if let fetchGate { await fetchGate.wait() }
    if failingFetches > 0 {
      failingFetches -= 1
      throw DeliveryStubError()
    }
    return snapshot
  }

  func sendEbookToDevice(
    account: TokenAccount, libraryItemID: String, deviceName: String
  ) async -> EbookDeliveryResult {
    sends.append(Send(userID: account.userID, itemID: libraryItemID, deviceName: deviceName))
    if let sendGate { await sendGate.wait() }
    return sendResult
  }
}
