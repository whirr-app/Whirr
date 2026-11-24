import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LibraryCollectionsBrowseModelTests {
  @Test func listsSplitIntoSectionsAndHideListsWithNothingHeld() async {
    let reading = ScriptedCollectionReading()
    let model = LibraryCollectionsBrowseModel(reading: reading, fill: { _ in })
    reading.yieldListings([
      listing("col", kind: .collection, held: 2),
      listing("empty", kind: .collection, held: 0),
      listing("pl", kind: .playlist, held: 1),
    ])

    await waitUntil { model.state == .loaded }
    #expect(model.collections.map(\.id.serverID) == ["col"])
    #expect(model.playlists.map(\.id.serverID) == ["pl"])
    #expect(model.collections.map(\.showsLibraryName) == [false])
  }

  @Test func aPinnedListsRowSaysSo() async {
    let reading = ScriptedCollectionReading()
    let pins = FakePinnedListDownloads()
    let model = LibraryCollectionsBrowseModel(reading: reading, fill: { _ in }, pins: pins)
    reading.yieldListings([
      listing("col", kind: .collection, held: 2), listing("pl", kind: .playlist, held: 1),
    ])
    await waitUntil { model.state == .loaded }
    #expect((model.collections + model.playlists).map(\.isPinned) == [false, false])

    pins.keys.yield([model.playlists[0].id])
    await waitUntil { model.playlists.first?.isPinned == true }
    #expect(model.collections.map(\.isPinned) == [false])
  }

  @Test func libraryNameShowsWhenListsComeFromMoreThanOneLibrary() async {
    let reading = ScriptedCollectionReading()
    let model = LibraryCollectionsBrowseModel(reading: reading, fill: { _ in })
    reading.yieldListings([
      listing("a", kind: .collection, held: 1, library: "books"),
      listing("b", kind: .playlist, held: 1, library: "pods"),
    ])

    await waitUntil { model.state == .loaded }
    let rows = model.collections + model.playlists
    #expect(rows.map(\.showsLibraryName) == [true, true])
  }

  @Test func coldCacheStaysLoadingUntilTheFirstFillLandsThenReportsEmpty() async {
    let reading = ScriptedCollectionReading()
    let fill = FillRecorder()
    let model = LibraryCollectionsBrowseModel(reading: reading, fill: { await fill.run($0) })
    reading.yieldListings([])
    await waitUntil { await fill.calls == [false] }
    #expect(model.state == .loading)

    await fill.release()
    await waitUntil { model.state == .empty }
  }

  @Test func refreshForcesAPass() async {
    let reading = ScriptedCollectionReading()
    let fill = FillRecorder(isOpen: true)
    let model = LibraryCollectionsBrowseModel(reading: reading, fill: { await fill.run($0) })

    await model.refresh()

    await waitUntil { await Set(fill.calls) == [false, true] }
  }

  @Test func categoryFilterShowsAListWhenOneHeldMemberMatchesAndOtherFiltersAreInert() async {
    let reading = ScriptedCollectionReading()
    let model = LibraryCollectionsBrowseModel(reading: reading, fill: { _ in })
    reading.yieldListings([
      listing("books", kind: .collection, held: 1, categories: [.audiobook]),
      listing("mixed", kind: .playlist, held: 2, categories: [.audiobook, .podcast]),
    ])
    await waitUntil { model.state == .loaded }

    model.updateFilters(BrowseFilters(categories: [.podcast]))
    #expect(model.collections.isEmpty)
    #expect(model.playlists.map(\.id.serverID) == ["mixed"])

    model.updateFilters(BrowseFilters(categories: [.ebook]))
    #expect(model.state == .filteredEmpty)

    model.updateFilters(BrowseFilters(downloadedOnly: true, playback: .finished))
    #expect(model.collections.count == 1)
    #expect(model.playlists.count == 1)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LibraryCollectionModelTests {
  @Test func entriesFollowTheStoredOrderAndARemovedListBecomesUnavailable() async {
    let reading = ScriptedCollectionReading()
    let model = makeModel(reading: reading)
    #expect(model.state == .loading)

    reading.yieldContents([title("b"), episode("show", "ep"), title("a")])
    await waitUntil { model.state == .loaded }
    #expect(model.entries.map(\.id) == ["b", "show/ep", "a"])

    reading.yieldContents([title("a")], name: "Renamed")
    await waitUntil { model.listing?.name == "Renamed" }
    #expect(model.entries.map(\.id) == ["a"])

    reading.yieldContents(nil)
    await waitUntil { model.state == .unavailable }
    #expect(model.entries.isEmpty)
    #expect(model.listing?.name == "Renamed")
  }

  @Test func aStoredListWithNothingHeldIsEmpty() async {
    let reading = ScriptedCollectionReading()
    let model = makeModel(reading: reading)
    reading.yieldContents([])
    await waitUntil { model.state == .empty }
  }

  @Test func targetsSkipFinishedAndAudiolessEntries() async {
    let reading = ScriptedCollectionReading()
    let model = makeModel(reading: reading)
    reading.yieldContents([
      title("done", finished: true),
      title("ebook", category: .ebook),
      title("book"),
      episode("show", "finished-ep", finished: true),
      episode("show", "ep"),
    ])
    await waitUntil { model.state == .loaded }

    #expect(model.playableEntries.map(\.id) == ["book", "show/ep"])
    #expect(
      model.upNextTargets.map { [$0.itemID, $0.episodeID ?? "-"] } == [["book", "-"], ["show", "ep"]])
  }

  @Test func playStartsTheFirstTargetAndPutsTheRestInFrontInOrder() async throws {
    let reading = ScriptedCollectionReading()
    let queue = FakeListeningQueueStoring()
    var started: [String] = []
    let model = makeModel(reading: reading, queue: queue) { itemID, episodeID, _ in
      started.append([itemID, episodeID].compactMap { $0 }.joined(separator: "/"))
      return true
    }
    reading.yieldContents([
      title("done", finished: true), title("first"), episode("show", "ep"), title("last"),
    ])
    await waitUntil { model.state == .loaded }

    #expect(await model.play())

    #expect(started == ["first"])
    let expected = try [
      #require(ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "ep")),
      #require(ListeningIdentity.audiobook(itemID: "last")),
    ]
    #expect(queue.batches == [expected])
  }

  @Test func aFailedStartLeavesUpNextUntouched() async {
    let reading = ScriptedCollectionReading()
    let queue = FakeListeningQueueStoring()
    let model = makeModel(reading: reading, queue: queue) { _, _, _ in false }
    reading.yieldContents([title("first"), title("second")])
    await waitUntil { model.state == .loaded }

    #expect(await model.play() == false)

    #expect(queue.batches.isEmpty)
  }

  @Test func playingASingleTargetQueuesNothing() async {
    let reading = ScriptedCollectionReading()
    let queue = FakeListeningQueueStoring()
    let model = makeModel(reading: reading, queue: queue) { _, _, _ in true }
    reading.yieldContents([title("only")])
    await waitUntil { model.state == .loaded }

    #expect(await model.play())
    #expect(queue.batches.isEmpty)
  }

  @Test func whenEverythingIsFinishedPlayReplaysTheFirstEntryFromTheStartAndQueuesNothing() async {
    let reading = ScriptedCollectionReading()
    let queue = FakeListeningQueueStoring()
    var started: [String] = []
    let model = makeModel(reading: reading, queue: queue) { itemID, _, fromStart in
      started.append("\(itemID) fromStart=\(fromStart)")
      return true
    }
    reading.yieldContents([
      title("ebook", finished: true, category: .ebook), title("first", finished: true),
      title("second", finished: true),
    ])
    await waitUntil { model.state == .loaded }

    #expect(model.canPlay)
    #expect(model.upNextTargets.isEmpty)
    #expect(await model.play())

    #expect(started == ["first fromStart=true"])
    #expect(queue.batches.isEmpty)
  }

  @Test func anUnfinishedEntryPlaysFromItsSavedPosition() async {
    let reading = ScriptedCollectionReading()
    var fromStarts: [Bool] = []
    let model = makeModel(reading: reading) { _, _, fromStart in
      fromStarts.append(fromStart)
      return true
    }
    reading.yieldContents([title("done", finished: true), title("next")])
    await waitUntil { model.state == .loaded }

    #expect(await model.play())
    #expect(fromStarts == [false])
  }

  @Test func nothingWithAudioCannotPlay() async {
    let reading = ScriptedCollectionReading()
    let model = makeModel(reading: reading)
    reading.yieldContents([title("ebook", category: .ebook)])
    await waitUntil { model.state == .loaded }

    #expect(model.canPlay == false)
    #expect(await model.play() == false)
  }

  private func makeModel(
    reading: ScriptedCollectionReading,
    queue: FakeListeningQueueStoring = FakeListeningQueueStoring(),
    start: @escaping @MainActor (String, String?, Bool) async -> Bool = { _, _, _ in true }
  ) -> LibraryCollectionModel {
    LibraryCollectionModel(
      key: collectionKey, reading: reading, queue: queue, startPlayback: start)
  }
}

