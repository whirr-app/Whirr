import ABSApi
import AppModel
import Foundation
import Persistence
import TestSupport
import Testing
import UIKit
import WidgetProtocol

@testable import Whirr

@MainActor
@Suite("Smart list widget publication", .serialized)
struct WidgetSmartListPublicationTests {
  // MARK: Assembly

  @Test("the list file waits until every list has been read")
  func assemblyHoldsBackAnUnreadList() {
    var assembly = Self.assembly(lists: [(1, "One"), (2, "Two")], contents: [1: Self.content(["a"])])
    #expect(assembly.makePublication() == nil)

    assembly.contents[2] = WidgetSmartListContent(episodes: [], matchCount: 0)
    let publication = assembly.makePublication()
    #expect(publication?.lists.lists.map(\.id) == [1, 2])
    #expect(publication?.lists.lists.last?.items.isEmpty == true)
  }

  @Test("an episode in two lists has a token per list, distinct from its shelf token")
  func assemblyTokensNameTheirList() throws {
    let selection = CompanionSelection(
      source: try #require(PodcastSourceIdentity(itemId: "show-a")), episodeID: "episode-a")
    let assembly = Self.assembly(
      lists: [(1, "One"), (2, "Two")],
      contents: [1: Self.content(["a"]), 2: Self.content(["b", "a"], matchCount: 9)],
      loaded: selection, isPlaying: true)

    let publication = try #require(assembly.makePublication())
    let one = try #require(publication.lists.list(id: 1))
    let two = try #require(publication.lists.list(id: 2))
    let tokenInOne = try #require(one.items.first?.token)
    let tokenInTwo = try #require(two.items.last?.token)

    #expect(tokenInOne != tokenInTwo)
    #expect(tokenInOne != WidgetSnapshotAssembly.token(for: selection, salt: "salt"))
    #expect(publication.selections[tokenInOne] == .init(listID: 1, selection: selection))
    #expect(publication.selections[tokenInTwo] == .init(listID: 2, selection: selection))
    #expect(one.loadedToken == tokenInOne)
    #expect(two.loadedToken == tokenInTwo)
    #expect(publication.lists.isPlaying)
    #expect(two.matchCount == 9)
    #expect(one.matchCount == 1, "never fewer than the rows drawn")
  }

  @Test("covers are requested for every list within the budget, and drawn once exported")
  func assemblyCoversEveryListWithinBudget() throws {
    var assembly = Self.assembly(
      lists: [(1, "One"), (2, "Two")], contents: [1: Self.content(["a"]), 2: Self.content(["b"])])

    let first = try #require(assembly.makePublication())
    #expect(first.coverRequests.count == 2, "a list no widget is known to show still gets covers")
    #expect(first.lists.list(id: 1)?.items.first?.coverFileName == nil, "not exported yet")

    assembly.exportedCovers = Set(first.coverRequests.map(\.fileName))
    let second = try #require(assembly.makePublication())
    #expect(second.lists.list(id: 1)?.items.first?.coverFileName == first.coverRequests[0].fileName)
    #expect(second.lists.list(id: 2)?.items.first?.coverFileName == first.coverRequests[1].fileName)
  }

  @Test("shown lists take the cover budget first; lists past it draw without covers")
  func assemblyCoverBudgetFavoursShownLists() throws {
    var assembly = Self.assembly(
      lists: [(1, "One"), (2, "Two")], contents: [1: Self.content(["a"]), 2: Self.content(["b"])],
      shown: [2], coverBudget: 1)

    let first = try #require(assembly.makePublication())
    let request = try #require(first.coverRequests.first)
    #expect(first.coverRequests.count == 1)

    assembly.exportedCovers = [request.fileName]
    let second = try #require(assembly.makePublication())
    #expect(second.lists.list(id: 2)?.items.first?.coverFileName == request.fileName)
    #expect(second.lists.list(id: 1)?.items.first?.coverFileName == nil)
  }

  // MARK: Feed

  @Test("a configured list is observed live; every other list is read once, and again on foreground")
  func feedObservesShownListsAndReadsTheRest() async {
    let source = FakeSmartListSource()
    for id: Int64 in [1, 2, 3] { source.set(Self.content(["\(id)"]), for: id) }
    let center = NotificationCenter()
    let feed = WidgetSmartListFeed(
      source: source, configuredLists: { [2] }, notificationCenter: center, onChange: {})
    feed.start(nativeEnabled: true)
    defer { feed.stop() }
    source.yieldLists([(1, "One"), (2, "Two"), (3, "Three")])

    #expect(await waitUntil("every list read") { feed.contents.count == 3 && source.fetched.count == 2 })
    #expect(feed.shownListIDs == [2])
    #expect(source.observed == [2])
    #expect(Set(source.fetched) == [1, 3])

    source.set(Self.content(["2", "x"]), for: 2)
    #expect(await waitUntil("live update") { feed.contents[2]?.episodes.count == 2 })

    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    #expect(await waitUntil("re-read on foreground") { source.fetched.count == 4 })
    #expect(source.observed == [2], "the observed list is not read again")
  }

  @Test("an unconfigured widget shows the first list; a list never read draws as empty")
  func feedResolvesUnconfiguredWidgets() async {
    let source = FakeSmartListSource()
    source.set(Self.content(["a"]), for: 5)
    let feed = WidgetSmartListFeed(
      source: source, configuredLists: { [nil] }, notificationCenter: NotificationCenter(), onChange: {})
    feed.start(nativeEnabled: false)
    defer { feed.stop() }
    source.yieldLists([(5, "First"), (6, "Unreadable")])

    #expect(await waitUntil("both lists known") { feed.contents.count == 2 })
    #expect(feed.shownListIDs == [5])
    #expect(source.observed == [5])
    #expect(feed.contents[6] == WidgetSmartListContent(episodes: [], matchCount: nil))
  }

  @Test("switching native subscriptions drops every list's content at once and reads it all again")
  func feedRereadsEverythingWhenNativeSubscriptionsSwitch() async {
    let source = FakeSmartListSource()
    for id: Int64 in [1, 2] { source.set(Self.content(["\(id)"]), for: id) }
    let feed = WidgetSmartListFeed(
      source: source, configuredLists: { [1] }, notificationCenter: NotificationCenter(), onChange: {})
    feed.start(nativeEnabled: true)
    defer { feed.stop() }
    source.yieldLists([(1, "One"), (2, "Two")])
    #expect(await waitUntil("every list read") { feed.contents.count == 2 })

    feed.start(nativeEnabled: true)
    #expect(feed.contents.count == 2, "the same setting changes nothing")

    feed.start(nativeEnabled: false)
    // Synchronously empty: the list file is held back rather than drawn from the old shape.
    #expect(feed.contents.isEmpty)
    #expect(await waitUntil("every list read again") { feed.contents.count == 2 })
    #expect(source.observedCalls.last == .init(listID: 1, nativeEnabled: false))
    #expect(source.fetchedCalls.last == .init(listID: 2, nativeEnabled: false))
    #expect(await waitUntil("the old observation ended") { source.terminated == [1] })
  }

  @Test("a deleted list is forgotten, and a list no widget shows is no longer observed")
  func feedFollowsListAndConfigurationChanges() async {
    let source = FakeSmartListSource()
    for id: Int64 in [1, 2, 3] { source.set(Self.content(["\(id)"]), for: id) }
    let configured = ConfiguredLists([2])
    let center = NotificationCenter()
    let feed = WidgetSmartListFeed(
      source: source, configuredLists: { configured.value }, notificationCenter: center, onChange: {})
    feed.start(nativeEnabled: true)
    defer { feed.stop() }
    source.yieldLists([(1, "One"), (2, "Two"), (3, "Three")])
    #expect(await waitUntil("every list read") { feed.contents.count == 3 })

    configured.value = [3]
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    #expect(await waitUntil("reconfigured") { feed.shownListIDs == [3] })
    #expect(await waitUntil("old observation ended") { source.terminated == [2] })
    #expect(source.observed == [2, 3])

    source.yieldLists([(1, "One"), (2, "Two")])
    #expect(await waitUntil("deleted list forgotten") { feed.contents[3] == nil })
    #expect(await waitUntil("its observation ended") { source.terminated == [2, 3] })
    #expect(feed.shownListIDs.isEmpty, "a widget showing a deleted list shows nothing")
    #expect(feed.contents.keys.sorted() == [1, 2])
  }

  @Test("at most four lists are observed; a fifth configured list is read like the rest")
  func feedObservesAtMostFourLists() async {
    let source = FakeSmartListSource()
    for id: Int64 in 1...5 { source.set(Self.content(["\(id)"]), for: id) }
    let feed = WidgetSmartListFeed(
      source: source, configuredLists: { [1, 2, 3, 4, 5, 1] }, notificationCenter: NotificationCenter(),
      onChange: {})
    feed.start(nativeEnabled: true)
    defer { feed.stop() }
    source.yieldLists((1...5).map { ($0, "List \($0)") })

    #expect(await waitUntil("every list read") { feed.contents.count == 5 })
    #expect(feed.shownListIDs == [1, 2, 3, 4, 5])
    #expect(Set(source.observed) == [1, 2, 3, 4])
    #expect(source.fetched.contains(5))
  }

  @Test("a failed read keeps what the list had")
  func feedKeepsContentWhenAReadFails() async {
    let source = FakeSmartListSource()
    source.set(Self.content(["a"]), for: 1)
    let center = NotificationCenter()
    let feed = WidgetSmartListFeed(
      source: source, configuredLists: { [] }, notificationCenter: center, onChange: {})
    feed.start(nativeEnabled: true)
    defer { feed.stop() }
    source.yieldLists([(1, "One")])
    #expect(await waitUntil("read") { feed.contents[1] == Self.content(["a"]) })
    await awaitQuiescence("first reads settle", stableFor: 50) { "\(source.fetched.count)" }
    let reads = source.fetched.count

    source.failReads(for: 1)
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    #expect(await waitUntil("read again") { source.fetched.count > reads })
    await awaitQuiescence("feed settles", stableFor: 50) { "\(feed.contents)" }
    #expect(feed.contents[1] == Self.content(["a"]))
  }

  @Test("a stopped feed reads nothing more")
  func stoppedFeedIgnoresLifecycle() async {
    let source = FakeSmartListSource()
    source.set(Self.content(["a"]), for: 1)
    let center = NotificationCenter()
    let feed = WidgetSmartListFeed(
      source: source, configuredLists: { [] }, notificationCenter: center, onChange: {})
    feed.start(nativeEnabled: true)
    source.yieldLists([(1, "One")])
    #expect(await waitUntil("read") { feed.contents[1] != nil })
    await awaitQuiescence("first reads settle", stableFor: 50) { "\(source.fetched.count)" }
    let reads = source.fetched.count

    feed.stop()
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    feed.refresh()
    await awaitQuiescence("nothing read", stableFor: 50) { "\(source.fetched.count)" }
    #expect(source.fetched.count == reads)
  }

  // MARK: Publisher

  @Test("a relaunch keeps the drawn list rows resolvable and their covers until the lists are read")
  func relaunchKeepsTheDrawnListRows() async throws {
    let directory = try SmartListTemporaryDirectory()
    let store = directory.store
    let first = FakeSmartListSource()
    first.set(Self.content(["a"]), for: 7)
    first.set(Self.content(["b"]), for: 8)
    let publisher = try WidgetSnapshotPublisher(
      identity: WidgetPublicationTests.identity(), artwork: PNGArtwork(), store: store, smartLists: first,
      configuredSmartLists: { [7] }, notificationCenter: NotificationCenter(), reloadTimelines: {})
    publisher.start()
    first.yieldLists([(7, "Morning"), (8, "Evening")])
    #expect(
      await waitUntil("list cover drawn") {
        store.readSmartLists()?.list(id: 7)?.items.first?.coverFileName != nil
      })
    let drawn = try #require(store.readSmartLists()?.list(id: 7)?.items.first)
    let cover = try #require(drawn.coverFileName)
    #expect(
      await waitUntil("the unshown list's cover drawn too") {
        store.readSmartLists()?.list(id: 8)?.items.first?.coverFileName != nil
      })
    publisher.stop()

