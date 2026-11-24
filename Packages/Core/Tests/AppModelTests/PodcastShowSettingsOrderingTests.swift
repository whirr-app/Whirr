import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite("Podcast show settings operation ordering", .timeLimit(.minutes(1)))
struct PodcastShowSettingsOrderingTests {
  @MainActor
  @Test func staleInitialCredentialLoadCannotOverwriteANewerSave() async throws {
    let access = OrderedCredentialAccess(holdInitialRead: true)
    let model = PodcastShowSettingsModel(
      itemID: try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId,
      reading: FakePodcastSettingsReading(), nativeFeedManaging: access)
    await access.waitForInitialRead()

    model.feedCredentialUsername = "listener"
    model.feedCredentialPassword = "secret"
    await model.requestSaveFeedCredential()?.value
    #expect(model.hasFeedCredential)

    await access.releaseInitialRead()
    await Task.yield()

    #expect(model.hasFeedCredential)
  }

  @MainActor
  @Test func newerCredentialFailurePublishesActualStateAfterOlderSuccess() async throws {
    let access = OrderedCredentialAccess(holdSave: true, clearFails: true)
    let model = PodcastShowSettingsModel(
      itemID: try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId,
      reading: FakePodcastSettingsReading(), nativeFeedManaging: access)
    await access.waitForInitialRead()
    model.feedCredentialUsername = "listener"
    model.feedCredentialPassword = "secret"

    let save = model.requestSaveFeedCredential()
    await access.waitForMutationCount(1)
    let remove = model.requestRemoveFeedCredential()
    await Task.yield()
    #expect(await access.mutations == [.save])

    await access.releaseSave()
    await access.waitForMutationCount(2)
    await save?.value
    await remove?.value

    #expect(await access.mutations == [.save, .clear])
    #expect(model.hasFeedCredential)
    #expect(model.actionErrorMessage == PodcastDownloadCopy.actionFailed)
  }

