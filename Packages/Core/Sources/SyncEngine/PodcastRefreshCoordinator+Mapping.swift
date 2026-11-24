import ABSApi
import Foundation
import Persistence

extension PodcastRefreshCoordinator {
  static func mapRefresh(
    context: PodcastRefreshContext,
    itemID: String,
    podcast: PodcastMedia,
    progress: UserProgressSnapshot,
    progressMerge: ProgressMergePolicy,
    detailDiagnostics: DecodeDiagnostics,
    forceIncompleteEpisodeList: Bool,
    now: @Sendable () -> Date,
    requestStartedAt: Date? = nil
  ) -> PodcastRefresh {
    // Duplicate ids are last-wins here; `episodeListProvesAbsence` separately refuses to infer
    // deletion from a list that carried any.
    var episodeByID: [String: PodcastEpisode] = [:]
    for episode in podcast.episodes {
      episodeByID[episode.id] = episode
    }
    // Completeness depends on this show's episode list only. A malformed `/api/me` progress row
    // for an unrelated audiobook must not count, or generation-based soft delete would be
    // disabled for every show. Progress decode health is reported separately, so only the detail
    // read's diagnostics reach this check.
    let isEpisodeListComplete =
      !forceIncompleteEpisodeList
      && podcast.episodeListProvesAbsence(detailDiagnostics: detailDiagnostics)
    let observations = Self.progressObservations(
      progress.progress, itemID: itemID, snapshotIsComplete: progress.isComplete,
      policy: progressMerge)
    return PodcastRefresh(
      accountID: context.accountID,
      localItemID: context.localItemID,
      itemID: itemID,
      episodes: episodeByID.keys.sorted().compactMap { episodeByID[$0].map(Self.mapEpisode) },
      progressObservations: observations.observations,
      autoDownloadEpisodes: podcast.autoDownloadEpisodes,
      autoDownloadSchedule: podcast.autoDownloadSchedule,
      lastEpisodeCheck: podcast.lastEpisodeCheck,
      maxEpisodesToKeep: podcast.maxEpisodesToKeep,
      maxNewEpisodesToDownload: podcast.maxNewEpisodesToDownload,
      showDescription: podcast.description,
      isComplete: isEpisodeListComplete,
      refreshedAt: now(),
      requestStartedAt: requestStartedAt,
      progressSnapshotIsComplete: observations.isComplete)
  }

  static func mapEpisode(_ episode: PodcastEpisode) -> PodcastRefreshEpisode {
    PodcastRefreshEpisode(
      serverEpisodeID: episode.id,
      title: episode.title,
      subtitle: episode.subtitle,
      episodeDescription: episode.description,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      episodeType: episode.episodeType,
      mimeType: episode.mimeType,
      durationSeconds: episode.duration,
      sizeBytes: episode.size,
      publishedAt: episode.publishedAt,
      storedAudio: episode.audioFile.map {
        PodcastRefreshEpisodeAudio(
          ino: $0.ino,
          expectedSize: $0.expectedSize,
          mimeType: $0.mimeType,
          durationSeconds: $0.duration)
      },
      chapters: storedItemChapters(from: episode.chapters, duration: episode.duration))
  }

  /// `isComplete` is true only when the snapshot was complete and every one of this show's episode
  /// rows became an observation: a row dropped here would otherwise read as a deleted one.
  static func progressObservations(
    _ rows: [MediaProgress],
    itemID: String,
    snapshotIsComplete: Bool = false,
    policy: ProgressMergePolicy
  ) -> (observations: [PodcastEpisodeProgressObservation], isComplete: Bool) {
    var grouped: [String: [ProgressMergePolicy.DuplicateServerRow]] = [:]
    var droppedRow = false
    for row in rows where row.libraryItemID == itemID {
      guard let episodeID = row.episodeID, row.currentTime != nil else {
        droppedRow = true
        continue
      }
      grouped[episodeID, default: []].append(ProgressMergePolicy.DuplicateServerRow(row))
    }
    let isComplete = snapshotIsComplete && droppedRow == false
    let observations = grouped.keys.sorted().compactMap {
      episodeID -> PodcastEpisodeProgressObservation? in
      let candidates = grouped[episodeID] ?? []
      guard let winner = policy.resolveDuplicateServerRows(candidates) else { return nil }
      return PodcastEpisodeProgressObservation(
        serverEpisodeId: episodeID,
        currentTime: winner.row.currentTime ?? 0,
        isFinished: winner.row.isFinished,
        hideFromContinueListening: winner.row.hideFromContinueListening,
        serverUpdatedAt: winner.row.lastUpdate,
        serverRow: ServerRowObservation(
          progressId: winner.row.serverProgressID,
          rowIDs: candidates.map(\.row.serverProgressID),
          startedAt: winner.row.startedAt,
          snapshotIsComplete: isComplete))
    }
    return (observations, isComplete)
  }
}
