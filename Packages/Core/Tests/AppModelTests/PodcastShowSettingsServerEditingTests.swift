import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// ADR 0017: Show Settings' server section as an editor, driven through the model with fakes for
/// the capability reader and the automation writer. The service itself is covered in SyncEngine.
@MainActor
@Suite("Show Settings server editing", .timeLimit(.minutes(1)))
struct PodcastShowSettingsServerEditingTests {
  private static let itemID = "show-1"
  private static let now = Date(timeIntervalSince1970: 1_700_100_000)
  private static let diagnostics = PodcastShowDiagnostics(
    autoDownloadEpisodes: true, autoDownloadSchedule: "17 3 * * 2",
    lastEpisodeCheck: Date(timeIntervalSince1970: 1_699_000_000), maxEpisodesToKeep: 10,
    maxNewEpisodesToDownload: 0)

  private struct Harness {
    let model: PodcastShowSettingsModel
    let diagnosticsReading: FakePodcastReading
    let capability: FakeServerPodcastMutationCapabilityReading
    let writer: EditingAutomationWriter
    let deviceWriting: EditingDeviceWriting
    let refreshing: FakePodcastRefreshing
    let itemID: String
  }

  private func makeHarness(
    itemID: String = Self.itemID,
    capability: ServerPodcastMutationCapability = .init(canSave: true, canRemove: false),
    capabilityGated: Bool = false,
    outcomes: [ServerPodcastAutomationSettingsOutcome] = [],
    writerGated: Bool = false,
    diagnostics: PodcastShowDiagnostics? = Self.diagnostics
  ) -> Harness {
    let diagnosticsReading = FakePodcastReading()
    let capabilityReader = FakeServerPodcastMutationCapabilityReading(capability)
    if capabilityGated { capabilityReader.gate.hold() }
    let writer = EditingAutomationWriter(outcomes: outcomes, gated: writerGated)
    let deviceWriting = EditingDeviceWriting()
    let refreshing = FakePodcastRefreshing()
    let fixedNow = Self.now
    let model = PodcastShowSettingsModel(
      itemID: itemID, reading: NoOpPodcastSettingsAccess(), writing: deviceWriting,
      podcastReading: diagnosticsReading, refreshing: refreshing,
      serverMutationCapability: capabilityReader, automationSettingsWriting: writer,
      now: { fixedNow })
    if let diagnostics { diagnosticsReading.pushDiagnostics(diagnostics, itemID: itemID) }
    return Harness(
      model: model, diagnosticsReading: diagnosticsReading, capability: capabilityReader,
      writer: writer, deviceWriting: deviceWriting, refreshing: refreshing, itemID: itemID)
  }

  private func eligible(
    outcomes: [ServerPodcastAutomationSettingsOutcome] = [], writerGated: Bool = false
  ) async -> Harness {
    let harness = makeHarness(outcomes: outcomes, writerGated: writerGated)
    await waitUntil("editor appears") { harness.model.serverSettingsEditor != nil }
    return harness
  }

  // MARK: - Eligibility

