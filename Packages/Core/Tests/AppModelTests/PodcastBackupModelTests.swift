import Foundation
import Persistence
import Testing

@testable import AppModel
@testable import SyncEngine

@MainActor
@Suite struct PodcastBackupModelTests {
  private struct StubExporter: PodcastBackupExporting {
    let result: Result<PodcastBackupExport, TestError>
    func exportBackup(at date: Date) async throws -> PodcastBackupExport { try result.get() }
  }

  private struct TestError: Error {}

  private nonisolated static let date = Date(timeIntervalSince1970: 1_790_000_000)

  private func model(_ result: Result<PodcastBackupExport, TestError>) -> PodcastBackupModel {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return PodcastBackupModel(exporter: StubExporter(result: result), now: { Self.date }, calendar: calendar)
  }

  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("PodcastBackupModelTests-\(UUID().uuidString)")
  }

  @Test func namesTheFileByTheUsersCalendarDay() {
    #expect(model(.failure(TestError())).filename(for: Self.date) == "Whirr Podcasts 2026-09-21.whirrpodcasts.json")
  }

  @Test func writesTheExportUnderItsReadableName() async throws {
    let export = PodcastBackupExport(data: Data("backup".utf8), showCount: 2, episodeCount: 5, skippedShows: 1)
    let model = model(.success(export))
    let root = directory()
    defer { try? FileManager.default.removeItem(at: root) }

    await model.prepareExport(in: root)
    let url = try #require(model.exportURL)
    #expect(url.lastPathComponent == "Whirr Podcasts 2026-09-21.whirrpodcasts.json")
    #expect(try Data(contentsOf: url) == export.data)
    #expect(model.lastExport == export)
    #expect(model.exportError == false && model.isExporting == false)
  }

  @Test func aSecondExportRemovesTheFirstFile() async throws {
    let model = model(.success(PodcastBackupExport(data: Data("a".utf8), showCount: 0, episodeCount: 0)))
    let root = directory()
    defer { try? FileManager.default.removeItem(at: root) }

    await model.prepareExport(in: root)
    let first = try #require(model.exportURL)
    await model.prepareExport(in: root)
    let second = try #require(model.exportURL)
    #expect(first != second)
    #expect(FileManager.default.fileExists(atPath: first.path) == false)
    #expect(FileManager.default.fileExists(atPath: second.path))
  }

  @Test func aFailureClearsTheFileAndReports() async {
    let model = model(.failure(TestError()))
    await model.prepareExport(in: directory())
    #expect(model.exportURL == nil && model.lastExport == nil)
    #expect(model.exportError)
  }

  /// The production exporter against a real database: the file it writes decodes and holds the show.
  @Test func nativeExporterWritesADecodableBackup() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO rssFeed (feedURL, title, subscribedAt) VALUES ('https://example.com/feed', 'Feed', ?)",
        arguments: [Self.date])
    }
    let export = try await NativePodcastBackupExporter(database: database, appBuild: "42").exportBackup(at: Self.date)
    #expect(export.showCount == 1 && export.episodeCount == 0)
    let snapshot = try PodcastStateSnapshotCodec.decodeWrapped(export.data)
    #expect(snapshot.subscriptions.map(\.title) == ["Feed"])
    #expect(snapshot.appBuild == "42")
    #expect(snapshot.exportedAt == Self.date)
  }

  /// Learned ads ride along, counted, and ones the store would expire anyway are left out. A
  /// device with learned ads and no shows (server podcasts only) still has something to back up.
  @Test func nativeExporterCarriesCurrentLearnedAds() async throws {
    let database = try AppDatabase.inMemory()
    let signatures = AdSignatureStore(database: database)
    func ad(_ hash: UInt64, daysOld: Double) -> NewAdSignatureCreative {
      NewAdSignatureCreative(
        kind: .learned, lastSeen: Self.date.addingTimeInterval(-daysOld * 86_400), startTime: 10, endTime: 40,
        teachers: [], hashes: [hash], audioPrint: Data([1, 0, 0, 0]))
    }
    let empty = try await NativePodcastBackupExporter(database: database).exportBackup(at: Self.date)
    #expect(empty.isEmpty)

    _ = try await signatures.apply(AdSignatureStoreChange(insertions: [ad(1, daysOld: 2), ad(2, daysOld: 91)]))
    let export = try await NativePodcastBackupExporter(database: database).exportBackup(at: Self.date)
    #expect(export.learnedAdCount == 1 && export.showCount == 0 && export.isEmpty == false)
    let section = try #require(try PodcastStateSnapshotCodec.decodeWrapped(export.data).learnedAds)
    #expect(section.printFormat == PodcastBackupLearnedAds.printFormat)
    #expect(section.ads.count == 1 && section.ads[0].printBytes != nil)

    // The same file restores into a clean device, and expired ads are not brought back later.
    let target = try AppDatabase.inMemory()
    let service = NativePodcastBackupRestoreService(database: target, now: { Self.date })
    let outcome = try await service.restore(try await service.read(export.data))
    #expect(outcome.learnedAdsAdded == 1)
    let prints = try await AdSignatureStore(database: target).learnedAudioPrints()
    #expect(prints.map(\.audioPrint) == [Data([1, 0, 0, 0])])
    let later = NativePodcastBackupRestoreService(
      database: try AppDatabase.inMemory(), now: { Self.date.addingTimeInterval(100 * 86_400) })
    #expect(try await later.preview(try await later.read(export.data)).learnedAdsAdded == 0)
  }

  /// A listener-confirmed ad never expires, so it travels however old it is and comes back on a
  /// restore; an unconfirmed ad past `expiry` is left out, as the store would drop it next pass.
  @Test func nativeExporterKeepsAConfirmedAdPastExpiry() async throws {
    let database = try AppDatabase.inMemory()
    let signatures = AdSignatureStore(database: database)
    func ad(_ hash: UInt64, daysOld: Double, confirmed: Bool) -> NewAdSignatureCreative {
      NewAdSignatureCreative(
        kind: .learned, lastSeen: Self.date.addingTimeInterval(-daysOld * 86_400), startTime: 10, endTime: 40,
        teachers: [], hashes: [hash], confirmed: confirmed)
    }
    _ = try await signatures.apply(
      AdSignatureStoreChange(insertions: [
        ad(1, daysOld: 200, confirmed: true), ad(2, daysOld: 91, confirmed: false),
      ]))

    let export = try await NativePodcastBackupExporter(database: database).exportBackup(at: Self.date)
    #expect(export.learnedAdCount == 1)
    let section = try #require(try PodcastStateSnapshotCodec.decodeWrapped(export.data).learnedAds)
    #expect(section.ads.compactMap(\.confirmed) == [true])

    // Read on a device whose own clock is far past the ad's last sighting: the store keeps a
    // confirmed creative, so the restore must too.
    let target = try AppDatabase.inMemory()
    let service = NativePodcastBackupRestoreService(
      database: target, now: { Self.date.addingTimeInterval(300 * 86_400) })
    #expect(try await service.preview(try await service.read(export.data)).learnedAdsAdded == 1)
    _ = try await service.restore(try await service.read(export.data))
    let restored = try await NativePodcastBackupReader(database: target).contents().learnedAds
    #expect(restored.map(\.confirmed) == [true])
  }

  @Test func smartListsRoundTripThroughTheExporterAndRestoreModel() async throws {
    let source = try AppDatabase.inMemory()
    let store = SmartListStore(database: source)
    var rules = SmartListRules.default
    rules.sortOrder = .oldest
    _ = try await store.create(
      name: "Commute", rules: rules,
      shows: [.init(ref: .native(feedURL: "https://example.com/feed"), role: .included, titleSnapshot: "Feed")])
    let export = try await NativePodcastBackupExporter(database: source).exportBackup(at: Self.date)
    #expect(export.smartListCount == 1 && export.isEmpty == false)

    let target = try AppDatabase.inMemory()
    let service = NativePodcastBackupRestoreService(database: target, now: { Self.date })
    let model = PodcastBackupRestoreModel(service: service, sync: nil, refreshFeeds: { _ in })
    await model.read(export.data)
    #expect(model.smartListsPending == 1)
    await model.confirm()
    let outcome = try #require(model.smartListOutcome)
    #expect(outcome.listsAdded == 1 && outcome.showsRestored == 1 && outcome.showsNotOnDevice == 1)
    let restored = try await SmartListStore(database: target).lists()
    #expect(restored.map(\.name) == ["Commute"] && restored[0].rules.sortOrder == .oldest)
    guard case .finished(let native) = model.phase else {
      Issue.record("expected finished")
      return
    }
    #expect(
      PodcastBackupPresentation.finishedMessage(native, smartLists: outcome)
        == "Added 1 smart list.")

    // Restoring again adds nothing and says what was kept.
    await model.read(export.data)
    #expect(model.smartListsPending == 0)
    await model.confirm()
    #expect(
      model.smartListOutcome.flatMap(PodcastBackupPresentation.smartListsLine)
        == "1 smart list already on this device was kept.")
  }

  @Test func aFileWithoutSmartListsRestoresWithNoSmartListLine() async throws {
    let source = try AppDatabase.inMemory()
    let snapshot = try PodcastBackupSnapshotMapping.snapshot(
      from: NativePodcastBackupContents(
        globalSettings: NativePodcastSettingsRecord(), showOrderMode: "alphabetical", feeds: [], episodes: [],
        bookmark: nil, followedGenerations: [:]), exportedAt: Self.date
    ).snapshot
    #expect(snapshot.smartLists == nil)
    _ = source
    let data = try PodcastStateSnapshotCodec.encodeWrapped(snapshot)
    let target = try AppDatabase.inMemory()
    let service = NativePodcastBackupRestoreService(database: target, now: { Self.date })
    let model = PodcastBackupRestoreModel(service: service, sync: nil, refreshFeeds: { _ in })
    await model.read(data)
    await model.confirm()
    #expect(model.smartListOutcome == nil && model.smartListsPending == 0)
    #expect(try await SmartListStore(database: target).lists().isEmpty)
    guard case .finished(let native) = model.phase else {
      Issue.record("expected finished")
      return
    }
    #expect(
      PodcastBackupPresentation.finishedMessage(native, smartLists: model.smartListOutcome)
        == "Nothing needed restoring.")
    #expect(PodcastBackupPresentation.smartListsLine(.init()) == nil)
  }
}