    // The relaunch's lists are never read, so the list file is held back throughout.
    let second = FakeSmartListSource()
    let bookmarks = FakePlaybackBookmarkStoring()
    defer { bookmarks.finishObservations() }
    let relaunch = try WidgetSnapshotPublisher(
      identity: WidgetPublicationTests.identity(), bookmarks: bookmarks,
      artwork: PNGArtwork(), store: store, smartLists: second, configuredSmartLists: { [7] },
      notificationCenter: NotificationCenter(), reloadTimelines: {})
    relaunch.start()
    defer { relaunch.stop() }
    second.yieldLists([(7, "Morning"), (8, "Evening")])
    bookmarks.push(WidgetPublicationTests.bookmark("book-a"))
    #expect(
      await waitUntil("shelf published with its cover") {
        store.readSnapshot()?.continueListening.first?.coverFileName != nil
      })

    #expect(store.readSmartLists()?.list(id: 7)?.items.first == drawn, "the list file is untouched")
    #expect(store.readTokenMap()?.listSelection(for: drawn.token)?.listID == 7)
    #expect(store.existingCoverNames().contains(cover))
    #expect(relaunch.publishedSmartListName(id: 7) == "Morning")
  }

  @Test("an unchanged list file is not rewritten; a changed one reloads timelines once")
  func publisherReloadsOncePerListChange() async throws {
    let directory = try SmartListTemporaryDirectory()
    let store = directory.store
    let source = FakeSmartListSource()
    source.set(Self.content(["a"]), for: 7)
    let reloads = ReloadCounter()
    let center = NotificationCenter()
    let publisher = try WidgetSnapshotPublisher(
      identity: WidgetPublicationTests.identity(), store: store, smartLists: source,
      configuredSmartLists: { [7] }, notificationCenter: center, reloadTimelines: { reloads.value += 1 })
    publisher.start()
    defer { publisher.stop() }
    source.yieldLists([(7, "Morning")])
    #expect(await waitUntil("list file written") { store.readSmartLists()?.lists.count == 1 })
    await awaitQuiescence("first publication settles", stableFor: 100) { "\(reloads.value)" }
    let settled = reloads.value

    source.set(Self.content(["a"]), for: 7)
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    await awaitQuiescence("unchanged republication settles", stableFor: 100) { "\(reloads.value)" }
    #expect(reloads.value == settled)

    source.set(Self.content(["a", "b"]), for: 7)
    #expect(await waitUntil("change written") { store.readSmartLists()?.lists.first?.items.count == 2 })
    await awaitQuiescence("change settles", stableFor: 100) { "\(reloads.value)" }
    #expect(reloads.value == settled + 1)
  }

  @Test("the publisher writes the list file, and its row tokens resolve to their list")
  func publisherWritesTheListFile() async throws {
    let directory = try SmartListTemporaryDirectory()
    let store = directory.store
    let source = FakeSmartListSource()
    source.set(Self.content(["a"]), for: 7)
    let publisher = try WidgetSnapshotPublisher(
      identity: WidgetPublicationTests.identity(), store: store, smartLists: source,
      configuredSmartLists: { [7] }, notificationCenter: NotificationCenter(), reloadTimelines: {})
    publisher.start()
    defer { publisher.stop() }
    source.yieldLists([(7, "Morning")])

    #expect(await waitUntil("list file written") { store.readSmartLists()?.lists.first?.items.count == 1 })
    let file = try #require(store.readSmartLists())
    let token = try #require(file.lists.first?.items.first?.token)
    let map = try #require(store.readTokenMap())
    #expect(file.accountStamp == store.readSnapshot()?.accountStamp)
    #expect(map.listSelection(for: token)?.listID == 7)
    #expect(map.listSelection(for: token)?.selection.episodeID == "episode-a")
    #expect(map.selection(for: token) == nil, "a list row is not a shelf row")
    #expect(publisher.publishedSmartListName(id: 7) == "Morning")
    #expect(publisher.publishedSmartListName(id: 8) == nil)
  }

  @Test("signing out removes the list file with the covers and token map")
  func logoutRemovesTheListFile() throws {
    let directory = try SmartListTemporaryDirectory()
    let store = directory.store
    let lists = try WidgetSmartLists(
      generatedAt: Date(timeIntervalSince1970: 1), accountStamp: WidgetPublicationTests.stamp("a"),
      isPlaying: false, lists: [WidgetSmartList(id: 1, name: "One", matchCount: 0, items: [])])
    try store.writeSmartLists(try WidgetSmartListsCodec.encode(lists))
    #expect(store.readSmartLists() == lists)

    store.removeCoversAndTokenMap()

    #expect(store.readSmartLists() == nil)
  }

  // MARK: Token map

  @Test("a list entry resolves only as a list row, and a shelf entry only as a shelf row")
  func tokenMapKeepsListAndShelfEntriesApart() throws {
    let selection = CompanionSelection(
      source: try #require(PodcastSourceIdentity(itemId: "show-a")), episodeID: "episode-1")
    let map = WidgetTokenMap(
      stamp: WidgetPublicationTests.stamp("a"), salt: "salt", selections: ["shelf": selection],
      listSelections: ["row": .init(listID: 3, selection: selection)])

    let decoded = try #require(WidgetTokenMap.decode(try map.encoded()))

    #expect(decoded == map)
    #expect(decoded.selection(for: "shelf") == selection)
    #expect(decoded.listSelection(for: "shelf") == nil)
    #expect(decoded.listSelection(for: "row") == .init(listID: 3, selection: selection))
    #expect(decoded.selection(for: "row") == nil)
  }

  // MARK: Fixtures

  static func episode(_ suffix: String) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: "show-\(suffix)", showTitle: "Show \(suffix)", showAuthor: nil, episodeID: "episode-\(suffix)",
      title: "Episode \(suffix)", subtitle: nil, publishedAt: Date(timeIntervalSince1970: 1),
      durationSeconds: 600)
  }

  static func content(_ suffixes: [String], matchCount: Int? = nil) -> WidgetSmartListContent {
    WidgetSmartListContent(
      episodes: suffixes.map { .init(episode: episode($0), isDownloaded: false) },
      matchCount: matchCount ?? suffixes.count)
  }

  static func assembly(
    lists: [(Int64, String)], contents: [Int64: WidgetSmartListContent], shown: Set<Int64> = [],
    loaded: CompanionSelection? = nil, isPlaying: Bool = false,
    coverBudget: Int = WidgetStorageLayout.maxCoverFiles
  ) -> WidgetSmartListAssembly {
    WidgetSmartListAssembly(
      accountStamp: WidgetPublicationTests.stamp("a"), tokenSalt: "salt",
      lists: lists.map { WidgetSmartListName(id: $0.0, name: $0.1) }, contents: contents,
      shownListIDs: shown, loaded: loaded, isPlaying: isPlaying, generatedAt: Date(timeIntervalSince1970: 1),
      absArtworkSource: .audiobookshelf(ArtworkAccountScope("widget-tests")), coverPixelWidth: 120,
      coverBudget: coverBudget, exportedCovers: [])
  }
}

