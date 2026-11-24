import Foundation
import GRDB
import Testing

@testable import Persistence

/// The storage ceiling never offers an unfinished episode a smart list claimed, for both
/// sources. Without the exclusion the ceiling evicts what the list just requested and the next
/// pass requests it again.
@Suite struct StorageEvictionSmartListClaimTests {

  @Test func anUnfinishedClaimedServerEpisodeIsNotACandidateAndAnUnclaimedOneIs() async throws {
    let world = try await SmartListReadingWorld.make()
    let accountId = try #require(world.accountId)
    let show = try await world.show("show")
    var episodes: [String: Int64] = [:]
    for index in 1...5 {
      episodes["s\(index)"] = try await world.server(
        show: show, "s\(index)", published: SmartListReadingWorld.at(Double(index)))
    }
    // Ranks 5 and 4 of 5: outside the default keep-latest window, so only the claim protects one.
    try await world.serverDownload(show: show, episode: try #require(episodes["s1"]))
    try await world.serverDownload(show: show, episode: try #require(episodes["s2"]))
    let list = try await world.list()
    try await world.store().recordClaim(
      listID: list, itemID: "show", episodeID: "s1", accountID: accountId, at: Date())

    let candidates = try await StorageEvictionStore(database: world.database, accountId: accountId)
      .fetchCandidates()

    #expect(candidates.map(\.podcastEpisodeId) == [episodes["s2"]])
  }

  @Test func aFinishedClaimedServerEpisodeIsStillACandidate() async throws {
    let world = try await SmartListReadingWorld.make()
    let accountId = try #require(world.accountId)
    let show = try await world.show("show")
    var episodes: [Int64] = []
    for index in 1...5 {
      episodes.append(
        try await world.server(show: show, "s\(index)", published: SmartListReadingWorld.at(Double(index))))
    }
    try await world.serverDownload(show: show, episode: episodes[0])
    try await world.serverProgress(show: show, episode: episodes[0], position: 1_800, finished: true)
    let list = try await world.list()
    try await world.store().recordClaim(
      listID: list, itemID: "show", episodeID: "s1", accountID: accountId, at: Date())

    let candidates = try await StorageEvictionStore(database: world.database, accountId: accountId)
      .fetchCandidates()

    #expect(candidates.map(\.podcastEpisodeId) == [episodes[0]])
  }

  @Test func anUnfinishedClaimedNativeEpisodeIsNotACandidateAndAnUnclaimedOneIs() async throws {
    let world = try await SmartListReadingWorld.make()
    let accountId = try #require(world.accountId)
    let feed = try await world.feed("https://a.example/feed")
    var episodes: [Int64] = []
    for index in 1...5 {
      episodes.append(
        try await world.native(feed: feed, "e\(index)", published: SmartListReadingWorld.at(Double(index))))
    }
    try await world.nativeDownload(episodes[0])
    try await world.nativeDownload(episodes[1])
    let list = try await world.list()
    try await world.store().recordClaim(
      listID: list, itemID: "rss:\(feed)", episodeID: "e1", accountID: nil, at: Date())
    let store = StorageEvictionStore(database: world.database, accountId: accountId)

    #expect(try await store.fetchCandidates().map(\.podcastEpisodeId) == [episodes[1]])
    // The atomic claim re-reads the same exclusion, so the claimed row is never marked deleting.
    let claimed = try await store.claimUnion(targetBytes: 1)
    #expect(claimed.map(\.podcastEpisodeId) == [episodes[1]])
  }

  @Test func aFinishedClaimedNativeEpisodeIsStillACandidate() async throws {
    let world = try await SmartListReadingWorld.make()
    let accountId = try #require(world.accountId)
    let feed = try await world.feed("https://a.example/feed")
    var episodes: [Int64] = []
    for index in 1...5 {
      episodes.append(
        try await world.native(feed: feed, "e\(index)", published: SmartListReadingWorld.at(Double(index))))
    }
    try await world.nativeDownload(episodes[0])
    try await world.nativeProgress(episodes[0], position: 1_800, finished: true)
    let list = try await world.list()
    try await world.store().recordClaim(
      listID: list, itemID: "rss:\(feed)", episodeID: "e1", accountID: nil, at: Date())

    let candidates = try await StorageEvictionStore(database: world.database, accountId: accountId)
      .fetchCandidates()

    #expect(candidates.map(\.podcastEpisodeId) == [episodes[0]])
  }
}
