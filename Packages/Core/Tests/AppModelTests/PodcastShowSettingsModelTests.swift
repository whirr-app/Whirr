import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite(.timeLimit(.minutes(1))) struct PodcastShowSettingsModelTests {
  @MainActor
  @Test func dismissalCleanupClearsUnsavedFeedPassword() throws {
    let model = PodcastShowSettingsModel(
      itemID: try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId,
      reading: FakePodcastSettingsReading(),
      nativeFeedManaging: FakeNativeFeedManaging())
    model.feedCredentialPassword = "unsaved-password"

    model.clearTransientCredentialInput()

    #expect(model.feedCredentialPassword.isEmpty)
  }

  @MainActor
  @Test func nativeFeedLoadsAndUpdatesBasicCredentialsWithoutRetainingThePassword() async throws {
    let access = FakeNativeFeedManaging(configuredFeedIDs: [17])
    let model = PodcastShowSettingsModel(
      itemID: try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId,
      reading: FakePodcastSettingsReading(), nativeFeedManaging: access)

    #expect(model.supportsFeedCredentials)
    #expect(await waitUntil { model.hasFeedCredential })

    model.feedCredentialUsername = "listener"
    model.feedCredentialPassword = "secret"
    await model.saveFeedCredential()

    #expect(
      access.savedCredentials == [
        .saveBasicCredential(feedID: 17, username: "listener", password: "secret")
      ])
    #expect(model.hasFeedCredential)
    #expect(model.feedCredentialPassword.isEmpty)

    await model.removeFeedCredential()
    #expect(access.clearedFeedIDs == [17])
    #expect(model.hasFeedCredential == false)
  }

  @MainActor
  @Test func absShowNeverConsultsOrExposesFeedCredentials() async {
    let access = FakeNativeFeedManaging(configuredFeedIDs: [17])
    let model = PodcastShowSettingsModel(
      itemID: "abs-show", reading: FakePodcastSettingsReading(), nativeFeedManaging: access)

    #expect(model.supportsFeedCredentials == false)
    #expect(access.checkedFeedIDs.isEmpty)
  }

  @MainActor
  @Test func uncachedDetailDoesNotReadSynchronously() async {
    let detail = Self.detail(itemID: "show-1", title: "Daily News", override: .enabled)
    let reading = FakePodcastSettingsReading()
    let model = PodcastShowSettingsModel(
      itemID: "show-1", reading: reading, titleSeed: "Daily News")

    #expect(model.state == .loading)
    #expect(model.title == "Daily News")
    #expect(reading.currentReadCount == 0)

    reading.pushShowSettings(detail, itemID: "show-1")
    await waitUntil { model.state == .loaded }
    #expect(model.autoDownloadOverride == .enabled)
  }

  @MainActor
  @Test func titleSeedIsVisibleWhileAnUncachedDetailLoads() {
    let model = PodcastShowSettingsModel(
      itemID: "show-1", reading: FakePodcastSettingsReading(), titleSeed: "Daily News")

    #expect(model.state == .loading)
    #expect(model.title == "Daily News")
  }

  @MainActor
  @Test func showLoadsTitleOverridesEffectiveValuesAndServerDiagnostic() async {
    let reading = FakePodcastSettingsReading()
    let podcastReading = FakePodcastReading()
    let fixedNow = Date(timeIntervalSince1970: 1_700_100_000)
    let model = PodcastShowSettingsModel(
      itemID: "show-1", reading: reading, podcastReading: podcastReading, now: { fixedNow })

    let detail = Self.detail(
      itemID: "show-1", title: "Daily News", override: .enabled, keepLatestOverride: 5,
      deleteAfterPlayedOverride: true,
      effective: PodcastEffectiveSettings(
        isEnabled: true, keepLatestCount: 5, deleteAfterPlayed: true, floor: .distantPast))
    reading.pushShowSettings(detail, itemID: "show-1")
    let diagnostics = PodcastShowDiagnostics(
      autoDownloadEpisodes: true,
      autoDownloadSchedule: "0 0 * * *",
      lastEpisodeCheck: Date(timeIntervalSince1970: 1_699_000_000),
      maxEpisodesToKeep: 10,
      maxNewEpisodesToDownload: 3)
    podcastReading.pushDiagnostics(diagnostics, itemID: "show-1")
    await waitUntil { model.state == .loaded }

    #expect(model.title == "Daily News")
    #expect(model.autoDownloadOverride == .enabled)
    #expect(model.keepLatestOverride == 5)
    #expect(model.deleteAfterPlayedOverride == true)
    #expect(model.effective.isEnabled == true)
    await waitUntil { model.serverSettings != nil }
    #expect(
      model.serverSettings
        == PodcastServerSettingsPresentation.section(diagnostics: diagnostics, now: fixedNow))
    #expect(
      model.serverSettings?.rows.map(\.value) == ["On", "Every day", "3 episodes", "10 episodes"])
  }

  /// The server section reports the *server's* retention, the device pickers above it report this
  /// phone's. A show whose two numbers disagree is the case where a shared value would look
  /// plausible and be wrong, so it is the one pinned here.
  @MainActor
  @Test func serverRetentionNeverBorrowsTheDeviceKeepLatestCount() async {
    let reading = FakePodcastSettingsReading()
    let podcastReading = FakePodcastReading()
    let model = PodcastShowSettingsModel(
      itemID: "show-1", reading: reading, podcastReading: podcastReading)

    reading.pushShowSettings(
      Self.detail(
        itemID: "show-1", keepLatestOverride: 5,
        effective: PodcastEffectiveSettings(
          isEnabled: true, keepLatestCount: 5, deleteAfterPlayed: false, floor: .distantPast)),
      itemID: "show-1")
    podcastReading.pushDiagnostics(
      PodcastShowDiagnostics(
        autoDownloadEpisodes: false, lastEpisodeCheck: nil, maxEpisodesToKeep: 25),
      itemID: "show-1")
    await waitUntil { model.serverSettings != nil }

    #expect(model.keepLatestOverride == 5)
    #expect(
      model.serverSettings?.rows.first(where: { $0.field == .retention })?.value == "25 episodes")
  }

  @MainActor
  @Test func changingOverridePersists() async {
    let reading = FakePodcastSettingsReading()
    let writing = FakeShowSettingsWriting()
    let model = PodcastShowSettingsModel(itemID: "show-1", reading: reading, writing: writing)
    reading.pushShowSettings(Self.detail(itemID: "show-1"), itemID: "show-1")
    await waitUntil { model.state == .loaded }

    await model.setAutoDownloadOverride(.enabled)
    await model.setKeepLatestOverride(10)
    await model.setKeepLatestOverride(nil)
    await model.setDeleteAfterPlayedOverride(true)
    await model.setIncludeInLatest(false)

    #expect(
      await writing.calls == [
        .setShowAutoDownloadOverride("show-1", .enabled),
        .setShowKeepLatestOverride("show-1", 10),
        .setShowKeepLatestOverride("show-1", nil),
        .setShowDeleteAfterPlayedOverride("show-1", true),
        .setShowIncludeInLatest("show-1", false),
      ])
    #expect(model.actionErrorMessage == nil)
  }

  /// Reaching Show Settings from Settings > Podcasts never passes through the show screen, which
  /// is the only thing that fetches the item detail those five server fields arrive on. Without
  /// this fetch the section is permanently absent on that route: the library sync writes nil for
  /// these columns and the background refresh takes the recent-episodes path, so nothing else ever
  /// fills them.
  @MainActor
  @Test func absentServerSettingsFetchTheShowDetailOnce() async {
    let reading = FakePodcastSettingsReading()
    let podcastReading = FakePodcastReading()
    let refreshing = FakePodcastRefreshing()
    let model = PodcastShowSettingsModel(
      itemID: "show-1", reading: reading, podcastReading: podcastReading, refreshing: refreshing)

    podcastReading.pushDiagnostics(nil, itemID: "show-1")

    #expect(await waitUntil { refreshing.refreshedItemIDs == ["show-1"] })
    _ = model
  }

  /// Arriving from the show screen, the detail fetch has already run and the section is cached.
  /// Re-fetching it on every visit would be a redundant `expanded=1` request (rule 15) for a
  /// value already on screen.
  @MainActor
  @Test func cachedServerSettingsFetchNothing() async {
    let reading = FakePodcastSettingsReading()
    let podcastReading = FakePodcastReading()
    let refreshing = FakePodcastRefreshing()
    let model = PodcastShowSettingsModel(
      itemID: "show-1", reading: reading, podcastReading: podcastReading, refreshing: refreshing)

    podcastReading.pushDiagnostics(
      PodcastShowDiagnostics(
        autoDownloadEpisodes: true, lastEpisodeCheck: nil, maxEpisodesToKeep: 10),
      itemID: "show-1")
    await waitUntil { model.serverSettings != nil }

    #expect(refreshing.refreshedItemIDs.isEmpty)
  }

  /// A show the server genuinely knows nothing about keeps yielding nil. One fetch answers that
  /// question; repeating it on every subsequent observation would be the fixed-interval retry
  /// loop rule 14 forbids.
  @MainActor
  @Test func stillAbsentServerSettingsDoNotFetchAgain() async {
    let reading = FakePodcastSettingsReading()
    let podcastReading = FakePodcastReading()
    let refreshing = FakePodcastRefreshing()
    let model = PodcastShowSettingsModel(
      itemID: "show-1", reading: reading, podcastReading: podcastReading, refreshing: refreshing)

    podcastReading.pushDiagnostics(nil, itemID: "show-1")
    #expect(await waitUntil { refreshing.refreshedItemIDs.count == 1 })

    podcastReading.pushDiagnostics(nil, itemID: "show-1")
    // The third value is the settling point: observing it proves the second was processed.
    podcastReading.pushDiagnostics(
      PodcastShowDiagnostics(
        autoDownloadEpisodes: false, lastEpisodeCheck: nil, maxEpisodesToKeep: 4),
      itemID: "show-1")
    await waitUntil { model.serverSettings != nil }

    #expect(refreshing.refreshedItemIDs.count == 1)
  }

  /// SwiftUI builds a navigation destination's model more than once, and `PodcastRefreshCoordinator`
  /// cancels the whole in-flight request once its last waiter goes away. A fill cancelled by a
  /// discarded model writes nothing at all, and the `try?` around it hides that. The durable write
  /// is the point of this fetch, not the screen update, so it has to outlive the model that asked.
  @MainActor
  @Test func aDiscardedModelDoesNotCancelTheServerFill() async {
    let reading = FakePodcastSettingsReading()
    let podcastReading = FakePodcastReading()
    let refreshing = FakePodcastRefreshing()
    refreshing.gate.hold()
    var model: PodcastShowSettingsModel? = PodcastShowSettingsModel(
      itemID: "show-1", reading: reading, podcastReading: podcastReading, refreshing: refreshing)

    podcastReading.pushDiagnostics(nil, itemID: "show-1")
    #expect(await refreshing.gate.waitUntilParked().isObserved)

    model = nil
    #expect(model == nil)
    refreshing.gate.release(.success(.complete))

    // A cancelled parked call would have returned before the release and counted as cancelled.
    #expect(await waitUntil { refreshing.completedCallCount == 1 })
    #expect(refreshing.cancelledCallCount == 0)
  }

  @MainActor
  @Test func defaultLabelsNameTheCurrentEffectiveValue() async {
    let reading = FakePodcastSettingsReading()
    let model = PodcastShowSettingsModel(itemID: "show-1", reading: reading)
    reading.pushShowSettings(
      Self.detail(
        itemID: "show-1", override: .inherit, keepLatestOverride: nil,
        deleteAfterPlayedOverride: nil,
        effective: PodcastEffectiveSettings(
          isEnabled: true, keepLatestCount: 3, deleteAfterPlayed: false, floor: .distantPast)),
      itemID: "show-1")
    await waitUntil { model.state == .loaded }

    #expect(model.autoDownloadOverrideLabel == "Default (On)")
    #expect(model.keepLatestOverrideLabel == "Default (3)")
    #expect(model.keepLatestOverrideLabel != "Default")
    #expect(model.deleteAfterPlayedOverrideLabel == "Default (Off)")
  }

  @MainActor
  @Test func unknownShowYieldsNotFound() async {
    let reading = FakePodcastSettingsReading()
    let model = PodcastShowSettingsModel(itemID: "missing-show", reading: reading)
    reading.pushShowSettings(nil, itemID: "missing-show")

    await waitUntil { model.state == .notFound }
  }

  @MainActor
  @Test func stateHintDescribesWhatWillHappen() async {
    let reading = FakePodcastSettingsReading()
    let model = PodcastShowSettingsModel(itemID: "show-1", reading: reading)
    reading.pushShowSettings(
      Self.detail(
        itemID: "show-1",
        effective: PodcastEffectiveSettings(
          isEnabled: true, keepLatestCount: 3, deleteAfterPlayed: false, floor: .distantPast)),
      itemID: "show-1")
    await waitUntil { model.state == .loaded }
    #expect(model.stateHint == "Keeping 3 newest on this device")

    reading.pushShowSettings(
      Self.detail(
        itemID: "show-1",
        effective: PodcastEffectiveSettings(
          isEnabled: true, keepLatestCount: 0, deleteAfterPlayed: false, floor: .distantPast)),
      itemID: "show-1")
    await waitUntil { model.stateHint == "Keeping new episodes on this device" }
  }

  @MainActor
  @Test func stateHintIsAbsentWhenAutoDownloadResolvesOff() async {
    let reading = FakePodcastSettingsReading()
    let model = PodcastShowSettingsModel(itemID: "show-1", reading: reading)
    reading.pushShowSettings(
      Self.detail(
        itemID: "show-1",
        effective: PodcastEffectiveSettings(
          isEnabled: false, keepLatestCount: 3, deleteAfterPlayed: false, floor: .distantPast)),
      itemID: "show-1")
    await waitUntil { model.state == .loaded }

    #expect(model.stateHint == nil)
  }

  @MainActor
  @Test func serverDiagnosticIsReadOnlyAndIndependentOfLocalSetting() async {
    let reading = FakePodcastSettingsReading()
    let podcastReading = FakePodcastReading()
    let model = PodcastShowSettingsModel(
      itemID: "show-1", reading: reading, podcastReading: podcastReading)
    let diagnostics = PodcastShowDiagnostics(autoDownloadEpisodes: true, lastEpisodeCheck: nil)
    podcastReading.pushDiagnostics(diagnostics, itemID: "show-1")
    reading.pushShowSettings(
      Self.detail(itemID: "show-1", override: .inherit), itemID: "show-1")
    await waitUntil { model.serverSettings != nil }
    let firstServerSettings = model.serverSettings

    // Changing the local override, with no new diagnostics emission, must not move the server
    // section. It is read-only and reports a different fact (the server's own RSS setting, not
    // this device's retention policy).
    reading.pushShowSettings(
      Self.detail(itemID: "show-1", override: .enabled), itemID: "show-1")
    await waitUntil { model.autoDownloadOverride == .enabled }

    #expect(model.serverSettings == firstServerSettings)
  }

  /// A show the server has told us nothing about renders no section at all, rather than a header
  /// over an empty group.
  @MainActor
  @Test func aShowWithNoServerFactsHasNoSection() async {
    let reading = FakePodcastSettingsReading()
    let podcastReading = FakePodcastReading()
    let model = PodcastShowSettingsModel(
      itemID: "show-1", reading: reading, podcastReading: podcastReading)
    podcastReading.pushDiagnostics(
      PodcastShowDiagnostics(autoDownloadEpisodes: nil, lastEpisodeCheck: nil), itemID: "show-1")
    reading.pushShowSettings(Self.detail(itemID: "show-1"), itemID: "show-1")
    await waitUntil { model.state == .loaded }

    #expect(model.serverSettings == nil)
  }

  /// Which kind of show this is comes from the id alone, so an ABS show says so before the server
  /// has told us anything about it.
  @MainActor
  @Test func absShowNamesAudiobookshelfAsItsSource() async {
    let model = PodcastShowSettingsModel(itemID: "show-1", reading: FakePodcastSettingsReading())

    #expect(model.source == .audiobookshelf)
    #expect(model.sourceSection?.rows.map(\.value) == ["Audiobookshelf"])
  }

  /// An RSS show's diagnostics are this device's own feed settings and refresh time. They must
  /// never surface under the "Audiobookshelf Server" header, and there is no server detail to
  /// fetch when they are absent, so the section stays nil and the refresh is never requested.
  @MainActor
  @Test func rssShowNeverBuildsAServerSectionOrRequestsAServerFill() async throws {
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId
    let reading = FakePodcastSettingsReading()
    let podcastReading = FakePodcastReading()
    let refreshing = FakePodcastRefreshing()
    let fixedNow = Date(timeIntervalSince1970: 1_700_100_000)
    let model = PodcastShowSettingsModel(
      itemID: itemID, reading: reading, podcastReading: podcastReading, refreshing: refreshing,
      now: { fixedNow })

    podcastReading.pushDiagnostics(
      PodcastShowDiagnostics(
        autoDownloadEpisodes: true,
        lastEpisodeCheck: fixedNow.addingTimeInterval(-3600),
        maxEpisodesToKeep: 5),
      itemID: itemID)
    reading.pushShowSettings(Self.detail(itemID: itemID), itemID: itemID)
    await waitUntil { model.state == .loaded }
    await waitUntil { model.sourceSection?.footer.contains("Last checked") == true }

    #expect(model.source == .rssFeed)
    #expect(model.serverSettings == nil)
    #expect(model.sourceSection?.footer.hasPrefix("Last checked 1 hour ago.") == true)

    podcastReading.pushDiagnostics(nil, itemID: itemID)
    await waitUntil { model.sourceSection?.footer.contains("Last checked") == false }
    #expect(model.serverSettings == nil)
    #expect(refreshing.refreshedItemIDs.isEmpty)
  }

  /// The feed URL comes from the followed-show projection and lands in the Source section as it
  /// arrives; the section exists before then, naming the source, rather than waiting for it.
  @MainActor
  @Test func rssShowNamesTheFeedItIsFollowedFrom() async throws {
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId
    let feedURL = try #require(URL(string: "https://example.com/feed.xml"))
    let shows = FakeNativePodcastShowsReading()
    let model = PodcastShowSettingsModel(
      itemID: itemID, reading: FakePodcastSettingsReading(), nativeShowsReading: shows)

    #expect(model.sourceSection?.rows.map(\.field) == [.source])

    shows.pushShow(
      ItemSummary(
        serverItemId: itemID, mediaKind: "podcast", title: "Feed", author: nil,
        durationSeconds: nil, category: .podcast, artworkFeedURL: feedURL),
      itemID: itemID)
    await waitUntil { model.sourceSection?.rows.count == 2 }

    #expect(model.sourceSection?.rows.map(\.field) == [.source, .feedURL])
    #expect(model.sourceSection?.rows.last?.value == feedURL.absoluteString)
  }

  /// An ABS show has no feed to observe: the native projection is never consulted.
  @MainActor
  @Test func absShowNeverObservesTheNativeShowProjection() async {
    let shows = FakeNativePodcastShowsReading()
    let model = PodcastShowSettingsModel(
      itemID: "show-1", reading: FakePodcastSettingsReading(), nativeShowsReading: shows)

    #expect(model.sourceSection?.rows.map(\.field) == [.source])
    #expect(shows.observedItemIDs.isEmpty)
  }

  private static func detail(
    itemID: String,
    title: String = "Show",
    override: PodcastShowAutoDownloadOverride = .inherit,
    keepLatestOverride: Int? = nil,
    deleteAfterPlayedOverride: Bool? = nil,
    includeInLatest: Bool? = nil,
    effective: PodcastEffectiveSettings = PodcastEffectiveSettings(
      isEnabled: false, keepLatestCount: 3, deleteAfterPlayed: false, floor: .distantPast)
  ) -> PodcastShowSettingsDetail {
    PodcastShowSettingsDetail(
      itemID: itemID,
      title: title,
      autoDownloadOverride: override,
      keepLatestOverride: keepLatestOverride,
      deleteAfterPlayedOverride: deleteAfterPlayedOverride,
      enabledAt: nil,
      effective: effective,
      includeInLatest: includeInLatest)
  }
}

