import AppModel
import Foundation
import Observation
import Persistence
import PlayerCore
import WatchProtocol

/// The projection readers behind a catalogue publication: each keeps the latest value from its
/// store and schedules a publication when it changes. Playback is observed separately, in
/// `WatchCataloguePublisher+Playback.swift`.
extension WatchCataloguePublisher {
  func startReaderTasks(publicationEpoch: UInt64) {
    let cutoff = HomeRecency.cutoff(now: now())
    readerTasks = [
      observe(
        home.observeContinueListening(category: nil, limit: CompanionCatalogueBuilder.maxItemsPerSection),
        publicationEpoch: publicationEpoch
      ) { [weak self] value in
        self?.absContinue = value
      },
      observe(
        nativeContinue.observeContinueListening(limit: CompanionCatalogueBuilder.maxItemsPerSection),
        publicationEpoch: publicationEpoch
      ) { [weak self] value in
        self?.nativeContinueItems = value
      },
      observe(bookmarks.observeBookmark(), publicationEpoch: publicationEpoch) { [weak self] value in
        self?.bookmark = value
      },
      observe(
        home.observeRecentlyAdded(category: nil, limit: CompanionCatalogueBuilder.maxItemsPerSection, since: cutoff),
        publicationEpoch: publicationEpoch
      ) { [weak self] value in
        self?.recentBooks = value.all
      },
      observe(
        home.observeNewPodcastEpisodes(cutoff: { cutoff }, limit: CompanionCatalogueBuilder.maxItemsPerSection),
        publicationEpoch: publicationEpoch
      ) { [weak self] value in
        self?.absLatest = value
      },
      observe(
        nativeLatest.observeLatestPodcastEpisodes(
          cutoff: { cutoff }, limit: CompanionCatalogueBuilder.maxItemsPerSection), publicationEpoch: publicationEpoch
      ) { [weak self] value in
        self?.nativeLatestEpisodes = value
      },
      observe(
        home.observeDownloaded(category: nil, limit: CompanionCatalogueBuilder.maxItemsPerSection),
        publicationEpoch: publicationEpoch
      ) { [weak self] value in
        self?.absDownloads = value
      },
      observe(rssDownloads.observeCompletedRSSDownloads(), publicationEpoch: publicationEpoch) { [weak self] value in
        self?.nativeDownloadFeeds = value
      },
      observe(nativeSubscriptions.observeEnabled(), publicationEpoch: publicationEpoch) { [weak self] value in
        self?.nativeEnabled = value
        self?.browseModel.setNativeEnabled(value)
      },
    ]
  }

  func observe<Value: Sendable>(
    _ stream: AsyncStream<Value>,
    publicationEpoch: UInt64,
    receive: @escaping @MainActor @Sendable (Value) -> Void
  ) -> Task<Void, Never> {
    Task { [weak self] in
      for await value in stream {
        guard let self, self.started, self.publicationEpoch == publicationEpoch, self.identity != nil else {
          return
        }
        receive(value)
        self.schedulePublication(publicationEpoch: publicationEpoch)
      }
    }
  }

  func cancelReaderTasks() {
    for task in readerTasks {
      task.cancel()
    }
    readerTasks.removeAll()
  }
}
