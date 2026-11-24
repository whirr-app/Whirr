import Foundation
import GRDB
import Testing

@testable import Persistence

/// Learned ads in the podcast backup (learned-ad backup plan, Phase A): what the reader exports,
/// and how restore fills them in.
@Suite struct NativePodcastBackupLearnedAdsTests {
  private typealias Contents = NativePodcastBackupContents
  private typealias Seed = NativePodcastBackupReaderTests

  private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
  private static let print = Data([1, 0, 0, 0, 2, 0, 0, 0])

  private static func ad(
    kind: AdSignatureKind = .learned, lastSeen: Date = t0, hashes: Set<UInt64> = [1, 2, UInt64.max],
    audioPrint: Data? = print, teachers: Set<Contents.LearnedAd.Teacher> = [], confirmed: Bool = false
  ) -> Contents.LearnedAd {
    Contents.LearnedAd(
      kind: kind, lastSeen: lastSeen, startTime: 10, endTime: 40, hashes: hashes,
      audioPrint: kind == .learned ? audioPrint : nil, teachers: teachers, confirmed: confirmed)
  }

  private static func backup(_ ads: [Contents.LearnedAd], feeds: [String] = []) -> Contents {
    var contents = Contents(
      globalSettings: NativePodcastSettingsRecord(), showOrderMode: "alphabetical",
      feeds: feeds.map {
        Contents.Feed(
          feedURL: $0, title: nil, author: nil, subscribedAt: Date(timeIntervalSince1970: 100),
          customSortIndex: nil, settings: nil)
      }, episodes: [], bookmark: nil, followedGenerations: [:])
    contents.learnedAds = ads
    return contents
  }

  private static func rssKey(feed: Int64, episode: String) -> String {
    AdSkipEpisodeIdentity(source: .rss, accountId: nil, itemID: "rss:\(feed)", episodeID: episode).teacherKey
  }

  @Test func theReaderExportsPrintsAndNamesOnlyTeachersOfFollowedShows() async throws {
    let database = try AppDatabase.inMemory()
    let feed = try await database.writeAsync { db in
      try Seed.insertFeed(db, url: "https://example.com/a", title: "A", order: nil)
    }
    let serverKey = AdSkipEpisodeIdentity(source: .abs, accountId: 3, itemID: "li_1", episodeID: "ep_1").teacherKey
    _ = try await AdSignatureStore(database: database).apply(
      AdSignatureStoreChange(insertions: [
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Self.t0, startTime: 10, endTime: 40,
          teachers: [Self.rssKey(feed: feed, episode: "guid:1"), Self.rssKey(feed: 999, episode: "guid:2"), serverKey],
          hashes: [1, 2, UInt64.max], audioPrint: Self.print),
        NewAdSignatureCreative(
          kind: .tombstone, lastSeen: Self.t0, startTime: 5, endTime: 9, teachers: [], hashes: [7]),
      ]))

