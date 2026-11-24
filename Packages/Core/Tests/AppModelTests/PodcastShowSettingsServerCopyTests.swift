import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// A followed RSS show's Show Settings may carry the server section, but only when that section
/// is fed by the feed's own server copy. A feed's device settings never appear under the server
/// header.
@MainActor
@Suite("Show Settings server copy of a followed feed", .timeLimit(.minutes(1)))
struct PodcastShowSettingsServerCopyTests {
  private static let feedID: Int64 = 9
  private static let fingerprint = PodcastFeedIdentity.fingerprint("https://example.com/feed")!
  private static let now = Date(timeIntervalSince1970: 1_700_100_000)
  /// What the server says about its copy.
  private static let serverValues = PodcastShowDiagnostics(
    autoDownloadEpisodes: true, autoDownloadSchedule: "17 3 * * 2",
    lastEpisodeCheck: Date(timeIntervalSince1970: 1_699_000_000), maxEpisodesToKeep: 10,
    maxNewEpisodesToDownload: 2)
  /// What this device's own feed diagnostics say; different in every field.
  private static let deviceValues = PodcastShowDiagnostics(
    autoDownloadEpisodes: false, autoDownloadSchedule: "0 * * * *",
    lastEpisodeCheck: Date(timeIntervalSince1970: 1_699_900_000), maxEpisodesToKeep: 3,
    maxNewEpisodesToDownload: 7)

  private var feedItemID: String { PodcastSourceIdentity.rss(feedId: Self.feedID)!.itemId }

  private struct Harness {
    let model: PodcastShowSettingsModel
    let reading: FakePodcastReading
    let shows: FakeNativePodcastShowsReading
    let capability: FakeServerPodcastMutationCapabilityReading
    let writer: CopyWriter
    let refreshing: FakePodcastRefreshing
    let credential: FakeNativeFeedManaging
    let feedItemID: String
  }

  private func makeHarness(
    capability: ServerPodcastMutationCapability = .init(canSave: true, canRemove: false),
    credential: FakeNativeFeedManaging = FakeNativeFeedManaging(),
    fingerprint: String? = Self.fingerprint
  ) -> Harness {
    let reading = FakePodcastReading()
    let shows = FakeNativePodcastShowsReading()
    let capabilityReader = FakeServerPodcastMutationCapabilityReading(capability)
    let writer = CopyWriter()
    let refreshing = FakePodcastRefreshing()
    let fixedNow = Self.now
    let model = PodcastShowSettingsModel(
      itemID: feedItemID, reading: NoOpPodcastSettingsAccess(), podcastReading: reading,
      refreshing: refreshing, nativeFeedManaging: credential, nativeShowsReading: shows,
      serverMutationCapability: capabilityReader, automationSettingsWriting: writer,
      now: { fixedNow })
    shows.pushShow(
      ItemSummary(
        serverItemId: feedItemID, mediaKind: "podcast", title: "Feed", author: nil,
        durationSeconds: nil, category: .podcast, podcastFeedFingerprint: fingerprint),
      itemID: feedItemID)
    return Harness(
      model: model, reading: reading, shows: shows, capability: capabilityReader, writer: writer,
      refreshing: refreshing, credential: credential, feedItemID: feedItemID)
  }

  private func settle(_ harness: Harness) async {
    await waitUntil("fingerprint observed") { harness.reading.observedFingerprints.count >= 1 }
  }

  @Test("a feed with no server copy has no section, and never reads the capability")
  func zeroCopies() async {
    let harness = makeHarness()
    harness.reading.pushDiagnostics(Self.deviceValues, itemID: harness.feedItemID)
    await settle(harness)
    harness.reading.pushServerCopies([], fingerprint: Self.fingerprint)
    await waitUntil("feed diagnostics seen") {
      harness.model.sourceSection?.footer.contains("Last checked") == true
    }

    #expect(harness.model.serverSettings == nil)
    #expect(harness.model.serverSettingsEditor == nil)
    #expect(harness.model.serverCopiesNotice == nil)
    #expect(harness.capability.readCount == 0)
  }

