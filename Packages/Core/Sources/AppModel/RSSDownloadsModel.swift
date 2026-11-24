import Observation
import Persistence
import SyncEngine

public enum RSSDownloadsCopy {
  public static let purgeFailed = StorageCopy.purgeFailed
}

/// Presentation model for device-owned RSS downloads.  Unlike `StorageModel`, this never reads
/// account totals and therefore remains valid across logout/account removal.
@MainActor
@Observable
public final class RSSDownloadsModel {
  public private(set) var feeds: [RSSDownloadedFeed] = []
  /// Distinguishes a settled empty projection from the initial value before GRDB has delivered its
  /// first snapshot. Browse filters use this to avoid briefly claiming there are no downloads.
  public private(set) var hasLoaded = false
  public private(set) var actionErrorMessage: String?
  private let reading: any RSSDownloadsReading
  private let downloadIntents: any DownloadIntents
  @ObservationIgnored private var observationTask: Task<Void, Never>?

  public init(reading: any RSSDownloadsReading, downloadIntents: any DownloadIntents) {
    self.reading = reading
    self.downloadIntents = downloadIntents
    let stream = reading.observeRSSDownloads()
    observationTask = Task { [weak self] in
      for await feeds in stream {
        guard let self else { return }
        self.feeds = feeds
        if self.hasLoaded == false { self.hasLoaded = true }
      }
    }
  }

  // The purge sources are fixed here rather than passed in: they describe where the deletion was
  // initiated, and the RSS downloads list is the only caller. This keeps `DownloadPurgeSource`
  // (and so `SyncEngine`) out of the view.
  public func purgeItemDownload(feedId: Int64) async {
    await perform(feedId: feedId) { itemID in
      try await downloadIntents.purgeItemDownload(itemID: itemID, source: .itemDetail)
    }
  }

  public func purgeEpisodeDownload(feedId: Int64, episodeID: String) async {
    await perform(feedId: feedId) { itemID in
      try await downloadIntents.purgeEpisodeDownload(
        itemID: itemID, episodeID: episodeID, source: .podcastEpisodeRemoval)
    }
  }

  public func dismissActionError() {
    actionErrorMessage = nil
  }

  /// Removes a confirmed selection and reports one failure after every request has been tried.
  public func purgeSelectedDownloads(feedIDs: Set<Int64>, episodeIDs: [Int64: Set<String>]) async {
    actionErrorMessage = nil
    let eligibleFeeds = feedIDs.filter { feedID in feeds.contains { $0.id == feedID } }.sorted()
    // Capture all targets before awaiting a purge: observations can remove rows while this runs.
    let eligibleEpisodes = episodeIDs.filter { !eligibleFeeds.contains($0.key) }
    let episodeTargets = eligibleEpisodes.map { feedID, ids in
      (
        feedID,
        ids.intersection(
          Set(
            feeds.first { $0.id == feedID }?.episodes
              .filter { $0.state != .deleting }.map(\.id) ?? [])
        ).sorted()
      )
    }.sorted { $0.0 < $1.0 }
    var failed = false
    for feedID in eligibleFeeds {
      await purgeItemDownload(feedId: feedID)
      failed = failed || actionErrorMessage != nil
    }
    for (feedID, ids) in episodeTargets {
      for episodeID in ids {
        await purgeEpisodeDownload(feedId: feedID, episodeID: episodeID)
        failed = failed || actionErrorMessage != nil
      }
    }
    actionErrorMessage = failed ? RSSDownloadsCopy.purgeFailed : nil
  }

  private func perform(
    feedId: Int64, _ action: (String) async throws -> Void
  ) async {
    guard let itemID = PodcastSourceIdentity.rss(feedId: feedId)?.itemId else {
      actionErrorMessage = StorageCopy.purgeFailed
      return
    }
    do {
      try await action(itemID)
      actionErrorMessage = nil
    } catch {
      actionErrorMessage = StorageCopy.purgeFailed
    }
  }

  deinit { observationTask?.cancel() }
}
