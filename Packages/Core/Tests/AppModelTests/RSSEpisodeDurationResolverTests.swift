import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

@Suite struct RSSEpisodeDurationResolverTests {
  @Test func usableDeclaredDurationShortCircuitsLoader() async throws {
    let (database, episodeID) = try await Self.makeEpisode(duration: 42)
    let loader = FakeEnclosureDurationLoading(result: 99)
    let resolver = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: database), loader: loader)

    let duration = try await resolver.resolve(episodeId: episodeID)

    #expect(duration == 42)
    #expect(loader.callCount == 0)
  }

  @Test func everyUnusableDeclaredDurationFallsThroughToLoader() async throws {
    for declaredDuration in [Double?.none, 0, -1, Double.infinity, Double.nan] {
      let (database, episodeID) = try await Self.makeEpisode(duration: declaredDuration)
      let loader = FakeEnclosureDurationLoading(result: 99)
      let resolver = RSSEpisodeDurationResolver(
        episodeStore: RSSEpisodeStore(database: database), loader: loader)

      let duration = try await resolver.resolve(episodeId: episodeID)

      #expect(duration == 99)
      #expect(loader.callCount == 1)
    }
  }

  @Test func measuredDurationIsReusedOnTheSecondCall() async throws {
    let (database, episodeID) = try await Self.makeEpisode(duration: nil)
    let loader = FakeEnclosureDurationLoading(result: 123.5)
    let resolver = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: database), loader: loader)

    #expect(try await resolver.resolve(episodeId: episodeID) == 123.5)
    #expect(try await resolver.resolve(episodeId: episodeID) == 123.5)
    #expect(loader.callCount == 1)
    #expect(
      try await RSSEpisodeStore(database: database).fetchEpisode(episodeId: episodeID)?
        .measuredDurationSeconds == 123.5)
  }

  @Test func nilAndUnusableLoaderResultsReturnNilWithoutWriting() async throws {
    for result in [Double?.none, 0, -1, Double.infinity, Double.nan] {
      let (database, episodeID) = try await Self.makeEpisode(duration: nil)
      let loader = FakeEnclosureDurationLoading(result: result)
      let resolver = RSSEpisodeDurationResolver(
        episodeStore: RSSEpisodeStore(database: database), loader: loader)

      #expect(try await resolver.resolve(episodeId: episodeID) == nil)
      #expect(loader.callCount == 1)
      #expect(
        try await RSSEpisodeStore(database: database).fetchEpisode(episodeId: episodeID)?
          .measuredDurationSeconds == nil)
    }
  }

  @Test func cancellationFromLoaderPropagates() async throws {
    let (database, episodeID) = try await Self.makeEpisode(duration: nil)
    let resolver = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: database),
      loader: FakeEnclosureDurationLoading(failure: CancellationError()))

    await #expect(throws: CancellationError.self) {
      try await resolver.resolve(episodeId: episodeID)
    }
  }

  @Test func concurrentCallsForOneEpisodeShareOneMeasurement() async throws {
    let (database, episodeID) = try await Self.makeEpisode(duration: nil)
    let (loader, gate) = Self.blockingLoader(result: 77)
    let resolver = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: database), loader: loader)

    let first = Task { try await resolver.resolve(episodeId: episodeID) }
    await loader.recorder.waitUntil(count: 1)
    let second = Task { try await resolver.resolve(episodeId: episodeID) }
    gate.release()

    #expect(try await first.value == 77)
    #expect(try await second.value == 77)
    #expect(loader.callCount == 1)
  }

  /// Every caller exists before any of them is allowed into `resolve`, unlike the two-call test
  /// above (whose second caller arrives after the loader is already held). This
  /// exercises the pre-flight database suspension: actor reentrancy may admit all of these reads,
  /// but each resumed actor turn must observe the one map entry installed by the first turn.
  @Test func callersReleasedBeforeAnyFlightExistsStillShareOneMeasurement() async throws {
    let (database, episodeID) = try await Self.makeEpisode(duration: nil)
    let (loader, gate) = Self.blockingLoader(result: 77)
    let resolver = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: database), loader: loader)
    let callerCount = 16
    let startGate = TestGate<Void>(label: "duration resolver callers")
    startGate.hold()
    let calls = (0..<callerCount).map { _ in
      Task {
        await startGate.pass()
        return try await resolver.resolve(episodeId: episodeID)
      }
    }
    await startGate.waitUntilParked(count: callerCount)

    startGate.release()
    await loader.recorder.waitUntil(count: 1)
    gate.release()
    var values: [Double?] = []
    for call in calls {
      values.append(try await call.value)
    }

    #expect(values == Array(repeating: 77, count: callerCount))
    #expect(loader.callCount == 1)
  }

  @Test("a local measurement does not join an earlier remote measurement")
  func localMeasurementDoesNotJoinAnEarlierRemoteMeasurement() async throws {
    let (database, episodeID) = try await Self.makeEpisode(duration: nil)
    let (loader, gate) = Self.blockingLoader(result: 77)
    let resolver = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: database), loader: loader)

    let remote = Task { try await resolver.resolve(episodeId: episodeID) }
    await loader.recorder.waitUntil(count: 1)
    let local = Task {
      try await resolver.resolve(
        episodeId: episodeID, localFileURL: URL(fileURLWithPath: "/tmp/local-episode.m4a"))
    }

    #expect(await loader.recorder.waitUntil(count: 2, timeout: 1).isObserved)
    gate.release()
    #expect(try await remote.value == 77)
    #expect(try await local.value == 88)
    #expect(loader.callCount == 2)
  }

  @Test("the measured local file wins over the feed-declared duration")
  func localFileMeasurementBeatsDeclaredDuration() async throws {
    let (database, episodeID) = try await Self.makeEpisode(duration: 120)
    let loader = FakeEnclosureDurationLoading(result: 95)
    let store = RSSEpisodeStore(database: database)
    let resolver = RSSEpisodeDurationResolver(episodeStore: store, loader: loader)

    let duration = try await resolver.resolve(
      episodeId: episodeID, localFileURL: URL(fileURLWithPath: "/tmp/dai.m4a"))

    #expect(duration == 95)
    // The enclosure-describing column is never replaced by a download's length.
    #expect(try await store.fetchEpisode(episodeId: episodeID)?.measuredDurationSeconds == nil)
  }

  @Test("a local file is measured once until it is replaced")
  func localFileMeasurementIsReusedUntilTheFileChanges() async throws {
    let (database, episodeID) = try await Self.makeEpisode(duration: 120)
    let loader = FakeEnclosureDurationLoading(result: 95)
    let resolver = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: database), loader: loader)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(UUID().uuidString).mp3")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data([1, 2, 3]).write(to: file)

    #expect(try await resolver.resolve(episodeId: episodeID, localFileURL: file) == 95)
    #expect(try await resolver.resolve(episodeId: episodeID, localFileURL: file) == 95)
    #expect(loader.callCount == 1)

    try Data([1, 2, 3, 4]).write(to: file)
    #expect(try await resolver.resolve(episodeId: episodeID, localFileURL: file) == 95)
    #expect(loader.callCount == 2)
  }

  @Test("an unmeasurable local file falls back to the declared and then cached duration")
  func unmeasurableLocalFileFallsBack() async throws {
    let local = URL(fileURLWithPath: "/tmp/broken.m4a")
    let (declaredDB, declaredID) = try await Self.makeEpisode(duration: 120)
    let declared = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: declaredDB), loader: FakeEnclosureDurationLoading(result: nil))
    #expect(try await declared.resolve(episodeId: declaredID, localFileURL: local) == 120)

    let (cachedDB, cachedID) = try await Self.makeEpisode(duration: nil)
    let cachedStore = RSSEpisodeStore(database: cachedDB)
    try await cachedStore.recordMeasuredDuration(episodeId: cachedID, seconds: 61)
    let cached = RSSEpisodeDurationResolver(
      episodeStore: cachedStore, loader: FakeEnclosureDurationLoading(failure: URLError(.cannotOpenFile)))
    #expect(try await cached.resolve(episodeId: cachedID, localFileURL: local) == 61)

    let (emptyDB, emptyID) = try await Self.makeEpisode(duration: nil)
    let empty = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: emptyDB), loader: FakeEnclosureDurationLoading(result: nil))
    #expect(try await empty.resolve(episodeId: emptyID, localFileURL: local) == nil)
  }

  @Test("a download's first measurement is stored on its download row")
  func localMeasurementIsStoredOnTheDownloadRow() async throws {
    let (database, episodeID) = try await Self.makeEpisode(duration: 120)
    try await Self.completeDownload(database, episodeID: episodeID)
    let downloadDurations = RSSDownloadDurationStore(database: database)
    let resolver = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: database),
      downloadDurationStore: downloadDurations, loader: FakeEnclosureDurationLoading(result: 95))

    #expect(
      try await resolver.resolve(
        episodeId: episodeID, localFileURL: URL(fileURLWithPath: "/tmp/dai.m4a")) == 95)

    #expect(try await downloadDurations.measuredDuration(episodeId: episodeID)?.seconds == 95)
    #expect(
      try await RSSEpisodeStore(database: database).fetchEpisode(episodeId: episodeID)?
        .measuredDurationSeconds == nil)
  }

  @Test("a stored download length is used in a later session without opening the file")
  func storedDownloadLengthSkipsTheLoader() async throws {
    let (database, episodeID) = try await Self.makeEpisode(duration: 120)
    try await Self.completeDownload(database, episodeID: episodeID)
    let downloadDurations = RSSDownloadDurationStore(database: database)
    let observed = try #require(try await downloadDurations.measuredDuration(episodeId: episodeID))
    try await downloadDurations.recordMeasuredDuration(
      episodeId: episodeID, observed: observed, seconds: 95)
    let loader = FakeEnclosureDurationLoading(result: 80)
    let resolver = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: database),
      downloadDurationStore: downloadDurations, loader: loader)

    #expect(
      try await resolver.resolve(
        episodeId: episodeID, localFileURL: URL(fileURLWithPath: "/tmp/dai.m4a")) == 95)
    #expect(loader.callCount == 0)
  }

  @Test("streaming never touches the download row")
  func streamingLeavesTheDownloadRowAlone() async throws {
    let (database, episodeID) = try await Self.makeEpisode(duration: nil)
    try await Self.completeDownload(database, episodeID: episodeID)
    let downloadDurations = RSSDownloadDurationStore(database: database)
    let resolver = RSSEpisodeDurationResolver(
      episodeStore: RSSEpisodeStore(database: database),
      downloadDurationStore: downloadDurations, loader: FakeEnclosureDurationLoading(result: 95))

    #expect(try await resolver.resolve(episodeId: episodeID) == 95)

    #expect(try await downloadDurations.measuredDuration(episodeId: episodeID)?.seconds == nil)
  }

  @Test func differentEpisodesCanLoadWhileAnotherEpisodeIsBlocked() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/two-episodes.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let episodeStore = RSSEpisodeStore(database: database)
    _ = try await episodeStore.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(identityKey: "one", enclosureURL: Self.episodeURL),
        RSSEpisodeUpsert(
          identityKey: "two", enclosureURL: URL(string: "https://example.com/two.mp3")!),
      ])
    let episodeIDs = try await database.readAsync { db in
      try Int64.fetchAll(db, sql: "SELECT id FROM rssEpisode ORDER BY id")
    }
    let (loader, gate) = Self.blockingLoader(result: 77)
    let resolver = RSSEpisodeDurationResolver(episodeStore: episodeStore, loader: loader)

    let first = Task { try await resolver.resolve(episodeId: episodeIDs[0]) }
    await loader.recorder.waitUntil(count: 1)
    let second = Task { try await resolver.resolve(episodeId: episodeIDs[1]) }

    // The proof is observable at the loader: a resolver that queued episodes behind one another
    // would never issue this second call while the first is blocked. Waiting for the call itself,
    // rather than racing a one-second wall clock, keeps the verdict independent of machine load.
    await loader.recorder.waitUntil(count: 2)
    #expect(try await second.value == 88)
    gate.release()
    #expect(try await first.value == 77)
  }

  private static let episodeURL = URL(string: "https://example.com/episode.mp3")!

  /// A loader that parks the remote enclosure's load until the returned gate is released, and
  /// answers every other URL at once with 88.
  private static func blockingLoader(
    result: Double
  ) -> (loader: FakeEnclosureDurationLoading, gate: TestGate<Void>) {
    let gate = TestGate<Void>(label: "blocked enclosure load")
    gate.hold()
    let blockedURL = episodeURL
    let loader = FakeEnclosureDurationLoading { url in
      guard url == blockedURL else { return 88 }
      await gate.pass()
      return result
    }
    return (loader, gate)
  }

  private static func completeDownload(_ database: AppDatabase, episodeID: Int64) async throws {
    let downloads = try RSSDownloadStore(database: database)
    let downloadID = try #require(
      try await downloads.claimOrCreateAsync(
        episodeId: episodeID, relativePath: "rss/episode.mp3", expectedBytes: 10
      ).id)
    _ = try await downloads.transitionAsync(downloadId: downloadID, to: .downloading)
    _ = try await downloads.completeAsync(downloadId: downloadID, actualBytes: 10)
  }

  private static func makeEpisode(duration: Double?) async throws -> (AppDatabase, Int64) {
    let database = try AppDatabase.inMemory()
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/feed-" + UUID().uuidString + ".xml")!, title: nil,
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let store = RSSEpisodeStore(database: database)
    _ = try await store.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "episode", enclosureURL: Self.episodeURL, durationSeconds: duration)
      ])
    let episodeID = try #require(
      try await database.readAsync { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM rssEpisode WHERE feedId = ?", arguments: [feedID])
      })
    return (database, episodeID)
  }
}
