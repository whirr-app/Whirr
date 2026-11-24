import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// Assertions over `podcast-item-expanded-live.json`, a sanitized capture of a real
/// `GET /api/items/{id}?expanded=1&include=downloads` response from Audiobookshelf 2.35.1
/// (12 stored episodes). The synthetic `podcast-item-expanded` fixture carries zero values and
/// cannot pin the field shapes the podcast DTOs and columns are built on; these tests do.
///
/// Sanitization replaced every identifying string (ids, guids, titles, descriptions, filenames,
/// paths, URLs) and preserved types, key sets, element order and non-identifying magnitudes
/// (durations, sizes, bit rates, epoch timestamps, season/episode numbering). Inodes were remapped
/// consistently, so the `audioFile.ino` to `libraryFiles[].ino` correspondence is the server's.
@Suite("Podcast live fixture")
struct PodcastLiveFixtureTests {

  @Test("decodes every episode of the live expanded podcast fixture")
  func decodesLiveExpandedPodcast() async throws {
    let (client, _, account) = try makeLiveFixtureClient()

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_podcast_live")

    #expect(detail.mediaType == "podcast")
    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    #expect(podcast.title == "Sanitized Live Show")
    #expect(podcast.author == "Sanitized Publisher")
    // Nothing lossy-dropped: the raw payload carries 12 episodes and so does the decode.
    #expect(podcast.episodes.count == 12)

    let episode = try #require(podcast.episodes.first)
    #expect(episode.id == "episode_live_01")
    #expect(episode.title == "Sanitized Episode 01")
    #expect(episode.mimeType == "audio/mpeg")
    // Live durations are fractional seconds, not the synthetic fixture's integer zero.
    #expect(try #require(episode.duration) > 2657.0)
    #expect(try #require(episode.duration) < 2658.0)
    #expect(episode.publishedAt == Date(timeIntervalSince1970: 1_782_477_000))
    #expect(episode.contentUrl == "/api/items/item_podcast_live/file/1000001")
  }

  /// A stored episode's `audioFile.ino` is the `{fileid}` the authorized download route consumes
  /// (API-CONVENTIONS rule 24). Confirmed live on all 12 episodes: every one has a non-empty
  /// `ino` that matches a `libraryFiles` entry, and the server's own `audioTrack.contentUrl` is
  /// built from that inode.
  @Test("every episode exposes a stored-audio inode that matches a library file")
  func everyEpisodeHasAStoredAudioInode() throws {
    let object = try liveFixtureObject()
    let itemID = try #require(object["id"] as? String)
    let libraryFileInodes = Set(
      (object["libraryFiles"] as? [[String: Any]] ?? []).compactMap { $0["ino"] as? String }
    )
    let episodes = try #require(
      (object["media"] as? [String: Any])?["episodes"] as? [[String: Any]]
    )
    #expect(episodes.count == 12)

    for episode in episodes {
      let audioFile = try #require(episode["audioFile"] as? [String: Any])
      let inode = try #require(audioFile["ino"] as? String)
      #expect(inode.isEmpty == false)
      #expect(libraryFileInodes.contains(inode))

      let audioTrack = try #require(episode["audioTrack"] as? [String: Any])
      #expect(audioTrack["ino"] as? String == inode)
      #expect(audioTrack["contentUrl"] as? String == "/api/items/\(itemID)/file/\(inode)")
    }
  }

  /// Displayed read-only in place of a feed-check control. Both are present on the live expanded
  /// item.
  @Test("the expanded item carries the two show diagnostics the app displays")
  func carriesShowDiagnostics() throws {
    let media = try #require(try liveFixtureObject()["media"] as? [String: Any])

    #expect(media["autoDownloadEpisodes"] as? Bool != nil)
    // Epoch milliseconds, like every other ABS timestamp, not an ISO string.
    let lastEpisodeCheck = try #require(media["lastEpisodeCheck"] as? Double)
    #expect(lastEpisodeCheck > 1_000_000_000_000)
    // Observed alongside them; a cron expression, present even though v1 never writes it.
    #expect(media["autoDownloadSchedule"] as? String != nil)
  }

  /// Wire quirks the DTOs and columns have to absorb. Each would be an easy wrong guess from the
  /// synthetic fixture alone.
  @Test("records the live episode wire quirks decoding must tolerate")
  func recordsLiveEpisodeWireQuirks() throws {
    let episodes = try #require(
      (try liveFixtureObject()["media"] as? [String: Any])?["episodes"] as? [[String: Any]]
    )

    for episode in episodes {
      // Season/episode/type are strings, never numbers, and `season` is "" on an unseasoned
      // episode rather than null or absent.
      #expect(episode["season"] as? String != nil)
      #expect(episode["episode"] as? String != nil)
      #expect(episode["episodeType"] as? String == "full")
      // `index` is null on every stored episode; ordering cannot come from it.
      #expect(episode["index"] is NSNull)
      // Two publication stamps in different formats: RFC-2822 string and epoch milliseconds.
      #expect(episode["pubDate"] as? String != nil)
      #expect(episode["publishedAt"] as? Double != nil)
      // `enclosure.length` is the feed's advertised size as a string and reads "0" here; the
      // trustworthy byte count is the episode's own `size`.
      let enclosure = try #require(episode["enclosure"] as? [String: Any])
      #expect(enclosure["length"] as? String == "0")
      #expect(try #require(episode["size"] as? Double) > 0)
      // Descriptions are HTML; subtitle exists but can be empty.
      #expect(try #require(episode["description"] as? String).hasPrefix("<"))
      #expect(episode["subtitle"] as? String != nil)
    }

    // Seasoned and unseasoned episodes coexist in one show.
    let seasons = Set(episodes.compactMap { $0["season"] as? String })
    #expect(seasons.contains(""))
    #expect(seasons.contains("9"))

    // Episodes do NOT arrive newest-last: the array order is the server's, not a sort key.
    let publishedAt = episodes.compactMap { $0["publishedAt"] as? Double }
    #expect(publishedAt.count == episodes.count)
    #expect(publishedAt != publishedAt.sorted())
  }

  /// `include=downloads` yields `episodeDownloadsQueued` (empty here) and no `episodesDownloading`
  /// key at all, so a decoder that requires the latter would fail on a real idle server. Progress
  /// is likewise absent; it arrives via `include=progress&episode=` (rule 15).
  @Test("include=downloads omits episodesDownloading and progress entirely")
  func downloadsIncludeShape() throws {
    let object = try liveFixtureObject()

    let queued = try #require(object["episodeDownloadsQueued"] as? [Any])
    #expect(queued.isEmpty)
    #expect(object["episodesDownloading"] == nil)
    #expect(object["userMediaProgress"] == nil)
  }
}

private func liveFixtureObject() throws -> [String: Any] {
  try #require(
    JSONSerialization.jsonObject(with: try Fixtures.data(named: "podcast-item-expanded-live"))
      as? [String: Any]
  )
}

private func makeLiveFixtureClient() throws -> (
  client: ABSClient, http: FakeHTTPClient, account: TokenAccount
) {
  let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
  let account = try TokenAccount(server: server, userID: "user_fixture")
  let store = InMemoryTokenStore()
  try store.save(
    TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"),
    for: account
  )
  let http = FakeHTTPClient(
    responses: [
      HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: try Fixtures.data(named: "podcast-item-expanded-live")
      )
    ]
  )
  return (ABSClient(server: server, httpClient: http, tokenStore: store), http, account)
}