    let ads = try await NativePodcastBackupReader(database: database).contents().learnedAds
    #expect(ads.count == 2)
    #expect(ads[0].kind == .learned && ads[0].hashes == [1, 2, UInt64.max] && ads[0].audioPrint == Self.print)
    #expect(ads[0].teachers == [.init(feedURL: "https://example.com/a", identityKey: "guid:1")])
    #expect(ads[1].kind == .tombstone && ads[1].audioPrint == nil && ads[1].teachers.isEmpty)
  }

  @Test func restoreAddsAdsWithLocalTeachersAndASecondRestoreAddsNothing() async throws {
    let database = try AppDatabase.inMemory()
    let contents = Self.backup(
      [
        Self.ad(teachers: [
          .init(feedURL: "https://example.com/a", identityKey: "guid:1"),
          .init(feedURL: "https://example.com/gone", identityKey: "guid:9"),
        ]),
        Self.ad(kind: .tombstone, hashes: [7]),
      ], feeds: ["https://example.com/a"])
    let restorer = NativePodcastBackupRestorer(database: database)

    let first = try await restorer.restore(contents)
    #expect(first.learnedAdsAdded == 2)
    let feed = try #require(first.addedFeedIDs.first)
    let stored = try await AdSignatureStore(database: database).allCreatives()
    #expect(stored.count == 2)
    #expect(stored[0].teachers == [Self.rssKey(feed: feed, episode: "guid:1")])
    #expect(stored[0].hashes == [1, 2, UInt64.max] && stored[0].hasAudioPrint)
    #expect(stored[1].kind == .tombstone && stored[1].hasAudioPrint == false)

    let second = try await restorer.restore(contents)
    #expect(second.learnedAdsAdded == 0)
    #expect(try await AdSignatureStore(database: database).allCreatives().count == 2)
  }

  @Test func aConfirmedAdIsExportedAndRestoredConfirmed() async throws {
    let source = try AppDatabase.inMemory()
    _ = try await AdSignatureStore(database: source).apply(
      AdSignatureStoreChange(insertions: [
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Self.t0, startTime: 10, endTime: 40, teachers: [], hashes: [1, 2],
          audioPrint: Self.print, confirmed: true),
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Self.t0, startTime: 10, endTime: 40, teachers: [], hashes: [3]),
      ]))
    let exported = try await NativePodcastBackupReader(database: source).contents().learnedAds
    #expect(exported.map(\.confirmed) == [true, false])

    let target = try AppDatabase.inMemory()
    _ = try await NativePodcastBackupRestorer(database: target).restore(Self.backup(exported))
    let restored = try await AdSignatureStore(database: target).allCreatives()
    #expect(restored.map(\.confirmed) == [true, false])
  }

  /// An ad the device holds unconfirmed becomes the listener's when the file says it is.
  @Test func aConfirmedFileAdConfirmsTheLocalAdHoldingIt() async throws {
    let database = try AppDatabase.inMemory()
    let store = AdSignatureStore(database: database)
    _ = try await store.apply(
      AdSignatureStoreChange(insertions: [
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Self.t0, startTime: 1, endTime: 2, teachers: [], hashes: [1, 2, 3])
      ]))
    _ = try await NativePodcastBackupRestorer(database: database).restore(
      Self.backup([Self.ad(hashes: [1, 2], confirmed: true)]))
    #expect(try await store.allCreatives().map(\.confirmed) == [true])
  }

  @Test func anAdTheDeviceAlreadyHasKeepsTheLaterLastSeenAndGainsAMissingPrint() async throws {
    let database = try AppDatabase.inMemory()
    let store = AdSignatureStore(database: database)
    _ = try await store.apply(
      AdSignatureStoreChange(insertions: [
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Self.t0, startTime: 1, endTime: 2, teachers: ["local"], hashes: [1, 2]),
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Self.t0.addingTimeInterval(500), startTime: 1, endTime: 2, teachers: [],
          hashes: [3], audioPrint: Data([9, 9, 9, 9])),
      ]))

    let outcome = try await NativePodcastBackupRestorer(database: database).restore(
      Self.backup([
        Self.ad(lastSeen: Self.t0.addingTimeInterval(60), hashes: [1, 2]),
        Self.ad(lastSeen: Self.t0, hashes: [3]),
      ]))
    #expect(outcome.learnedAdsAdded == 0)
    let stored = try await store.allCreatives()
    #expect(stored.count == 2)
    #expect(stored[0].lastSeen == Self.t0.addingTimeInterval(60) && stored[0].hasAudioPrint)
    #expect(stored[0].teachers == ["local"])
    #expect(stored[1].lastSeen == Self.t0.addingTimeInterval(500))
    let prints = try await store.learnedAudioPrints()
    #expect(prints.map(\.audioPrint) == [Self.print, Data([9, 9, 9, 9])])
  }

  /// The device stores each ad once with the hashes of every copy, so a copy in the file is inside
  /// the local ad. It adds nothing but its teachers, and the coordinator is owed a recompute.
  @Test func aFileAdALocalAdHoldsAddsItsTeachersAndNoAd() async throws {
    let database = try AppDatabase.inMemory()
    let store = AdSignatureStore(database: database)
    _ = try await store.apply(
      AdSignatureStoreChange(insertions: [
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Self.t0, startTime: 1, endTime: 2, teachers: ["local"], hashes: [1, 2, 3, 4],
          audioPrint: Data([9, 9, 9, 9])),
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Self.t0, startTime: 1, endTime: 2, teachers: [], hashes: [1, 2, 3, 4, 5]),
      ]))
    let contents = Self.backup(
      [
        Self.ad(hashes: [1, 2], teachers: [.init(feedURL: "https://example.com/a", identityKey: "guid:1")]),
        Self.ad(hashes: [3, 4], teachers: [.init(feedURL: "https://example.com/a", identityKey: "guid:1")]),
      ], feeds: ["https://example.com/a"])
    let restorer = NativePodcastBackupRestorer(database: database)

    let outcome = try await restorer.restore(contents)
    #expect(outcome.learnedAdsAdded == 0)
    // Both file ads land on the lowest holder; the second changes nothing.
    #expect(outcome.learnedAdsChanged == 1)
    let feed = try #require(outcome.addedFeedIDs.first)
    let stored = try await store.allCreatives()
    #expect(stored.count == 2)
    #expect(stored[0].teachers == ["local", Self.rssKey(feed: feed, episode: "guid:1")])
    #expect(stored[0].hashes == [1, 2, 3, 4] && stored[1].teachers.isEmpty)
    #expect(try await store.learnedAudioPrints().map(\.audioPrint) == [Data([9, 9, 9, 9])])

    let again = try await restorer.restore(contents)
    #expect(again.learnedAdsAdded == 0 && again.learnedAdsChanged == 0)
  }

  @Test func aFileAdWithAHashNoLocalAdHoldsIsAdded() async throws {
    let database = try AppDatabase.inMemory()
    let store = AdSignatureStore(database: database)
    _ = try await store.apply(
      AdSignatureStoreChange(insertions: [
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Self.t0, startTime: 1, endTime: 2, teachers: [], hashes: [1, 2]),
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Self.t0, startTime: 1, endTime: 2, teachers: [], hashes: [3]),
      ]))
    // [1, 2, 3] is spread over two local ads and held by neither.
    let outcome = try await NativePodcastBackupRestorer(database: database).restore(
      Self.backup([Self.ad(hashes: [1, 2, 3]), Self.ad(hashes: [1, 99])]))
    #expect(outcome.learnedAdsAdded == 2 && outcome.learnedAdsChanged == 0)
    #expect(try await store.allCreatives().count == 4)
  }

  /// An ad the same restore added holds the copies that follow it in the file.
  @Test func aLaterFileAdInsideAnEarlierOneIsNotAdded() async throws {
    let database = try AppDatabase.inMemory()
    let outcome = try await NativePodcastBackupRestorer(database: database).restore(
      Self.backup([Self.ad(hashes: [1, 2, 3]), Self.ad(hashes: [2, 3], audioPrint: nil)]))
    #expect(outcome.learnedAdsAdded == 1 && outcome.learnedAdsChanged == 0)
    let stored = try await AdSignatureStore(database: database).allCreatives()
    #expect(stored.map(\.hashes) == [[1, 2, 3]])
  }

  /// An undone skip is exact: one inside another is a different range the listener refused.
  @Test func anUndoneSkipIsHereOnlyWithExactlyTheSameHashes() async throws {
    let database = try AppDatabase.inMemory()
    let restorer = NativePodcastBackupRestorer(database: database)
    let contents = Self.backup([
      Self.ad(kind: .tombstone, hashes: [1, 2, 3]), Self.ad(kind: .tombstone, hashes: [1, 2]),
      Self.ad(hashes: [1, 2, 3, 4]), Self.ad(kind: .tombstone, hashes: [1, 2, 3, 4]),
    ])
    #expect(try await restorer.restore(contents).learnedAdsAdded == 4)
    let again = try await restorer.restore(contents)
    #expect(again.learnedAdsAdded == 0 && again.learnedAdsChanged == 0)
  }

  @Test func aLocalAdNeverGainsMoreTeachersThanTheBackupLimit() async throws {
    let database = try AppDatabase.inMemory()
    let store = AdSignatureStore(database: database)
    let limit = NativePodcastBackupRestorer.maximumLearnedAdTeachers
    _ = try await store.apply(
      AdSignatureStoreChange(insertions: [
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Self.t0, startTime: 1, endTime: 2,
          teachers: Set((0..<(limit - 1)).map { "local-\($0)" }), hashes: [1, 2])
      ]))
    let outcome = try await NativePodcastBackupRestorer(database: database).restore(
      Self.backup(
        [
          Self.ad(
            hashes: [1], audioPrint: nil,
            teachers: Set((0..<5).map { .init(feedURL: "https://example.com/a", identityKey: "guid:\($0)") }))
        ], feeds: ["https://example.com/a"]))
    #expect(outcome.learnedAdsChanged == 1)
    let feed = try #require(outcome.addedFeedIDs.first)
    let teachers = try #require(try await store.allCreatives().first?.teachers)
    #expect(teachers.count == limit)
    #expect(teachers.contains(Self.rssKey(feed: feed, episode: "guid:0")))
  }

  /// The same hashes as a tombstone and as a learned ad are two different entries.
  @Test func aTombstoneAndALearnedAdWithTheSameHashesAreBothKept() async throws {
    let database = try AppDatabase.inMemory()
    let outcome = try await NativePodcastBackupRestorer(database: database).restore(
      Self.backup([Self.ad(hashes: [5]), Self.ad(kind: .tombstone, hashes: [5])]))
    #expect(outcome.learnedAdsAdded == 2)
  }

  @Test func previewCountsLearnedAdsAndWritesNothing() async throws {
    let database = try AppDatabase.inMemory()
    let outcome = try await NativePodcastBackupRestorer(database: database).preview(Self.backup([Self.ad()]))
    #expect(outcome.learnedAdsAdded == 1)
    #expect(try await AdSignatureStore(database: database).allCreatives().isEmpty)
  }

  @Test func rssTeacherKeysRoundTripAndOtherKeysAreNotRSSTeachers() {
    let key = Self.rssKey(feed: 12, episode: "guid:abc")
    let parsed = AdSkipEpisodeIdentity.rssTeacher(fromKey: key)
    #expect(parsed?.feedID == 12 && parsed?.identityKey == "guid:abc")
    #expect(AdSkipEpisodeIdentity.rssTeacherKey(feedID: 12, identityKey: "guid:abc") == key)
    let server = AdSkipEpisodeIdentity(source: .abs, accountId: 1, itemID: "li", episodeID: "ep").teacherKey
    #expect(AdSkipEpisodeIdentity.rssTeacher(fromKey: server) == nil)
    #expect(AdSkipEpisodeIdentity.rssTeacher(fromKey: "ep-a") == nil)
  }
}
