import Foundation
import Observation
import Persistence
import TestSupport
import Testing

@testable import AppModel

/// One `DownloadReading.observeItemDownloadPresence` subscription serves a whole screen's rows,
/// instead of two GRDB `ValueObservation`s per visible row re-running on every write to
/// `item`/`download`.
@MainActor
@Suite struct DownloadStatusStoreTests {

  @Test func constructionOpensExactlyOneSubscriptionRegardlessOfHowManyItemsAreRead() {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)

    for index in 0..<50 {
      _ = store.presence(for: "item-\(index)")
      _ = store.isDownloaded("item-\(index)")
    }

    #expect(reading.presenceSubscriptionCount == 1)
  }

  @Test func anItemAbsentFromTheProjectionIsNotDownloaded() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    reading.pushPresence(["item-1": .completed])
    await waitUntil { store.presence(for: "item-1") == .completed }

    #expect(store.presence(for: "item-2") == .none)
    #expect(store.isDownloaded("item-2") == false)
  }

  @Test func isDownloadedIsTrueOnlyForCompleted() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    reading.pushPresence([
      "done": .completed, "partial": .partial, "going": .deleting,
    ])
    await waitUntil { store.presence(for: "done") == .completed }

    #expect(store.isDownloaded("done"))
    #expect(store.isDownloaded("partial") == false)
    #expect(store.isDownloaded("going") == false)
  }

  @Test func aLaterEmissionReplacesTheWholeProjection() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    reading.pushPresence(["item-1": .completed, "item-2": .partial])
    await waitUntil { store.presence(for: "item-2") == .partial }

    // A removal drops the key entirely rather than emitting `.none` for it, so the store must
    // adopt the new map wholesale instead of merging into the old one.
    reading.pushPresence(["item-1": .completed])
    await waitUntil { store.presence(for: "item-2") == ItemDownloadPresence.none }

    #expect(store.presence(for: "item-1") == .completed)
  }

  @Test func episodePresenceIsReadByTheFullShowEpisodeIdentity() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    reading.pushEpisodePresence([
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-1"): .completed,
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-2"): .deleting,
    ])
    await waitUntil { store.presence(for: "show-1", episodeID: "ep-1") == .completed }

    #expect(store.downloadAction(for: "show-1", episodeID: "ep-1") == .remove)
    #expect(store.downloadAction(for: "show-1", episodeID: "ep-2") == .unavailable)
    // An absent episode, and the show itself, are both untouched by the episode projection.
    #expect(store.downloadAction(for: "show-1", episodeID: "ep-3") == .download)
    #expect(store.presence(for: "show-1") == ItemDownloadPresence.none)
  }

  @Test func downloadedPodcastItemIDsComeFromEpisodePresence() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    reading.pushEpisodePresence([
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-1"): .partial,
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-2"): .deleting,
      EpisodeDownloadKey(itemID: "show-2", episodeID: "ep-3"): .completed,
    ])

    await waitUntil {
      store.downloadedPodcastItemIDs == Set(["show-1", "show-2"])
    }

    #expect(store.downloadedPodcastItemIDs == Set(["show-1", "show-2"]))
  }

  @Test func byteProgressDoesNotChangeDownloadedPodcastMembership() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    let firstEpisode = EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-1")
    let secondEpisode = EpisodeDownloadKey(itemID: "show-2", episodeID: "ep-2")
    reading.pushEpisodePresence([
      firstEpisode: .partial,
      secondEpisode: .completed,
    ])
    await waitUntil {
      store.downloadedPodcastItemIDs == Set(["show-1", "show-2"])
    }

    let membershipChanges = ObservationChangeFlag()
    withObservationTracking {
      _ = store.downloadedPodcastItemIDs
    } onChange: {
      membershipChanges.mark()
    }

    let publishedMembership = store.downloadedPodcastItemIDs
    reading.pushEpisodePresence([
      firstEpisode: .completed,
      secondEpisode: .deleting,
    ])
    await waitUntil { store.presence(for: "show-1", episodeID: "ep-1") == .completed }

    #expect(membershipChanges.didChange == false)
    #expect(store.downloadedPodcastItemIDs == publishedMembership)
  }

  @Test func episodePresenceOpensExactlyOneSubscription() {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)

    for index in 0..<50 {
      _ = store.presence(for: "show-1", episodeID: "ep-\(index)")
    }

    #expect(reading.episodePresenceSubscriptionCount == 1)
  }

  @Test("no provisional status exists before the first presence emission")
  func provisionalStatusIsUnavailableUntilPresenceResolves() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)

    #expect(store.hasResolvedPresence == false)
    #expect(store.provisionalStatus(for: "item-1") == nil)

    reading.pushPresence(["item-1": .completed])
    await waitUntil { store.hasResolvedPresence }

    #expect(store.provisionalStatus(for: "item-1") == .completed)
  }

  @Test("a resolved projection answers for absent items too")
  func provisionalStatusMapsEveryPresenceOntoADetailStatus() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    reading.pushPresence(["done": .completed, "partial": .partial, "going": .deleting])
    await waitUntil { store.hasResolvedPresence }

    #expect(store.provisionalStatus(for: "done") == .completed)
    #expect(store.provisionalStatus(for: "going") == .deleting)
    // `.partial` collapses seven detailed states, so it seeds the one that promises least: the
    // remove affordance is right for all of them and `.queued` draws no progress arc.
    #expect(store.provisionalStatus(for: "partial") == .queued)
    #expect(store.provisionalStatus(for: "absent") == .notDownloaded)
  }

  @Test("an empty projection still counts as resolved")
  func anEmptyFirstEmissionResolvesTheProjection() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    reading.pushPresence([:])

    #expect(await waitUntil { store.hasResolvedPresence })
    #expect(store.provisionalStatus(for: "item-1") == .notDownloaded)
  }

  @Test func downloadActionMapsPresenceToTheRowAffordance() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    reading.pushPresence(["done": .completed, "partial": .partial, "going": .deleting])
    await waitUntil { store.presence(for: "done") == .completed }

    #expect(store.downloadAction(for: "absent") == .download)
    #expect(store.downloadAction(for: "done") == .remove)
    #expect(store.downloadAction(for: "partial") == .remove)
    #expect(store.downloadAction(for: "going") == .unavailable)
  }

  @Test func storeDeinitializesWhileItsObservationStreamsRemainAlive() async {
    let reading = FakeDownloadReading()
    weak var observer: DownloadStatusStore?
    var store: DownloadStatusStore?

    do {
      store = DownloadStatusStore(downloadReading: reading)
      observer = store
      reading.pushPresence(["item-1": .completed])
      #expect(await waitUntil { store?.hasResolvedPresence == true })
      store = nil
    }

    #expect(await waitUntil { observer == nil })
  }
}

private final class ObservationChangeFlag: @unchecked Sendable {
  private(set) var didChange = false

  func mark() { didChange = true }
}