  @Test("an account that cannot save sees today's read-only section and no editor")
  func ineligibleAccountKeepsTheReadOnlySection() async {
    let states: [PodcastShowDiagnostics] = [
      Self.diagnostics,
      PodcastShowDiagnostics(
        autoDownloadEpisodes: false, autoDownloadSchedule: "0 * * * *", lastEpisodeCheck: nil,
        maxEpisodesToKeep: 0, maxNewEpisodesToDownload: 3),
      PodcastShowDiagnostics(autoDownloadEpisodes: nil, lastEpisodeCheck: Self.now),
    ]
    for diagnostics in states {
      let harness = makeHarness(capability: .none, diagnostics: diagnostics)
      await waitUntil("section appears") { harness.model.serverSettings != nil }
      await waitUntil("capability read") { harness.capability.readCount >= 1 }

      #expect(harness.model.serverSettingsEditor == nil)
      #expect(
        harness.model.serverSettings
          == PodcastServerSettingsPresentation.section(diagnostics: diagnostics, now: Self.now))
      #expect(harness.model.serverSettings?.footer.contains("Audiobookshelf web app") == true)
    }
  }

  @Test("the read-only section shows until the capability resolves, then the editor replaces it")
  func readOnlyUntilCapabilityResolves() async {
    let harness = makeHarness(capabilityGated: true)
    await waitUntil("section appears") { harness.model.serverSettings != nil }

    #expect(harness.model.serverSettingsEditor == nil)

    harness.capability.gate.release()
    await waitUntil("editor appears") { harness.model.serverSettingsEditor != nil }
    #expect(
      harness.model.serverSettingsEditor
        == PodcastServerSettingsPresentation.editor(
          diagnostics: Self.diagnostics, now: Self.now))
  }

  @Test("an eligible account gets the editor built from the stored values")
  func eligibleAccountGetsTheEditor() async throws {
    let harness = await eligible()
    let editor = try #require(harness.model.serverSettingsEditor)

    #expect(editor.schedule?.selection == .stored("17 3 * * 2"))
    #expect(editor.newEpisodeLimit?.selection == 0)
    #expect(editor.retention?.selection == 10)
    #expect(harness.capability.readCount == 1)
  }

  @Test("no diagnostics means no section and no editor, even for an eligible account")
  func noDiagnosticsNoSection() async {
    let harness = makeHarness(diagnostics: nil)
    await waitUntil("capability read") { harness.capability.readCount >= 1 }

    #expect(harness.model.serverSettings == nil)
    #expect(harness.model.serverSettingsEditor == nil)

    await harness.model.setServerKeepLimit(5)
    #expect(await harness.writer.calls.isEmpty)
  }

  @Test("a native RSS show has no server section, no editor and never reads the capability")
  func nativeShowIsUnchanged() async throws {
    let rssID = try #require(PodcastSourceIdentity.rss(feedId: 9)).itemId
    let harness = makeHarness(itemID: rssID)
    await harness.model.setServerKeepLimit(5)

    #expect(harness.model.serverSettings == nil)
    #expect(harness.model.serverSettingsEditor == nil)
    #expect(harness.capability.readCount == 0)
    #expect(await harness.writer.calls.isEmpty)
  }

  @Test("intents do nothing for an account without an editor")
  func intentsIgnoredWithoutAnEditor() async {
    let harness = makeHarness(capability: .none)
    await waitUntil("capability read") { harness.capability.readCount >= 1 }

    await harness.model.setServerDownloadsNewEpisodes(false)
    await harness.model.setServerSchedule(.hourly)
    await harness.model.setServerNewEpisodeLimit(2)
    await harness.model.setServerKeepLimit(2)

    #expect(await harness.writer.calls.isEmpty)
    #expect(harness.model.serverSettingsMessage == nil)
  }

  // MARK: - One field per change

  @Test("each intent sends exactly one field and asks to refresh the local row")
  func eachIntentSendsOneField() async {
    let harness = await eligible()

    await harness.model.setServerDownloadsNewEpisodes(false)
    await harness.model.setServerSchedule(.everySixHours)
    await harness.model.setServerNewEpisodeLimit(5)
    await harness.model.setServerKeepLimit(0)

    let calls = await harness.writer.calls
    #expect(
      calls.map(\.change) == [
        PodcastAutomationSettingsRequest(autoDownloadEpisodes: false),
        PodcastAutomationSettingsRequest(autoDownloadSchedule: .everySixHours),
        PodcastAutomationSettingsRequest(maxNewEpisodesToDownload: 5),
        PodcastAutomationSettingsRequest(maxEpisodesToKeep: 0),
      ])
    #expect(calls.allSatisfy { $0.confirmation == .refreshLocalRow })
    #expect(calls.allSatisfy { $0.itemID == harness.itemID })
  }

  @Test("Whirr never sends an unlimited new-episode limit")
  func noZeroNewEpisodeLimit() async {
    let harness = await eligible()

    await harness.model.setServerNewEpisodeLimit(0)
    await harness.model.setServerNewEpisodeLimit(-1)

    #expect(await harness.writer.calls.isEmpty)
  }

  @Test("a retention change calls the server writer once and nothing else")
  func retentionChangeTouchesOnlyTheWriter() async {
    let harness = await eligible()

    await harness.model.setServerKeepLimit(3)

    #expect(
      await harness.writer.calls.map(\.change) == [
        PodcastAutomationSettingsRequest(maxEpisodesToKeep: 3)
      ])
    #expect(await harness.deviceWriting.callCount == 0)
    #expect(harness.refreshing.refreshedItemIDs.isEmpty)
  }

  // MARK: - In flight

  @Test("the chosen value shows while the write runs and stays once the server confirms it")
  func chosenValueShowsAtOnce() async {
    let harness = await eligible(writerGated: true)

    let task = Task { await harness.model.setServerKeepLimit(3) }
    await waitUntil("saving") { harness.model.isSavingServerSettings }

    #expect(harness.model.serverSettingsEditor?.retention?.selection == 3)

    await harness.writer.release()
    await task.value

    #expect(harness.model.isSavingServerSettings == false)
    #expect(harness.model.serverSettingsEditor?.retention?.selection == 3)

    // The stored row is the authority again once it reports after the write.
    harness.diagnosticsReading.pushDiagnostics(
      PodcastShowDiagnostics(
        autoDownloadEpisodes: true, autoDownloadSchedule: "17 3 * * 2",
        lastEpisodeCheck: nil, maxEpisodesToKeep: 5, maxNewEpisodesToDownload: 0),
      itemID: harness.itemID)
    await waitUntil("editor follows diagnostics") {
      harness.model.serverSettingsEditor?.retention?.selection == 5
    }
  }

  @Test("a failed write puts the stored value back")
  func failedWriteRestoresStoredValue() async {
    let harness = await eligible(outcomes: [.uncertain], writerGated: true)
    let before = harness.model.serverSettingsEditor

    let task = Task { await harness.model.setServerKeepLimit(3) }
    await waitUntil("saving") { harness.model.isSavingServerSettings }
    #expect(harness.model.serverSettingsEditor?.retention?.selection == 3)

    await harness.writer.release()
    await task.value

    #expect(harness.model.serverSettingsEditor == before)
    #expect(harness.model.serverSettingsMessage == PodcastServerSettingsMessage.unreachable)
  }

  @Test("a second intent while one is in flight is ignored")
  func reentrancyIsIgnored() async {
    let harness = await eligible(writerGated: true)

    let first = Task { await harness.model.setServerKeepLimit(3) }
    await waitUntil("saving") { harness.model.isSavingServerSettings }
    await harness.model.setServerSchedule(.hourly)
    await harness.model.setServerDownloadsNewEpisodes(false)

    await harness.writer.release()
    await first.value

    #expect(await harness.writer.calls.count == 1)
    #expect(harness.model.isSavingServerSettings == false)
  }

  // MARK: - Outcomes

  @Test(
    "each outcome has its own inline message",
    arguments: [
      (
        ServerPodcastAutomationSettingsOutcome.confirmed(
          PodcastAutomationSettingsResult(), refresh: .completed), String?.none
      ),
      (
        .confirmed(PodcastAutomationSettingsResult(), refresh: .incomplete),
        "Saved on the server. This screen will update after the next refresh."
      ),
      (
        .unconfirmed(PodcastAutomationSettingsResult(), refresh: .completed),
        "The change could not be confirmed. Showing the server's last known settings."
      ),
      (.notFound, "This show is no longer on the server."),
      (.uncertain, "The server could not be reached. Nothing was changed on this device."),
      (.accountChanged, nil),
      (.cancelled, nil),
      (.rejected, "The server did not accept the change."),
      (.failed, "The server did not accept the change."),
      (.invalidRequest, "The server did not accept the change."),
    ])
  func outcomeMessages(
    outcome: ServerPodcastAutomationSettingsOutcome, message: String?
  ) async {
    let harness = await eligible(outcomes: [outcome])

    await harness.model.setServerKeepLimit(3)

    #expect(harness.model.serverSettingsMessage == message)
    #expect(harness.model.actionErrorMessage == nil, "never the alert")
    #expect(harness.model.serverSettingsEditor != nil, "the editor stays")
  }

  @Test(
    "a refused write re-reads the capability and the editor disappears",
    arguments: [
      ServerPodcastAutomationSettingsOutcome.forbidden, .notPermitted,
    ])
  func refusedWriteDropsTheEditor(outcome: ServerPodcastAutomationSettingsOutcome) async {
    let harness = await eligible(outcomes: [outcome])
    harness.capability.stubCapability(.none)

    await harness.model.setServerKeepLimit(3)

    #expect(harness.capability.readCount == 2)
    #expect(harness.model.serverSettingsEditor == nil)
    #expect(harness.model.serverSettings != nil, "the read-only section remains")
    #expect(
      harness.model.serverSettingsMessage == "This account can no longer change server settings.")
  }

  @Test("a later confirmed write clears an earlier failure message")
  func confirmedClearsTheMessage() async {
    let harness = await eligible(outcomes: [
      .failed, .confirmed(PodcastAutomationSettingsResult(), refresh: .completed),
    ])

    await harness.model.setServerKeepLimit(3)
    #expect(harness.model.serverSettingsMessage == "The server did not accept the change.")

    await harness.model.setServerKeepLimit(5)
    #expect(harness.model.serverSettingsMessage == nil)
  }

  @Test("an account change or cancellation leaves no message behind")
  func accountChangeAndCancellationClearTheMessage() async {
    let harness = await eligible(outcomes: [.failed, .accountChanged, .failed, .cancelled])

    await harness.model.setServerKeepLimit(3)
    await harness.model.setServerKeepLimit(5)
    #expect(harness.model.serverSettingsMessage == nil)

    await harness.model.setServerKeepLimit(3)
    await harness.model.setServerKeepLimit(5)
    #expect(harness.model.serverSettingsMessage == nil)
  }
}