// MARK: - Fixtures

private let collectionKey = LibraryCollectionKey(
  serverLibraryID: "books", kind: .playlist, serverID: "list")

private func listing(
  _ serverID: String,
  kind: LibraryCollectionListKind,
  held: Int,
  library: String = "books",
  categories: Set<ItemMediaCategory> = [.audiobook],
  name: String? = nil
) -> LibraryCollectionListing {
  LibraryCollectionListing(
    key: LibraryCollectionKey(serverLibraryID: library, kind: kind, serverID: serverID),
    libraryName: library, name: name ?? serverID, description: nil, lastUpdate: nil,
    heldMemberCount: held, heldCategories: held > 0 ? categories : [])
}

private func title(
  _ id: String, finished: Bool = false, category: ItemMediaCategory = .audiobook
) -> LibraryCollectionEntry {
  .title(
    ItemSummary(
      serverItemId: id, mediaKind: "book", title: id, author: nil, durationSeconds: 60,
      category: category),
    isFinished: finished)
}

private func episode(_ show: String, _ id: String, finished: Bool = false) -> LibraryCollectionEntry {
  .episode(
    HomePodcastEpisode(
      itemID: show, showTitle: show, showAuthor: nil, episodeID: id, title: id, subtitle: nil,
      publishedAt: .distantPast, durationSeconds: 30, isFinished: finished))
}

