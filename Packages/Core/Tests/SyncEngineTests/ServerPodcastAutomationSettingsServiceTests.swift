import ABSApi
import Foundation
import TestSupport
import Testing

@testable import SyncEngine

@Suite struct ServerPodcastAutomationSettingsServiceTests {
  private let change = PodcastAutomationSettingsRequest(maxEpisodesToKeep: 10)
  private let matching = PodcastAutomationSettingsResult(
    autoDownloadEpisodes: true, autoDownloadSchedule: "0 * * * *",
    maxNewEpisodesToDownload: 3, maxEpisodesToKeep: 10)

  @Test func ineligibleAccountSendsNothing() async {
    let rig = Rig(capability: .none)
    let outcome = await rig.service.update(
      itemID: "show", change: change, confirmation: .refreshLocalRow)
    #expect(outcome == .notPermitted)
    #expect(await rig.client.sendCount == 0)
    #expect(rig.accounts.readCount == 0)
    #expect(rig.refresher.refreshCount == 0)
  }

  @Test func successRefreshesOnceAndConfirms() async {
    let rig = Rig()
    await rig.client.script([.success(matching)])
    let outcome = await rig.service.update(
      itemID: "show", change: change, confirmation: .refreshLocalRow)
    #expect(outcome == .confirmed(matching, refresh: .completed))
    #expect(await rig.client.sendCount == 1)
    #expect(rig.refresher.refreshCount == 1)
    #expect(rig.refresher.staleRefreshCount == 0)
    #expect(rig.capability.invalidationCount == 0)
  }

  @Test func forbiddenInvalidatesCapability() async {
    let rig = Rig()
    await rig.client.script([.failure(APIError.forbidden)])
    let outcome = await rig.service.update(
      itemID: "show", change: change, confirmation: .refreshLocalRow)
    #expect(outcome == .forbidden)
    #expect(rig.capability.invalidationCount == 1)
    #expect(rig.refresher.refreshCount == 0)
  }

  @Test func notFoundAndBadRequestAreDistinct() async {
    let rig = Rig()
    await rig.client.script([.failure(APIError.notFound), .failure(APIError.badRequest)])
    #expect(
      await rig.service.update(itemID: "s", change: change, confirmation: .refreshLocalRow)
        == .notFound)
    #expect(
      await rig.service.update(itemID: "s", change: change, confirmation: .refreshLocalRow)
        == .rejected)
    #expect(rig.capability.invalidationCount == 0)
    #expect(rig.refresher.refreshCount == 0)
  }

  @Test func transportLossIsUncertainWithoutRetryOrRefresh() async {
    let rig = Rig()
    await rig.client.script([.failure(APIError.transport)])
    let outcome = await rig.service.update(
      itemID: "show", change: change, confirmation: .refreshLocalRow)
    #expect(outcome == .uncertain)
    #expect(await rig.client.sendCount == 1)
    #expect(rig.refresher.refreshCount == 0)
  }

  @Test func clientSideValidationFailureIsInvalidRequest() async {
    let rig = Rig()
    await rig.client.script([.failure(PodcastWriteError.invalidValue(field: .maxEpisodesToKeep))])
    #expect(
      await rig.service.update(itemID: "s", change: change, confirmation: .refreshLocalRow)
        == .invalidRequest)
  }

  @Test func accountReplacedBetweenSendAndRefreshReportsNothing() async {
    let rig = Rig()
    await rig.client.script([.success(matching)])
    rig.accounts.replaceAfterReads(1)
    let outcome = await rig.service.update(
      itemID: "show", change: change, confirmation: .refreshLocalRow)
    #expect(outcome == .accountChanged)
    #expect(rig.refresher.refreshCount == 0)
  }

  @Test func fingerprintChangeAlsoCountsAsReplacement() async {
    let rig = Rig()
    await rig.client.script([.success(matching)])
    rig.accounts.replaceAfterReads(1, fingerprint: "other")
    let outcome = await rig.service.update(
      itemID: "show", change: change, confirmation: .refreshLocalRow)
    #expect(outcome == .accountChanged)
  }

  @Test func partialRefreshIsRepeatedExactlyOnce() async {
    let rig = Rig()
    await rig.client.script([.success(matching)])
    rig.refresher.script([.partial, .complete])
    let outcome = await rig.service.update(
      itemID: "show", change: change, confirmation: .refreshLocalRow)
    #expect(outcome == .confirmed(matching, refresh: .completed))
    #expect(rig.refresher.refreshCount == 2)
  }

  @Test func refreshThatKeepsFailingStopsAfterTwoCalls() async {
    let rig = Rig()
    await rig.client.script([.success(matching)])
    rig.refresher.script([.partial, .failure])
    let outcome = await rig.service.update(
      itemID: "show", change: change, confirmation: .refreshLocalRow)
    #expect(outcome == .confirmed(matching, refresh: .incomplete))
    #expect(rig.refresher.refreshCount == 2)
  }

  @Test func completeFirstRefreshIsNotRepeated() async {
    let rig = Rig()
    await rig.client.script([.success(matching)])
    rig.refresher.script([.complete, .complete])
    _ = await rig.service.update(itemID: "s", change: change, confirmation: .refreshLocalRow)
    #expect(rig.refresher.refreshCount == 1)
  }

  @Test func responseDisagreeingWithSentValueIsUnconfirmed() async {
    let rig = Rig()
    let stale = PodcastAutomationSettingsResult(maxEpisodesToKeep: 4)
    await rig.client.script([.success(stale)])
    let outcome = await rig.service.update(
      itemID: "show", change: change, confirmation: .refreshLocalRow)
    #expect(outcome == .unconfirmed(stale, refresh: .completed))
  }

  @Test func emptyResponseIsNotEvidence() async {
    let rig = Rig()
    await rig.client.script([.success(PodcastAutomationSettingsResult())])
    let outcome = await rig.service.update(
      itemID: "show", change: change, confirmation: .responseOnly)
    #expect(outcome == .unconfirmed(PodcastAutomationSettingsResult(), refresh: .notAttempted))
  }

  @Test func scheduleIsComparedAsItsCronString() async {
    let rig = Rig()
    let daily = PodcastAutomationSettingsRequest(autoDownloadSchedule: .daily)
    await rig.client.script([
      .success(PodcastAutomationSettingsResult(autoDownloadSchedule: "0 0 * * *"))
    ])
    let outcome = await rig.service.update(
      itemID: "show", change: daily, confirmation: .responseOnly)
    #expect(
      outcome
        == .confirmed(
          PodcastAutomationSettingsResult(autoDownloadSchedule: "0 0 * * *"),
          refresh: .notAttempted))
  }

  @Test func responseOnlyNeverRefreshes() async {
    let rig = Rig()
    await rig.client.script([.success(matching)])
    let outcome = await rig.service.update(
      itemID: "show", change: change, confirmation: .responseOnly)
    #expect(outcome == .confirmed(matching, refresh: .notAttempted))
    #expect(rig.refresher.refreshCount == 0)
    #expect(rig.refresher.staleRefreshCount == 0)
  }

  @Test func noOpWriterIsNotPermitted() async {
    let outcome = await NoOpServerPodcastAutomationSettingsWriting().update(
      itemID: "s", change: change, confirmation: .responseOnly)
    #expect(outcome == .notPermitted)
  }
}

