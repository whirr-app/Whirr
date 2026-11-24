import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite("SmartListEpisodesReading twins", .timeLimit(.minutes(1)))
struct SmartListEpisodesReadingTwinTests {
  typealias World = SmartListReadingWorld

  private static let fingerprint = String(repeating: "c", count: 64)

  /// A followed native show and the same show on the server, one episode saved from the first to
  /// the second, linked the way Home's `nativePreferred` rule reads.
  private struct Pair {
    let world: World
    let feed: Int64
    let nativeEpisode: Int64
    let show: Int64
    let serverEpisode: Int64
  }

  private func pair(
    linked: Bool = true, feedFingerprint: String? = fingerprint, generation: Int = 1,
    viaAlternateKey: Bool = false
  ) async throws -> Pair {
    let w = try await World.make()
    let feed = try await w.feed(
      "https://f/twin", fingerprint: feedFingerprint, generation: generation)
    let native = try await w.native(
      feed: feed, "primary", published: World.at(-10), generation: generation,
      alternateKey: "alternate")
    let show = try await w.show("srv", fingerprint: Self.fingerprint)
    let server = try await w.server(show: show, "srv-ep", published: World.at(-10))
    try await w.server(show: show, "srv-other", published: World.at(-20))
    if linked {
      try await w.link(
        feed: feed, nativeEpisode: native, identityKey: viaAlternateKey ? "alternate" : "primary",
        serverItemID: "srv", serverEpisodeID: "srv-ep")
    }
    return Pair(world: w, feed: feed, nativeEpisode: native, show: show, serverEpisode: server)
  }

  @Test("a linked server copy is dropped for the native one, by either identity key")
  func collapses() async throws {
    for alternate in [false, true] {
      let p = try await pair(viaAlternateKey: alternate)
      let list = try await p.world.list()
      #expect(try await p.world.ids(list) == ["n:primary", "s:srv-other"])
    }
  }

  @Test("the twin is dropped even when the list's rules exclude the native copy")
  func nativeNeedNotMatchTheRules() async throws {
    let p = try await pair()
    try await p.world.nativeProgress(p.nativeEpisode, position: 1, finished: true)
    let list = try await p.world.list()  // Played off: the native copy is not listed.
    #expect(try await p.world.ids(list) == ["s:srv-other"])
    // Likewise when the native show is not one the list names.
    let only = try await p.world.list(
      SmartListRules(showScope: .only), shows: [.server("srv", .included)])
    #expect(try await p.world.ids(only) == ["s:srv-other"])
  }

  @Test("without a save-attempt link, after re-login, both copies appear")
  func appearsTwiceWithoutALink() async throws {
    let p = try await pair(linked: false)
    #expect(Set(try await p.world.ids(try await p.world.list())) == ["n:primary", "s:srv-ep", "s:srv-other"])

    // A link written for the previous login's client UUID no longer joins.
    let relinked = try await pair()
    try await relinked.world.database.writeAsync { db in
      try db.execute(sql: "UPDATE account SET clientUUID = ?", arguments: [UUID().uuidString])
    }
    let list = try await relinked.world.list()
    #expect(Set(try await relinked.world.ids(list)) == ["n:primary", "s:srv-ep", "s:srv-other"])
  }

  @Test("the link needs equal valid fingerprints, a current native episode and native enabled")
  func linkConditions() async throws {
    let differentFeed = try await pair(feedFingerprint: String(repeating: "d", count: 64))
    #expect(
      try await differentFeed.world.ids(try await differentFeed.world.list()).contains("s:srv-ep"))

    let missing = try await pair(feedFingerprint: nil)
    #expect(try await missing.world.ids(try await missing.world.list()).contains("s:srv-ep"))

    // The native episode dropped out of its feed: the server copy stands in for it.
    let stale = try await pair()
    try await stale.world.database.writeAsync { db in
      try db.execute(sql: "UPDATE rssFeed SET refreshGeneration = 2")
    }
    #expect(try await stale.world.ids(try await stale.world.list()) == ["s:srv-ep", "s:srv-other"])

    // Native subscriptions off: nothing prefers a native copy that is not read.
    let off = try await pair()
    let list = try await off.world.list()
    #expect(try await off.world.ids(list, nativeEnabled: false) == ["s:srv-ep", "s:srv-other"])
  }

  @Test("a link for another server episode or item does not collapse this one")
  func linkIsExact() async throws {
    let p = try await pair(linked: false)
    try await p.world.link(
      feed: p.feed, nativeEpisode: p.nativeEpisode, identityKey: "primary", serverItemID: "srv",
      serverEpisodeID: "srv-other")
    let list = try await p.world.list()
    #expect(try await p.world.ids(list) == ["n:primary", "s:srv-ep"])
  }

  @Test("show-level helper: a server show with a fingerprint-matching followed feed")
  func showLevelHelper() async throws {
    let p = try await pair(linked: false)
    _ = try await p.world.show("plain", fingerprint: String(repeating: "e", count: 64))
    _ = try await p.world.show("malformed", fingerprint: "not-a-fingerprint")
    _ = try await p.world.show("none")
    let keys = try await p.world.reading().serverShowKeysWithFollowedNativeTwin()
    #expect(keys == ["user-1|srv"])

    let signedOut = try await World.make(signedIn: false)
    #expect(try await signedOut.reading().serverShowKeysWithFollowedNativeTwin().isEmpty)
  }
}
