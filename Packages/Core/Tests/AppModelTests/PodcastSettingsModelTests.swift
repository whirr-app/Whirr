import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

@Suite(.timeLimit(.minutes(1))) struct PodcastSettingsModelTests {
  @MainActor
  @Test func initialStateLoadsGlobalAndShows() async {
    let reading = FakePodcastSettingsReading()
    let model = PodcastSettingsModel(reading: reading)
    #expect(model.state == .loading)

    var enabled = PodcastGlobalSettings.defaults
    enabled.autoDownloadEnabled = true
    reading.pushGlobal(enabled)
    reading.pushShowRows([Self.row(id: "show-1")])
    await waitUntil { model.state == .loaded }

    #expect(model.global == enabled)
    #expect(model.showRows.map(\.itemID) == ["show-1"])
  }

  @MainActor
  @Test func globalTogglePersistsAndUpdatesEffectiveRows() async {
    let reading = FakePodcastSettingsReading()
    let writing = FakePodcastSettingsWriting()
    let model = PodcastSettingsModel(reading: reading, writing: writing)
    reading.pushGlobal(.defaults)
    reading.pushShowRows([Self.row(id: "show-1", override: .inherit, effectiveEnabled: false)])
    await waitUntil { model.state == .loaded }

    await model.setAutoDownloadEnabled(true)

    #expect(await writing.calls == [.setGlobalAutoDownloadEnabled(true)])

    // The real store's `ValueObservation` re-fires both streams once the mutation commits; the
    // fake mirrors that by pushing the settled values a caller would actually see next.
    var enabledGlobal = PodcastGlobalSettings.defaults
    enabledGlobal.autoDownloadEnabled = true
    reading.pushGlobal(enabledGlobal)
    reading.pushShowRows([Self.row(id: "show-1", override: .inherit, effectiveEnabled: true)])
    await waitUntil { model.global.autoDownloadEnabled }

    #expect(model.showRows.first?.effective.isEnabled == true)
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test func mutationFailureKeepsPreviousVisibleValueAndShowsError() async {
    let reading = FakePodcastSettingsReading()
    let writing = FakePodcastSettingsWriting()
    await writing.failNext()
    let model = PodcastSettingsModel(reading: reading, writing: writing)
    reading.pushGlobal(.defaults)
    reading.pushShowRows([])
    await waitUntil { model.state == .loaded }

    await model.setAutoDownloadEnabled(true)

    #expect(model.global == .defaults, "no optimistic update to roll back")
    #expect(model.actionErrorMessage == PodcastDownloadCopy.actionFailed)
  }

  @MainActor
  @Test func lateValuesFromOldSubscriptionAreIgnored() async {
    let reading = FakePodcastSettingsReading()
    let model = PodcastSettingsModel(reading: reading)
    reading.pushGlobal(.defaults, generation: 0)
    reading.pushShowRows([], generation: 0)
    await waitUntil { model.state == .loaded }

    model.reload()

    // A value delivered by the superseded (generation 0) subscription must never land, even
    // though the fake still holds a handle to its continuation.
    var stale = PodcastGlobalSettings.defaults
    stale.keepLatestCount = 999
    reading.pushGlobal(stale, generation: 0)
    reading.pushShowRows([Self.row(id: "stale")], generation: 0)

    // The fresh (generation 1) subscription is the one that should actually land.
    var fresh = PodcastGlobalSettings.defaults
    fresh.keepLatestCount = 7
    reading.pushGlobal(fresh, generation: 1)
    reading.pushShowRows([], generation: 1)
    await waitUntil { model.global.keepLatestCount == 7 }

    #expect(model.global.keepLatestCount != 999)
    #expect(model.showRows.isEmpty)
  }

  /// A show that inherits carries no trailing label at all: a list of rows each restating the one
  /// global default reads as a list of independent settings, which they are not.
  /// The label exists to mark deviation, so it must not move when only the global moves.
  @MainActor
  @Test func inheritingShowRowsCarryNoLabelWhicheverWayTheGlobalMoves() async {
    let reading = FakePodcastSettingsReading()
    let model = PodcastSettingsModel(reading: reading)
    reading.pushGlobal(.defaults)
    reading.pushShowRows([Self.row(id: "show-1", override: .inherit, effectiveEnabled: false)])
    await waitUntil { model.state == .loaded }
    #expect(PodcastDownloadCopy.showRowLabel(model.showRows[0]) == nil)

    var enabledGlobal = PodcastGlobalSettings.defaults
    enabledGlobal.autoDownloadEnabled = true
    reading.pushGlobal(enabledGlobal)
    reading.pushShowRows([Self.row(id: "show-1", override: .inherit, effectiveEnabled: true)])
    await waitUntil { model.showRows.first?.effective.isEnabled == true }

    #expect(PodcastDownloadCopy.showRowLabel(model.showRows[0]) == nil)
  }

  /// Only an explicit override names its state, and it names the override's own outcome rather
  /// than the resolved value. The two agree by construction (`PodcastEffectiveSettingsResolver`),
  /// and reading the override keeps the label honest if a stale effective value arrives.
  @Test func overriddenShowRowsNameTheirOwnState() {
    #expect(
      PodcastDownloadCopy.showRowLabel(
        Self.row(id: "on", override: .enabled, effectiveEnabled: true)) == "Downloads on")
    #expect(
      PodcastDownloadCopy.showRowLabel(
        Self.row(id: "off", override: .disabled, effectiveEnabled: false)) == "Downloads off")
  }

  /// Either defaults section can be the only one on the Downloads screen, so neither footer may
  /// depend on the other being visible to say which podcasts it governs.
  @Test func eachDefaultsFooterNamesItsOwnSourceAndTheDevice() {
    #expect(PodcastDownloadCopy.directDefaultsFooter != PodcastDownloadCopy.serverDefaultsFooter)
    #expect(PodcastDownloadCopy.directDefaultsFooter.contains("directly in Whirr"))
    #expect(PodcastDownloadCopy.serverDefaultsFooter.contains("Audiobookshelf"))
    for footer in [PodcastDownloadCopy.directDefaultsFooter, PodcastDownloadCopy.serverDefaultsFooter] {
      #expect(footer.contains("this device"))
      #expect(footer.contains("Individual shows can override these settings."))
    }
  }

  /// The notification footer answers questions about notifications only. Sharing a section with
  /// the subscription toggle would make it read as a condition on following feeds.
  @Test func notificationCopyStandsOnItsOwnAwayFromTheSubscriptionToggle() {
    #expect(SettingsCopy.podcastEpisodeNotificationsFooter.contains("Background App Refresh"))
    #expect(
      SettingsCopy.nativePodcastSubscriptionsFooter.contains("Background App Refresh") == false)
  }

  @Test func copyNeverUsesTheBareWordAutoDownloadForTheDeviceFeature() {
    let deviceCopyStrings = [
      PodcastDownloadCopy.autoDownloadToggleTitle,
      PodcastDownloadCopy.allowCellularToggleTitle,
      PodcastDownloadCopy.keepLatestStateHint(count: 3),
      PodcastDownloadCopy.keepLatestStateHint(count: 0),
      PodcastDownloadCopy.autoDownloadOverrideLabel(.inherit, effectiveIsEnabled: true),
      PodcastDownloadCopy.autoDownloadOverrideLabel(.enabled, effectiveIsEnabled: true),
      PodcastDownloadCopy.autoDownloadOverrideLabel(.disabled, effectiveIsEnabled: false),
    ]
    for string in deviceCopyStrings {
      #expect(string != "Auto-download")
      #expect(string.contains("Auto-download") == false)
    }

    #expect(PodcastDownloadCopy.keepLatestStateHint(count: 3).contains("this device"))
    #expect(PodcastDownloadCopy.keepLatestStateHint(count: 0).contains("this device"))
  }

  private static func row(
    id: String,
    override: PodcastShowAutoDownloadOverride = .inherit,
    effectiveEnabled: Bool = false,
    keepLatestCount: Int = 3
  ) -> PodcastShowSettingsSummary {
    PodcastShowSettingsSummary(
      itemID: id,
      title: id,
      autoDownloadOverride: override,
      effective: PodcastEffectiveSettings(
        isEnabled: effectiveEnabled, keepLatestCount: keepLatestCount, deleteAfterPlayed: false,
        floor: .distantPast))
  }
}

