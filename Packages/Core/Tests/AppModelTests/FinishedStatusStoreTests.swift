import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

/// One `LibraryReading.observeItemPlaybackStatuses` subscription serves every row and detail
/// screen that needs a progress glyph, as in `DownloadStatusStore`, rather than a per-row
/// observation.
@MainActor
@Suite struct FinishedStatusStoreTests {

  @Test func constructionOpensExactlyOneSubscriptionRegardlessOfHowManyItemsAreRead() {
    let library = FakeLibraryReading()
    let store = FinishedStatusStore(library: library)

    for index in 0..<50 {
      _ = store.isFinished("item-\(index)")
      _ = store.playbackStatus("item-\(index)")
    }

    #expect(library.itemPlaybackStatusSubscriptionCount == 1)
    #expect(library.episodePlaybackStatusSubscriptionCount == 1)
  }

  @Test func anItemAbsentFromTheProjectionIsNotFinished() async {
    let library = FakeLibraryReading()
    let store = FinishedStatusStore(library: library)
    library.pushItemPlaybackStatuses(["item-1": .finished])
    await waitUntil { store.isFinished("item-1") }

    #expect(store.isFinished("item-2") == false)
  }

  @Test func aLaterEmissionReplacesTheWholeProjection() async {
    let library = FakeLibraryReading()
    let store = FinishedStatusStore(library: library)
    library.pushItemPlaybackStatuses(["item-1": .finished, "item-2": .inProgress])
    await waitUntil { store.playbackStatus("item-2") == .inProgress }

    #expect(store.playbackStatus("item-2") == .inProgress)

    // Resetting an item's progress drops its id from the set rather than emitting anything for
    // it, so the store must adopt each emission wholesale instead of merging into the last.
    library.pushItemPlaybackStatuses(["item-1": .finished])
    await waitUntil { store.isFinished("item-2") == false }

    #expect(store.isFinished("item-1"))
  }

  @Test func inProgressAndFinishedRemainDistinct() async {
    let library = FakeLibraryReading()
    let store = FinishedStatusStore(library: library)
    library.pushItemPlaybackStatuses([
      "audio": .inProgress,
      "ebook": .inProgress,
      "done": .finished,
    ])
    await waitUntil { store.playbackStatus("ebook") == .inProgress }

    #expect(store.isFinished("audio") == false)
    #expect(store.isFinished("done"))
    #expect(store.playbackStatus("done") == .finished)
  }

  /// An episode's status is its own row's, never its show's. Reading the show's would make every
  /// episode of a finished show offer Reset and none offer Mark as Finished.
  @Test func anEpisodeReadsItsOwnStatusNotItsShows() async throws {
    let library = FakeLibraryReading()
    let store = FinishedStatusStore(library: library)
    let episode = try #require(ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "ep-1"))
    library.pushItemPlaybackStatuses(["show": .finished])
    library.pushEpisodePlaybackStatuses([episode: .inProgress])
    await waitUntil { store.playbackStatus(itemID: "show", episodeID: "ep-1") == .inProgress }

    #expect(store.playbackStatus(itemID: "show", episodeID: nil) == .finished)
    #expect(store.playbackStatus(itemID: "show", episodeID: "ep-2") == nil)
    #expect(store.playbackStatus("show") == .finished)
  }

  @Test func aLaterEpisodeEmissionReplacesTheWholeEpisodeProjection() async throws {
    let library = FakeLibraryReading()
    let store = FinishedStatusStore(library: library)
    let first = try #require(ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "ep-1"))
    let second = try #require(ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "ep-2"))
    library.pushEpisodePlaybackStatuses([first: .finished, second: .inProgress])
    await waitUntil { store.playbackStatus(itemID: "show", episodeID: "ep-2") == .inProgress }

    library.pushEpisodePlaybackStatuses([first: .finished])
    await waitUntil { store.playbackStatus(itemID: "show", episodeID: "ep-2") == nil }

    #expect(store.playbackStatus(itemID: "show", episodeID: "ep-1") == .finished)
  }

  @Test func storeDeinitializesWhileItsObservationStreamRemainsAlive() async {
    let library = FakeLibraryReading()
    weak var observer: FinishedStatusStore?
    var store: FinishedStatusStore?

    do {
      store = FinishedStatusStore(library: library)
      observer = store
      library.pushItemPlaybackStatuses(["item-1": .finished])
      #expect(await waitUntil { store?.isFinished("item-1") == true })
      store = nil
    }

    #expect(await waitUntil { observer == nil })
  }
}