  @Test("one server copy: the section shows the server item's values and never the feed's")
  func oneCopyShowsOnlyTheServerItem() async {
    let harness = makeHarness(capability: .none)
    harness.reading.pushDiagnostics(Self.deviceValues, itemID: harness.feedItemID)
    await settle(harness)
    harness.reading.pushServerCopies(["server-1"], fingerprint: Self.fingerprint)
    await waitUntil("server item observed") {
      harness.reading.observedDiagnosticsItemIDs.contains("server-1")
    }
    harness.reading.pushDiagnostics(Self.serverValues, itemID: "server-1")
    await waitUntil("section appears") { harness.model.serverSettings != nil }

    #expect(
      harness.model.serverSettings
        == PodcastServerSettingsPresentation.section(
          diagnostics: Self.serverValues, now: Self.now))
    #expect(
      harness.model.serverSettings
        != PodcastServerSettingsPresentation.section(
          diagnostics: Self.deviceValues, now: Self.now))

    // A later change to the feed's own diagnostics cannot move the server section.
    let before = harness.model.serverSettings
    harness.reading.pushDiagnostics(
      PodcastShowDiagnostics(
        autoDownloadEpisodes: true, lastEpisodeCheck: nil, maxEpisodesToKeep: 1),
      itemID: harness.feedItemID)
    await waitUntil("feed diagnostics seen") {
      harness.model.sourceSection?.footer.contains("Last checked") == false
    }
    #expect(harness.model.serverSettings == before)
    #expect(harness.model.serverSettingsEditor == nil, "an ineligible account sees read-only rows")
  }

  @Test("device feed diagnostics alone never produce a server section")
  func deviceSettingsNeverReachTheServerHeader() async {
    let harness = makeHarness()
    await settle(harness)
    harness.reading.pushDiagnostics(Self.deviceValues, itemID: harness.feedItemID)
    await waitUntil("feed diagnostics seen") {
      harness.model.sourceSection?.footer.contains("Last checked") == true
    }
    harness.reading.pushServerCopies([], fingerprint: Self.fingerprint)
    await Task.yield()

    #expect(harness.model.serverSettings == nil)
    #expect(harness.model.serverSettingsEditor == nil)
    #expect(harness.model.serverCopiesNotice == nil)
  }

  @Test("an eligible account edits the single copy through its server item id")
  func editorWritesTargetTheServerItem() async {
    let harness = makeHarness()
    await settle(harness)
    harness.reading.pushServerCopies(["server-1"], fingerprint: Self.fingerprint)
    await waitUntil("server item observed") {
      harness.reading.observedDiagnosticsItemIDs.contains("server-1")
    }
    harness.reading.pushDiagnostics(Self.serverValues, itemID: "server-1")
    await waitUntil("editor appears") { harness.model.serverSettingsEditor != nil }

    #expect(harness.capability.readCount == 1)
    #expect(
      harness.model.serverSettingsEditor
        == PodcastServerSettingsPresentation.editor(
          diagnostics: Self.serverValues, now: Self.now))

    await harness.model.setServerKeepLimit(5)

    let calls = await harness.writer.calls
    #expect(calls.map(\.itemID) == ["server-1"])
    #expect(calls.map(\.confirmation) == [.refreshLocalRow])
    #expect(calls.first?.change == PodcastAutomationSettingsRequest(maxEpisodesToKeep: 5))
  }

  @Test("several copies: no editor, no rows, a read-only notice")
  func severalCopies() async {
    let harness = makeHarness()
    await settle(harness)
    harness.reading.pushServerCopies(["server-1", "server-2"], fingerprint: Self.fingerprint)
    await waitUntil("notice appears") { harness.model.serverCopiesNotice != nil }

    #expect(
      harness.model.serverCopiesNotice
        == "This podcast has more than one copy on the server. Change its settings in the Audiobookshelf web app."
    )
    #expect(harness.model.serverSettings == nil)
    #expect(harness.model.serverSettingsEditor == nil)
    #expect(harness.reading.observedDiagnosticsItemIDs.contains("server-1") == false)

    await harness.model.setServerKeepLimit(5)
    #expect(await harness.writer.calls.isEmpty)

    // Dropping back to one copy replaces the notice with that copy's section.
    harness.reading.pushServerCopies(["server-2"], fingerprint: Self.fingerprint)
    await waitUntil("notice clears") { harness.model.serverCopiesNotice == nil }
    harness.reading.pushDiagnostics(Self.serverValues, itemID: "server-2")
    await waitUntil("editor appears") { harness.model.serverSettingsEditor != nil }
  }

  @Test("a known-empty server show still yields the section")
  func knownEmptyCopyStillYieldsTheSection() async {
    let harness = makeHarness()
    await settle(harness)
    harness.reading.pushServerCopies(["server-1"], fingerprint: Self.fingerprint)
    await waitUntil("server item observed") {
      harness.reading.observedDiagnosticsItemIDs.contains("server-1")
    }
    // Off, with nothing downloaded and nothing yet checked: a created show before its first run.
    harness.reading.pushDiagnostics(
      PodcastShowDiagnostics(autoDownloadEpisodes: false, lastEpisodeCheck: nil), itemID: "server-1")

    await waitUntil("editor appears") { harness.model.serverSettingsEditor != nil }
    #expect(harness.model.serverSettingsEditor?.downloadsNewEpisodes == false)
  }

  @Test("no section before the copy's row exists, and one after, without a new model")
  func sectionAppearsAfterTheSync() async {
    let harness = makeHarness()
    await settle(harness)
    harness.reading.pushServerCopies([], fingerprint: Self.fingerprint)
    await Task.yield()
    #expect(harness.model.serverSettings == nil)
    #expect(harness.model.serverSettingsEditor == nil)

    harness.reading.pushServerCopies(["created"], fingerprint: Self.fingerprint)
    await waitUntil("server item observed") {
      harness.reading.observedDiagnosticsItemIDs.contains("created")
    }
    harness.reading.pushDiagnostics(
      PodcastShowDiagnostics(autoDownloadEpisodes: false, lastEpisodeCheck: nil), itemID: "created")
    await waitUntil("editor appears") { harness.model.serverSettingsEditor != nil }
  }

  @Test("a feed with a device-held credential never reads the fingerprint")
  func credentialedFeedShowsNothing() async {
    let harness = makeHarness(credential: makeCopyCredentials(.configured, feedID: Self.feedID))
    await waitUntil("credential read") { harness.credential.reads >= 1 }
    await Task.yield()

    #expect(harness.reading.observedFingerprints.isEmpty)
    #expect(harness.model.serverSettings == nil)
    #expect(harness.model.serverSettingsEditor == nil)
    #expect(harness.model.serverCopiesNotice == nil)
    #expect(harness.capability.readCount == 0)
  }

  @Test("a pending or failed credential read counts as held")
  func unknownCredentialShowsNothing() async {
    let pending = makeCopyCredentials(.pending, feedID: Self.feedID)
    let pendingHarness = makeHarness(credential: pending)
    await waitUntil("credential read started") {
      pendingHarness.credential.reads >= 1
    }
    #expect(pendingHarness.reading.observedFingerprints.isEmpty)

    let failedHarness = makeHarness(credential: makeCopyCredentials(.failing, feedID: Self.feedID))
    await waitUntil("credential read attempted") {
      failedHarness.credential.reads >= 1
    }
    await Task.yield()
    #expect(failedHarness.reading.observedFingerprints.isEmpty)
    #expect(failedHarness.model.serverSettings == nil)
    #expect(failedHarness.model.serverSettingsEditor == nil)

    pending.credentialReadGate.release()
    await waitUntil("read after the credential resolves") {
      pendingHarness.reading.observedFingerprints == [Self.fingerprint]
    }
  }

  @Test("saving a credential withdraws a section that was showing")
  func savingACredentialWithdrawsTheSection() async {
    let harness = makeHarness()
    await settle(harness)
    harness.reading.pushServerCopies(["server-1"], fingerprint: Self.fingerprint)
    await waitUntil("server item observed") {
      harness.reading.observedDiagnosticsItemIDs.contains("server-1")
    }
    harness.reading.pushDiagnostics(Self.serverValues, itemID: "server-1")
    await waitUntil("editor appears") { harness.model.serverSettingsEditor != nil }

    harness.model.feedCredentialUsername = "user"
    harness.model.feedCredentialPassword = "secret"
    await harness.model.saveFeedCredential()

    #expect(harness.model.serverSettings == nil)
    #expect(harness.model.serverSettingsEditor == nil)
  }

  @Test("a feed with no fingerprint never asks for copies")
  func noFingerprint() async {
    let harness = makeHarness(fingerprint: nil)
    await waitUntil("show observed") { harness.shows.observedItemIDs.isEmpty == false }
    await Task.yield()

    #expect(harness.reading.observedFingerprints.isEmpty)
    #expect(harness.model.serverSettings == nil)
  }
}

