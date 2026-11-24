import AppModel
import Foundation
import PlayerCore
import Synchronization
import Testing

@testable import Whirr

/// The Reduce Ads setting: hidden without a recogniser, consent before the speech model
/// downloads, Wi-Fi unless the listener says otherwise, retry, and Forget.
@MainActor
@Suite("Ad skip settings")
struct AdSkipSettingsModelTests {

  nonisolated final class Installer: SpeechAssetInstalling, Sendable {
    let current: Mutex<SpeechAssetState>
    let installs = Mutex(0)
    let failure = Mutex<(any Error)?>(nil)

    init(_ state: SpeechAssetState) { current = Mutex(state) }

    func state() async -> SpeechAssetState { current.withLock { $0 } }

    func install(progress: @Sendable (Progress) -> Void) async throws {
      installs.withLock { $0 += 1 }
      if let error = failure.withLock({ $0 }) { throw error }
      current.withLock { $0 = .installed }
    }
  }

  /// Opens only when `connect()` is called, so a test can see the model waiting.
  nonisolated final class Network: UnmeteredNetworkWaiting, Sendable {
    let waits = Mutex(0)
    private let gate = AsyncStream<Void>.makeStream()

    func waitForUnmeteredNetwork() async throws {
      waits.withLock { $0 += 1 }
      for await _ in gate.stream { return }
      throw CancellationError()
    }

    func connect() { gate.continuation.yield() }
  }

  struct Failure: Error {}

  final class Calls {
    var installed = 0
    var forgotten = 0
  }

  private func defaults() throws -> UserDefaults {
    let name = "AdSkipSettingsModelTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private func model(
    _ installer: Installer, network: Network = Network(), defaults: UserDefaults, calls: Calls
  ) -> AdSkipSettingsModel {
    AdSkipSettingsModel(
      installer: installer, network: network, defaults: defaults,
      systemDownloadPollInterval: .milliseconds(10),
      onInstalled: { calls.installed += 1 }, onForget: { calls.forgotten += 1 })
  }

  @Test("hidden until read, and for good without a recogniser")
  func hiddenWithoutARecogniser() async throws {
    let model = model(Installer(.unavailable), defaults: try defaults(), calls: Calls())
    #expect(model.isVisible == false)
    await model.refresh()
    #expect(model.isVisible == false)
  }

  @Test("with the model installed the toggle turns on at once")
  func installedTurnsOnDirectly() async throws {
    let defaults = try defaults()
    let model = model(Installer(.installed), defaults: defaults, calls: Calls())
    await model.refresh()
    #expect(model.isVisible)
    model.setToggle(true)
    #expect(model.isConfirmingDownload == false)
    #expect(AdSkipPreference.isEnabled(in: defaults))
  }

  @Test("without the model, turning on asks first and cancelling leaves it off")
  func askingBeforeDownloading() async throws {
    let defaults = try defaults()
    let installer = Installer(.notInstalled)
    let model = model(installer, defaults: defaults, calls: Calls())
    await model.refresh()

    model.setToggle(true)
    #expect(model.isConfirmingDownload)
    #expect(model.isToggleOn)
    #expect(AdSkipPreference.isEnabled(in: defaults) == false)

    model.cancelDownloadConfirmation()
    #expect(model.isToggleOn == false)
    #expect(AdSkipPreference.isEnabled(in: defaults) == false)
    #expect(installer.installs.withLock { $0 } == 0)
  }

  @Test("download on Wi-Fi waits for it, then installs and wakes analysis")
  func downloadWaitsForWiFi() async throws {
    let defaults = try defaults()
    let installer = Installer(.notInstalled)
    let network = Network()
    let calls = Calls()
    let model = model(installer, network: network, defaults: defaults, calls: calls)
    await model.refresh()

    model.setToggle(true)
    model.confirmDownload(allowingCellular: false)
    #expect(AdSkipPreference.isEnabled(in: defaults))
    #expect(model.asset == .waitingForWiFi)
    #expect(installer.installs.withLock { $0 } == 0)

    network.connect()
    await model.waitForDownload()
    #expect(installer.installs.withLock { $0 } == 1)
    #expect(model.asset == .installed)
    #expect(calls.installed == 1)
  }

