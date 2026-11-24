import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite struct PodcastShowModelTests {
  @MainActor
  @Test("a deep-linked filter is selected before the show first renders")
  func initialFilterIsAppliedDuringInitialization() {
    let model = PodcastShowModel(
      itemID: "show-1", reading: FakePodcastReading(), initialFilter: .downloaded)

    #expect(model.filter == .downloaded)
  }

  @MainActor
  @Test("a native show observes its durable recovery marker")
  func nativeRecoveryProjectionIsVisible() async {
    let model = PodcastShowModel(
      itemID: "rss:7", reading: FakePodcastReading(),
      nativeFeedRecoveryReading: StaticShowRecoveryReading(feedIDs: [7]))

    await waitUntil { model.needsAttention }

    #expect(model.isNativeFeed)
    #expect(model.needsAttention)
  }

  @MainActor
  @Test("download progress is read per episode from its own projection and cleared on show change")
  func downloadProgressIsReadPerEpisodeFromItsOwnProjection() async {
    let reading = FakePodcastReading()
    let model = PodcastShowModel(itemID: "rss:1", reading: reading)

    #expect(model.downloadProgressFraction(for: "episode-1") == nil)

    reading.pushDownloadProgress(["episode-1": 0.42], itemID: "rss:1")
    await waitUntil { model.downloadProgressFraction(for: "episode-1") == 0.42 }
    #expect(model.downloadProgressFraction(for: "episode-2") == nil)
    // The list itself is untouched by progress: it was never pushed and stays empty.
    #expect(model.episodes.isEmpty)

    model.show(itemID: "rss:2")
    #expect(model.downloadProgressFraction(for: "episode-1") == nil)
    await waitUntil { reading.terminatedObservations.contains(.downloadProgress(itemID: "rss:1")) }
    reading.pushDownloadProgress(["episode-1": 0.9], itemID: "rss:1")
    reading.pushDownloadProgress(["episode-9": 0.1], itemID: "rss:2")
    await waitUntil { model.downloadProgressFraction(for: "episode-9") == 0.1 }
    #expect(model.downloadProgressFraction(for: "episode-1") == nil)
  }

  @MainActor
  @Test("saved membership is withheld when the show has no status store")
  func savedMembershipIsNilWithoutStore() {
    let model = PodcastShowModel(itemID: "show-1", reading: FakePodcastReading())

    #expect(model.isSaved(episodeID: "episode-1") == nil)
  }

  @MainActor
  @Test("saved membership is withheld until the status store resolves")
  func savedMembershipIsNilWhileUnresolved() {
    let reading = FakeSavedShelfReading()
    let status = SavedStatusStore(savedShelf: reading)
    let model = PodcastShowModel(
      itemID: "show-1", reading: FakePodcastReading(), savedStatus: status)

    #expect(status.hasResolvedMembership == false)
    #expect(model.isSaved(episodeID: "episode-1") == nil)
  }

  @MainActor
  @Test("saved membership reflects the resolved episode projection")
  func savedMembershipReflectsResolvedProjection() async {
    let reading = FakeSavedShelfReading()
    let status = SavedStatusStore(savedShelf: reading)
    let model = PodcastShowModel(
      itemID: "show-1", reading: FakePodcastReading(), savedStatus: status)
    let identity = SavedShelfIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1")

    reading.pushSavedIdentities([identity])
    await waitUntil { model.isSaved(episodeID: "episode-1") == true }

    reading.pushSavedIdentities([])
    await waitUntil { model.isSaved(episodeID: "episode-1") == false }
  }

  @MainActor
  @Test("Continue Listening visibility is scoped to the exact show episode")
  func continueListeningVisibilityReflectsEpisodeProjection() throws {
    let identity = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))
    let visibility = ContinueListeningVisibilityStore(hidden: [identity])
    let model = PodcastShowModel(
      itemID: "show-1",
      reading: FakePodcastReading(),
      continueListeningVisibility: visibility)

    #expect(model.isHiddenFromContinueListening(episodeID: "episode-1"))
    #expect(model.isHiddenFromContinueListening(episodeID: "episode-2") == false)
    #expect(
      PodcastShowModel(itemID: "show-1", reading: FakePodcastReading())
        .isHiddenFromContinueListening(episodeID: "episode-1") == false)
  }

  @MainActor
  @Test("the appear refresh is stale-gated and pull-to-refresh is not")
  func appearRefreshIsStaleGatedAndPullToRefreshIsNot() async {
    let reading = FakePodcastReading()
    let refresh = FakePodcastRefreshing()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, refreshing: refresh)

    await model.refreshOnAppear()
    #expect(refresh.calls.count == 1)
    #expect(
      refresh.calls == [
        .refreshIfStale(
          itemID: "show-1", maximumAge: PodcastShowModel.appearRefreshMaximumAge)
      ])
    #expect(model.state == .empty)

    await model.refresh()
    #expect(refresh.calls.count == 2)
    #expect(
      refresh.calls == [
        .refreshIfStale(
          itemID: "show-1", maximumAge: PodcastShowModel.appearRefreshMaximumAge),
        .refresh(itemID: "show-1"),
      ])
  }

  @MainActor
  @Test("the cache counts as read only once its first value arrives, and resets on a show change")
  func episodeCacheReadIsTrackedPerShow() async {
    let reading = FakePodcastReading()
    let refresh = FakePodcastRefreshing()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, refreshing: refresh)
    refresh.gate.hold()
    let task = Task { await model.refreshOnAppear() }
    await refresh.recorder.waitUntil(count: 1)

    // The appear refresh starts before the cache answers; that is not yet an empty show.
    #expect(model.state == .refreshing)
    #expect(model.hasReadEpisodeCache == false)

    reading.pushEpisodes([], itemID: "show-1")
    await waitUntil { model.hasReadEpisodeCache }

    model.show(itemID: "show-2")
    #expect(model.hasReadEpisodeCache == false)
    refresh.gate.release(.success(.complete))
    await task.value
  }

  @MainActor
  @Test("a show with a cached baseline has its episodes before any observation value arrives")
  func cachedBaselineIsPresentAtCreationAndOnShowChange() {
    let reading = FakePodcastReading()
    let first = Self.episode(id: "episode-1")
    reading.stubEpisodePrefix(.init(episodes: [first], isComplete: true), itemID: "show-1")
    reading.stubEpisodePrefix(.init(episodes: [], isComplete: true), itemID: "show-2")

    // No push and no await: the screen's first frame reads the model straight after creation.
    let model = PodcastShowModel(itemID: "show-1", reading: reading)
    #expect(model.episodes == [first])
    #expect(model.hasReadEpisodeCache)
    #expect(model.state == .loaded)

    model.show(itemID: "show-2")
    #expect(model.episodes.isEmpty)
    #expect(model.hasReadEpisodeCache)
    #expect(model.state == .empty)

    model.show(itemID: "show-3")
    #expect(model.hasReadEpisodeCache == false)
    #expect(model.state == .loading)
  }

  @MainActor
  @Test("the first-frame read is bounded, and a cut-short prefix waits for the full list")
  func cutShortBaselineShowsRowsWithoutAnsweringForTheCache() async {
    let reading = FakePodcastReading()
    let leading = (1...3).map { Self.episode(id: "episode-\($0)") }
    let all = leading + [Self.episode(id: "episode-4")]
    reading.stubEpisodePrefix(.init(episodes: leading, isComplete: false), itemID: "show-1")

    let model = PodcastShowModel(itemID: "show-1", reading: reading, initialFilter: .downloaded)
    #expect(reading.requestedPrefixLimits == [PodcastShowModel.firstFrameEpisodeLimit])
    #expect(model.episodes == leading)
    #expect(model.state == .loaded)
    // None of the leading rows is downloaded; the hidden rest may be, so nothing claims "no match".
    #expect(model.hasReadEpisodeCache == false)

    reading.pushEpisodes(all, itemID: "show-1")
    await waitUntil { model.episodes == all }
    #expect(model.hasReadEpisodeCache)
    #expect(model.state == .loaded)
  }

  @MainActor
  @Test("cached episodes render immediately and remain visible while refreshing")
  func cachedFirstAndRefreshing() async {
    let reading = FakePodcastReading()
    let refresh = FakePodcastRefreshing()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, refreshing: refresh)
    let episode = Self.episode(id: "episode-1")

    reading.pushEpisodes([episode], itemID: "show-1")
    await waitUntil { model.episodes == [episode] }
    refresh.gate.hold()
    let task = Task { await model.refresh() }
    await refresh.recorder.waitUntil(count: 1)

    #expect(model.state == .refreshing)
    #expect(model.episodes == [episode])

    refresh.gate.release(.success(.complete))
    await task.value
    #expect(model.state == .loaded)
  }

  @MainActor
  @Test("empty, partial, stale offline, and recoverable error states have copy")
  func explicitStatesHaveCopy() async {
    let reading = FakePodcastReading()
    let refresh = FakePodcastRefreshing()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, refreshing: refresh)
    reading.pushEpisodes([], itemID: "show-1")
    await waitUntil { model.state == .empty }
    #expect(model.state.copyText.isEmpty == false)

    refresh.stub(.success(.partial))
    await model.refresh()
    #expect(model.state == .partiallyDecoded)

    reading.pushEpisodes([Self.episode(id: "cached")], itemID: "show-1")
    await waitUntil { model.episodes.isEmpty == false }
    refresh.stub(.failure(PodcastFixtureError.offline))
    await model.refresh()
    #expect(model.state == .staleOffline)

    reading.pushEpisodes([], itemID: "show-1")
    await waitUntil { model.episodes.isEmpty }
    await model.refresh()
    #expect(model.state == .recoverableError)
    #expect(Set(PodcastShowModel.State.allCases.map(\.copyKey)).count == PodcastShowModel.State.allCases.count)
  }

  @MainActor
  @Test("a cached yield arriving after a fast offline failure settles as stale offline")
  func cachedYieldAfterOfflineFailure() async {
    let reading = FakePodcastReading()
    let refresh = FakePodcastRefreshing()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, refreshing: refresh)
    refresh.stub(.failure(PodcastFixtureError.offline))

    await model.refresh()
    #expect(model.state == .recoverableError)

    reading.pushEpisodes([Self.episode(id: "cached")], itemID: "show-1")
    await waitUntil { model.episodes.isEmpty == false }
    #expect(model.state == .staleOffline)
  }

  @MainActor
  @Test("played, unplayed, and downloaded filters are deterministic")
  func filters() async {
    let reading = FakePodcastReading()
    let model = PodcastShowModel(itemID: "show-1", reading: reading)
    reading.pushEpisodes(
      [
        Self.episode(id: "unplayed"),
        Self.episode(id: "played", isPlayed: true),
        Self.episode(id: "downloaded", downloadStatus: .completed),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 3 }

    model.filter = .played
    #expect(model.filteredEpisodes.map(\.id) == ["played"])
    model.filter = .unplayed
    #expect(model.filteredEpisodes.map(\.id) == ["unplayed", "downloaded"])
    model.filter = .downloaded
    #expect(model.filteredEpisodes.map(\.id) == ["downloaded"])
  }

  @MainActor
  @Test("episode search combines with the status filter and scopes bulk actions")
  func episodeSearchCombinesWithStatusFilterAndBulkActions() async {
    let reading = FakePodcastReading()
    let model = PodcastShowModel(itemID: "show-1", reading: reading)
    reading.pushEpisodes(
      [
        Self.episode(id: "title-match", title: "Islam and Europe"),
        Self.episode(
          id: "description-match", title: "The Abbasids", description: "A history of Islam",
          isPlayed: true, isFinished: true),
        Self.episode(id: "no-match", title: "Plate Tectonics"),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 3 }

    model.episodeQuery = "islam"
    #expect(model.filteredEpisodes.map(\.id) == ["title-match", "description-match"])

    model.filter = .unplayed
    #expect(model.filteredEpisodes.map(\.id) == ["title-match"])
    #expect(model.showMenuCounts.unplayed == 1)
    #expect(model.episodesToMark(isFinished: true).map(\.id) == ["title-match"])

    model.episodeQuery = " . "
    #expect(model.filteredEpisodes.map(\.id) == ["title-match", "no-match"])
  }

  @MainActor
  @Test("a held episode search follows a cache update that changes an episode's text")
  func episodeSearchFollowsEpisodeTextChanges() async {
    let reading = FakePodcastReading()
    let model = PodcastShowModel(itemID: "show-1", reading: reading)
    reading.pushEpisodes(
      [
        Self.episode(id: "a", title: "Islam and Europe"),
        Self.episode(id: "b", title: "The Abbasids", description: "Baghdad"),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 2 }

    model.episodeQuery = "islam"
    #expect(model.filteredEpisodes.map(\.id) == ["a"])
    #expect(model.filteredEpisodes.map(\.id) == ["a"])

    reading.pushEpisodes(
      [
        Self.episode(id: "a", title: "Islam and Europe"),
        Self.episode(id: "b", title: "The Abbasids", description: "A history of Islam"),
        Self.episode(id: "c", title: "Islamic Spain", isPlayed: true),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 3 }

    #expect(model.filteredEpisodes.map(\.id) == ["a", "b", "c"])
    model.filter = .played
    #expect(model.filteredEpisodes.map(\.id) == ["c"])
    model.episodeQuery = "abbasids"
    #expect(model.filteredEpisodes.isEmpty)
    model.filter = .all
    #expect(model.filteredEpisodes.map(\.id) == ["b"])
  }

  @MainActor
  @Test("warming the episode search keys leaves the first keystroke nothing to canonicalize")
  func warmedEpisodeSearchNeedsNoKeysOnTheFirstKeystroke() async {
    let reading = FakePodcastReading()
    let model = PodcastShowModel(itemID: "show-1", reading: reading)
    reading.pushEpisodes(
      [
        Self.episode(id: "a", title: "Islam and Europe"),
        Self.episode(id: "b", title: "The Abbasids", description: "Baghdad"),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 2 }

    await model.warmEpisodeSearchKeys()?.value
    #expect(model.warmEpisodeSearchKeys() == nil)

    model.episodeQuery = "islam"
    #expect(model.filteredEpisodes.map(\.id) == ["a"])
    #expect(model.episodeSearchKeyComputations == 0)
  }

  @MainActor
  @Test("a warmup that finishes after the show has changed is discarded")
  func episodeSearchWarmupForAPreviousShowIsDiscarded() async {
    let reading = FakePodcastReading()
    let model = PodcastShowModel(itemID: "show-1", reading: reading)
    reading.pushEpisodes([Self.episode(id: "a", title: "Islam and Europe")], itemID: "show-1")
    await waitUntil { model.episodes.count == 1 }

    let warmup = model.warmEpisodeSearchKeys()
    model.show(itemID: "show-2")
    await warmup?.value

    #expect(model.episodeSearchKeyEntryCount == 0)
  }

  @MainActor
  @Test("show menu counts match bulk action counts across filters")
  func showMenuCountsMatchBulkActionCountsAcrossFilters() async {
    let reading = FakePodcastReading()
    let model = PodcastShowModel(itemID: "show-1", reading: reading)
    reading.pushEpisodes(
      [
        Self.episode(id: "not-downloaded", isFinished: false),
        Self.episode(
          id: "downloading", isPlayed: true, isFinished: true,
          downloadStatus: .downloading(progressFraction: 0.4)),
        Self.episode(id: "completed", isFinished: false, downloadStatus: .completed),
        Self.episode(id: "deleting", isPlayed: true, isFinished: true, downloadStatus: .deleting),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 4 }

    #expect(model.showMenuCounts.unplayed == model.episodesToMark(isFinished: true).count)
    #expect(model.showMenuCounts.played == model.episodesToMark(isFinished: false).count)
    #expect(model.showMenuCounts.downloadable == model.episodesToDownload().count)
    #expect(model.showMenuCounts.removable == model.episodesToRemove().count)

    model.filter = .unplayed

    #expect(model.showMenuCounts.unplayed == model.episodesToMark(isFinished: true).count)
    #expect(model.showMenuCounts.played == model.episodesToMark(isFinished: false).count)
    #expect(model.showMenuCounts.downloadable == model.episodesToDownload().count)
    #expect(model.showMenuCounts.removable == model.episodesToRemove().count)
  }

  @MainActor
  @Test("show menu counts are zero when a filter has no matches")
  func showMenuCountsAreZeroWhenFilterHasNoMatches() async {
    let reading = FakePodcastReading()
    let model = PodcastShowModel(itemID: "show-1", reading: reading)
    reading.pushEpisodes([Self.episode(id: "not-downloaded")], itemID: "show-1")
    await waitUntil { model.episodes.count == 1 }

    model.filter = .downloaded

    #expect(model.filteredEpisodes.isEmpty)
    #expect(model.showMenuCounts == .init(unplayed: 0, played: 0, downloadable: 0, removable: 0))
    #expect(model.showMenuCounts.unplayed == model.episodesToMark(isFinished: true).count)
    #expect(model.showMenuCounts.played == model.episodesToMark(isFinished: false).count)
    #expect(model.showMenuCounts.downloadable == model.episodesToDownload().count)
    #expect(model.showMenuCounts.removable == model.episodesToRemove().count)
  }

  @MainActor
  @Test("duplicate refresh calls share one intent and diagnostics update independently")
  func duplicateRefreshAndDiagnostics() async {
    let reading = FakePodcastReading()
    let refresh = FakePodcastRefreshing()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, refreshing: refresh)
    let diagnostics = PodcastShowDiagnostics(
      autoDownloadEpisodes: false,
      lastEpisodeCheck: Date(timeIntervalSince1970: 123))
    reading.pushDiagnostics(diagnostics, itemID: "show-1")
    await waitUntil { model.diagnostics == diagnostics }
    refresh.gate.hold()

    let first = Task { await model.refresh() }
    let second = Task { await model.refresh() }
    await refresh.recorder.waitUntil(count: 1)
    #expect(refresh.calls.count == 1)
    refresh.gate.release(.success(.complete))
    await first.value
    await second.value
  }

  @MainActor
  @Test("the show's live effective settings feed the diagnostic hint and clear when it resolves off")
  func effectiveSettingsFeedTheDiagnosticHint() async {
    let reading = FakePodcastReading()
    let settingsReading = FakePodcastSettingsReading()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, settingsReading: settingsReading)

    let enabled = PodcastEffectiveSettings(
      isEnabled: true, keepLatestCount: 3, deleteAfterPlayed: false, floor: .distantPast)
    settingsReading.pushShowSettings(Self.settingsDetail(effective: enabled), itemID: "show-1")
    await waitUntil { model.effective == enabled }
    #expect(
      PodcastShowPresentation.diagnosticText(diagnostics: nil, effective: model.effective, now: Date())
        == "Keeping 3 newest on this device")

    let disabled = PodcastEffectiveSettings(
      isEnabled: false, keepLatestCount: 3, deleteAfterPlayed: false, floor: .distantPast)
    settingsReading.pushShowSettings(Self.settingsDetail(effective: disabled), itemID: "show-1")
    await waitUntil { model.effective == disabled }
    #expect(
      PodcastShowPresentation.diagnosticText(diagnostics: nil, effective: model.effective, now: Date())
        == nil)
  }

  @MainActor
  @Test("switching shows cancels the old observation and ignores its late values")
  func showSwitchCancelsOldObservation() async {
    let reading = FakePodcastReading()
    let model = PodcastShowModel(itemID: "show-1", reading: reading)
    reading.pushEpisodes([Self.episode(id: "old")], itemID: "show-1")
    await waitUntil { model.episodes.map(\.id) == ["old"] }

    model.show(itemID: "show-2")
    reading.pushEpisodes([Self.episode(id: "late")], itemID: "show-1")
    reading.pushEpisodes([Self.episode(id: "new")], itemID: "show-2")
    await waitUntil { model.episodes.map(\.id) == ["new"] }

    #expect(reading.terminatedObservations.contains(.episodes(itemID: "show-1")))
  }

  @MainActor
  @Test("show switch cancels a blocked refresh and deinit terminates both observations")
  func lifecycleCancellation() async {
    let reading = FakePodcastReading()
    let refresh = FakePodcastRefreshing()
    var model: PodcastShowModel? = PodcastShowModel(
      itemID: "show-1", reading: reading, refreshing: refresh)
    refresh.gate.hold()
    let task = Task { await model?.refresh() }
    await refresh.recorder.waitUntil(count: 1)

    model?.show(itemID: "show-2")
    await task.value
    #expect(refresh.cancelledCallCount == 1)
    // A cancelled call leaves the shared gate held, so open it for the next refresh.
    refresh.gate.release(.success(.complete))
    await model?.refresh()
    #expect(refresh.calls.count == 2)
    model = nil
    await waitUntil {
      reading.terminatedObservations.contains(.episodes(itemID: "show-2"))
        && reading.terminatedObservations.contains(.diagnostics(itemID: "show-2"))
    }
  }

  @MainActor
  static func idlePlayback() -> PlaybackModel {
    PlaybackModelHarness().model
  }

  static func episode(
    id: String,
    title: String? = nil,
    subtitle: String? = nil,
    description: String? = nil,
    synopsis: String? = nil,
    isPlayed: Bool = false,
    isFinished: Bool = false,
    isAvailableOnServer: Bool = true,
    downloadStatus: ItemDownloadStatus = .notDownloaded
  ) -> PodcastEpisodeSummary {
    PodcastEpisodeSummary(
      id: id, title: title ?? id, subtitle: subtitle, episodeDescription: description, seasonNumber: nil,
      episodeNumber: nil, episodeType: nil, durationSeconds: 120, sizeBytes: nil,
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000), progressSeconds: isPlayed ? 30 : 0,
      isPlayed: isPlayed, isFinished: isFinished, downloadStatus: downloadStatus,
      isAvailableOnServer: isAvailableOnServer, synopsisLine: synopsis)
  }

  static func settingsDetail(effective: PodcastEffectiveSettings) -> PodcastShowSettingsDetail {
    PodcastShowSettingsDetail(
      itemID: "show-1", title: "Show", autoDownloadOverride: effective.isEnabled ? .enabled : .disabled,
      keepLatestOverride: nil, deleteAfterPlayedOverride: nil, enabledAt: nil, effective: effective)
  }
}

extension FakePodcastReading {
  fileprivate var requestedPrefixLimits: [Int] {
    calls.compactMap { call -> Int? in
      if case .episodePrefix(_, let limit) = call { return limit }
      return nil
    }
  }
}
