import Foundation
import Testing

@testable import WatchProtocol

@Suite("Watch podcast browse wire")
struct WatchBrowseTests {
  private let stamp = WatchProtocolFixtures.accountStamp()

  @Test("In Progress requests round trip for cross-show and per-show browsing")
  func inProgressRequests() throws {
    let filter = try #require(WatchBrowsePlayedFilter(rawValue: "inProgress"))
    for scope in [WatchBrowseScope.latestEpisodes, .episodes(show: .nativeFeed(feedID: "17"))] {
      let request = try WatchBrowseRequest(accountStamp: stamp, scope: scope, played: filter)
      #expect(try WatchWireCodec.decode(WatchBrowseRequest.self, from: WatchWireCodec.encode(request)) == request)
    }
  }

  @Test("a request may name one source; an older Watch's request names none and means both")
  func requestSourceRoundTripsAndStaysOptional() throws {
    for source in [WatchBrowseSource.audiobookshelf, .nativeFeed] {
      let request = try WatchBrowseRequest(accountStamp: stamp, scope: .shows, source: source)
      let decoded = try WatchWireCodec.decode(WatchBrowseRequest.self, from: WatchWireCodec.encode(request))
      #expect(decoded == request)
      #expect(decoded.source == source)
    }

    let legacy = try WatchBrowseRequest(accountStamp: stamp, scope: .latestEpisodes)
    let object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(legacy)) as? [String: Any])
    #expect(object["source"] == nil)
    let decoded = try WatchWireCodec.decode(
      WatchBrowseRequest.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.source == nil)

    var unknown = object
    unknown["source"] = "somewhereElse"
    #expect(throws: (any Error).self) {
      try WatchWireCodec.decode(WatchBrowseRequest.self, from: JSONSerialization.data(withJSONObject: unknown))
    }
  }

  @Test("a browse source matches the source of the rows it names")
  func sourceMatchesRows() throws {
    let abs = WatchBrowseShowIdentity.audiobookshelf(itemID: "same")
    let rss = WatchBrowseShowIdentity.nativeFeed(feedID: "same")
    #expect(WatchBrowseSource.audiobookshelf.contains(abs))
    #expect(!WatchBrowseSource.audiobookshelf.contains(rss))
    #expect(WatchBrowseSource.nativeFeed.contains(rss))
    #expect(!WatchBrowseSource.nativeFeed.contains(abs))
  }

  @Test("request and paged reply round trip without URLs or credentials")
  func roundTrip() throws {
    let selection = WatchSelection.nativeFeed(feedID: "17", episodeID: "episode:1")
    let row = try WatchBrowseEpisodeRow(
      selection: selection,
      show: .nativeFeed(feedID: "17"),
      showTitle: "A show",
      title: "An episode",
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      durationSeconds: 120,
      progressSeconds: 12,
      isPlayed: true)
    let page = try WatchProtocolFixtures.browsePage(
      page: 0, pageSize: 10, rows: [.episode(row)], nextPage: 1, isComplete: false, generation: 3)
    let request = try WatchBrowseRequest(accountStamp: stamp, scope: .latestEpisodes, pageSize: 10)
    let reply = try WatchBrowseReply(request: request, status: .accepted, page: page)
    let data = try WatchWireCodec.encode(reply)
    let decoded = try WatchWireCodec.decode(WatchBrowseReply.self, from: data)
    #expect(decoded == reply)
    #expect(row.phonePlayable)
    #expect(!row.watchPlayable)
    #expect(String(decoding: data, as: UTF8.self).contains("http") == false)
    #expect(String(decoding: data, as: UTF8.self).contains("token") == false)
  }

  @Test("source qualified identities keep ABS and RSS shows distinct")
  func sourcesDoNotCollide() throws {
    let abs = try WatchBrowseShowRow(id: .audiobookshelf(itemID: "same"), title: "ABS")
    let rss = try WatchBrowseShowRow(id: .nativeFeed(feedID: "same"), title: "RSS")
    #expect(abs.id != rss.id)
    let absEpisode = try WatchBrowseEpisodeRow(
      selection: .audiobookshelf(itemID: "same", episodeID: "ep"), show: abs.id,
      showTitle: "ABS", title: "Episode", publishedAt: nil, durationSeconds: nil, isPlayed: false)
    let rssEpisode = try WatchBrowseEpisodeRow(
      selection: .nativeFeed(feedID: "same", episodeID: "ep"), show: rss.id,
      showTitle: "RSS", title: "Episode", publishedAt: nil, durationSeconds: nil, isPlayed: false)
    #expect(absEpisode.id != rssEpisode.id)
  }

  @Test("show rows carry an optional, bounded cover revision")
  func showRowsCarryArtworkRevision() throws {
    let row = try WatchBrowseShowRow(
      id: .audiobookshelf(itemID: "show"), title: "Show", artworkRevision: "1790000000123")
    let decoded = try JSONDecoder().decode(WatchBrowseShowRow.self, from: JSONEncoder().encode(row))
    #expect(decoded.artworkRevision == "1790000000123")
    #expect(try WatchBrowseShowRow(id: .audiobookshelf(itemID: "show"), title: "Show").artworkRevision == nil)
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchBrowseShowRow(id: .audiobookshelf(itemID: "show"), title: "Show", artworkRevision: "https://x/y")
    }
  }

  @Test("episode rows require a real episode identity and accept undated episodes")
  func episodeValidation() throws {
    #expect(throws: WatchProtocolCodingError.invalidSelection) {
      _ = try WatchBrowseEpisodeRow(
        selection: .audiobookshelf(itemID: "item", episodeID: nil), show: .audiobookshelf(itemID: "item"),
        showTitle: "Show", title: "Episode", publishedAt: nil, durationSeconds: nil, isPlayed: false)
    }
    _ = try WatchBrowseEpisodeRow(
      selection: .nativeFeed(feedID: "1", episodeID: "opaque:episode"), show: .nativeFeed(feedID: "1"),
      showTitle: "Show", title: "Episode", publishedAt: nil, durationSeconds: nil, isPlayed: false)
  }

  @Test("opaque ids containing separators remain distinct row identities")
  func opaqueIdentityComponentsDoNotCollide() throws {
    let first = try WatchBrowseEpisodeRow(
      selection: .audiobookshelf(itemID: "show", episodeID: "part:two"),
      show: .audiobookshelf(itemID: "show"), showTitle: "Show", title: "One",
      publishedAt: nil, durationSeconds: nil, isPlayed: false)
    let second = try WatchBrowseEpisodeRow(
      selection: .audiobookshelf(itemID: "show:part", episodeID: "two"),
      show: .audiobookshelf(itemID: "show:part"), showTitle: "Show", title: "Two",
      publishedAt: nil, durationSeconds: nil, isPlayed: false)
    #expect(first.id != second.id)
  }

  @Test("Watch capability is explicit and native episodes cannot claim it")
  func watchCapabilityIsSourceSafe() throws {
    #expect(throws: WatchProtocolCodingError.invalidSelection) {
      _ = try WatchBrowseEpisodeRow(
        selection: .nativeFeed(feedID: "1", episodeID: "episode"),
        show: .nativeFeed(feedID: "1"), showTitle: "Native", title: "Episode",
        publishedAt: nil, durationSeconds: nil, isPlayed: false, watchPlayable: true)
    }

    let serverRow = try WatchBrowseEpisodeRow(
      selection: .audiobookshelf(itemID: "item", episodeID: "episode"),
      show: .audiobookshelf(itemID: "item"), showTitle: "Server", title: "Episode",
      publishedAt: nil, durationSeconds: nil, isPlayed: false)
    let page = try WatchProtocolFixtures.browsePage(
      page: 0, pageSize: 1, rows: [.episode(serverRow)], nextPage: nil, isComplete: true, generation: 1)
    let request = try WatchBrowseRequest(accountStamp: stamp, scope: .latestEpisodes)
    let reply = try WatchBrowseReply(request: request, status: .accepted, page: page)
    var object = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(reply)) as? [String: Any])
    var pageObject = try #require(object["page"] as? [String: Any])
    var rows = try #require(pageObject["rows"] as? [[String: Any]])
    rows[0]["episode"] = try #require(rows[0]["episode"] as? [String: Any])
    var episodeObject = try #require(rows[0]["episode"] as? [String: Any])
    episodeObject.removeValue(forKey: "watchPlayable")
    rows[0]["episode"] = episodeObject
    pageObject["rows"] = rows
    object["page"] = pageObject
    let oldPayload = try JSONSerialization.data(withJSONObject: object)
    let decoded = try WatchWireCodec.decode(WatchBrowseReply.self, from: oldPayload)
    guard case .some(.episode(let decodedRow)) = decoded.page?.rows.first else {
      Issue.record("missing decoded episode row")
      return
    }
    #expect(decodedRow.watchPlayable == false)
    #expect(decodedRow.phonePlayable)
  }

  @Test("pages are bounded and error replies remain actionable")
  func boundsAndErrors() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      _ = try WatchBrowseRequest(accountStamp: stamp, scope: .shows, pageSize: WatchBrowseLimits.maxPageSize + 1)
    }
    let request = try WatchBrowseRequest(accountStamp: stamp, scope: .shows)
    let error = try WatchBrowseError(
      code: .phoneUnavailable, message: "Connect to the phone and try again.", retryable: true, retryAfterSeconds: 2)
    let reply = try WatchBrowseReply(request: request, status: .retryableError, error: error)
    #expect(reply.error?.actionableMessage == "Connect to the phone and try again.")
    #expect(try WatchWireCodec.encode(reply).count <= WatchBrowseLimits.maxWireBytes)
  }
}