  @Test("download now does not wait for Wi-Fi")
  func downloadNowSkipsTheWait() async throws {
    let installer = Installer(.notInstalled)
    let network = Network()
    let model = model(installer, network: network, defaults: try defaults(), calls: Calls())
    await model.refresh()

    model.confirmDownload(allowingCellular: true)
    await model.waitForDownload()
    #expect(network.waits.withLock { $0 } == 0)
    #expect(model.asset == .installed)
  }

  @Test("a failed download offers a retry that can succeed")
  func failureThenRetry() async throws {
    let installer = Installer(.notInstalled)
    installer.failure.withLock { $0 = Failure() }
    let calls = Calls()
    let model = model(installer, defaults: try defaults(), calls: calls)
    await model.refresh()

    model.confirmDownload(allowingCellular: true)
    await model.waitForDownload()
    #expect(model.asset == .failed)
    #expect(calls.installed == 0)

    installer.failure.withLock { $0 = nil }
    model.retry()
    await model.waitForDownload()
    #expect(model.asset == .installed)
    #expect(calls.installed == 1)
  }

  @Test("turning off while waiting stops the download and the setting")
  func turningOffStopsTheWait() async throws {
    let defaults = try defaults()
    let installer = Installer(.notInstalled)
    let model = model(installer, defaults: defaults, calls: Calls())
    await model.refresh()

    model.confirmDownload(allowingCellular: false)
    model.setToggle(false)
    #expect(AdSkipPreference.isEnabled(in: defaults) == false)
    #expect(model.asset == .notInstalled)
    #expect(installer.installs.withLock { $0 } == 0)
  }

  @Test("on from another device without the model offers the download")
  func syncedOnOffersTheDownload() async throws {
    let defaults = try defaults()
    defaults.set(true, forKey: AdSkipPreference.key)
    let model = model(Installer(.notInstalled), defaults: defaults, calls: Calls())
    await model.refresh()
    #expect(model.isEnabled)
    #expect(model.asset == .notInstalled)
  }

  @Test("forget runs only once confirmed")
  func forgetIsConfirmed() async throws {
    let calls = Calls()
    let model = model(Installer(.installed), defaults: try defaults(), calls: calls)
    model.isConfirmingForget = true
    #expect(calls.forgotten == 0)
    model.confirmForget()
    #expect(calls.forgotten == 1)
    #expect(model.isConfirmingForget == false)
  }

  @Test("the setting syncs through iCloud")
  func settingSyncs() {
    #expect(ICloudSettingsSync.syncedKeys.contains(AdSkipPreference.key))
  }

  @Test("a refresh while waiting for Wi-Fi leaves the wait alone")
  func refreshDuringTheWait() async throws {
    let model = model(Installer(.notInstalled), defaults: try defaults(), calls: Calls())
    await model.refresh()
    model.confirmDownload(allowingCellular: false)
    await model.refresh()
    #expect(model.asset == .waitingForWiFi)
  }

  @Test("a refresh after a failure keeps offering the retry")
  func refreshKeepsTheFailure() async throws {
    let installer = Installer(.notInstalled)
    installer.failure.withLock { $0 = Failure() }
    let model = model(installer, defaults: try defaults(), calls: Calls())
    await model.refresh()
    model.confirmDownload(allowingCellular: true)
    await model.waitForDownload()
    await model.refresh()
    #expect(model.asset == .failed)
  }

