import Foundation
import TestSupport
import Testing

@testable import Persistence
@testable import SyncEngine

/// The reap pass: query the reap store, forward each identity to the purge boundary. Most tests
/// fake both seams (`FakePodcastAutoDownloadReapCandidateProviding`,
/// `FakePodcastAutoDownloadPurging`); `reapNeverTouchesManualRows` drives the real
/// `PodcastAutoDownloadReapStore` over an in-memory database to prove the manual/automatic
/// exclusion end to end.
@Suite(.timeLimit(.minutes(1))) struct PodcastAutoDownloadReapTests {

  @Test func reapForwardsEachIdentityToPurgeEpisodeDownload() async throws {
    let candidates = [
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-1"),
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-2"),
      EpisodeDownloadKey(itemID: "show-2", episodeID: "ep-3"),
    ]
    let provider = FakePodcastAutoDownloadReapCandidateProviding(candidates: candidates)
    let purging = FakePodcastAutoDownloadPurging()
    let reaper = PodcastAutoDownloadReaper(reapCandidateProvider: provider, purging: purging)

    await reaper.reap()

    #expect(await purging.calls == candidates)
  }

  /// A failed candidate read is a completed pass: it purges nothing and must not leave the flight
  /// holding the next trigger.
  @Test func aFailedCandidateReadIsRecordedAndPurgesNothing() async throws {
    let purging = FakePodcastAutoDownloadPurging()
    let diagnostics = FakeDiagnosticsRecording()
    let provider = FakePodcastAutoDownloadReapCandidateProviding()
    await provider.failReads(with: URLError(.unknown))
    let reaper = PodcastAutoDownloadReaper(
      reapCandidateProvider: provider, purging: purging,
      diagnostics: diagnostics, accountId: 1)

    await reaper.reap()
    await reaper.reap()

    #expect(await purging.calls.isEmpty)
    #expect(diagnostics.recorded.map(\.statusClass) == [.clientError, .clientError])
    #expect(await reaper.joinedFlightCount == 0, "the failed pass settled before the second reap")
  }

  @Test func onePurgeFailureDoesNotStopTheRest() async throws {
    let candidates = [
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-1"),
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-2"),
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-3"),
    ]
    let provider = FakePodcastAutoDownloadReapCandidateProviding(candidates: candidates)
    let purging = FakePodcastAutoDownloadPurging()
    await purging.failPurge(itemID: "show-1", episodeID: "ep-2")
    let reaper = PodcastAutoDownloadReaper(reapCandidateProvider: provider, purging: purging)

    await reaper.reap()

    #expect(
      await purging.calls == candidates,
      "every identity is attempted in order despite the middle one failing")
  }

  /// A background pass cancelled part-way must stop purging rather than drain the candidate list,
  /// so the pass-level deadline can interrupt this loop. The purge seam triggers the cancellation
  /// so the stopping point is exact.
  @Test("cancellation stops a sequential reap mid-purge")
  func cancellationStopsSequentialReapMidPurge() async throws {
    let candidates = (1...20).map { EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-\($0)") }
    let provider = FakePodcastAutoDownloadReapCandidateProviding(candidates: candidates)
    let purging = FakePodcastAutoDownloadPurging()
    let reaper = PodcastAutoDownloadReaper(reapCandidateProvider: provider, purging: purging)
    await purging.setAfterPurge { count in
      if count == 3 { await reaper.cancel() }
    }

    await reaper.reap()

    #expect(await purging.calls.count == 3, "the loop stops at the first check after cancellation")
  }

  /// A reap requested while a pass is in flight may follow a state change that pass's candidate
  /// read already missed (an RSS episode finishing during a refresh-triggered pass), so joining
  /// must not return until a pass that started after the request has run.
  @Test("a reap requested mid-pass purges a candidate that appeared after the pass read its list")
  func reapRequestedMidPassPurgesLateCandidate() async throws {
    let finished = EpisodeDownloadKey(itemID: "show-1", episodeID: "finished")
    let provider = FakePodcastAutoDownloadReapCandidateProviding()
    provider.readGate.hold()
    let purging = FakePodcastAutoDownloadPurging()
    let reaper = PodcastAutoDownloadReaper(reapCandidateProvider: provider, purging: purging)

    let inFlight = Task { await reaper.reap() }
    await provider.readGate.waitUntilParked()
    await provider.setCandidates([finished])
    let requestedAfterChange = Task { await reaper.reap() }
    #expect(await TestSupport.waitUntil { await reaper.joinedFlightCount == 1 })
    provider.readGate.release()

    await requestedAfterChange.value
    #expect(await purging.calls == [finished])
    await inFlight.value
  }

  @Test("any number of mid-pass reap requests coalesce into one follow-up pass")
  func midPassReapRequestsCoalesceIntoOneFollowUpPass() async throws {
    let finished = EpisodeDownloadKey(itemID: "show-1", episodeID: "finished")
    let provider = FakePodcastAutoDownloadReapCandidateProviding()
    provider.readGate.hold()
    let purging = FakePodcastAutoDownloadPurging()
    let reaper = PodcastAutoDownloadReaper(reapCandidateProvider: provider, purging: purging)

    let inFlight = Task { await reaper.reap() }
    await provider.readGate.waitUntilParked()
    await provider.setCandidates([finished])
    let joiners = (0..<3).map { _ in Task { await reaper.reap() } }
    #expect(await TestSupport.waitUntil { await reaper.joinedFlightCount == 3 })
    provider.readGate.release()

    for joiner in joiners { await joiner.value }
    await inFlight.value
    #expect(await provider.callCount == 2, "the original pass plus exactly one follow-up")
    #expect(await purging.calls == [finished])
  }

  @Test("account removal closes the shared RSS purge boundary before the reaper runs")
  func accountRemovalStopsRSSReaping() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let claimed = try await harness.seedRSSDownload(episodeKey: "rss-episode", bytes: 5)
    let downloadID = try #require(claimed.id)
    _ = try await harness.rssDownloadStore.transitionAsync(
      downloadId: downloadID, to: .downloading)
    let completed = try await harness.rssDownloadStore.completeAsync(
      downloadId: downloadID, actualBytes: 5)
    let fileURL = harness.rssFileStore.absoluteURL(forRelativePath: completed.relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 5).write(to: fileURL)

    let episode = try #require(
      await RSSEpisodeStore(database: harness.database).fetchEpisode(episodeId: completed.episodeId))
    let provider = FakePodcastAutoDownloadReapCandidateProviding(
      candidates: [
        EpisodeDownloadKey(
          itemID: "rss:\(episode.feedId)", episodeID: episode.identityKey)
      ])
    let reaper = PodcastAutoDownloadReaper(
      reapCandidateProvider: provider, purging: harness.coordinator)
    provider.readGate.hold()
    let reapTask = Task { await reaper.reap() }

    await provider.readGate.waitUntilParked()
    await harness.coordinator.beginAccountRemoval()
    provider.readGate.release()
    await reapTask.value

    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try await harness.rssDownloadStore.fetchAsync(downloadId: downloadID)?.state == .completed)
  }

  @Test(
    "RSS playback that starts after selection is protected at deletion and remains eligible later"
  )
  func rssPlaybackStartingAfterSelectionIsProtectedAtDeletion() async throws {
    let fixture = try await makeRSSReapFixture()
    let activePlayback = ActivePlaybackStartingAfterSelection(episodeID: fixture.episode.id!)
    let reapStore = RSSPodcastAutoDownloadReapStore(
      database: fixture.harness.database,
      accountId: fixture.harness.accountId,
      activeEpisodeIDs: { activePlayback.snapshot() })
    let reaper = PodcastAutoDownloadReaper(
      reapCandidateProvider: reapStore, purging: fixture.harness.coordinator)

    await reaper.reap()

    #expect(
      try await fixture.harness.rssDownloadStore.fetchAsync(downloadId: fixture.downloadID)?.state
        == .completed,
      "a deletion-time playback recheck skips without marking the row deleting")
    #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path))

    activePlayback.stop()
    await reaper.reap()

    #expect(try await fixture.harness.rssDownloadStore.fetchAsync(downloadId: fixture.downloadID) == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path) == false)
  }

  @Test("RSS promotion after selection is protected by the deletion-time origin recheck")
  func rssPromotionAfterSelectionIsNotReaped() async throws {
    let fixture = try await makeRSSReapFixture()
    let reapStore = RSSPodcastAutoDownloadReapStore(
      database: fixture.harness.database, accountId: fixture.harness.accountId)
    let provider = PromoteRSSDownloadAfterSelection(
      store: reapStore, downloads: fixture.harness.rssDownloadStore, downloadID: fixture.downloadID)
    let reaper = PodcastAutoDownloadReaper(
      reapCandidateProvider: provider, purging: fixture.harness.coordinator)

    await reaper.reap()

    let survivor = try await fixture.harness.rssDownloadStore.fetchAsync(downloadId: fixture.downloadID)
    #expect(survivor?.origin == .manual)
    #expect(survivor?.state == .completed, "a skipped promotion must not strand the row deleting")
    #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path))
  }

  @Test("an ordinary automatic RSS download is still reaped")
  func ordinaryAutomaticRSSDownloadIsStillReaped() async throws {
    let fixture = try await makeRSSReapFixture()
    let reapStore = RSSPodcastAutoDownloadReapStore(
      database: fixture.harness.database, accountId: fixture.harness.accountId)
    let reaper = PodcastAutoDownloadReaper(
      reapCandidateProvider: reapStore, purging: fixture.harness.coordinator)

    await reaper.reap()

    #expect(try await fixture.harness.rssDownloadStore.fetchAsync(downloadId: fixture.downloadID) == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path) == false)
  }

  private func makeRSSReapFixture() async throws -> RSSReapFixture {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let claimed = try await harness.seedRSSDownload(bytes: 50)
    let downloadID = try #require(claimed.id)
    _ = try await harness.rssDownloadStore.transitionAsync(downloadId: downloadID, to: .downloading)
    let completed = try await harness.rssDownloadStore.completeAsync(
      downloadId: downloadID, actualBytes: 50)
    let episode = try #require(
      await RSSEpisodeStore(database: harness.database).fetchEpisode(episodeId: completed.episodeId))

    try await harness.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssDownload SET origin = ? WHERE id = ?",
        arguments: [DownloadOrigin.automatic.rawValue, downloadID])
    }
    let settings = RSSFeedSettingsStore(database: harness.database)
    try await settings.setAutoDownloadOverride(feedId: episode.feedId, override: .enabled)
    try await settings.setDeleteAfterPlayedOverride(feedId: episode.feedId, enabled: true)
    _ = try await RSSEpisodeStateStore(database: harness.database).recordTick(
      episodeId: episode.id!, position: 60, finished: true, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))

    let fileURL = harness.rssFileStore.absoluteURL(forRelativePath: completed.relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 50).write(to: fileURL)

    return RSSReapFixture(
      harness: harness, downloadID: downloadID, episode: episode, fileURL: fileURL)
  }

  private struct RSSReapFixture {
    let harness: DownloadCoordinatorHarness
    let downloadID: Int64
    let episode: RSSEpisodeRecord
    let fileURL: URL
  }

  private final class ActivePlaybackStartingAfterSelection: @unchecked Sendable {
    private let episodeID: Int64
    private let lock = NSLock()
    private var firstSelectionCompleted = false
    private var active = false

    init(episodeID: Int64) {
      self.episodeID = episodeID
    }

    func snapshot() -> Set<Int64> {
      lock.lock()
      defer { lock.unlock() }
      if firstSelectionCompleted == false {
        firstSelectionCompleted = true
        active = true
        return []
      }
      return active ? [episodeID] : []
    }

    func stop() {
      lock.lock()
      active = false
      lock.unlock()
    }
  }

  // Kept: wraps the real RSSPodcastAutoDownloadReapStore and acts after its read, which the
  // static shared fake cannot do.
  private struct PromoteRSSDownloadAfterSelection: PodcastAutoDownloadReapCandidateProviding {
    let store: RSSPodcastAutoDownloadReapStore
    let downloads: RSSDownloadStore
    let downloadID: Int64

    func reapCandidates() async throws -> [EpisodeDownloadKey] {
      let candidates = try await store.reapCandidates()
      _ = try await downloads.promoteToManualAsync(downloadId: downloadID)
      return candidates
    }
  }

  @Test("the shared reap candidate fake records calls and accepts replacement candidates")
  func sharedReapCandidateFakeRecordsCallsAndAcceptsReplacementCandidates() async throws {
    let first = EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-1")
    let second = EpisodeDownloadKey(itemID: "show-2", episodeID: "ep-2")
    let provider = FakePodcastAutoDownloadReapCandidateProviding(candidates: [first])

    #expect(try await provider.reapCandidates() == [first])
    await provider.setCandidates([second])
    #expect(try await provider.reapCandidates() == [second])
    #expect(await provider.callCount == 2)
  }

  @Test("the shared purging fake records calls and injects identity-specific failures")
  func sharedPurgingFakeRecordsCallsAndInjectsIdentitySpecificFailures() async throws {
    let failing = EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-1")
    let succeeding = EpisodeDownloadKey(itemID: "show-2", episodeID: "ep-2")
    let purging = FakePodcastAutoDownloadPurging()
    await purging.failPurge(itemID: failing.itemID, episodeID: failing.episodeID)

    await #expect(throws: FakePodcastAutoDownloadPurgingError.failed) {
      try await purging.purgeEpisodeDownload(
        itemID: failing.itemID, episodeID: failing.episodeID, source: .autoDownloadReaper)
    }
    try await purging.purgeEpisodeDownload(
      itemID: succeeding.itemID, episodeID: succeeding.episodeID, source: .autoDownloadReaper)
    #expect(await purging.calls == [failing, succeeding])
  }

  @Test func reapIsIdempotent() async throws {
    let candidates = [EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-1")]
    let provider = FakePodcastAutoDownloadReapCandidateProviding(candidates: candidates)
    let purging = FakePodcastAutoDownloadPurging()
    let reaper = PodcastAutoDownloadReaper(reapCandidateProvider: provider, purging: purging)

    await reaper.reap()
    #expect(await purging.calls == candidates)

    // The real store never resurfaces an already-purged row, so a second pass sees an empty
    // result and must be a silent no-op.
    await provider.setCandidates([])
    await reaper.reap()

    #expect(await purging.calls == candidates, "no new purge call on the idempotent second pass")
  }

  @Test func reapNeverTouchesManualRows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId)
    // Keep-latest-1: only the newest episode's download stays inside the window.
    try await insertShowOverride(database, accountId: accountId, itemId: show.itemRowId)
    let store = try DownloadStore(database: database)

    let newest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 3_000))
    let middle = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "middle",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let oldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    // Rank 1: inside the keep-latest-1 window, never a candidate.
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: newest, fileIno: "newest")
    // Rank 2, automatic: outside the window, the one identity the reaper must purge.
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: middle, fileIno: "middle")
    // Rank 3, manual: further outside the window than "middle", but never reaped.
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: oldest, fileIno: "oldest",
      origin: .manual)

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let purging = FakePodcastAutoDownloadPurging()
    let reaper = PodcastAutoDownloadReaper(reapCandidateProvider: reapStore, purging: purging)

    await reaper.reap()

    #expect(await purging.calls == [EpisodeDownloadKey(itemID: show.serverItemID, episodeID: "middle")])
    #expect(
      await purging.calls.contains(EpisodeDownloadKey(itemID: show.serverItemID, episodeID: "oldest"))
        == false, "a manual download is never reaped")
  }

  @Test func reapEmitsAggregateDiagnosticsOnly() async throws {
    let candidates = [
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-1"),
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-2"),
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-3"),
    ]
    let provider = FakePodcastAutoDownloadReapCandidateProviding(candidates: candidates)
    let purging = FakePodcastAutoDownloadPurging()
    await purging.failPurge(itemID: "show-1", episodeID: "ep-2")
    let diagnostics = FakeDiagnosticsRecording()
    let reaper = PodcastAutoDownloadReaper(
      reapCandidateProvider: provider, purging: purging, diagnostics: diagnostics, accountId: 7)

    await reaper.reap()

    let recorded = diagnostics.recorded
    #expect(recorded.count == 1, "one aggregate event per pass, never one per episode")
    #expect(recorded.allSatisfy { $0.category == .download })
    #expect(recorded.first?.statusClass == .clientError, "at least one purge in the pass failed")
    // `DiagnosticsEvent` has no field that can carry an item/episode id, title, URL or credential,
    // so there is nothing further to assert.
  }

  @Test("a backwards clock clamps reaper diagnostic duration to zero")
  func backwardsClockClampsDiagnosticDurationToZero() async throws {
    let diagnostics = FakeDiagnosticsRecording()
    let clock = ReaperDiagnosticClock([
      Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 99),
    ])
    let reaper = PodcastAutoDownloadReaper(
      reapCandidateProvider: FakePodcastAutoDownloadReapCandidateProviding(candidates: []),
      diagnostics: diagnostics,
      accountId: 7,
      now: { clock.now() })

    await reaper.reap()

    let event = try #require(diagnostics.recorded.first)
    #expect(event.durationMilliseconds == 0)
  }

  // MARK: - Fixtures

  private struct Show {
    let itemRowId: Int64
    let serverItemID: String
  }

  private func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "podcast", name: "Library")
      try library.insert(db)
      return (account.id!, library.id!)
    }
  }

  private func insertShow(_ database: AppDatabase, accountId: Int64, libraryId: Int64) async throws
    -> Show
  {
    try await database.writeAsync { db in
      let serverItemID = "show-1"
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemID,
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try item.insert(db)
      return Show(itemRowId: item.id!, serverItemID: serverItemID)
    }
  }

  private func insertShowOverride(_ database: AppDatabase, accountId: Int64, itemId: Int64) async throws {
    try await database.writeAsync { db in
      let record = PodcastShowSettingsRecord(
        itemId: itemId, accountId: accountId, autoDownloadOverride: .enabled,
        keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
      try record.save(db)
    }
  }

  @discardableResult
  private func insertDownload(
    _ store: DownloadStore, accountId: Int64, itemId: Int64, episodeId: Int64, fileIno: String,
    origin: DownloadOrigin = .automatic
  ) throws -> Int64 {
    let record = try store.enqueue(
      accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, serverFileIno: fileIno,
      orderIndex: 0, destinationRelativePath: "show/\(fileIno).mp3", expectedBytes: 500,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 30, origin: origin)
    _ = try store.transition(downloadId: record.id!, to: .downloading)
    let completedRecord = try store.complete(downloadId: record.id!, finalSizeBytes: 500)
    return completedRecord.id!
  }
}

private final class ReaperDiagnosticClock: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Date]

  init(_ values: [Date]) {
    self.values = values
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    if values.count > 1 {
      return values.removeFirst()
    }
    return values[0]
  }
}
