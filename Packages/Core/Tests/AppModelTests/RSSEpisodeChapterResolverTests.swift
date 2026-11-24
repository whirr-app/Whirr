import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

/// Fake loader shared with the playback coordinator tests.
actor EmbeddedChapterLoaderSpy: EmbeddedChapterLoading {
  enum Outcome: Sendable {
    case chapters([EmbeddedChapter])
    case failure
    case cancellation
  }

  private let outcome: Outcome
  private(set) var requestedURLs: [URL] = []

  init(_ outcome: Outcome) {
    self.outcome = outcome
  }

  init(chapters: [EmbeddedChapter]) {
    self.outcome = .chapters(chapters)
  }

  var callCount: Int { requestedURLs.count }

  func loadChapters(from localFileURL: URL) async throws -> [EmbeddedChapter] {
    requestedURLs.append(localFileURL)
    switch outcome {
    case .chapters(let chapters): return chapters
    case .failure: throw EmbeddedChapterLoaderSpyError.unreadable
    case .cancellation: throw CancellationError()
    }
  }
}

enum EmbeddedChapterLoaderSpyError: Error { case unreadable }

/// Parks every load until it is cancelled, recording that it saw the cancellation.
actor CancellableChapterLoader: EmbeddedChapterLoading {
  private nonisolated let starts = TestCountRecorder(label: "CancellableChapterLoader loads")
  private(set) var sawCancellation = false

  func waitUntilStarted() async {
    await starts.waitUntil(count: 1)
  }

  func loadChapters(from _: URL) async throws -> [EmbeddedChapter] {
    starts.record()
    do {
      try await Task.sleep(for: .seconds(600))
    } catch {
      sawCancellation = true
      throw CancellationError()
    }
    return []
  }
}