  @Test("a download already under way is followed until it finishes")
  func followsADownloadItDidNotStart() async throws {
    let defaults = try defaults()
    defaults.set(true, forKey: AdSkipPreference.key)
    let installer = Installer(.downloading)
    let calls = Calls()
    let model = model(installer, defaults: defaults, calls: calls)
    await model.refresh()
    #expect(model.asset == .downloading(nil))

    installer.current.withLock { $0 = .installed }
    await model.waitForDownload()
    #expect(model.asset == .installed)
    #expect(calls.installed == 1)
    #expect(installer.installs.withLock { $0 } == 0)
  }

  @Test("turning off stops following a download under way")
  func turningOffStopsFollowing() async throws {
    let installer = Installer(.downloading)
    let calls = Calls()
    let model = model(installer, defaults: try defaults(), calls: calls)
    await model.refresh()
    model.setToggle(false)
    #expect(model.asset == .notInstalled)
    #expect(calls.installed == 0)
  }

  // MARK: - Progress

  @Test("the page follows the coordinator's progress")
  func followsProgress() async throws {
    let updates = AsyncStream<AdSkipProgress?>.makeStream()
    let model = AdSkipSettingsModel(
      installer: Installer(.installed), network: Network(), defaults: try defaults(),
      progressUpdates: { updates.stream }, onInstalled: {}, onForget: {})
    let working = AdSkipProgress(analysed: 3, unanalysable: 0, total: 5, activity: .analysing)
    updates.continuation.yield(working)
    updates.continuation.yield(nil)
    updates.continuation.yield(working)
    updates.continuation.finish()

    await model.followProgress()
    #expect(model.progress == working)
  }

