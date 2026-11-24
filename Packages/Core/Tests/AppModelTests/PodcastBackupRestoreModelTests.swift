import CryptoKit
import Foundation
import Persistence
import Testing

@testable import AppModel
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PodcastBackupRestoreModelTests {
  private actor StubService: PodcastBackupRestoring {
    var readFailure: PodcastBackupReadFailure?
    var restoreCount = 0
    let outcome: NativePodcastRestoreOutcome

    init(readFailure: PodcastBackupReadFailure? = nil, outcome: NativePodcastRestoreOutcome) {
      self.readFailure = readFailure
      self.outcome = outcome
    }

    func read(_ data: Data) async throws -> PodcastBackupDocument {
      if let readFailure { throw readFailure }
      return PodcastBackupDocument(
        exportedAt: Date(timeIntervalSince1970: 1), showCount: 1,
        contents: NativePodcastBackupContents(
          globalSettings: NativePodcastSettingsRecord(), showOrderMode: "alphabetical", feeds: [], episodes: [],
          bookmark: nil, followedGenerations: [:]))
    }
    func preview(_ document: PodcastBackupDocument) async throws -> NativePodcastRestoreOutcome { outcome }
    func restore(_ document: PodcastBackupDocument) async throws -> NativePodcastRestoreOutcome {
      restoreCount += 1
      return outcome
    }
  }

  private actor StubSync: PodcastCloudSyncControlling {
    var current: PodcastCloudSyncStatus
    let afterSync: PodcastCloudSyncStatus
    var syncCount = 0

    init(_ current: PodcastCloudSyncStatus, afterSync: PodcastCloudSyncStatus) {
      self.current = current
      self.afterSync = afterSync
    }

    func status() async -> PodcastCloudSyncStatus { current }
    func lastSuccessfulSync() async -> Date? { nil }
    func recoverFromZoneLoss() async throws {}
    func repairClock() async throws {}
    func syncNow() async throws {
      syncCount += 1
      current = afterSync
    }
    func deleteCloudData() async throws {}
  }

  /// Refresh runs in its own task after the restore finishes; the stream is how a test waits for it.
  private struct Refreshes: Sendable {
    let stream: AsyncStream<[Int64]>
    private let continuation: AsyncStream<[Int64]>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream() }
    func record(_ ids: [Int64]) { continuation.yield(ids) }
  }

  private static func outcome(added: [Int64] = [7]) -> NativePodcastRestoreOutcome {
    var outcome = NativePodcastRestoreOutcome()
    outcome.showsAdded = added.count
    outcome.addedFeedIDs = added
    return outcome
  }

  @Test func readShowsThePreviewAndConfirmRestoresAndRefreshesAddedShows() async throws {
    let service = StubService(outcome: Self.outcome())
    let refreshes = Refreshes()
    let model = PodcastBackupRestoreModel(service: service, sync: nil) { refreshes.record($0) }

    await model.read(Data())
    guard case .preview(let document, let preview) = model.phase else {
      Issue.record("expected a preview, got \(model.phase)")
      return
    }
    #expect(document.showCount == 1 && preview.showsAdded == 1)

    await model.confirm()
    #expect(model.phase == .finished(Self.outcome()))
    #expect(await service.restoreCount == 1)
    var iterator = refreshes.stream.makeAsyncIterator()
    #expect(await iterator.next() == [7])
  }

  /// A backup read long after its ads were last seen keeps a listener-confirmed ad and drops an
  /// unconfirmed one past `expiry`, because the read filter is the store's own expiry rule.
  @Test func readingKeepsAConfirmedAdPastExpiry() async throws {
    let exportedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let source = try AppDatabase.inMemory()
    _ = try await AdSignatureStore(database: source).apply(
      AdSignatureStoreChange(insertions: [
        NewAdSignatureCreative(
          kind: .learned, lastSeen: exportedAt, startTime: 1, endTime: 2, teachers: [], hashes: [7],
          confirmed: true),
        NewAdSignatureCreative(
          kind: .learned, lastSeen: exportedAt, startTime: 3, endTime: 4, teachers: [], hashes: [8]),
      ]))
    let data = try await NativePodcastBackupExporter(database: source).exportBackup(at: exportedAt).data

    let service = NativePodcastBackupRestoreService(
      database: try AppDatabase.inMemory(), now: { exportedAt.addingTimeInterval(300 * 86_400) })
    let model = PodcastBackupRestoreModel(service: service, sync: nil, refreshFeeds: { _ in })
    await model.read(data)
    guard case .preview(let document, let preview) = model.phase else {
      Issue.record("expected a preview, got \(model.phase)")
      return
    }
    #expect(document.contents.learnedAds.count == 1)
    #expect(document.contents.learnedAds.first?.hashes == [7])
    #expect(preview.learnedAdsAdded == 1)
  }

  /// The ad-skip coordinator holds the store in memory, so it is told when ads were added or changed.
  @Test func aRestoreThatAddedLearnedAdsTellsTheCoordinator() async throws {
    actor Notices {
      var count = 0
      func note() { count += 1 }
    }
    for (added, changed) in [(0, 0), (3, 0), (0, 2)] {
      var outcome = Self.outcome(added: [])
      outcome.learnedAdsAdded = added
      outcome.learnedAdsChanged = changed
      let notices = Notices()
      let model = PodcastBackupRestoreModel(
        service: StubService(outcome: outcome), sync: nil, learnedAdsRestored: { await notices.note() },
        refreshFeeds: { _ in })
      await model.read(Data())
      await model.confirm()
      #expect(model.phase == .finished(outcome))
      #expect(await notices.count == (added + changed > 0 ? 1 : 0))
    }
  }

  @Test func readFailuresAreReported() async {
    for (failure, expected) in [
      (PodcastBackupReadFailure.unreadable, PodcastBackupRestoreModel.Failure.unreadable),
      (.newerVersion, .newerVersion),
    ] {
      let model = PodcastBackupRestoreModel(
        service: StubService(readFailure: failure, outcome: Self.outcome()), sync: nil, refreshFeeds: { _ in })
      await model.read(Data())
      #expect(model.phase == .failed(expected))
    }
  }

  @Test func syncTurnedOffDoesNotSyncFirst() async {
    let sync = StubSync(.off, afterSync: .upToDate)
    let model = PodcastBackupRestoreModel(
      service: StubService(outcome: Self.outcome(added: [])), sync: sync, refreshFeeds: { _ in })
    await model.read(Data())
    await model.confirm()
    #expect(model.phase == .finished(Self.outcome(added: [])))
    #expect(await sync.syncCount == 0)
  }

  @Test func syncOnSyncsFirstAndRestoresOnceUpToDate() async {
    let sync = StubSync(.waiting(until: nil), afterSync: .upToDate)
    let service = StubService(outcome: Self.outcome(added: []))
    let model = PodcastBackupRestoreModel(service: service, sync: sync, refreshFeeds: { _ in })
    await model.read(Data())
    await model.confirm()
    #expect(await sync.syncCount == 1)
    #expect(await service.restoreCount == 1)
  }

  /// Restoring before the other devices' changes arrive could overwrite newer progress.
  @Test func syncThatCannotFinishBlocksTheRestore() async {
    let sync = StubSync(.upToDate, afterSync: .accountUnavailable)
    let service = StubService(outcome: Self.outcome())
    let model = PodcastBackupRestoreModel(service: service, sync: sync, refreshFeeds: { _ in })
    await model.read(Data())
    await model.confirm()
    #expect(model.phase == .failed(.syncNotReady))
    #expect(await service.restoreCount == 0)
  }

  @Test func theServiceRejectsDamagedAndNewerFiles() async throws {
    let service = NativePodcastBackupRestoreService(database: try AppDatabase.inMemory())
    await #expect(throws: PodcastBackupReadFailure.unreadable) { try await service.read(Data("{}".utf8)) }

    let export = try await NativePodcastBackupExporter(database: AppDatabase.inMemory()).exportBackup(at: .now)
    var envelope = try #require(JSONSerialization.jsonObject(with: export.data) as? [String: Any])
    var payload = try #require(
      JSONSerialization.jsonObject(with: Data((envelope["payload"] as! String).utf8)) as? [String: Any])
    payload["version"] = 2
    let text = String(data: try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), encoding: .utf8)!
    envelope["payload"] = text
    envelope["sha256"] = SHA256Hex.of(Data(text.utf8))
    let newer = try JSONSerialization.data(withJSONObject: envelope)
    await #expect(throws: PodcastBackupReadFailure.newerVersion) { try await service.read(newer) }
  }
}

private enum SHA256Hex {
  static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