// MARK: - Fakes

private actor EditingAutomationWriter: ServerPodcastAutomationSettingsWriting {
  struct Call: Equatable {
    let itemID: String
    let change: PodcastAutomationSettingsRequest
    let confirmation: ServerPodcastAutomationConfirmation
  }

  private(set) var calls: [Call] = []
  private var outcomes: [ServerPodcastAutomationSettingsOutcome]
  // The write runs to completion regardless of cancellation, so a cancelled one stays parked.
  private nonisolated let gate = TestGate<Void>(
    label: "EditingAutomationWriter update", ignoresCancellation: true)

  init(outcomes: [ServerPodcastAutomationSettingsOutcome], gated: Bool) {
    self.outcomes = outcomes
    if gated { gate.hold() }
  }

  func update(
    itemID: String, change: PodcastAutomationSettingsRequest,
    confirmation: ServerPodcastAutomationConfirmation
  ) async -> ServerPodcastAutomationSettingsOutcome {
    calls.append(Call(itemID: itemID, change: change, confirmation: confirmation))
    await gate.pass()
    return outcomes.isEmpty
      ? .confirmed(PodcastAutomationSettingsResult(), refresh: .completed)
      : outcomes.removeFirst()
  }

  func release() {
    gate.release()
  }
}

private actor EditingDeviceWriting: PodcastSettingsWriting {
  private(set) var callCount = 0

  func setGlobalAutoDownloadEnabled(_ enabled: Bool) async throws { callCount += 1 }
  func setGlobalKeepLatestCount(_ count: Int) async throws { callCount += 1 }
  func setGlobalDeleteAfterPlayed(_ enabled: Bool) async throws { callCount += 1 }
  func setGlobalAllowCellularAutoDownload(_ enabled: Bool) async throws { callCount += 1 }
  func setShowAutoDownloadOverride(itemID: String, override: PodcastShowAutoDownloadOverride)
    async throws
  { callCount += 1 }
  func setShowKeepLatestOverride(itemID: String, count: Int?) async throws { callCount += 1 }
  func setShowDeleteAfterPlayedOverride(itemID: String, enabled: Bool?) async throws {
    callCount += 1
  }
  func setShowIncludeInLatest(itemID: String, enabled: Bool) async throws { callCount += 1 }
}