  @Test("progress reads as a count of analysed episodes, with what is happening to the rest")
  func progressCopy() {
    func copy(_ analysed: Int, _ unanalysable: Int, _ total: Int, _ activity: AdSkipProgress.Activity)
      -> AdSkipProgressCopy.Status
    {
      AdSkipProgressCopy.status(
        for: AdSkipProgress(
          analysed: analysed, unanalysable: unanalysable, total: total, activity: activity))
    }
    #expect(copy(0, 0, 0, .idle) == .init(title: "No downloaded episodes to analyse", detail: nil))
    #expect(copy(12, 0, 14, .analysing) == .init(title: "12 of 14 episodes analysed", detail: "Analysing…"))
    #expect(copy(1, 0, 1, .idle) == .init(title: "1 of 1 episode analysed", detail: nil))
    #expect(copy(2, 0, 3, .paused) == .init(title: "2 of 3 episodes analysed", detail: "Paused"))
    // Every episode counts, but windows remain on some: the work is still shown.
    #expect(
      copy(3, 0, 3, .analysing)
        == .init(title: "3 of 3 episodes analysed", detail: "Checking for more ads…"))
    #expect(copy(3, 0, 3, .paused) == .init(title: "3 of 3 episodes analysed", detail: "Paused"))
    #expect(
      copy(13, 1, 14, .idle)
        == .init(title: "13 of 14 episodes analysed", detail: "1 couldn’t be analysed"))
    #expect(
      copy(10, 2, 14, .analysing)
        == .init(title: "10 of 14 episodes analysed", detail: "Analysing… · 2 couldn’t be analysed"))
  }

  @Test("the root row's detail says what Reduce Ads is doing right now")
  func rowDetail() {
    func detail(
      enabled: Bool = true, asset: AdSkipSettingsModel.Asset = .installed,
      progress: AdSkipProgress? = nil, pauseReason: AdSkipPauseReason? = nil
    ) -> String {
      AdSkipSettingsCopy.rowDetail(
        isEnabled: enabled, asset: asset, progress: progress, pauseReason: pauseReason)
    }
    func progress(_ analysed: Int, _ total: Int, _ activity: AdSkipProgress.Activity)
      -> AdSkipProgress
    {
      AdSkipProgress(analysed: analysed, unanalysable: 0, total: total, activity: activity)
    }

    #expect(detail(enabled: false) == "Skips ads in downloaded episodes")
    #expect(detail(enabled: false, asset: .downloading(0.5)) == "Skips ads in downloaded episodes")
    #expect(detail() == "Skips ads in downloaded episodes", "no count heard yet")
    #expect(detail(asset: .notInstalled) == "Speech model needed")
    #expect(detail(asset: .waitingForWiFi) == "Waiting for Wi-Fi…")
    #expect(detail(asset: .downloading(nil)) == "Downloading speech model…")
    #expect(detail(asset: .failed) == "Speech model download failed")
    #expect(detail(progress: progress(0, 0, .idle)) == "No downloaded episodes to analyse")
    #expect(detail(progress: progress(12, 14, .idle)) == "12 of 14 episodes analysed")
    #expect(detail(progress: progress(1, 1, .idle)) == "1 of 1 episode analysed")
    #expect(detail(progress: progress(12, 14, .analysing)) == "Analysing 12 of 14 episodes")
    #expect(
      detail(progress: progress(2, 3, .paused), pauseReason: .notCharging)
        == "Waiting for iPhone to charge")
    #expect(detail(progress: progress(2, 3, .paused)) == "Paused after 2 of 3 episodes")
    #expect(detail(progress: progress(3, 3, .idle)) == "3 of 3 episodes analysed")
    #expect(
      detail(progress: progress(3, 3, .analysing)) == "Checking 3 of 3 episodes for more ads")
    #expect(
      detail(progress: progress(3, 3, .paused), pauseReason: .notCharging)
        == "Waiting for iPhone to charge", "windows remain on analysed episodes")
  }

  @Test("a pause says why when the conditions explain it")
  func pauseCopy() {
    let paused = AdSkipProgress(analysed: 2, unanalysable: 0, total: 3, activity: .paused)
    #expect(
      AdSkipProgressCopy.status(for: paused, pauseReason: .notCharging).detail
        == "Waiting for iPhone to charge")
    #expect(
      AdSkipProgressCopy.status(for: paused, pauseReason: .lowPowerMode).detail
        == "Paused in Low Power Mode")
    #expect(
      AdSkipProgressCopy.status(for: paused, pauseReason: .warm).detail
        == "Paused while iPhone is warm")
    let working = AdSkipProgress(analysed: 2, unanalysable: 0, total: 3, activity: .analysing)
    #expect(
      AdSkipProgressCopy.status(for: working, pauseReason: .notCharging).detail == "Analysing…")
  }

  @Test("only while charging is off by default, and the toggle writes it")
  func chargingToggle() async throws {
    let defaults = try defaults()
    let model = model(Installer(.installed), defaults: defaults, calls: Calls())
    #expect(model.isOnlyWhileCharging == false)

    model.setOnlyWhileCharging(true)
    #expect(model.isOnlyWhileCharging)
    #expect(AdSkipPreference.isOnlyWhileCharging(in: defaults))

    defaults.set(false, forKey: AdSkipPreference.onlyWhileChargingKey)
    await model.refresh()
    #expect(model.isOnlyWhileCharging == false)
  }

  @Test("progress carries the reason analysis is paused")
  func progressCarriesThePauseReason() async throws {
    let updates = AsyncStream<AdSkipProgress?>.makeStream()
    let model = AdSkipSettingsModel(
      installer: Installer(.installed), network: Network(), defaults: try defaults(),
      progressUpdates: { updates.stream }, pauseReason: { .notCharging },
      onInstalled: {}, onForget: {})
    updates.continuation.yield(
      AdSkipProgress(analysed: 0, unanalysable: 0, total: 4, activity: .paused))
    updates.continuation.finish()

    await model.followProgress()
    #expect(model.pauseReason == .notCharging)
  }
}

