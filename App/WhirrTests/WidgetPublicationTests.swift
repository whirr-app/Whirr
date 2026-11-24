import ABSApi
import AppModel
import CoreGraphics
import Foundation
import ImageIO
import Persistence
import SyncEngine
import TestSupport
import Testing
import UniformTypeIdentifiers
import WidgetProtocol

@testable import Whirr

@MainActor
@Suite("Widget publication", .serialized)
struct WidgetPublicationTests {
  // MARK: Token map

  @Test("the token map resolves its own tokens and only for its own account")
  func tokenMapRoundTrip() throws {
    let selection = CompanionSelection(
      source: try #require(PodcastSourceIdentity(itemId: "show-a")), episodeID: "episode-1")
    let map = WidgetTokenMap(stamp: Self.stamp("a"), salt: "salt", selections: ["token": selection])

    let decoded = try #require(WidgetTokenMap.decode(try map.encoded()))

    #expect(decoded == map)
    #expect(decoded.selection(for: "token") == selection)
    #expect(decoded.selection(for: "other") == nil)
    #expect(decoded.belongs(to: Self.stamp("a")))
    #expect(decoded.belongs(to: Self.stamp("c")) == false)
  }

  @Test("a token map of another version, or too large to be one, is not read")
  func tokenMapRejectsForeignFiles() throws {
    let map = WidgetTokenMap(stamp: Self.stamp("a"), salt: "salt", selections: [:])
    var object = try #require(
      try JSONSerialization.jsonObject(with: try map.encoded()) as? [String: Any])
    object["version"] = WidgetTokenMap.currentVersion + 1

    #expect(WidgetTokenMap.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
    #expect(WidgetTokenMap.decode(Data(count: WidgetTokenMap.maxEncodedBytes + 1)) == nil)
  }

  // MARK: File store

  @Test("the store writes under the container's widget folder and the private token folder")
  func fileStoreLayout() throws {
    let directory = try TemporaryDirectory()
    let store = WidgetFileStore.production(applicationSupportDirectory: directory.url)
    let container = try #require(store.containerURL)
    #expect(container.path.hasPrefix(directory.url.path))
    #expect(
      store.removalRootURLs == [
        WidgetStorageLayout.rootDirectory(inContainer: container), store.privateRootURL,
      ])

    let snapshot = WidgetSnapshot.signedOut(generatedAt: Date(timeIntervalSince1970: 1))
    try store.writeSnapshot(try WidgetSnapshotCodec.encode(snapshot))
    try store.writeTokenMap(WidgetTokenMap(stamp: Self.stamp("a"), salt: "s", selections: [:]))
    let keep = Self.coverName("1")
    let drop = Self.coverName("2")
    try store.writeCover(Data([1]), named: keep)
    try store.writeCover(Data([2]), named: drop)

    #expect(store.readSnapshot() == snapshot)
    #expect(store.readTokenMap()?.salt == "s")
    #expect(store.existingCoverNames() == [keep, drop])

    store.pruneCovers(keeping: [keep])
    #expect(store.existingCoverNames() == [keep])