// MARK: - Fakes

private actor CopyWriter: ServerPodcastAutomationSettingsWriting {
  struct Call: Equatable {
    let itemID: String
    let change: PodcastAutomationSettingsRequest
    let confirmation: ServerPodcastAutomationConfirmation
  }
  private(set) var calls: [Call] = []
  func update(
    itemID: String, change: PodcastAutomationSettingsRequest,
    confirmation: ServerPodcastAutomationConfirmation
  ) async -> ServerPodcastAutomationSettingsOutcome {
    calls.append(Call(itemID: itemID, change: change, confirmation: confirmation))
    return .confirmed(PodcastAutomationSettingsResult(), refresh: .completed)
  }
}

extension FakePodcastReading {
  fileprivate var observedFingerprints: [String] {
    calls.compactMap { call -> String? in
      if case .observeServerCopyItemIDs(let fingerprint) = call { return fingerprint }
      return nil
    }
  }

  fileprivate var observedDiagnosticsItemIDs: [String] {
    calls.compactMap { call -> String? in
      if case .observeShowDiagnostics(let itemID) = call { return itemID }
      return nil
    }
  }
}

extension FakeNativeFeedManaging {
  fileprivate var reads: Int {
    calls.filter { call in
      if case .hasCredential = call { return true }
      return false
    }.count
  }
}

private enum CopyCredentialState { case configured, pending, failing }

/// A credential store whose read answers as `state` says; the default store has no credential.
private func makeCopyCredentials(
  _ state: CopyCredentialState, feedID: Int64
) -> FakeNativeFeedManaging {
  let credentials = FakeNativeFeedManaging(
    configuredFeedIDs: state == .configured ? [feedID] : [])
  switch state {
  case .configured: break
  case .pending: credentials.credentialReadGate.hold()
  case .failing: credentials.stubReadFailure(PodcastFixtureError.offline)
  }
  return credentials
}