private actor FakeShowSettingsWriting: PodcastSettingsWriting {
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

  func setGlobalAutoDownloadEnabled(_ enabled: Bool) async throws {
    calls.append(.setGlobalAutoDownloadEnabled(enabled))
  }
  func setGlobalKeepLatestCount(_ count: Int) async throws {
    calls.append(.setGlobalKeepLatestCount(count))
  }
  func setGlobalDeleteAfterPlayed(_ enabled: Bool) async throws {
    calls.append(.setGlobalDeleteAfterPlayed(enabled))
  }
  func setGlobalAllowCellularAutoDownload(_ enabled: Bool) async throws {
    calls.append(.setGlobalAllowCellularAutoDownload(enabled))
  }
  func setShowAutoDownloadOverride(itemID: String, override: PodcastShowAutoDownloadOverride)
    async throws
  {
    calls.append(.setShowAutoDownloadOverride(itemID, override))
  }
  func setShowKeepLatestOverride(itemID: String, count: Int?) async throws {
    calls.append(.setShowKeepLatestOverride(itemID, count))
  }
  func setShowDeleteAfterPlayedOverride(itemID: String, enabled: Bool?) async throws {
    calls.append(.setShowDeleteAfterPlayedOverride(itemID, enabled))
  }
  func setShowIncludeInLatest(itemID: String, enabled: Bool) async throws {
    calls.append(.setShowIncludeInLatest(itemID, enabled))
  }
}

extension FakeNativeFeedManaging {
  fileprivate var checkedFeedIDs: [Int64] {
    calls.compactMap { call -> Int64? in
      if case .hasCredential(let feedID) = call { return feedID }
      return nil
    }
  }

  fileprivate var savedCredentials: [Call] {
    calls.filter { call in
      if case .saveBasicCredential = call { return true }
      return false
    }
  }

  fileprivate var clearedFeedIDs: [Int64] {
    calls.compactMap { call -> Int64? in
      if case .clearCredential(let feedID) = call { return feedID }
      return nil
    }
  }
}