private final class ScriptedCollectionReading: LibraryCollectionReading, @unchecked Sendable {
  private let listings = AsyncStream<[LibraryCollectionListing]>.makeStream()
  private let contents = AsyncStream<LibraryCollectionContents?>.makeStream()

  func observeListings() -> AsyncStream<[LibraryCollectionListing]> { listings.stream }

  func observeContents(key: LibraryCollectionKey) -> AsyncStream<LibraryCollectionContents?> {
    contents.stream
  }

  func yieldListings(_ value: [LibraryCollectionListing]) { listings.continuation.yield(value) }

  func yieldContents(_ entries: [LibraryCollectionEntry]?, name: String = "List") {
    guard let entries else {
      contents.continuation.yield(nil)
      return
    }
    contents.continuation.yield(
      LibraryCollectionContents(
        listing: LibraryCollectionListing(
          key: collectionKey, libraryName: "Books", name: name, description: nil,
          lastUpdate: nil, heldMemberCount: entries.count),
        entries: entries))
  }
}

private actor FillRecorder {
  private(set) var calls: [Bool] = []
  // A parked fill stays parked through task cancellation until `release()`.
  private nonisolated let gate = TestGate<Void>(
    label: "FillRecorder fill", ignoresCancellation: true)

  init(isOpen: Bool = false) {
    if isOpen == false { gate.hold() }
  }

  func run(_ force: Bool) async {
    calls.append(force)
    await gate.pass()
  }

  func release() {
    gate.release()
  }
}