    store.removeCoversAndTokenMap()
    #expect(store.existingCoverNames().isEmpty)
    #expect(store.readTokenMap() == nil)
    #expect(store.readSnapshot() == snapshot, "logout replaces the snapshot; it does not delete it")
  }

  @Test("with no App Group container nothing is written for the extension, but the map is kept")
  func fileStoreWithoutContainer() throws {
    let directory = try TemporaryDirectory()
    let store = WidgetFileStore(
      containerURL: nil, privateRootURL: directory.url.appendingPathComponent("WidgetTokens"),
      protect: { _ in })

    try store.writeSnapshot(Data([1]))
    try store.writeCover(Data([1]), named: Self.coverName("1"))
    try store.writeTokenMap(WidgetTokenMap(stamp: Self.stamp("a"), salt: "s", selections: [:]))

    #expect(store.readSnapshot() == nil)
    #expect(store.existingCoverNames().isEmpty)
    #expect(store.readTokenMap() != nil)
    #expect(store.removalRootURLs == [store.privateRootURL])
  }

  // MARK: Publisher

  @Test("a bookmark publishes one row, its token resolves, and its cover follows")
  func publisherPublishesTheBookmark() async throws {
    let harness = try PublisherHarness()
    let publisher = try harness.makePublisher()
    publisher.start()
    defer { publisher.stop() }
    harness.bookmarks.push(Self.bookmark("book-a"))

    #expect(
      await waitUntil("cover drawn") {
        harness.store.readSnapshot()?.nowPlaying != nil
          && harness.store.readSnapshot()?.continueListening.first?.coverFileName != nil
      })
    let snapshot = try #require(harness.store.readSnapshot())
    let row = try #require(snapshot.continueListening.first)
    #expect(row.title == "Bookmarked book-a")
    #expect(snapshot.nowPlaying?.token == row.token)
    #expect(snapshot.skipBackSeconds == 45, "the listener's own interval, from the injected defaults")
    #expect(harness.store.existingCoverNames() == [try #require(row.coverFileName)])
    #expect(harness.store.readTokenMap()?.selection(for: row.token)?.itemID == "book-a")
    // One reload for the row, one for its cover.
    #expect(harness.reloads.value == 2)
  }

  @Test("an unchanged shelf rewrites nothing and reloads no timeline")
  func publisherSkipsUnchangedContent() async throws {
    let harness = try PublisherHarness()
    let publisher = try harness.makePublisher()
    publisher.start()
    defer { publisher.stop() }
    harness.bookmarks.push(Self.bookmark("book-a"))
    #expect(
      await waitUntil("cover drawn") {
        harness.store.readSnapshot()?.continueListening.first?.coverFileName != nil
      })
    let reloads = harness.reloads.value

    harness.bookmarks.push(Self.bookmark("book-a"))
    publisher.refresh()
    await awaitQuiescence("republication settles", stableFor: 100) { "\(harness.reloads.value)" }

    #expect(harness.reloads.value == reloads)
  }

  @Test("a relaunch for the same account keeps its tokens; another account's are removed")
  func publisherReusesItsSaltPerAccount() async throws {
    let harness = try PublisherHarness()
    let first = try harness.makePublisher()
    first.start()
    harness.bookmarks.push(Self.bookmark("book-a"))
    #expect(await waitUntil("published") { harness.store.readSnapshot()?.nowPlaying?.token != nil })
    let token = try #require(harness.store.readSnapshot()?.nowPlaying?.token)
    first.stop()

    let relaunch = PublisherHarness(sharing: harness)
    let second = try relaunch.makePublisher()
    second.start()
    relaunch.bookmarks.push(Self.bookmark("book-a"))
    await awaitQuiescence("relaunch settles", stableFor: 100) {
      "\(harness.store.readTokenMap()?.salt ?? "")-\(harness.store.readSnapshot()?.nowPlaying?.token ?? "")"
    }
    #expect(harness.store.readSnapshot()?.nowPlaying?.token == token)
    second.stop()

    let other = PublisherHarness(sharing: harness)
    let third = try other.makePublisher(identity: Self.identity(id: 2))
    third.start()
    #expect(harness.store.readTokenMap() == nil, "the previous account's map is gone at once")
    other.bookmarks.push(Self.bookmark("book-a"))
    #expect(
      await waitUntil("other account published") {
        harness.store.readSnapshot()?.nowPlaying?.token.map { $0 != token } ?? false
      })
    third.stop()
  }

  @Test("stored stats publish at start and again when the stats model fetches newer ones")
  func publisherFollowsTheStoredStats() async throws {
    let harness = try PublisherHarness()
    let stats = StubListeningStats(Self.statsSnapshot(fetchedAt: 1_000, total: 3_600))
    let publisher = try harness.makePublisher(listeningStats: stats)
    publisher.start()
    defer { publisher.stop() }
    #expect(
      await waitUntil("stats published") { harness.store.readSnapshot()?.stats?.totalSeconds == 3_600 })

    let model = ListeningStatsModel(stats: stats)
    publisher.observeStats(model)
    stats.next = Self.statsSnapshot(fetchedAt: 2_000, total: 7_200)
    await model.refresh(trigger: .explicit)

    #expect(
      await waitUntil("newer stats published") {
        harness.store.readSnapshot()?.stats?.fetchedAt == Date(timeIntervalSince1970: 2_000)
      })
    #expect(harness.store.readSnapshot()?.stats?.totalSeconds == 7_200)
    #expect(stats.refreshes == 1, "the publisher itself never asks for a fetch")
  }

  // MARK: Runtime

  @Test("unbinding signs the widgets out once, removing covers and the token map")
  func runtimeUnbindSignsOut() throws {
    let directory = try TemporaryDirectory()
    let store = WidgetFileStore.production(applicationSupportDirectory: directory.url)
    let reloads = Counter()
    let runtime = WidgetRuntime(store: { _ in store }, reloadTimelines: { reloads.value += 1 })
    let snapshot = try WidgetSnapshot(
      generatedAt: Date(timeIntervalSince1970: 1), accountStamp: Self.stamp("a"), skipBackSeconds: 15)
    try store.writeSnapshot(try WidgetSnapshotCodec.encode(snapshot))
    try store.writeCover(Data([1]), named: Self.coverName("1"))
    try store.writeTokenMap(WidgetTokenMap(stamp: Self.stamp("a"), salt: "s", selections: [:]))

    runtime.unbind()

    #expect(store.readSnapshot()?.accountStamp == nil)
    #expect(store.existingCoverNames().isEmpty)
    #expect(store.readTokenMap() == nil)
    #expect(reloads.value == 1)
    #expect(runtime.selection(for: "anything") == nil)

    runtime.unbind()
    #expect(reloads.value == 1, "already signed out: nothing to redraw")
  }

  // MARK: Fixtures

  static func stamp(_ fill: Character) -> WidgetAccountStamp {
    try! WidgetAccountStamp(
      accountIdentityHash: String(repeating: fill, count: 64),
      serverIdentityHash: String(repeating: "b", count: 64))
  }

  static func coverName(_ fill: Character) -> String {
    String(repeating: fill, count: 32) + ".jpg"
  }

  nonisolated static func identity(id: Int64 = 1) -> AccountIdentity {
    AccountIdentity(id: id, clientUUID: "client-\(id)", serverIdentityFingerprint: "server")
  }

  static func bookmark(_ id: String) -> PlaybackBookmark {
    PlaybackBookmark(
      serverItemId: id, title: "Bookmarked \(id)", author: "Author", durationSeconds: 100,
      positionSeconds: 10, isFinished: false)
  }

  static func statsSnapshot(fetchedAt: TimeInterval, total: Double) -> ListeningStatsSnapshot {
    ListeningStatsSnapshot(
      fetchedAt: Date(timeIntervalSince1970: fetchedAt), totalSeconds: total, days: [],
      weekdaySeconds: [:], titles: [])
  }
}