@Suite(.timeLimit(.minutes(1))) struct RSSEpisodeChapterResolverTests {
  private static let fileURL = URL(fileURLWithPath: "/tmp/episode.mp3")

  private static let chapters = [
    EmbeddedChapter(start: 0, end: 30, title: "Intro"),
    EmbeddedChapter(start: 30, end: 90, title: "Main"),
  ]

  private static func makeEpisode(complete: Bool = true) async throws -> (
    AppDatabase, RSSEpisodeChapterStore, Int64
  ) {
    let database = try AppDatabase.inMemory()
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/feed.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "episode", enclosureURL: URL(string: "https://example.com/a.mp3")!)
      ])
    let episodeID = try #require(
      try await database.readAsync { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM rssEpisode LIMIT 1")
      })
    if complete {
      let downloads = try RSSDownloadStore(database: database)
      let row = try await downloads.claimOrCreateAsync(episodeId: episodeID)
      _ = try await downloads.transitionAsync(downloadId: try #require(row.id), to: .downloading)
      _ = try await downloads.completeAsync(downloadId: try #require(row.id), actualBytes: 10)
    }
    return (database, RSSEpisodeChapterStore(database: database), episodeID)
  }

  @Test func chaptersAreLoadedOnceAndServedFromTheCacheAfterwards() async throws {
    let (_, store, episodeID) = try await Self.makeEpisode()
    let loader = EmbeddedChapterLoaderSpy(chapters: Self.chapters)
    let resolver = RSSEpisodeChapterResolver(chapterStore: store, loader: loader)

    #expect(try await resolver.resolve(episodeId: episodeID, localFileURL: Self.fileURL) == Self.chapters)
    #expect(try await resolver.resolve(episodeId: episodeID, localFileURL: Self.fileURL) == Self.chapters)
    #expect(await loader.callCount == 1)
    #expect(await loader.requestedURLs == [Self.fileURL])
  }

  @Test func aFileWithoutChaptersIsNotParsedAgain() async throws {
    let (_, store, episodeID) = try await Self.makeEpisode()
    let loader = EmbeddedChapterLoaderSpy(chapters: [])
    let resolver = RSSEpisodeChapterResolver(chapterStore: store, loader: loader)

    #expect(try await resolver.resolve(episodeId: episodeID, localFileURL: Self.fileURL).isEmpty)
    #expect(try await resolver.resolve(episodeId: episodeID, localFileURL: Self.fileURL).isEmpty)
    #expect(await loader.callCount == 1)
  }

  @Test func aLoaderErrorYieldsNoChaptersAndIsRetriedNextTime() async throws {
    let (_, store, episodeID) = try await Self.makeEpisode()
    let loader = EmbeddedChapterLoaderSpy(.failure)
    let resolver = RSSEpisodeChapterResolver(chapterStore: store, loader: loader)

    #expect(try await resolver.resolve(episodeId: episodeID, localFileURL: Self.fileURL).isEmpty)
    #expect(try await resolver.resolve(episodeId: episodeID, localFileURL: Self.fileURL).isEmpty)
    #expect(await loader.callCount == 2)
    #expect(try await store.cache(episodeId: episodeID)?.chapters == nil)
  }

  @Test func cancellationPropagates() async throws {
    let (_, store, episodeID) = try await Self.makeEpisode()
    let resolver = RSSEpisodeChapterResolver(
      chapterStore: store, loader: EmbeddedChapterLoaderSpy(.cancellation))

    await #expect(throws: CancellationError.self) {
      try await resolver.resolve(episodeId: episodeID, localFileURL: Self.fileURL)
    }
  }

  @Test func withoutACompletedDownloadNothingIsParsed() async throws {
    let (_, store, episodeID) = try await Self.makeEpisode(complete: false)
    let loader = EmbeddedChapterLoaderSpy(chapters: Self.chapters)
    let resolver = RSSEpisodeChapterResolver(chapterStore: store, loader: loader)

    #expect(try await resolver.resolve(episodeId: episodeID, localFileURL: Self.fileURL).isEmpty)
    #expect(await loader.callCount == 0)
  }

  @Test func unusableRangesAreDroppedAndTheRestOrdered() async throws {
    let (_, store, episodeID) = try await Self.makeEpisode()
    let loader = EmbeddedChapterLoaderSpy(
      chapters: [
        EmbeddedChapter(start: 60, end: 90, title: "  Second "),
        EmbeddedChapter(start: 0, end: 60, title: "  "),
        EmbeddedChapter(start: .nan, end: 10, title: "NaN"),
        EmbeddedChapter(start: 5, end: 5, title: "Empty"),
        EmbeddedChapter(start: -1, end: 5, title: "Negative"),
        EmbeddedChapter(start: 90, end: .infinity, title: "Open"),
      ])
    let resolver = RSSEpisodeChapterResolver(chapterStore: store, loader: loader)

    let resolved = try await resolver.resolve(episodeId: episodeID, localFileURL: Self.fileURL)

    #expect(
      resolved == [
        EmbeddedChapter(start: 0, end: 60, title: nil),
        EmbeddedChapter(start: 60, end: 90, title: "Second"),
      ])
  }

  @Test func concurrentCallsShareOneParse() async throws {
    let (_, store, episodeID) = try await Self.makeEpisode()
    let loader = EmbeddedChapterLoaderSpy(chapters: Self.chapters)
    let resolver = RSSEpisodeChapterResolver(chapterStore: store, loader: loader)

    let calls = (0..<8).map { _ in
      Task { try await resolver.resolve(episodeId: episodeID, localFileURL: Self.fileURL) }
    }
    for call in calls {
      #expect(try await call.value == Self.chapters)
    }
    #expect(await loader.callCount == 1)
  }

  @Test func cancellingTheOnlyCallerCancelsTheParse() async throws {
    let (_, store, episodeID) = try await Self.makeEpisode()
    let loader = CancellableChapterLoader()
    let resolver = RSSEpisodeChapterResolver(chapterStore: store, loader: loader)

    let call = Task { try await resolver.resolve(episodeId: episodeID, localFileURL: Self.fileURL) }
    await loader.waitUntilStarted()
    call.cancel()

    await #expect(throws: CancellationError.self) { try await call.value }
    #expect(await loader.sawCancellation)
    #expect(try await store.cache(episodeId: episodeID)?.chapters == nil)
  }
}