  @MainActor
  @Test func newerCredentialSuccessClearsAnOlderFailure() async throws {
    let access = OrderedCredentialAccess(
      initiallyConfigured: true, holdSave: true, saveFails: true)
    let model = PodcastShowSettingsModel(
      itemID: try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId,
      reading: FakePodcastSettingsReading(), nativeFeedManaging: access)
    await access.waitForInitialRead()
    #expect(await waitUntil { model.hasFeedCredential })
    model.feedCredentialUsername = "listener"
    model.feedCredentialPassword = "secret"

    let save = model.requestSaveFeedCredential()
    await access.waitForMutationCount(1)
    let remove = model.requestRemoveFeedCredential()
    await access.releaseSave()
    await access.waitForMutationCount(2)
    await save?.value
    await remove?.value

    #expect(await access.mutations == [.save, .clear])
    #expect(model.hasFeedCredential == false)
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test func rapidNotificationOverridesCommitAndReportErrorsInInvocationOrder() async throws {
    let writing = HeldNotificationOverrideWriting(outcomes: [.failure, .success])
    let model = PodcastShowSettingsModel(
      itemID: try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId,
      reading: FakePodcastSettingsReading(), writing: writing)

    let enable = model.requestNotificationOverride(.enabled)
    await writing.waitForCallCount(1)
    let disable = model.requestNotificationOverride(.disabled)
    await Task.yield()
    #expect(await writing.calls == [.enabled])

    await writing.completeCall(0)
    await writing.waitForCallCount(2)
    await writing.completeCall(1)
    await enable.value
    await disable.value

    #expect(await writing.calls == [.enabled, .disabled])
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test func refusedFeedEnableWritesNothingAndLaterOverridesStillCommit() async throws {
    let writing = HeldNotificationOverrideWriting(outcomes: [.success])
    let notifications = PodcastNotificationSettingsModel(
      preference: DisabledRSSNotificationIntent(),
      authorizer: BackgroundRefreshOffAuthorizer())
    let model = PodcastShowSettingsModel(
      itemID: try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId,
      reading: FakePodcastSettingsReading(), writing: writing,
      notificationSettings: notifications)

    await model.requestNotificationOverride(.enabled).value
    #expect(await writing.calls.isEmpty)
    #expect(model.notificationRefusal == .backgroundRefreshDenied)
    #expect(notifications.enableRefusal == nil)

    let disable = model.requestNotificationOverride(.disabled)
    await writing.waitForCallCount(1)
    await writing.completeCall(0)
    await disable.value
    #expect(await writing.calls == [.disabled])
  }
}

private struct BackgroundRefreshOffAuthorizer: RSSLocalNotificationAuthorizing {
  func authorizationStatus() async -> RSSLocalNotificationAuthorizationStatus { .allowed }
  func requestAuthorization() async -> RSSLocalNotificationAuthorizationStatus { .allowed }
  func backgroundRefreshStatus() async -> BackgroundRefreshStatus { .denied }
}

// Local rather than `FakeNativeFeedManaging`: the first credential read must stay suspended after
// its task is cancelled (the model cancels it when a save is requested) so the stale read
// completes after the newer save, and `FakeNativeFeedManaging.credentialReadGate` is not created
// with `ignoresCancellation: true`.
private actor OrderedCredentialAccess: NativeFeedManaging {
  enum Mutation: Equatable, Sendable { case save, clear }

  private var configured: Bool
  private let holdInitialRead: Bool
  private let holdSave: Bool
  private let saveFails: Bool
  private let clearFails: Bool
  private nonisolated let initialReadStarted = WaitableState(
    false, label: "OrderedCredentialAccess initial read started")
  private nonisolated let initialReadGate = TestGate<Void>(
    label: "OrderedCredentialAccess initial read", ignoresCancellation: true)
  private nonisolated let saveGate = TestGate<Void>(
    label: "OrderedCredentialAccess save", ignoresCancellation: true)
  private nonisolated let mutationRecorder = CallRecorder<Mutation>(
    label: "OrderedCredentialAccess mutations")
  var mutations: [Mutation] { mutationRecorder.calls }

  init(
    initiallyConfigured: Bool = false,
    holdInitialRead: Bool = false,
    holdSave: Bool = false,
    saveFails: Bool = false,
    clearFails: Bool = false
  ) {
    configured = initiallyConfigured
    self.holdInitialRead = holdInitialRead
    self.holdSave = holdSave
    self.saveFails = saveFails
    self.clearFails = clearFails
    if holdInitialRead { initialReadGate.hold() }
    if holdSave { saveGate.hold() }
  }

  func unsubscribe(feedId: Int64) async throws {}

  func hasCredential(feedId: Int64) async throws -> Bool {
    if initialReadStarted.value == false {
      initialReadStarted.mutate { $0 = true }
      let snapshot = configured
      await initialReadGate.pass()
      return snapshot
    }
    return configured
  }

  func saveBasicCredential(username: String, password: String, feedId: Int64) async throws {
    record(.save)
    await saveGate.pass()
    if saveFails { throw SettingsOrderingError.failed }
    configured = true
  }

  func clearCredential(feedId: Int64) async throws {
    record(.clear)
    if clearFails { throw SettingsOrderingError.failed }
    configured = false
  }

  func waitForInitialRead() async {
    await initialReadStarted.waitUntil("starting") { $0 }
  }

  // The read starts before it parks, so wait for the park before releasing it.
  func releaseInitialRead() async {
    guard holdInitialRead else { return }
    await initialReadGate.waitUntilParked()
    initialReadGate.releaseParked()
  }

  func releaseSave() async {
    guard holdSave else { return }
    await saveGate.waitUntilParked()
    saveGate.releaseParked()
  }

  func waitForMutationCount(_ count: Int) async {
    await mutationRecorder.waitUntil(count: count)
  }

  private func record(_ mutation: Mutation) {
    mutationRecorder.record(mutation)
  }
}

private enum SettingsOrderingError: Error { case failed }

private actor HeldNotificationOverrideWriting: PodcastSettingsWriting {
  enum Outcome: Sendable { case success, failure }

  private let outcomes: [Outcome]
  // One gate per call, so `completeCall(_:)` frees exactly the call it names. Each stays parked on
  // task cancellation, as the write it stands in for runs to completion.
  private nonisolated let gates = Locked<[Int: TestGate<Void>]>([:])
  private nonisolated let callRecorder = CallRecorder<RSSNotificationOverride>(
    label: "HeldNotificationOverrideWriting calls")
  var calls: [RSSNotificationOverride] { callRecorder.calls }

  init(outcomes: [Outcome]) { self.outcomes = outcomes }

  func setGlobalAutoDownloadEnabled(_ enabled: Bool) async throws {}
  func setGlobalKeepLatestCount(_ count: Int) async throws {}
  func setGlobalDeleteAfterPlayed(_ enabled: Bool) async throws {}
  func setGlobalAllowCellularAutoDownload(_ enabled: Bool) async throws {}
  func setShowAutoDownloadOverride(itemID: String, override: PodcastShowAutoDownloadOverride)
    async throws
  {}
  func setShowKeepLatestOverride(itemID: String, count: Int?) async throws {}
  func setShowDeleteAfterPlayedOverride(itemID: String, enabled: Bool?) async throws {}
  func setShowIncludeInLatest(itemID: String, enabled: Bool) async throws {}

  func setShowNotificationOverride(itemID: String, override: RSSNotificationOverride) async throws {
    let index = callRecorder.count
    let gate = TestGate<Void>(
      label: "HeldNotificationOverrideWriting call \(index)", ignoresCancellation: true)
    gate.hold()
    gates.withValue { $0[index] = gate }
    callRecorder.record(override)
    await gate.pass()
    if case .failure = outcomes[index] { throw SettingsOrderingError.failed }
  }

  func waitForCallCount(_ count: Int) async {
    await callRecorder.waitUntil(count: count)
  }

  func completeCall(_ index: Int) {
    guard let gate = gates.value[index] else {
      preconditionFailure("No held notification override call \(index)")
    }
    gate.release()
  }
}