// MARK: - Fakes

private struct Rig {
  let client = FakeClient()
  let capability: FakeServerPodcastMutationCapabilityReading
  let accounts = FakeNativeEpisodeServerSaveAccountReading(automationAccount())
  let refresher = FakePodcastRefreshing()
  let service: ServerPodcastAutomationSettingsService

  init(capability: ServerPodcastMutationCapability = .init(canSave: true, canRemove: false)) {
    let capability = FakeServerPodcastMutationCapabilityReading(capability)
    self.capability = capability
    service = ServerPodcastAutomationSettingsService(
      client: client, capabilityReader: capability, accountReader: accounts,
      refreshing: refresher)
  }
}

private actor FakeClient: ServerPodcastAutomationSettingsClient {
  private var results: [Result<PodcastAutomationSettingsResult, any Error>] = []
  private(set) var sendCount = 0

  func script(_ results: [Result<PodcastAutomationSettingsResult, any Error>]) {
    self.results = results
  }

  func updatePodcastAutomationSettings(
    account: TokenAccount, itemID: String, request: PodcastAutomationSettingsRequest
  ) async throws -> PodcastAutomationSettingsResult {
    sendCount += 1
    guard results.isEmpty == false else { throw APIError.transport }
    return try results.removeFirst().get()
  }
}

private let automationToken: TokenAccount = {
  let server = try! ABSServerConfig(url: URL(string: "https://books.example.test")!)
  return try! TokenAccount(server: server, userID: "user_fixture")
}()

/// The account every read serves until a test replaces it: `replaced` swaps the client fence, and
/// a `fingerprint` other than the default swaps the server identity instead.
private func automationAccount(
  replaced: Bool = false,
  fingerprint: String = "fingerprint"
) -> NativeEpisodeServerSaveAccount {
  NativeEpisodeServerSaveAccount(
    accountID: 1,
    clientUUID: replaced && fingerprint == "fingerprint" ? "replacement" : "client",
    serverIdentityFingerprint: replaced ? fingerprint : "fingerprint",
    tokenAccount: automationToken)
}

extension FakeNativeEpisodeServerSaveAccountReading {
  /// Serves the replaced account from the read after `reads` reads on.
  fileprivate func replaceAfterReads(_ reads: Int, fingerprint: String = "fingerprint") {
    stubAccounts { readNumber in
      automationAccount(replaced: readNumber > reads, fingerprint: fingerprint)
    }
  }
}

private enum RefreshStep { case complete, partial, failure }

extension FakePodcastRefreshing {
  /// Answers the next refreshes with `steps` in order, then `.complete`.
  fileprivate func script(_ steps: [RefreshStep]) {
    stubSequence(
      steps.map { step -> RefreshResult in
        switch step {
        case .complete: return .success(.complete)
        case .partial: return .success(.partial)
        case .failure: return .failure(PodcastRefreshError.itemUnavailable)
        }
      })
  }

  fileprivate var refreshCount: Int { refreshedItemIDs.count }
  fileprivate var staleRefreshCount: Int { staleRefreshedItemIDs.count }
}
