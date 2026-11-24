import Foundation
import TestSupport
import Testing

@testable import Persistence

@Suite(.timeLimit(.minutes(1))) struct RSSDownloadsReadingTests {
  @Test func projectsFeedArtworkURLIntoDownloadedFeed() async throws {
    let artworkURL = try #require(URL(string: "https://images.example.test/show.jpg"))
    let database = try AppDatabase.inMemory()
    _ = try await Self.seedDownloadedFeed(database: database, artworkURL: artworkURL)

    var iterator = DefaultRSSDownloadsReading(database: database)
      .observeRSSDownloads()
      .makeAsyncIterator()
    let feeds = try #require(await iterator.next())

    #expect(feeds.count == 1)
    #expect(feeds[0].artworkURL == artworkURL)
  }

  @Test func projectsNullArtworkURLWithoutDroppingDownloadedFeed() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.seedDownloadedFeed(database: database, artworkURL: nil)

    var iterator = DefaultRSSDownloadsReading(database: database)
      .observeRSSDownloads()
      .makeAsyncIterator()
    let feeds = try #require(await iterator.next())

    #expect(feeds.map(\.id) == [feedID])
    #expect(feeds[0].artworkURL == nil)
    #expect(feeds[0].episodes.count == 1)
  }

  @Test("in-flight byte writes inside one quantum are suppressed; completed rows keep exact bytes")
  func inFlightByteWritesInsideOneQuantumAreSuppressed() async throws {
    let database = try AppDatabase.inMemory()
    _ = try await Self.seedDownloadedFeed(database: database, artworkURL: nil)
    let downloadStore = try RSSDownloadStore(database: database)
    let record = try #require(try downloadStore.fetchAll().first)
    let downloadID = try #require(record.id)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssDownload SET state = 'downloading', expectedBytes = 1000, actualBytes = 0 WHERE id = ?",
        arguments: [downloadID])
    }
    let observations = PersistenceObservationCollector(
      DefaultRSSDownloadsReading(database: database).observeRSSDownloads())

    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    #expect(observations.values.first?.first?.episodes.first?.actualBytes == 0)
    let initialCount = observations.values.count

    // Inside the first 2% bucket: nothing may be emitted for these.
    _ = try await downloadStore.updateProgressAsync(downloadId: downloadID, actualBytes: 1)
    _ = try await downloadStore.updateProgressAsync(downloadId: downloadID, actualBytes: 19)
    // Crossing into the second bucket floors to the bucket's byte count.
    _ = try await downloadStore.updateProgressAsync(downloadId: downloadID, actualBytes: 47)
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.first?.episodes.first?.actualBytes == 40 }
      })
    #expect(observations.values.count == initialCount + 1)

    // Completion reports the exact byte count, not a floored one.
    _ = try await downloadStore.completeAsync(downloadId: downloadID, actualBytes: 999)
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.first?.episodes.first?.actualBytes == 999 }
      })
    #expect(observations.values.last?.first?.episodes.first?.state == .completed)
  }

  @Test("the completed-only stream drops in-flight rows and emits nothing for their progress")
  func completedOnlyStreamIgnoresInFlightProgress() async throws {
    let source = AsyncStream<[RSSDownloadedFeed]>.makeStream()
    let observations = PersistenceObservationCollector(
      StreamRSSDownloadsReading(stream: source.stream).observeCompletedRSSDownloads())
    let finished = Self.episode(id: "finished", state: .completed, actualBytes: 900)

    source.continuation.yield([Self.feed(id: 1, [Self.episode(id: "new", state: .downloading, actualBytes: 0)])])
    // Each step below is a distinct value of the full projection, as a 2% progress step is.
    for bytes: Int64 in [20, 40, 60] {
      source.continuation.yield([
        Self.feed(id: 1, [Self.episode(id: "new", state: .downloading, actualBytes: bytes)])
      ])
    }
    source.continuation.yield([
      Self.feed(id: 1, [Self.episode(id: "new", state: .downloading, actualBytes: 80), finished])
    ])
    source.continuation.yield([
      Self.feed(id: 1, [Self.episode(id: "new", state: .downloading, actualBytes: 100), finished])
    ])
    source.continuation.yield([
      Self.feed(id: 1, [Self.episode(id: "new", state: .completed, actualBytes: 1000), finished])
    ])
    source.continuation.finish()

    let completedFeeds = [
      Self.feed(id: 1, [Self.episode(id: "new", state: .completed, actualBytes: 1000), finished])
    ]
    // Stream order is preserved, so the last value arriving means every earlier one was handled.
    // The stream is latest-only, so a slow consumer may miss an earlier set; none may repeat.
    #expect(await TestSupport.waitUntil { observations.values.last == completedFeeds })
    #expect(observations.values.allSatisfy { $0.allSatisfy { $0.episodes.allSatisfy { $0.state == .completed } } })
    #expect(zip(observations.values, observations.values.dropFirst()).allSatisfy { $0 != $1 })
    // Seven source values, but only three distinct completed sets: empty, one, then two episodes.
    #expect(observations.values.count <= 3)
  }

  private static func feed(id: Int64, _ episodes: [RSSDownloadedEpisode]) -> RSSDownloadedFeed {
    RSSDownloadedFeed(
      id: id, title: "Feed \(id)", sourceURL: URL(string: "https://feeds.example.test/\(id).xml")!,
      episodes: episodes)
  }

  private static func episode(id: String, state: DownloadState, actualBytes: Int64) -> RSSDownloadedEpisode {
    RSSDownloadedEpisode(
      id: id, title: id, state: state, actualBytes: actualBytes, expectedBytes: 1000, holdReason: nil)
  }

  private static func seedDownloadedFeed(
    database: AppDatabase, artworkURL: URL?
  ) async throws -> Int64 {
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://feeds.example.test/show.xml")!,
      title: "The Feed",
      author: "Host",
      synopsis: nil,
      artworkURL: artworkURL,
      subscribedAt: Date())
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "episode-1",
          title: "Episode One",
          enclosureURL: URL(string: "https://media.example.test/episode.mp3")!,
          enclosureType: "audio/mpeg",
          declaredBytes: 123)
      ])
    let episode = try #require(
      await RSSEpisodeStore(database: database).fetchEpisode(
        feedId: feedID, identityKey: "episode-1"))
    let downloadStore = try RSSDownloadStore(database: database)
    _ = try await downloadStore.claimOrCreateAsync(episodeId: try #require(episode.id))
    return feedID
  }
}

private struct StreamRSSDownloadsReading: RSSDownloadsReading {
  let stream: AsyncStream<[RSSDownloadedFeed]>
  func observeRSSDownloads() -> AsyncStream<[RSSDownloadedFeed]> { stream }
}