/// The receipt for a skip.
@MainActor
@Suite("Ad skip receipt")
struct AdSkipReceiptTests {
  private func receipt(_ start: Double, _ end: Double, endsItem: Bool = false, sequence: Int = 1)
    -> PlaybackSkipReceipt
  {
    PlaybackSkipReceipt(
      range: PlayerSkipRange(start: start, end: end, endsItem: endsItem), sequence: sequence)
  }

  @Test("copy shows the ad's length, rounded, in unpadded minutes")
  func copy() {
    let short = receipt(100, 132)
    #expect(AdSkipReceiptPresentation.text(for: short) == "Skipped 0:32 of ads")
    #expect(AdSkipReceiptPresentation.announcement(for: short) == "Skipped 32 seconds of ads")
    #expect(AdSkipReceiptPresentation.text(for: receipt(0, 31.6)) == "Skipped 0:32 of ads")
    #expect(AdSkipReceiptPresentation.text(for: receipt(10, 75)) == "Skipped 1:05 of ads")
  }

  @Test("Undo is offered unless the skip ended the episode")
  func undoUnlessEnding() {
    #expect(receipt(100, 132).canUndo)
    #expect(receipt(100, 132, endsItem: true).canUndo == false)
  }

  @Test("a skip's time on screen starts when it is first seen, and a newer skip replaces it")
  func sharedClock() {
    let first = receipt(500, 530, sequence: 900)
    #expect(AdSkipReceiptPresentation.remaining(for: first) == nil)
    AdSkipReceiptPresentation.note(first)
    let left = AdSkipReceiptPresentation.remaining(for: first)
    #expect(left.map { $0 > .zero && $0 <= AdSkipReceiptPresentation.visibleDuration } == true)

    let second = receipt(500, 530, sequence: 901)
    AdSkipReceiptPresentation.note(second)
    #expect(AdSkipReceiptPresentation.remaining(for: first) == nil)
    #expect(AdSkipReceiptPresentation.remaining(for: second) != nil)
  }

  @Test("an undone or superseded skip leaves every surface; an ending skip stays its time")
  func clearing() {
    let undoable = receipt(100, 132)
    let ending = receipt(100, 132, endsItem: true)
    let newer = receipt(200, 230, sequence: 2)
    #expect(AdSkipReceiptPresentation.shown(after: nil, showing: undoable) == nil)
    #expect(AdSkipReceiptPresentation.shown(after: nil, showing: ending) == ending)
    #expect(AdSkipReceiptPresentation.shown(after: newer, showing: undoable) == newer)
    #expect(AdSkipReceiptPresentation.shown(after: nil, showing: nil) == nil)
  }

  /// The privacy claim is the first thing the section says, and every expectation row follows it.
  @Test func theGoodToKnowSectionLeadsWithThePrivacyClaim() {
    #expect(
      AdSkipSettingsCopy.goodToKnowRows.map(\.title) == [
        AdSkipSettingsCopy.onDeviceTitle,
        AdSkipSettingsCopy.downloadedOnlyTitle,
        AdSkipSettingsCopy.autoDownloadsTitle,
        AdSkipSettingsCopy.batteryTitle,
      ])
    #expect(
      AdSkipSettingsCopy.goodToKnowRows.first?.detail
        == "Whirr compares downloaded episodes here, looking for audio that repeats. "
        + "No audio or transcript leaves it.")
  }

  /// A host-read miss is answered by the rows beneath it: transcribing, then marking oneself.
  @Test func theHostReadRowIsFollowedByHowToFixIt() throws {
    let row = try #require(
      AdSkipSettingsCopy.whenItGetsItWrongRows.first { $0.title == AdSkipSettingsCopy.hostReadTitle })
    #expect(
      row.detail
        == "Most aren’t caught. Transcribing the episode finds more, usually where the host "
        + "reads out a web address.")
    #expect(
      AdSkipSettingsCopy.whenItGetsItWrongRows.map(\.title) == [
        "New ads",
        "Host-read sponsor messages",
        "Mark ads yourself",
        "Repeated intros, credits and promos",
      ])
  }
}
