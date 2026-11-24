import ABSApi
import Foundation
import Persistence
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch episode send publisher", .serialized)
struct WatchEpisodeSendPublisherTests {

  // MARK: - Offers

  @Test func offerNamesTheEnclosureAndMetadataWithoutAPhoneDownload() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    fixture.overrideFacts(
      episode: 0, position: 42, lastListenedAt: Fixture.date(5),
      chapters: [try WatchEpisodeChapter(title: "Intro", start: 0, end: 30)])
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    let offer = try #require(try fixture.offers().last)
    let first = try #require(offer.entries.first)
    #expect(offer.entries.map(\.selection) == [fixture.selection(0)])
    #expect(first.revision == 1)
    #expect(first.title == "Episode 1")
    #expect(first.showTitle == "Watch Show")
    #expect(first.enclosureURL == URL(string: "https://cdn.invalid/0.mp3"))
    #expect(first.declaredBytes == 100)
    #expect(first.mimeType == "audio/mpeg")
    #expect(first.duration == 600)
    #expect(first.chapters.map(\.title) == ["Intro"])
    #expect(first.position == 42)
    #expect(first.lastListenedAt == Fixture.date(5))
    // The request alone puts the row in the offer; there is no phone download to wait for.
    #expect(offer.generation == 1)
    #expect(offer.watchInstallID == nil)
    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(0))?.state == .wanted)
  }

  @Test func theOfferIsSizedFromThePhonesCopyThenTheFeedThenTheDuration() {
    // The phone's finished copy is measured, so it beats the feed's declared length.
    #expect(
      WatchEpisodeSendPublisher.offerBytes(downloaded: 57_790_052, declared: 100, duration: 3_600)
        == 57_790_052)
    #expect(
      WatchEpisodeSendPublisher.offerBytes(downloaded: nil, declared: 100, duration: 3_600) == 100)
    // No size at all: an hour at 192 kbps, rather than nothing and a 1 GiB reservation.
    #expect(
      WatchEpisodeSendPublisher.offerBytes(downloaded: nil, declared: nil, duration: 3_600)
        == 86_400_000)
    #expect(
      WatchEpisodeSendPublisher.offerBytes(downloaded: 0, declared: -1, duration: 3_600)
        == 86_400_000)
    #expect(WatchEpisodeSendPublisher.offerBytes(downloaded: nil, declared: nil, duration: nil) == nil)
    #expect(WatchEpisodeSendPublisher.offerBytes(downloaded: nil, declared: nil, duration: .nan) == nil)
    // An estimate past the per-episode ceiling is no estimate; the Watch reserves the ceiling.
    #expect(
      WatchEpisodeSendPublisher.offerBytes(downloaded: nil, declared: nil, duration: 100_000)
        == nil)
  }

  @Test func offerListsRowsNewestRequestFirst() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(1), now: Fixture.date(20))
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    let offer = try #require(try fixture.offers().last)
    #expect(offer.entries.map(\.selection) == [fixture.selection(1), fixture.selection(0)])
    #expect(offer.generation == 2, "two requests, one generation each")
  }

  @Test func aFinishedEpisodeIsOfferedFromTheBeginning() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    // A finished episode's stored position sits at its end. The phone's own Play restarts such a
    // title from the beginning, so the copy must carry that position rather than the stored one.
    fixture.overrideFacts(
      episode: 0, position: 600, lastListenedAt: Fixture.date(5), finished: true)
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    let entry = try #require(try fixture.offers().last?.entries.first)
    #expect(entry.position == 0)
    #expect(entry.lastListenedAt == Fixture.date(5))
  }

  @Test func anEpisodeWithoutAnEnclosureIsNotOffered() async throws {
    let fixture = try await Fixture()
    fixture.setEnclosureURL(nil, episode: 0)
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    #expect(try fixture.offers().last?.entries.isEmpty == true)
  }

  @Test func anEnclosureTheWireRejectsIsNotOffered() async throws {
    let fixture = try await Fixture()
    // Embedded credentials are never put on the wire (ADR 0020 Decision 2).
    fixture.setEnclosureURL(
      URL(string: "https://user:secret@cdn.invalid/0.mp3"), episode: 0)
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    #expect(try fixture.offers().last?.entries.isEmpty == true)
    #expect(
      WatchEnclosureURL.isValid(URL(string: "https://user:secret@cdn.invalid/0.mp3")!) == false)
  }

  @Test func aPrivateFeedsEpisodeIsNotOffered() async throws {
    let fixture = try await Fixture()
    fixture.setPrivateFeed(true, for: 0)
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(1), now: Fixture.date(20))
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    let offer = try #require(try fixture.offers().last)
    #expect(offer.entries.map(\.selection) == [fixture.selection(1)])
  }

  @Test func aFeedWithADeviceHeldCredentialIsPrivateAndAnUnreadableStoreFailsClosed() throws {
    let store = InMemoryFeedCredentialStore()
    #expect(WatchEpisodeSendEligibility.isPrivateFeed(feedId: 7, credentialStore: store) == false)

    try store.save(
      try FeedCredential(authorization: "Basic d2hhdGV2ZXI6c2VjcmV0"), forFeedID: 7)

    #expect(WatchEpisodeSendEligibility.isPrivateFeed(feedId: 7, credentialStore: store))
    #expect(
      WatchEpisodeSendEligibility.isPrivateFeed(feedId: 7, credentialStore: nil),
      "an unreadable credential store must not make a private feed look public")
  }

  @Test func anEpisodeTheWireRejectsIsNotOffered() async throws {
    let fixture = try await Fixture(episodeCount: 2, longSecondIdentityKey: true)
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(1), now: Fixture.date(20))
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    let offer = try #require(try fixture.offers().last)
    #expect(offer.entries.map(\.selection) == [fixture.selection(0)])
    #expect(
      WatchEpisodeSendEligibility.selection(
        feedId: fixture.feedID, identityKey: fixture.episodeRecord(1).identityKey) == nil)
  }

  @Test func anIdenticalOfferIsNotResentButANewGenerationIs() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let publisher = fixture.publisher()
    publisher.refresh()
    await publisher.settle()
    #expect(try fixture.offers().count == 1)

    publisher.refresh()
    await publisher.settle()
    #expect(try fixture.offers().count == 1, "a refresh with no change must not queue the same offer")

    _ = try await fixture.copies.request(episodeId: fixture.episodeID(1), now: Fixture.date(20))
    publisher.refresh()
    await publisher.settle()
    #expect(try fixture.offers().count == 2)
    #expect(try fixture.offers().last?.generation == 2)
  }

  @Test func anEmptyDesiredSetSendsNothing() async throws {
    let fixture = try await Fixture()
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    #expect(try fixture.offers().isEmpty)
  }

  @Test func nothingIsSentWhileTheWatchAppIsNotInstalled() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    fixture.installed = false
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    #expect(try fixture.offers().isEmpty)
  }

  // MARK: - Inventory truth

  @Test func aSignedOutWatchKeepsTheCopyInTheOffer() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let publisher = fixture.publisher()
    publisher.refresh()
    await publisher.settle()
    let generation = try await fixture.copies.setState().generation

    try await fixture.applyInventory(
      sequence: 1, acknowledged: UInt64(generation), acceptsCopies: false)
    publisher.refresh()
    await publisher.settle()

    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(0))?.state == .waitingForWatch)
    #expect(try fixture.offers().last?.entries.map(\.selection) == [fixture.selection(0)])
  }

  @Test func aReadyInventoryMarksTheCopyDeliveredAndKeepsItAMember() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let publisher = fixture.publisher()
    publisher.refresh()
    await publisher.settle()
    let generation = try await fixture.copies.setState().generation

    try await fixture.applyInventory(
      sequence: 1, acknowledged: UInt64(generation), acceptsCopies: true,
      entries: [
        try WatchEpisodeInventoryEntry(
          selection: fixture.selection(0), revision: 1, state: .ready, committedBytes: 4_096)
      ])
    publisher.refresh()
    await publisher.settle()

    let copy = try #require(try await fixture.copies.copy(episodeId: fixture.episodeID(0)))
    #expect(copy.state == .delivered)
    #expect(try fixture.offers().last?.entries.map(\.selection) == [fixture.selection(0)])
  }

  @Test func anAcknowledgedGenerationSendsNoOfferButTheMemberStays() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let publisher = fixture.publisher()
    publisher.refresh()
    await publisher.settle()
    let generation = try await fixture.copies.setState().generation
    try await fixture.applyInventory(
      sequence: 1, acknowledged: UInt64(generation), acceptsCopies: true)

    publisher.refresh()
    await publisher.settle()

    #expect(try fixture.offers().count == 1, "an acknowledged generation is not offered again")
    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(0))?.state == .wanted)
  }

  @Test func aFailedDownloadIsRetriedAtANewRevision() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let publisher = fixture.publisher()
    publisher.refresh()
    await publisher.settle()
    let generation = try await fixture.copies.setState().generation

    try await fixture.applyInventory(
      sequence: 1, acknowledged: UInt64(generation), acceptsCopies: true,
      entries: [
        try WatchEpisodeInventoryEntry(
          selection: fixture.selection(0), revision: 1, state: .failed,
          failureReason: .httpStatus)
      ])
    publisher.refresh()
    await publisher.settle()
    let failed = try #require(try await fixture.copies.copy(episodeId: fixture.episodeID(0)))
    #expect(failed.state == .failed)
    #expect(try fixture.offers().last?.entries.first?.revision == 1)

    // Try Again is a new request: the store bumps the revision and the Watch re-queues the entry.
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(40))
    publisher.refresh()
    await publisher.settle()

    let copy = try #require(try await fixture.copies.copy(episodeId: fixture.episodeID(0)))
    #expect(copy.revision == 2)
    #expect(copy.state == .wanted)
    #expect(try fixture.offers().last?.entries.first?.revision == 2)
  }

  // MARK: - Played episodes

  @Test func aFinishRecordedAfterTheRequestRemovesTheCopy() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    fixture.overrideFacts(episode: 0, finished: true, stateUpdatedAt: Fixture.date(20))
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(0))?.state == .removed)
    #expect(try fixture.offers().last?.entries.isEmpty == true)
  }

  @Test func aFinishRecordedBeforeTheRequestDoesNotRemoveTheCopy() async throws {
    let fixture = try await Fixture()
    fixture.overrideFacts(episode: 0, finished: true, stateUpdatedAt: Fixture.date(5))
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    let publisher = fixture.publisher()

    publisher.refresh()
    await publisher.settle()

    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(0))?.state == .wanted)
    #expect(try fixture.offers().last?.entries.map(\.selection) == [fixture.selection(0)])
  }

  /// The setting is the listener's: off keeps a finished episode on the Watch until they remove it.
  @Test func aPlayedEpisodeStaysWhenRemovingPlayedEpisodesIsOff() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.copies.request(episodeId: fixture.episodeID(0), now: Fixture.date(10))
    fixture.overrideFacts(episode: 0, finished: true, stateUpdatedAt: Fixture.date(20))
    let publisher = fixture.publisher(removesPlayedEpisodes: { false })

    publisher.refresh()
    await publisher.settle()

    #expect(try await fixture.copies.copy(episodeId: fixture.episodeID(0))?.state == .wanted)
    #expect(try fixture.offers().last?.entries.map(\.selection) == [fixture.selection(0)])
  }

  // MARK: - Fixture

  @MainActor
  final class Fixture {
    let database: AppDatabase
    let feedID: Int64
    let copies: RSSWatchCopyStore
    private var records: [Int64: RSSEpisodeRecord] = [:]
    private var orderedIDs: [Int64] = []
    private var factsOverrides:
      [Int64: (position: Double, lastListenedAt: Date?, finished: Bool, stateUpdatedAt: Date?)] = [:]
    private var enclosureOverrides: [Int64: URL?] = [:]
    private var chapterOverrides: [Int64: [WatchEpisodeChapter]] = [:]
    private var privateFeedOverrides: Set<Int64> = []
    private(set) var offersData: [Data] = []
    var installed = true
    var now = Fixture.date(10)

    init(episodeCount: Int = 3, longSecondIdentityKey: Bool = false) async throws {
      let database = try AppDatabase.inMemory()
      self.database = database
      let feedID = try await RSSFeedStore(database: database).subscribe(
        feedURL: URL(string: "https://feeds.invalid/watch.xml")!, title: "Watch Show",
        author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Fixture.date(0))
      self.feedID = feedID
      _ = try await RSSEpisodeStore(database: database).applyRefresh(
        feedId: feedID,
        episodes: (0..<episodeCount).map { index in
          RSSEpisodeUpsert(
            identityKey: longSecondIdentityKey && index == 1
              ? String(repeating: "a", count: 600) : "episode-\(index)",
            guid: "episode-\(index)",
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
      self.records = byID
      self.orderedIDs = ordered
      self.copies = RSSWatchCopyStore(database: database)
    }

    func episodeID(_ index: Int) -> Int64 { orderedIDs[index] }
    func episodeRecord(_ index: Int) -> RSSEpisodeRecord { records[orderedIDs[index]]! }

    func selection(_ index: Int) -> WatchNativeSelection {
      WatchEpisodeSendEligibility.selection(
        feedId: feedID, identityKey: episodeRecord(index).identityKey)!
    }

    func overrideFacts(
      episode index: Int, position: Double = 0, lastListenedAt: Date? = nil,
      finished: Bool = false, stateUpdatedAt: Date? = nil,
      chapters: [WatchEpisodeChapter] = []
    ) {
      factsOverrides[episodeID(index)] = (position, lastListenedAt, finished, stateUpdatedAt)
      chapterOverrides[episodeID(index)] = chapters
    }

    func setEnclosureURL(_ url: URL?, episode index: Int) {
      enclosureOverrides.updateValue(url, forKey: episodeID(index))
    }

    func setPrivateFeed(_ isPrivate: Bool, for index: Int) {
      if isPrivate {
        privateFeedOverrides.insert(episodeID(index))
      } else {
        privateFeedOverrides.remove(episodeID(index))
      }
    }

    func facts(for episodeId: Int64) -> WatchEpisodeOfferFacts? {
      guard let record = records[episodeId] else { return nil }
      let override = factsOverrides[episodeId]
      let enclosureURL: URL?
      if let custom = enclosureOverrides[episodeId] {
        enclosureURL = custom
      } else {
        enclosureURL = URL(string: record.enclosureURL)
      }
      return WatchEpisodeOfferFacts(
        feedId: record.feedId, identityKey: record.identityKey,
        title: record.title ?? "Episode", showTitle: "Watch Show",
        duration: 600, enclosureURL: enclosureURL, declaredBytes: record.declaredBytes,
        mimeType: "audio/mpeg", chapters: chapterOverrides[episodeId] ?? [],
        position: override?.position ?? 0, lastListenedAt: override?.lastListenedAt,
        finished: override?.finished ?? false, stateUpdatedAt: override?.stateUpdatedAt,
        isPrivateFeed: privateFeedOverrides.contains(episodeId))
    }

    func episodeID(feedId: Int64, identityKey: String) -> Int64? {
      records.values.first { $0.feedId == feedId && $0.identityKey == identityKey }?.id
    }

    func publisher(
      removesPlayedEpisodes: @escaping @MainActor () -> Bool = { true }
    ) -> WatchEpisodeSendPublisher {
      makePublisher(removesPlayedEpisodes: removesPlayedEpisodes)
    }

    func applyInventory(
      sequence: UInt64, acknowledged: UInt64, acceptsCopies: Bool,
      entries: [WatchEpisodeInventoryEntry] = []
    ) async throws {
      let inventory = try WatchEpisodeInventory(
        watchInstallID: Fixture.installID, sequence: sequence,
        acknowledgedGeneration: acknowledged, acceptsCopies: acceptsCopies, entries: entries,
        budgetTotalBytes: 2_000_000_000, budgetUsedBytes: 0, observedAt: Fixture.date(30))
      let data = try WatchWireCodec.encode(inventory)
      // A throwaway suite: the inbox saves its projection, which must not reach the real defaults.
      let defaults = UserDefaults(suiteName: "watch.publisher.tests.\(UUID().uuidString)")!
      let inbox = WatchEpisodeInventoryInbox(
        copies: copies, record: WatchDownloadStatusRecord(defaults: defaults),
        episodeIDs: { [weak self] feedId, keys in
          guard let self else { return [:] }
          var result: [String: Int64] = [:]
          for key in keys {
            if let id = self.episodeID(feedId: feedId, identityKey: key) { result[key] = id }
          }
          return result
        })
      await inbox.receive(data, now: Fixture.date(30))
    }

    func offers() throws -> [WatchEpisodeSendOffer] {
      try offersData.map { try WatchWireCodec.decode(WatchEpisodeSendOffer.self, from: $0) }
    }

    private func makePublisher(
      removesPlayedEpisodes: @escaping @MainActor () -> Bool = { true }
    ) -> WatchEpisodeSendPublisher {
      WatchEpisodeSendPublisher(
        copies: copies,
        reader: WatchEpisodeSendPublisher.Reader(
          facts: { [weak self] in self?.facts(for: $0) }),
        sender: WatchEpisodeSendPublisher.Sender(
          isWatchInstalled: { [weak self] in self?.installed ?? false },
          sendOffer: { [weak self] data in
            self?.offersData.append(data)
            return true
          }),
        now: { [weak self] in self?.now ?? Fixture.date(10) },
        debounce: .zero,
        removesPlayedEpisodes: removesPlayedEpisodes)
    }

    static let installID = "0f0e0d0c-0b0a-4908-8706-050403020100"

    static func date(_ offset: TimeInterval) -> Date {
      Date(timeIntervalSince1970: 1_790_000_000 + offset)
    }
  }
}