/// The stored snapshot, replaced by `next` when a refresh is asked for.
private nonisolated final class StubListeningStats: ListeningStatsProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ListeningStatsSnapshot?
  private var pending: ListeningStatsSnapshot?
  private var refreshCount = 0

  init(_ stored: ListeningStatsSnapshot?) {
    self.stored = stored
  }

  var next: ListeningStatsSnapshot? {
    get { lock.withLock { pending } }
    set { lock.withLock { pending = newValue } }
  }

  var refreshes: Int { lock.withLock { refreshCount } }

  func cachedListeningStats() async -> ListeningStatsSnapshot? {
    lock.withLock { stored }
  }

  func refreshListeningStats(
    trigger: ListeningStatsRefreshTrigger, beforeFetch: @escaping @concurrent @Sendable () async -> Void
  ) async -> Bool {
    lock.withLock {
      refreshCount += 1
      if let pending { stored = pending }
      return true
    }
  }
}

@MainActor
private final class Counter {
  var value = 0
}

private final class TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WidgetPublicationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

@MainActor
private final class PublisherHarness {
  let directory: TemporaryDirectory
  let store: WidgetFileStore
  let reloads: Counter
  let defaults: UserDefaults
  let bookmarks = FakePlaybackBookmarkStoring()
  private let suite: String

  convenience init() throws {
    let directory = try TemporaryDirectory()
    let suite = "WidgetPublicationTests.publisher-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(45, forKey: SkipIntervalConfiguration.backwardStorageKey)
    self.init(directory: directory, defaults: defaults, suite: suite, reloads: Counter())
  }

  /// A second launch over the same files and preferences.
  convenience init(sharing other: PublisherHarness) {
    self.init(
      directory: other.directory, defaults: other.defaults, suite: other.suite,
      reloads: other.reloads)
  }

  private init(directory: TemporaryDirectory, defaults: UserDefaults, suite: String, reloads: Counter) {
    self.directory = directory
    self.defaults = defaults
    self.suite = suite
    self.reloads = reloads
    store = WidgetFileStore(
      containerURL: directory.url.appendingPathComponent("AppGroupContainer", isDirectory: true),
      privateRootURL: directory.url.appendingPathComponent("WidgetTokens", isDirectory: true),
      protect: { _ in })
  }

  func makePublisher(
    identity: AccountIdentity = WidgetPublicationTests.identity(),
    listeningStats: any ListeningStatsProviding = NoOpListeningStatsProviding()
  ) throws -> WidgetSnapshotPublisher {
    let reloads = reloads
    return try WidgetSnapshotPublisher(
      identity: identity, bookmarks: bookmarks,
      listeningStats: listeningStats, artwork: PNGArtwork(), store: store, defaults: defaults,
      reloadTimelines: { reloads.value += 1 })
  }

  deinit {
    bookmarks.finishObservations()
  }
}

/// Every cover is a small solid PNG, already cached.
struct PNGArtwork: ArtworkServing {
  var defaultSource: ArtworkSource? { .audiobookshelf(ArtworkAccountScope("widget-tests")) }

  func data(for key: ArtworkKey) async -> Data? { Self.png }
  func needsRefresh(_ key: ArtworkKey) async -> Bool { false }
  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    CoverImageResult(data: Self.png, contentType: "image/png")
  }

  static let png: Data = {
    let context = CGContext(
      data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
  }()
}
