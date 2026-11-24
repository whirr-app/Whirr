import Foundation
import Persistence
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch episode inventory inbox", .serialized)
struct WatchEpisodeInventoryInboxTests {

  @Test func anOversizedPayloadIsDropped() async throws {
    let fixture = try await Fixture()
    let outcome = await fixture.inbox.receive(
      Data(repeating: 0, count: WatchEpisodeInventory.maxWireBytes + 1), now: Fixture.date(30))

    #expect(outcome == nil)
    #expect(try await fixture.copies.setState().inventorySequence == 0)
  }

  @Test func anUndecodablePayloadIsDropped() async throws {
    let fixture = try await Fixture()
    let outcome = await fixture.inbox.receive(Data("not-json".utf8), now: Fixture.date(30))

    #expect(outcome == nil)
    #expect(try await fixture.copies.setState().inventorySequence == 0)
  }

  @Test func entriesForAFeedOrEpisodeThePhoneNoLongerHasAreDropped() async throws {
    let fixture = try await Fixture()
    fixture.completeDownload(0)
    _ = try await fixture.copies.request(
      episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let entries = try [
      WatchEpisodeInventoryEntry(
        selection: try WatchNativeSelection(feedID: "999", episodeID: "gone"),
        revision: 1, state: .ready, committedBytes: 100),
      WatchEpisodeInventoryEntry(
        selection: try WatchNativeSelection(
          feedID: String(fixture.feedID), episodeID: "unknown-episode"),
        revision: 1, state: .ready, committedBytes: 100),
    ]

    let outcome = try await fixture.receive(entries: entries, acknowledged: 1)

    #expect(outcome.changedEpisodeIds.isEmpty)
    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(0))?.state == .wanted)
  }

  @Test func statesDeclineReasonsAndRevisionsMapOntoTheStore() async throws {
    let fixture = try await Fixture(episodeCount: 5)
    for index in 0..<5 {
      fixture.completeDownload(index)
      _ = try await fixture.copies.request(
        episodeId: fixture.episodeID(index), now: Fixture.date(TimeInterval(index)))
    }
    let entries = try [
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(0), revision: 1, state: .ready,
        committedBytes: 4_096),
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(1), revision: 1, state: .declined,
        declineReason: .storageFull),
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(2), revision: 1, state: .downloading, progress: 0.42),
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(3), revision: 1, state: .waitingForNetwork),
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(4), revision: 1, state: .failed,
        failureReason: .httpStatus),
    ]

    let outcome = try await fixture.receive(entries: entries, acknowledged: 2)

    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(0))?.state == .delivered)
    let declined = try #require(try await fixture.copies.copy(episodeId: fixture.episodeID(1)))
    #expect(declined.state == .declined)
    #expect(declined.declineReason == .storageFull)
    // The store's in-progress state is the coarse one; the percentage and the network hold live in
    // memory only.
    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(2))?.state == .sending)
    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(3))?.state == .sending)
    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(4))?.state == .failed)
    #expect(Set(outcome.changedEpisodeIds) == Set((0..<4).map { fixture.episodeID($0) }))
  }

  @Test func downloadingProgressReachesTheMemoryProjectionOnly() async throws {
    let fixture = try await Fixture(episodeCount: 2)
    for index in 0..<2 {
      fixture.completeDownload(index)
      _ = try await fixture.copies.request(
        episodeId: fixture.episodeID(index), now: Fixture.date(TimeInterval(index)))
    }
    let entries = try [
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(0), revision: 1, state: .downloading, progress: 0.42),
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(1), revision: 1, state: .downloading),
    ]

    _ = try await fixture.receive(entries: entries, acknowledged: 2)

    let statuses = try #require(fixture.publishedStatuses.last)
    #expect(statuses[fixture.episodeID(0)]?.state == .downloading)
    #expect(statuses[fixture.episodeID(0)]?.progress == 0.42)
    #expect(statuses[fixture.episodeID(0)]?.revision == 1)
    #expect(statuses[fixture.episodeID(1)]?.progress == nil)
    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(0))?.state == .sending)

    // The next inventory is the whole truth: a copy it no longer names has no live status.
    _ = try await fixture.receive(entries: [], acknowledged: 2, sequence: 2)
    #expect(fixture.publishedStatuses.last?.isEmpty == true)
  }

  @Test func aLateInventoryCannotReplaceTheLiveProjection() async throws {
    let fixture = try await Fixture()
    fixture.completeDownload(0)
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let latest = try [
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(0), revision: 1, state: .downloading, progress: 0.8)
    ]
    _ = try await fixture.receive(entries: latest, acknowledged: 1, sequence: 5)

    let late = try [
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(0), revision: 1, state: .downloading, progress: 0.2)
    ]
    _ = try await fixture.receive(entries: late, acknowledged: 1, sequence: 4)

    #expect(fixture.publishedStatuses.count == 1)
    #expect(fixture.publishedStatuses.last?[fixture.episodeID(0)]?.progress == 0.8)
  }

  @Test func aNewerInventorySavesItsProjectionForTheNextLaunch() async throws {
    let fixture = try await Fixture()
    fixture.completeDownload(0)
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let downloading = try [
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(0), revision: 1, state: .downloading, progress: 0.42)
    ]

    _ = try await fixture.receive(entries: downloading, acknowledged: 1)

    let saved = try #require(fixture.record.load(watchInstallID: Fixture.installID))
    #expect(saved[fixture.episodeID(0)]?.revision == 1)
    #expect(saved[fixture.episodeID(0)]?.state == .downloading)
    #expect(saved[fixture.episodeID(0)]?.progress == 0.42)

    // An inventory naming no in-progress copy is the newest answer and clears the saved one.
    _ = try await fixture.receive(entries: [], acknowledged: 1, sequence: 2)
    #expect(fixture.record.load(watchInstallID: Fixture.installID) == [:])
  }

  @Test func aLateInventoryDoesNotOverwriteTheSavedProjection() async throws {
    let fixture = try await Fixture()
    fixture.completeDownload(0)
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    _ = try await fixture.receive(
      entries: [
        try WatchEpisodeInventoryEntry(
          selection: try fixture.selection(0), revision: 1, state: .downloading, progress: 0.8)
      ], acknowledged: 1, sequence: 5)

    _ = try await fixture.receive(
      entries: [
        try WatchEpisodeInventoryEntry(
          selection: try fixture.selection(0), revision: 1, state: .downloading, progress: 0.2)
      ], acknowledged: 1, sequence: 4)

    #expect(
      fixture.record.load(watchInstallID: Fixture.installID)?[fixture.episodeID(0)]?.progress == 0.8)
  }

  @Test func aFailedDownloadKeepsTheRowRetryableAtANewRevision() async throws {
    let fixture = try await Fixture()
    fixture.completeDownload(0)
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))

    _ = try await fixture.receive(
      entries: [
        try WatchEpisodeInventoryEntry(
          selection: try fixture.selection(0), revision: 1, state: .failed,
          failureReason: .insecureRedirect)
      ], acknowledged: 1)

    let failed = try #require(try await fixture.copies.copy(episodeId: fixture.episodeID(0)))
    #expect(failed.state == .failed)
    #expect(failed.failedAt != nil)

    let retried = try await fixture.copies.request(
      episodeId: fixture.episodeID(0), now: Fixture.date(40))
    #expect(retried.revision == 2)
    #expect(retried.state == .wanted)
  }

  @Test func aRevisionBeyondInt64IsDropped() async throws {
    let fixture = try await Fixture()
    fixture.completeDownload(0)
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let entries = try [
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(0), revision: .max, state: .ready,
        committedBytes: 4_096)
    ]

    _ = try await fixture.receive(entries: entries, acknowledged: 1)

    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(0))?.state == .wanted)
  }

  @Test func aValidInventoryReachesTheStoreAndNotifiesThePublisher() async throws {
    let fixture = try await Fixture()
    fixture.completeDownload(0)
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    var applied: [RSSWatchCopyInventoryOutcome] = []
    fixture.inbox.onApplied = { applied.append($0) }
    let entries = try [
      WatchEpisodeInventoryEntry(
        selection: try fixture.selection(0), revision: 1, state: .ready,
        committedBytes: 4_096)
    ]

    let outcome = try await fixture.receive(entries: entries, acknowledged: 1)

    #expect(outcome.changedEpisodeIds == [fixture.episodeID(0)])
    #expect(applied == [outcome])
    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(0))?.state == .delivered)
    let set = try await fixture.copies.setState()
    #expect(set.watchInstallID == Fixture.installID)
    #expect(set.acceptsCopies == true)
    #expect(set.inventorySequence == 1)
  }

  // MARK: - Fixture

  @MainActor
  final class Fixture {
    let database: AppDatabase
    let feedID: Int64
    let copies: RSSWatchCopyStore
    let record: WatchDownloadStatusRecord
    let inbox: WatchEpisodeInventoryInbox
    private let downloads: RSSDownloadStore
    private var byID: [Int64: RSSEpisodeRecord] = [:]
    private var orderedIDs: [Int64] = []
    private(set) var publishedStatuses: [[Int64: WatchEpisodeDownloadStatus]] = []

    init(episodeCount: Int = 2) async throws {
      let database = try AppDatabase.inMemory()
      self.database = database
      let feedID = try await RSSFeedStore(database: database).subscribe(
        feedURL: URL(string: "https://feeds.invalid/inventory.xml")!, title: "Watch Show",
        author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Fixture.date(0))
      self.feedID = feedID
      _ = try await RSSEpisodeStore(database: database).applyRefresh(
        feedId: feedID,
        episodes: (0..<episodeCount).map { index in
          RSSEpisodeUpsert(
            identityKey: "episode-\(index)", guid: "episode-\(index)",
            title: "Episode \(index + 1)",
            enclosureURL: URL(string: "https://cdn.invalid/\(index).mp3")!,
            enclosureType: "audio/mpeg", declaredBytes: 100,
            publishedAt: Fixture.date(TimeInterval(index)))
        })
      let fetched = try await database.readAsync { db in
        try RSSEpisodeRecord.fetchAll(
          db, sql: "SELECT * FROM rssEpisode WHERE feedId = ? ORDER BY publishedAt",
          arguments: [feedID])
      }
      var byID: [Int64: RSSEpisodeRecord] = [:]
      var ordered: [Int64] = []
      for record in fetched {
        guard let id = record.id else { continue }
        byID[id] = record
        ordered.append(id)
      }
      self.byID = byID
      self.orderedIDs = ordered
      self.copies = RSSWatchCopyStore(database: database)
      self.downloads = try RSSDownloadStore(database: database)
      // One scratch suite reset per fixture: the suite is serialized, so this is the isolation the
      // saved-projection tests need without a shared app domain.
      let statusSuite = "watch.download.status.inbox.tests"
      let statusDefaults = UserDefaults(suiteName: statusSuite)!
      statusDefaults.removePersistentDomain(forName: statusSuite)
      let record = WatchDownloadStatusRecord(defaults: statusDefaults)
      self.record = record
      let inbox = WatchEpisodeInventoryInbox(
        copies: copies,
        record: record,
        episodeIDs: { feedId, identityKeys in
          (try? await RSSEpisodeStore(database: database).fetchEpisodeIDs(
            feedId: feedId, identityKeys: identityKeys)) ?? [:]
        })
      self.inbox = inbox
      inbox.onStatuses = { [weak self] in self?.publishedStatuses.append($0) }
    }

    func episodeID(_ index: Int) -> Int64 { orderedIDs[index] }

    func selection(_ index: Int) throws -> WatchNativeSelection {
      let record = byID[episodeID(index)]!
      return try #require(
        WatchEpisodeSendEligibility.selection(
          feedId: record.feedId, identityKey: record.identityKey))
    }

    func completeDownload(_ index: Int) {
      let episodeId = episodeID(index)
      let row = try! downloads.claimOrCreate(
        episodeId: episodeId, origin: .manual, decidedStamp: Fixture.date(0))
      let downloadID = row.id!
      _ = try! downloads.transition(downloadId: downloadID, to: .downloading)
      _ = try! downloads.complete(downloadId: downloadID, actualBytes: 4_096)
    }

    func receive(
      entries: [WatchEpisodeInventoryEntry], acknowledged: UInt64, sequence: UInt64 = 1
    ) async throws -> RSSWatchCopyInventoryOutcome {
      let inventory = try WatchEpisodeInventory(
        watchInstallID: Fixture.installID, sequence: sequence,
        acknowledgedGeneration: acknowledged, acceptsCopies: true, entries: entries,
        budgetTotalBytes: 2_000_000_000, budgetUsedBytes: 4_096, observedAt: Fixture.date(30))
      let data = try WatchWireCodec.encode(inventory)
      return try #require(await inbox.receive(data, now: Fixture.date(30)))
    }

    static let installID = "0f0e0d0c-0b0a-4908-8706-050403020100"

    static func date(_ offset: TimeInterval) -> Date {
      Date(timeIntervalSince1970: 1_790_000_000 + offset)
    }
  }
}
