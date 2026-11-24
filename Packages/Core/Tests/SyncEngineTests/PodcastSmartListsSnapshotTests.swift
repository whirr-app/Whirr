import Foundation
import GRDB
import Persistence
import Testing

@testable import SyncEngine

/// The optional smart-lists section of the podcast backup file.
@Suite struct PodcastSmartListsSnapshotTests {
  private typealias Seed = PodcastBackupSnapshotMappingTests
  private typealias Codec = PodcastSmartListsSnapshotCodec

  private static let feedA = "https://example.com/feed"
  private static let feedB = "https://example.com/other"

  private static func database(followed urls: [String]) async throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    var contents = Seed.contents()
    contents.feeds = urls.map { Seed.feed($0) }
    contents.episodes = []
    contents.bookmark = nil
    _ = try await NativePodcastBackupRestorer(database: database).restore(contents)
    return database
  }

  private static func feedID(_ database: AppDatabase, _ url: String) async throws -> Int64 {
    try #require(try await RSSFeedStore(database: database).fetchFeeds().first { $0.feedURL == url }?.id)
  }

  /// Two lists, one with every kind of reference and hidden episode.
  private static func seededSource() async throws -> AppDatabase {
    let database = try await Self.database(followed: [feedA, feedB])
    let store = SmartListStore(database: database)
    var rules = SmartListRules.default
    rules.showScope = .only
    rules.sortOrder = .oldest
    rules.autoDownload = true
    let commute = try await store.create(
      name: "Commute", rules: rules,
      shows: [
        .init(ref: .native(feedURL: feedA), role: .included, titleSnapshot: "Feed A"),
        .init(ref: .native(feedURL: "https://gone.example.com/feed"), role: .priority, titleSnapshot: "Gone"),
        .init(ref: .server(serverUserID: "user-1", serverItemID: "item-9"), role: .excluded, titleSnapshot: "Server"),
      ])
    _ = try await store.create(name: "Gym", rules: .newReleases)
    let hidden = SmartListHiddenEpisodeStore(database: database)
    try await hidden.hide(listID: commute.id, itemID: "rss:\(try await feedID(database, feedB))", episodeID: "zero")
    try await hidden.hide(listID: commute.id, itemID: "rss:\(try await feedID(database, feedA))", episodeID: "alpha")
    try await hidden.hide(listID: commute.id, itemID: "server-item", episodeID: "server-episode")
    // Device state, not carried.
    try await SmartListRunStore(database: database).begin(listID: commute.id, now: Seed.date(5))
    return database
  }

  private static func file(_ database: AppDatabase) async throws -> Data {
    let export = try await Codec.export(from: database)
    return try PodcastStateSnapshotCodec.encodeWrapped(
      PodcastBackupSnapshotMapping.snapshot(
        from: Seed.contents(), exportedAt: Seed.date(900), smartLists: export.snapshot
      ).snapshot)
  }

  @Test func listsSurviveTheFileRoundTripByPortableIdentity() async throws {
    let source = try await Self.seededSource()
    let decoded = try PodcastStateSnapshotCodec.decodeWrapped(try await Self.file(source))
    let section = try #require(decoded.smartLists)

    #expect(section.lists.map(\.name) == ["Commute", "Gym"])
    let commute = section.lists[0]
    #expect(commute.rules.showScope == .only && commute.rules.sortOrder == .oldest && commute.rules.autoDownload)
    #expect(section.lists[1].rules == .newReleases)
    #expect(
      commute.shows == [
        .init(source: .native, feedURL: Self.feedA, role: .included, titleSnapshot: "Feed A"),
        .init(source: .native, feedURL: "https://gone.example.com/feed", role: .priority, titleSnapshot: "Gone"),
        .init(
          source: .server, serverUserId: "user-1", serverItemId: "item-9", role: .excluded, titleSnapshot: "Server"),
      ])
    // Native before server, then by show address, then by episode.
    #expect(
      commute.hiddenEpisodes == [
        .init(source: .native, feedURL: Self.feedA, episodeID: "alpha"),
        .init(source: .native, feedURL: Self.feedB, episodeID: "zero"),
        .init(source: .server, itemID: "server-item", episodeID: "server-episode"),
      ])
    #expect(try PodcastStateSnapshotCodec.encode(decoded) == PodcastStateSnapshotCodec.encode(decoded))
  }

  @Test func theFileNamesNoRowIdsAndNothingFromTheRun() async throws {
    let source = try await Self.seededSource()
    let payload = try await Self.payload(Self.file(source))
    #expect(payload.contains("\"smartLists\""))
    for forbidden in ["rss:", "anchor", "startedAt", "claim", "listId"] {
      #expect(payload.contains(forbidden) == false, "\(forbidden)")
    }
  }

  @Test func aDeviceWithNoListsWritesTheFileItAlwaysDid() async throws {
    let empty = try await Self.database(followed: [Self.feedA])
    let export = try await Codec.export(from: empty)
    #expect(export.snapshot == nil)
    let plain = try PodcastStateSnapshotCodec.encodeWrapped(
      PodcastBackupSnapshotMapping.snapshot(from: Seed.contents(), exportedAt: Seed.date(900)).snapshot)
    #expect(try await Self.file(empty) == plain)
    #expect(try Self.payload(plain).contains("smartLists") == false)
  }

  @Test func encodingIsDeterministicWhateverTheRowOrder() async throws {
    let first = try await Self.file(try await Self.seededSource())
    let second = try await Self.file(try await Self.seededSource())
    #expect(first == second)
    // The hidden episodes are written in a fixed order, not the order they were hidden.
    let reversed = try await Self.database(followed: [Self.feedA, Self.feedB])
    let store = SmartListStore(database: reversed)
    let list = try await store.create(name: "L")
    let hidden = SmartListHiddenEpisodeStore(database: reversed)
    let id = try await Self.feedID(reversed, Self.feedA)
    for episode in ["c", "a", "b"] { try await hidden.hide(listID: list.id, itemID: "rss:\(id)", episodeID: episode) }
    let section = try #require(try await Codec.export(from: reversed).snapshot)
    #expect(section.lists[0].hiddenEpisodes.map(\.episodeID) == ["a", "b", "c"])
  }

  @Test func aBuildThatDoesNotKnowTheSectionReadsTheRest() async throws {
    struct Envelope: Decodable { let payload: String }
    struct Before: Decodable {
      let version: Int
      let subscriptions: [SubscriptionSnapshot]
      let episodes: [EpisodeSnapshot]
    }
    let payload = try await Self.payload(Self.file(Self.seededSource()))
    #expect(payload.contains("\"smartLists\""))
    let before = try JSONDecoder().decode(Before.self, from: Data(payload.utf8))
    #expect(before.version == 1 && before.subscriptions.count == 1 && before.episodes.count == 3)
    #expect(try PodcastStateSnapshotCodec.decode(Data(payload.utf8)).version == 1)
  }

  @Test func anOldFileWithoutTheSectionRestoresWithoutLists() async throws {
    let plain = try PodcastStateSnapshotCodec.encodeWrapped(
      PodcastBackupSnapshotMapping.snapshot(from: Seed.contents(), exportedAt: Seed.date(900)).snapshot)
    let decoded = try PodcastStateSnapshotCodec.decodeWrapped(plain)
    #expect(decoded.smartLists == nil)
    let target = try await Self.database(followed: [Self.feedA])
    let outcome = try await Codec.restore(decoded.smartLists, into: target)
    #expect(outcome == Codec.RestoreOutcome())
    #expect(try await SmartListStore(database: target).lists().isEmpty)
  }

  @Test func hiddenNativeEpisodesFollowTheFeedAddressToTheNewRowId() async throws {
    let source = try await Self.seededSource()
    let decoded = try PodcastStateSnapshotCodec.decodeWrapped(try await Self.file(source))
    // A device whose feeds were added in the other order, so the row ids differ.
    let target = try await Self.database(followed: [Self.feedB, Self.feedA])
    let outcome = try await Codec.restore(decoded.smartLists, into: target)

    #expect(outcome.listsAdded == 2 && outcome.listsSkippedExisting == 0)
    let lists = try await SmartListStore(database: target).lists()
    #expect(lists.map(\.name) == ["Commute", "Gym"] && lists.map(\.position) == [0, 1])
    let hidden = try await SmartListHiddenEpisodeStore(database: target).hiddenEpisodes(listID: lists[0].id)
    let idA = try await Self.feedID(target, Self.feedA)
    let idB = try await Self.feedID(target, Self.feedB)
    #expect(idA != (try await Self.feedID(source, Self.feedA)))
    #expect(
      Set(hidden.map { "\($0.itemID)|\($0.episodeID)" })
        == ["rss:\(idB)|zero", "rss:\(idA)|alpha", "server-item|server-episode"])
    #expect(outcome.hiddenEpisodesRestored == 3 && outcome.hiddenEpisodesDropped == 0)
  }

  @Test func hiddenEpisodesOfAFeedNotFollowedAreDroppedAndCounted() async throws {
    let source = try await Self.seededSource()
    let decoded = try PodcastStateSnapshotCodec.decodeWrapped(try await Self.file(source))
    let target = try await Self.database(followed: [Self.feedA])
    let outcome = try await Codec.restore(decoded.smartLists, into: target)

    let lists = try await SmartListStore(database: target).lists()
    let hidden = try await SmartListHiddenEpisodeStore(database: target).hiddenEpisodes(listID: lists[0].id)
    #expect(hidden.map(\.episodeID).sorted() == ["alpha", "server-episode"])
    #expect(outcome.hiddenEpisodesRestored == 2 && outcome.hiddenEpisodesDropped == 1)
  }

  @Test func showRowsForShowsNotOnTheDeviceAreKeptAndCounted() async throws {
    let source = try await Self.seededSource()
    let decoded = try PodcastStateSnapshotCodec.decodeWrapped(try await Self.file(source))
    let target = try await Self.database(followed: [Self.feedA])
    let outcome = try await Codec.restore(decoded.smartLists, into: target)

    let list = try #require(try await SmartListStore(database: target).lists().first)
    let shows = try await SmartListStore(database: target).shows(listID: list.id)
    #expect(
      shows.map { "\($0.source.rawValue)|\($0.showKey)|\($0.role.rawValue)|\($0.titleSnapshot)" } == [
        "native|\(Self.feedA)|included|Feed A", "native|https://gone.example.com/feed|priority|Gone",
        "server|user-1|item-9|excluded|Server",
      ])
    #expect(outcome.showsRestored == 3 && outcome.showsNotOnDevice == 2)
  }

  @Test func listsAreAppendedAfterTheDevicesOwnAndNeverDuplicated() async throws {
    let source = try await Self.seededSource()
    let decoded = try PodcastStateSnapshotCodec.decodeWrapped(try await Self.file(source))
    let target = try await Self.database(followed: [Self.feedA])
    let store = SmartListStore(database: target)
    _ = try await store.create(name: "Mine")
    _ = try await store.create(name: " gym ")

    let first = try await Codec.restore(decoded.smartLists, into: target)
    #expect(first.listsAdded == 1 && first.listsSkippedExisting == 1)
    #expect(try await store.lists().map(\.name) == ["Mine", "gym", "Commute"])
    let again = try await Codec.restore(decoded.smartLists, into: target)
    #expect(again.listsAdded == 0 && again.listsSkippedExisting == 2)
    #expect(try await store.lists().count == 3)
  }

  @Test func theFiftyListCapDropsTheRestAndCountsThem() async throws {
    let target = try await Self.database(followed: [Self.feedA])
    let store = SmartListStore(database: target)
    for index in 0..<48 { _ = try await store.create(name: "Existing \(index)") }
    let section = PodcastSmartListsSnapshot(
      lists: (0..<4).map {
        SmartListBackupSnapshot(name: "Imported \($0)", rules: .default, shows: [], hiddenEpisodes: [])
      })
    let outcome = try await Codec.restore(section, into: target)
    #expect(outcome.listsAdded == 2 && outcome.listsDroppedOverLimit == 2)
    #expect(try await store.lists().count == SmartListStore.maximumListCount)
  }

  @Test func aListThisBuildRefusesIsSkippedNotFatal() async throws {
    var bad = SmartListRules.default
    bad.includeUnplayed = false
    bad.includeInProgress = false
    bad.includePlayed = false
    let section = PodcastSmartListsSnapshot(lists: [
      SmartListBackupSnapshot(name: "Bad", rules: bad, shows: [], hiddenEpisodes: []),
      SmartListBackupSnapshot(name: "   ", rules: .default, shows: [], hiddenEpisodes: []),
      SmartListBackupSnapshot(name: "Fine", rules: .default, shows: [], hiddenEpisodes: []),
    ])
    let target = try await Self.database(followed: [])
    let outcome = try await Codec.restore(section, into: target)
    #expect(outcome.listsAdded == 1 && outcome.listsSkippedInvalid == 2)
  }

  @Test func aListWithAnUnknownRuleValueIsLeftOutOfTheDecodedSection() throws {
    let json = """
      {"lists":[{"name":"A","rules":{"showScope":"someday"},"shows":[],"hiddenEpisodes":[]}]}
      """
    let decoded = try JSONDecoder().decode(PodcastSmartListsSnapshot.self, from: Data(json.utf8))
    #expect(decoded.lists.isEmpty)
  }

  @Test func exportLeavesOutWhatTheFileCannotCarryAndCountsIt() async throws {
    let database = try await Self.database(followed: [Self.feedA])
    let store = SmartListStore(database: database)
    let list = try await store.create(
      name: "L",
      shows: [
        .init(ref: .native(feedURL: "https://user:secret@example.com/feed"), role: .included, titleSnapshot: "Cred"),
        .init(ref: .native(feedURL: Self.feedA), role: .included, titleSnapshot: "Ok"),
        .init(ref: SmartListShowRef(source: .server, showKey: "nobar"), role: .included, titleSnapshot: "Bad"),
      ])
    // Stale hidden row: the feed row is gone.
    try await SmartListHiddenEpisodeStore(database: database).hide(listID: list.id, itemID: "rss:999", episodeID: "x")
    let export = try await Codec.export(from: database)
    #expect(export.showsDropped == 2 && export.hiddenEpisodesDropped == 1)
    #expect(export.snapshot?.lists[0].shows.map(\.titleSnapshot) == ["Ok"])
  }

  @Test func validationRefusesASectionOutsideItsLimits() throws {
    let base = try PodcastBackupSnapshotMapping.snapshot(from: Seed.contents(), exportedAt: Seed.date(900)).snapshot
    func snapshot(_ lists: [SmartListBackupSnapshot]) -> PodcastStateSnapshot {
      PodcastStateSnapshot(
        exportedAt: base.exportedAt, globalSettings: base.globalSettings, subscriptions: base.subscriptions,
        episodeIdentities: base.episodeIdentities, episodes: base.episodes,
        smartLists: PodcastSmartListsSnapshot(lists: lists))
    }
    func list(shows: [SmartListShowBackupSnapshot] = [], hidden: [SmartListHiddenEpisodeBackupSnapshot] = [])
      -> SmartListBackupSnapshot
    {
      SmartListBackupSnapshot(name: "A", rules: .default, shows: shows, hiddenEpisodes: hidden)
    }
    try PodcastStateSnapshotCodec.validate(snapshot([list()]))
    let tooMany = (0...Codec.maxLists).map { _ in list() }
    #expect(throws: PodcastStateSnapshotCodecError.invalidValue) {
      try PodcastStateSnapshotCodec.validate(snapshot(tooMany))
    }
    let mismatched = [
      list(shows: [.init(source: .native, role: .included, titleSnapshot: "")]),
      list(shows: [.init(source: .server, serverUserId: "a|b", serverItemId: "i", role: .included, titleSnapshot: "")]),
      list(hidden: [.init(source: .native, itemID: "rss:1", episodeID: "e")]),
      list(hidden: [.init(source: .server, itemID: "i", episodeID: "")]),
    ]
    for bad in mismatched {
      #expect(throws: PodcastStateSnapshotCodecError.invalidValue) {
        try PodcastStateSnapshotCodec.validate(snapshot([bad]))
      }
    }
    #expect(throws: PodcastStateSnapshotCodecError.credentialedURL) {
      try PodcastStateSnapshotCodec.validate(
        snapshot([
          list(shows: [.init(source: .native, feedURL: "https://u:p@example.com/f", role: .included, titleSnapshot: "")]
          )
        ]))
    }
  }

  private static func payload(_ file: Data) throws -> String {
    struct Envelope: Decodable { let payload: String }
    return try JSONDecoder().decode(Envelope.self, from: file).payload
  }
}
