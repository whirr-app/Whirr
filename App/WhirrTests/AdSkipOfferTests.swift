import AppModel
import Foundation
import Testing

@testable import Whirr

/// The one-time Reduce Ads offer in the expanded player.
@MainActor
@Suite("Ad skip offer")
struct AdSkipOfferTests {
  typealias Presentation = AdSkipOfferPresentation
  typealias Installer = AdSkipSettingsModelTests.Installer
  typealias Network = AdSkipSettingsModelTests.Network

  private static let presentable = Presentation.Inputs(
    status: .notEnabled, asset: .notInstalled, hasChosenSetting: false, isAnswered: false,
    showings: 0, isCountedLoad: false)

  private func presents(_ change: (inout Presentation.Inputs) -> Void = { _ in }) -> Bool {
    var inputs = Self.presentable
    change(&inputs)
    return Presentation.shouldPresent(inputs)
  }

  private func defaults() throws -> UserDefaults {
    let name = "AdSkipOfferTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private func model(
    _ installer: Installer, network: Network = Network(), defaults: UserDefaults
  ) -> AdSkipSettingsModel {
    AdSkipSettingsModel(
      installer: installer, network: network, defaults: defaults, onInstalled: {}, onForget: {})
  }

  @Test("offered for an episode analysis would cover, with the setting off and never chosen")
  func presentsWhenActionable() {
    #expect(presents())
  }

  @Test("only the off-and-covered status offers")
  func otherStatusesDoNotOffer() {
    for status in [PlaybackAdAnalysisStatus.none, .checking, .waiting(.conditions), .waiting(.speechModel)] {
      #expect(presents { $0.status = status } == false)
    }
  }

  @Test("every asset state it can be acted on from offers; unread and unavailable do not")
  func assetStates() {
    for asset in [AdSkipSettingsModel.Asset.notInstalled, .failed, .installed, .downloading(nil), .waitingForWiFi] {
      #expect(presents { $0.asset = asset })
    }
    #expect(presents { $0.asset = .checking } == false)
    #expect(presents { $0.asset = .unavailable } == false)
  }

  @Test("a listener who has already chosen, either way and on any device, is not offered")
  func chosenIsNotOffered() {
    #expect(presents { $0.hasChosenSetting = true } == false)
  }

  @Test("answered is for good")
  func answeredIsNotOffered() {
    #expect(presents { $0.isAnswered = true } == false)
  }

  @Test("three counted showings, and the third stays up for its own load")
  func showingCount() {
    #expect(presents { $0.showings = 2 })
    #expect(presents { $0.showings = 3 } == false)
    #expect(
      presents {
        $0.showings = 3
        $0.isCountedLoad = true
      })
  }

  @Test("the store counts each load once, and reads the setting's key as the choice")
  func store() throws {
    let defaults = try defaults()
    let store = AdSkipOfferStore(defaults: defaults)
    #expect(store.showings == 0)
    #expect(store.isAnswered == false)
    #expect(store.hasChosenSetting == false)

    store.noteShown(forLoad: "show/a")
    store.noteShown(forLoad: "show/a")
    #expect(store.showings == 1)
    #expect(store.isCounted(load: "show/a"))
    store.noteShown(forLoad: "show/b")
    #expect(store.showings == 2)
    #expect(store.isCounted(load: "show/a") == false)

    // A relaunch counts the restored episode again.
    AdSkipOfferStore(defaults: defaults).noteShown(forLoad: "show/b")
    #expect(store.showings == 3)

    store.markAnswered()
    #expect(AdSkipOfferStore(defaults: defaults).isAnswered)

    defaults.set(false, forKey: AdSkipPreference.key)
    #expect(store.hasChosenSetting)
  }

  @Test("with the speech model installed, Turn On turns the setting on without asking")
  func acceptWithModelInstalled() async throws {
    let defaults = try defaults()
    let model = model(Installer(.installed), defaults: defaults)
    await model.refresh()
    var asked = false
    Presentation.accept(on: model) { asked = true }
    #expect(asked == false)
    #expect(AdSkipPreference.isEnabled(in: defaults))
    #expect(AdSkipOfferStore(defaults: defaults).hasChosenSetting)
  }

  @Test("without the model, Turn On asks, through the offer and not the shared Settings prompt")
  func acceptWithoutModelAsks() async throws {
    let defaults = try defaults()
    let model = model(Installer(.notInstalled), defaults: defaults)
    await model.refresh()
    var asked = false
    Presentation.accept(on: model) { asked = true }
    #expect(asked)
    #expect(model.isConfirmingDownload == false)
    #expect(AdSkipPreference.isEnabled(in: defaults) == false)
    #expect(AdSkipOfferStore(defaults: defaults).hasChosenSetting == false)
  }

  @Test("confirming downloads on the chosen network and turns the setting on")
  func confirmDownloads() async throws {
    let defaults = try defaults()
    let installer = Installer(.notInstalled)
    let model = model(installer, defaults: defaults)
    await model.refresh()
    Presentation.confirmDownload(on: model, allowingCellular: true)
    await model.waitForDownload()
    #expect(installer.installs.withLock { $0 } == 1)
    #expect(AdSkipPreference.isEnabled(in: defaults))
  }

  @Test("a prompt confirmed after a download began turns the setting on without restarting it")
  func confirmAfterDownloadBegan() async throws {
    let defaults = try defaults()
    let network = Network()
    let model = model(Installer(.notInstalled), network: network, defaults: defaults)
    await model.refresh()
    // Settings started a Wi-Fi download while the offer's prompt was up.
    model.confirmDownload(allowingCellular: false)
    #expect(model.asset == .waitingForWiFi)
    defaults.removeObject(forKey: AdSkipPreference.key)

    Presentation.confirmDownload(on: model, allowingCellular: true)

    #expect(model.asset == .waitingForWiFi)
    #expect(network.waits.withLock { $0 } <= 1)
    #expect(AdSkipPreference.isEnabled(in: defaults))
    network.connect()
    await model.waitForDownload()
  }

  @Test("the offer's keys stay on this device")
  func keysStayLocal() {
    let synced = Set(ICloudSettingsSync.syncedKeys)
    #expect(synced.contains(AdSkipOfferStore.answeredKey) == false)
    #expect(synced.contains(AdSkipOfferStore.showingsKey) == false)
  }

  @Test("the overlay offers only in the off-and-covered state, after the receipt and the status")
  func overlayOrder() throws {
    let root = ViewSourceScan.repositoryRoot()
    let text = try ViewSourceScan.executableText(
      of: root.appending(path: "App/Whirr/AdSkip/AdSkipReceipt.swift"))
    let receipt = try #require(text.range(of: "if let receipt = visible"))
    let status = try #require(text.range(of: "} else if let status {"))
    let offer = try #require(text.range(of: "} else if playback.adAnalysisStatus == .notEnabled {"))
    #expect(receipt.lowerBound < status.lowerBound)
    #expect(status.lowerBound < offer.lowerBound)
  }
}