private actor FakePodcastSettingsWriting: PodcastSettingsWriting {
  enum Call: Equatable {
    case setGlobalAutoDownloadEnabled(Bool)
    case setGlobalKeepLatestCount(Int)
    case setGlobalDeleteAfterPlayed(Bool)
    case setGlobalAllowCellularAutoDownload(Bool)
    case setShowAutoDownloadOverride(String, PodcastShowAutoDownloadOverride)
    case setShowKeepLatestOverride(String, Int?)
    case setShowDeleteAfterPlayedOverride(String, Bool?)
    case setShowIncludeInLatest(String, Bool)
  }

  private(set) var calls: [Call] = []
  private var shouldFail = false

  func failNext() { shouldFail = true }

  func setGlobalAutoDownloadEnabled(_ enabled: Bool) async throws {
    try checkFailure()
    calls.append(.setGlobalAutoDownloadEnabled(enabled))
  }
  func setGlobalKeepLatestCount(_ count: Int) async throws {
    try checkFailure()
    calls.append(.setGlobalKeepLatestCount(count))
  }
  func setGlobalDeleteAfterPlayed(_ enabled: Bool) async throws {
    try checkFailure()
    calls.append(.setGlobalDeleteAfterPlayed(enabled))
  }
  func setGlobalAllowCellularAutoDownload(_ enabled: Bool) async throws {
    try checkFailure()
    calls.append(.setGlobalAllowCellularAutoDownload(enabled))
  }
  func setShowAutoDownloadOverride(itemID: String, override: PodcastShowAutoDownloadOverride)
    async throws
  {
    try checkFailure()
    calls.append(.setShowAutoDownloadOverride(itemID, override))
  }
  func setShowKeepLatestOverride(itemID: String, count: Int?) async throws {
    try checkFailure()
    calls.append(.setShowKeepLatestOverride(itemID, count))
  }
  func setShowDeleteAfterPlayedOverride(itemID: String, enabled: Bool?) async throws {
    try checkFailure()
    calls.append(.setShowDeleteAfterPlayedOverride(itemID, enabled))
  }
  func setShowIncludeInLatest(itemID: String, enabled: Bool) async throws {
    try checkFailure()
    calls.append(.setShowIncludeInLatest(itemID, enabled))
  }

  private func checkFailure() throws {
    if shouldFail {
      shouldFail = false
      throw PodcastSettingsFixtureError.failed
    }
  }
}

private enum PodcastSettingsFixtureError: Error { case failed }
