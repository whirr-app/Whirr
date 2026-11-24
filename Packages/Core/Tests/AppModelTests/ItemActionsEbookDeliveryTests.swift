import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The book menu's Send to E-reader entry and its feedback.
@MainActor
@Suite struct ItemActionsEbookDeliveryTests {
  private let kindle = EbookDeliveryDevice(name: "Rhys's Kindle")
  private let pocketBook = EbookDeliveryDevice(name: "PocketBook")

  // MARK: - Menu policy

  @Test func noDevicesMeansNoEntry() {
    for capability in [ItemMediaCapability.ebook, .audioAndEbook, .unsupportedDocument] {
      #expect(EbookDeliveryMenuEntry.resolve(capability: capability, devices: []) == nil)
    }
  }

  @Test func itemsWithoutAnEbookFileNeverOfferIt() {
    for capability in [ItemMediaCapability.audio, .podcast] {
      #expect(EbookDeliveryMenuEntry.resolve(capability: capability, devices: [kindle]) == nil)
    }
  }

  @Test func documentsWhirrCannotOpenCanStillBeSent() {
    #expect(
      EbookDeliveryMenuEntry.resolve(capability: .unsupportedDocument, devices: [kindle])
        == .single(kindle))
  }

  @Test func oneDeviceIsARowAndSeveralAreASubmenuInServerOrder() {
    #expect(
      EbookDeliveryMenuEntry.resolve(capability: .ebook, devices: [kindle]) == .single(kindle))
    #expect(
      EbookDeliveryMenuEntry.resolve(capability: .audioAndEbook, devices: [pocketBook, kindle])
        == .submenu([pocketBook, kindle]))
  }

  @Test func rowTitlesUseTheServersLabel() {
    #expect(EbookDeliveryCopy.sendTo(kindle.name) == "Send to Rhys's Kindle")
  }

  // MARK: - Device list

  @Test func devicesAreEmptyUntilLoaded() async {
    let delivery = DeliveryFake(devices: [kindle])
    let model = makeModel(delivery: delivery)

    #expect(model.ereaderDevices.isEmpty)
    await model.loadEreaderDevicesIfNeeded()
    #expect(model.ereaderDevices == [kindle])
  }

  @Test func overlappingLoadsAskTheServiceOnce() async {
    let delivery = DeliveryFake(devices: [kindle])
    let model = makeModel(delivery: delivery)

    async let first: Void = model.loadEreaderDevicesIfNeeded()
    async let second: Void = model.loadEreaderDevicesIfNeeded()
    _ = await (first, second)

    #expect(await delivery.deviceReads == 1)
    #expect(model.ereaderDevices == [kindle])
  }

  @Test func eachLaterLoadAsksAgainSoTheServiceDecidesFreshness() async {
    let delivery = DeliveryFake(devices: [kindle])
    let model = makeModel(delivery: delivery)

    await model.loadEreaderDevicesIfNeeded()
    await delivery.setDevices([pocketBook])
    await model.loadEreaderDevicesIfNeeded()

    #expect(await delivery.deviceReads == 2)
    #expect(model.ereaderDevices == [pocketBook])
  }

  // MARK: - Sending

  @Test func aSuccessfulSendConfirmsWithABanner() async {
    let delivery = DeliveryFake(devices: [kindle], outcome: .sent)
    let model = makeModel(delivery: delivery)

    await model.sendEbook(itemID: "li_fixture", deviceName: kindle.name)

    #expect(model.ebookDeliveryFeedbackMessage == "Sent to Rhys's Kindle")
    #expect(model.actionErrorMessage == nil)
    #expect(await delivery.sends == ["li_fixture|Rhys's Kindle"])
  }

  @Test(arguments: [
    EbookDeliveryOutcome.NotSentReason.serverEmailUnavailable, .rejectedByMailServer,
    .notPermitted, .deviceNotFound, .noEbookFile, .unreachable, .signInRequired, .refused,
  ])
  func aFailedSendRaisesTheScreensAlert(reason: EbookDeliveryOutcome.NotSentReason) async {
    let delivery = DeliveryFake(devices: [kindle], outcome: .notSent(reason))
    let model = makeModel(delivery: delivery)

    await model.sendEbook(itemID: "li_fixture", deviceName: kindle.name)

    #expect(model.ebookDeliveryFeedbackMessage == nil)
    #expect(model.actionErrorMessage == EbookDeliveryCopy.notSent(reason, deviceName: kindle.name))
  }

  @Test func anUncertainSendSaysSoAndWarnsAgainstRetrying() async {
    let delivery = DeliveryFake(devices: [kindle], outcome: .uncertain)
    let model = makeModel(delivery: delivery)

    await model.sendEbook(itemID: "li_fixture", deviceName: kindle.name)

    let message = model.actionErrorMessage
    #expect(message == EbookDeliveryCopy.uncertain(deviceName: kindle.name))
    #expect(message?.contains("may still arrive") == true)
    #expect(model.ebookDeliveryFeedbackMessage == nil)
  }

  @Test func failureCopyNamesTheDeviceWhereItMatters() {
    #expect(
      EbookDeliveryCopy.notSent(.deviceNotFound, deviceName: "Kindle")
        == "Kindle is no longer set up on the server.")
    #expect(
      EbookDeliveryCopy.notSent(.notPermitted, deviceName: "Kindle")
        == "You don't have access to Kindle.")
    #expect(
      EbookDeliveryCopy.notSent(.unreachable, deviceName: "Kindle")
        == "Couldn't reach the server. Nothing was sent.")
  }

  @Test func aMissingDeviceRefreshesTheList() async {
    let delivery = DeliveryFake(devices: [kindle], outcome: .notSent(.deviceNotFound))
    let model = makeModel(delivery: delivery)
    await model.loadEreaderDevicesIfNeeded()
    await delivery.setDevices([pocketBook])

    await model.sendEbook(itemID: "li_fixture", deviceName: kindle.name)

    #expect(model.ereaderDevices == [pocketBook])
  }

  @Test func onlyTheSendingDeviceIsBusyWhileInFlight() async {
    let gate = TestGate<Void>(label: "DeliveryFake sendEbook", ignoresCancellation: true)
    gate.hold()
    let delivery = DeliveryFake(devices: [kindle, pocketBook], outcome: .sent, gate: gate)
    let model = makeModel(delivery: delivery)

    let send = Task { await model.sendEbook(itemID: "li_fixture", deviceName: kindle.name) }
    _ = await awaitCondition("the send is in flight") {
      model.isSendingEbook(itemID: "li_fixture", deviceName: kindle.name)
    }
    #expect(model.isSendingEbook(itemID: "li_fixture", deviceName: pocketBook.name) == false)
    #expect(model.isSendingEbook(itemID: "li_other", deviceName: kindle.name) == false)

    gate.release()
    await send.value
    #expect(model.isSendingEbook(itemID: "li_fixture", deviceName: kindle.name) == false)
  }

  @Test func aRepeatedTapWhileInFlightIsIgnored() async {
    let gate = TestGate<Void>(label: "DeliveryFake sendEbook", ignoresCancellation: true)
    gate.hold()
    let delivery = DeliveryFake(devices: [kindle], outcome: .sent, gate: gate)
    let model = makeModel(delivery: delivery)

    let first = Task { await model.sendEbook(itemID: "li_fixture", deviceName: kindle.name) }
    _ = await awaitCondition("the send is in flight") {
      model.isSendingEbook(itemID: "li_fixture", deviceName: kindle.name)
    }
    await model.sendEbook(itemID: "li_fixture", deviceName: kindle.name)
    gate.release()
    await first.value

    #expect(await delivery.sends.count == 1)
  }

  @Test func dismissingTheBannerClearsIt() async {
    let model = makeModel(delivery: DeliveryFake(devices: [kindle], outcome: .sent))
    await model.sendEbook(itemID: "li_fixture", deviceName: kindle.name)

    model.dismissEbookDeliveryFeedback()

    #expect(model.ebookDeliveryFeedbackMessage == nil)
  }

  @Test func theDefaultModelHasNoDevices() async {
    let model = ItemActionsModel(
      downloadStatus: DownloadStatusStore(downloadReading: NoOpDownloadReading()),
      downloadIntents: NoOpDownloadIntents(),
      progressIntents: NoOpItemProgressIntents(),
      extrasAccess: NoOpItemDetailExtrasAccess())

    await model.loadEreaderDevicesIfNeeded()

    #expect(model.ereaderDevices.isEmpty)
  }

  private func makeModel(delivery: DeliveryFake) -> ItemActionsModel {
    ItemActionsModel(
      downloadStatus: DownloadStatusStore(downloadReading: NoOpDownloadReading()),
      downloadIntents: NoOpDownloadIntents(),
      progressIntents: NoOpItemProgressIntents(),
      extrasAccess: NoOpItemDetailExtrasAccess(),
      ebookDelivery: delivery)
  }
}

private actor DeliveryFake: EbookDelivering {
  private var devices: [EbookDeliveryDevice]
  private let outcome: EbookDeliveryOutcome
  private let gate: TestGate<Void>?
  private(set) var deviceReads = 0
  private(set) var sends: [String] = []

  init(
    devices: [EbookDeliveryDevice], outcome: EbookDeliveryOutcome = .sent, gate: TestGate<Void>? = nil
  ) {
    self.devices = devices
    self.outcome = outcome
    self.gate = gate
  }

  func setDevices(_ devices: [EbookDeliveryDevice]) {
    self.devices = devices
  }

  func ereaderDevices() async -> [EbookDeliveryDevice] {
    deviceReads += 1
    await Task.yield()
    return devices
  }

  func sendEbook(itemID: String, deviceName: String) async -> EbookDeliveryOutcome {
    sends.append("\(itemID)|\(deviceName)")
    if let gate { await gate.pass() }
    return outcome
  }
}
