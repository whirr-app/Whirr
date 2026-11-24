import Persistence

extension PodcastRefreshStore: PodcastRefreshApplying {
  public func applyPodcastRefresh(
    _ refresh: PodcastRefresh,
    decideProgress: @escaping PodcastProgressMergeDecider
  ) async throws {
    let episodes = Self.episodeRecords(
      from: refresh.episodes, accountId: refresh.accountID, itemId: refresh.localItemID)
    try await applyAsync(
      PodcastRefreshApplication(
        accountId: refresh.accountID,
        itemId: refresh.localItemID,
        episodes: episodes,
        episodeChapters: Dictionary(
          refresh.episodes.map { ($0.serverEpisodeID, $0.chapters) },
          uniquingKeysWith: { _, later in later }),
        progressObservations: refresh.progressObservations,
        autoDownloadEpisodes: refresh.autoDownloadEpisodes,
        autoDownloadSchedule: refresh.autoDownloadSchedule,
        lastEpisodeCheck: refresh.lastEpisodeCheck,
        maxEpisodesToKeep: refresh.maxEpisodesToKeep,
        maxNewEpisodesToDownload: refresh.maxNewEpisodesToDownload,
        showDescription: refresh.showDescription,
        responseIsComplete: refresh.isComplete,
        refreshedAt: refresh.refreshedAt,
        serverItemId: refresh.itemID,
        requestStartedAt: refresh.requestStartedAt,
        progressSnapshotIsComplete: refresh.progressSnapshotIsComplete),
      decideProgress: decideProgress)
  }

  /// Shared with `NativeEpisodeServerSaveRemoval`'s post-delete reconciliation, so there is one
  /// mapping from a decoded episode list to `PodcastEpisodeRecord`, not two that can drift apart.
  static func episodeRecords(
    from episodes: [PodcastRefreshEpisode], accountId: Int64, itemId: Int64
  ) -> [PodcastEpisodeRecord] {
    episodes.map { episode in
      PodcastEpisodeRecord(
        accountId: accountId,
        itemId: itemId,
        serverEpisodeId: episode.serverEpisodeID,
        title: episode.title ?? "",
        subtitle: episode.subtitle,
        episodeDescription: episode.episodeDescription,
        seasonNumber: episode.seasonNumber,
        episodeNumber: episode.episodeNumber,
        episodeType: episode.episodeType,
        mimeType: episode.mimeType,
        durationSeconds: episode.durationSeconds,
        sizeBytes: episode.sizeBytes,
        publishedAt: episode.publishedAt,
        storedAudioIno: episode.storedAudio?.ino,
        storedAudioExpectedSize: episode.storedAudio?.expectedSize,
        storedAudioMimeType: episode.storedAudio?.mimeType,
        storedAudioDurationSeconds: episode.storedAudio?.durationSeconds,
        lastSeenGeneration: 0)
    }
  }
}