/// Lists and content set by the test. Observing a list yields its current content and every later
/// `set`; a read returns the current content, or `nil` (a failed read) for a list never set.
private nonisolated final class FakeSmartListSource: WidgetSmartListSource, @unchecked Sendable {
  struct Call: Equatable {
    let listID: Int64
    let nativeEnabled: Bool
  }

  private let lock = NSLock()
  private let listStream: AsyncStream<[WidgetSmartListName]>
  private let listContinuation: AsyncStream<[WidgetSmartListName]>.Continuation
  private var stored: [Int64: WidgetSmartListContent] = [:]
  private var failing: Set<Int64> = []
  private var continuations: [Int64: AsyncStream<WidgetSmartListContent>.Continuation] = [:]
  private var observedLog: [Call] = []
  private var fetchedLog: [Call] = []
  private var terminatedLog: [Int64] = []

  init() {
    (listStream, listContinuation) = AsyncStream.makeStream()
  }

  deinit {
    listContinuation.finish()
  }

  var observed: [Int64] { observedCalls.map(\.listID) }
  var fetched: [Int64] { fetchedCalls.map(\.listID) }
  var observedCalls: [Call] { lock.withLock { observedLog } }
  var fetchedCalls: [Call] { lock.withLock { fetchedLog } }
  /// Lists whose observation ended, in order.
  var terminated: [Int64] { lock.withLock { terminatedLog } }

  func yieldLists(_ lists: [(Int64, String)]) {
    listContinuation.yield(lists.map { WidgetSmartListName(id: $0.0, name: $0.1) })
  }

  func set(_ content: WidgetSmartListContent, for listID: Int64) {
    lock.withLock {
      stored[listID] = content
      failing.remove(listID)
      _ = continuations[listID]?.yield(content)
    }
  }

  /// Later reads of the list fail; its observation is unaffected.
  func failReads(for listID: Int64) {
    lock.withLock { _ = failing.insert(listID) }
  }

  func observeLists() -> AsyncStream<[WidgetSmartListName]> { listStream }

  func observeContent(listID: Int64, nativeEnabled: Bool) -> AsyncStream<WidgetSmartListContent> {
    let (stream, continuation) = AsyncStream.makeStream(of: WidgetSmartListContent.self)
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      self.lock.withLock { self.terminatedLog.append(listID) }
    }
    lock.withLock {
      observedLog.append(Call(listID: listID, nativeEnabled: nativeEnabled))
      continuations[listID] = continuation
      if let content = stored[listID] { continuation.yield(content) }
    }
    return stream
  }

  func fetchContent(listID: Int64, nativeEnabled: Bool) async -> WidgetSmartListContent? {
    lock.withLock {
      fetchedLog.append(Call(listID: listID, nativeEnabled: nativeEnabled))
      return failing.contains(listID) ? nil : stored[listID]
    }
  }
}

/// The lists placed widgets show, changed by the test between reads.
private nonisolated final class ConfiguredLists: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Int64?]

  init(_ value: [Int64?]) {
    stored = value
  }

  var value: [Int64?] {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

@MainActor
private final class ReloadCounter {
  var value = 0
}

private final class SmartListTemporaryDirectory {
  let url: URL
  let store: WidgetFileStore

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WidgetSmartListPublicationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    store = WidgetFileStore(
      containerURL: url.appendingPathComponent("AppGroupContainer", isDirectory: true),
      privateRootURL: url.appendingPathComponent("WidgetTokens", isDirectory: true), protect: { _ in })
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
