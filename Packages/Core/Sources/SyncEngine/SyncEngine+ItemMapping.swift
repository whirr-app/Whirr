import ABSApi
import CoreSupport
import Foundation
import Persistence

extension SyncEngine {
  private static let itemMappingLogger = CoreLogging.logger(category: "sync")

  /// `existingAddedAt` is the previously stored row's `addedAt`, if any. A payload that omits
  /// `addedAt` must not null out a value an earlier pull recorded. `durationSeconds`,
  /// `numAudioFiles` and `ebookFormat` carry no such rule and mirror the latest payload, nil
  /// included.
  static func mapItem(
    _ summary: LibraryItemSummary,
    library: Library,
    accountId: Int64,
    libraryId: Int64,
    existingMetadata: ItemDAO.PreservedMetadata? = nil
  ) -> ItemRecord? {
    let title = summary.title ?? summary.id
    let mediaKind = summary.mediaType ?? library.mediaType
    let mediaCategory = ItemMediaCategory.derive(
      mediaKind: mediaKind ?? "", numAudioFiles: summary.numAudioFiles,
      ebookFormat: summary.ebookFormat)
    let podcastEpisodeCount =
      // Keep this change signal independent of the derived display category. Complete server
      // projections can carry `numEpisodes` alongside book/audiobook signals; absence and
      // invalid negatives are non-authoritative and therefore fall back to the prior value.
      summary.podcastEpisodeCount.flatMap { $0 >= 0 ? $0 : nil }
      ?? existingMetadata?.podcastServerEpisodeCount
    let podcastFeedFingerprint: String?
    if mediaCategory == .podcast {
      podcastFeedFingerprint =
        switch summary.feedURLState {
        case .absent:
          PodcastFeedIdentity.validatedFingerprint(existingMetadata?.podcastFeedFingerprint)
        case .value(let feedURL):
          PodcastFeedIdentity.fingerprint(feedURL)
        case .invalid:
          nil
        }
    } else {
      podcastFeedFingerprint = nil
    }
    let podcastLanguage: String? =
      switch summary.podcastLanguageState {
      case .absent: existingMetadata?.podcastLanguage
      case .value(let language): language
      case .cleared: nil
      }
    return Self.makeItemRecord(
      accountId: accountId,
      libraryId: libraryId,
      serverItemId: summary.id,
      mediaKind: mediaKind,
      mediaCategory: mediaCategory,
      title: title,
      author: summary.authorName,
      // Populating this enables ProgressMergePolicy's duration-relative zero-position guard.
      durationSeconds: summary.durationSeconds,
      // Expanded-only, so a minified page carries no information about it.
      itemDescription: existingMetadata?.itemDescription,
      addedAt: summary.addedAt ?? existingMetadata?.addedAt,
      numAudioFiles: summary.numAudioFiles,
      ebookFormat: summary.ebookFormat,
      ebookFileIno: nil,
      ebookFileExt: nil,
      seriesName:
        summary.title != nil || summary.authorName != nil
        ? summary.seriesName : existingMetadata?.seriesName,
      narratorName: existingMetadata?.narratorName,
      expandedMetadataFetchedAt: existingMetadata?.expandedMetadataFetchedAt,
      audioDownloadExpectedBytes: existingMetadata?.audioDownloadExpectedBytes,
      ebookDownloadExpectedBytes: existingMetadata?.ebookDownloadExpectedBytes,
      // Expanded-only podcast diagnostics: the minified summary never carries them.
      podcastAutoDownloadEpisodes: existingMetadata?.podcastAutoDownloadEpisodes,
      podcastLastEpisodeCheck: existingMetadata?.podcastLastEpisodeCheck,
      podcastAutoDownloadSchedule: existingMetadata?.podcastAutoDownloadSchedule,
      podcastMaxEpisodesToKeep: existingMetadata?.podcastMaxEpisodesToKeep,
      podcastMaxNewEpisodesToDownload: existingMetadata?.podcastMaxNewEpisodesToDownload,
      serverUpdatedAt: summary.updatedAt,
      // A minified summary is allowed to omit the podcast count. Invalid negative counts are
      // likewise not authoritative; retain the existing complete count in either case.
      podcastServerEpisodeCount: podcastEpisodeCount,
      podcastFeedFingerprint: podcastFeedFingerprint,
      podcastLanguage: podcastLanguage,
      hasServerArtwork: summary.hasServerArtwork ?? existingMetadata?.hasServerArtwork,
      softDeleted: false
    )
  }

  /// The one SyncEngine-owned projection into Persistence's `ItemRecord`. Callers keep their
  /// insert/update policies separate by deciding which source or existing values to pass here;
  /// this function only constructs the record and applies the canonical media-category rule.
  static func makeItemRecord(
    id: Int64? = nil,
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String,
    mediaKind: String?,
    mediaCategory: ItemMediaCategory? = nil,
    title: String,
    author: String?,
    durationSeconds: Double?,
    itemDescription: String?,
    addedAt: Date?,
    numAudioFiles: Int?,
    ebookFormat: String?,
    ebookFileIno: String?,
    ebookFileExt: String?,
    seriesName: String?,
    narratorName: String?,
    expandedMetadataFetchedAt: Date?,
    audioDownloadExpectedBytes: Int64? = nil,
    ebookDownloadExpectedBytes: Int64? = nil,
    podcastAutoDownloadEpisodes: Bool?,
    podcastLastEpisodeCheck: Date?,
    podcastAutoDownloadSchedule: String? = nil,
    podcastMaxEpisodesToKeep: Int? = nil,
    podcastMaxNewEpisodesToDownload: Int? = nil,
    serverUpdatedAt: Date?,
    podcastServerEpisodeCount: Int?,
    podcastFeedFingerprint: String? = nil,
    podcastLanguage: String?,
    hasServerArtwork: Bool?,
    softDeleted: Bool
  ) -> ItemRecord? {
    guard PodcastSourceIdentity.hasReservedPrefix(serverItemId) == false else {
      itemMappingLogger.fault(
        "Rejected server item whose identifier occupies the native RSS namespace: \(serverItemId, privacy: .private)"
      )
      return nil
    }
    let category =
      mediaCategory
      ?? ItemMediaCategory.derive(
        mediaKind: mediaKind ?? "", numAudioFiles: numAudioFiles, ebookFormat: ebookFormat)
    let canonicalMediaKind = category == .podcast ? "podcast" : "book"
    // This server change signal is retained even when the same complete projection derives to a
    // book/audiobook category; only malformed negative values are discarded.
    let canonicalPodcastEpisodeCount =
      podcastServerEpisodeCount.flatMap { $0 >= 0 ? $0 : nil }
    let canonicalPodcastFeedFingerprint =
      category == .podcast ? PodcastFeedIdentity.validatedFingerprint(podcastFeedFingerprint) : nil
    return ItemRecord(
      id: id,
      accountId: accountId,
      libraryId: libraryId,
      serverItemId: serverItemId,
      mediaKind: canonicalMediaKind,
      title: title,
      sortTitle: ItemSortTitle.derive(from: title),
      author: author,
      durationSeconds: durationSeconds,
      itemDescription: itemDescription,
      addedAt: addedAt,
      numAudioFiles: numAudioFiles,
      ebookFormat: ebookFormat,
      ebookFileIno: ebookFileIno,
      ebookFileExt: ebookFileExt,
      seriesName: seriesName,
      narratorName: narratorName,
      expandedMetadataFetchedAt: expandedMetadataFetchedAt,
      audioDownloadExpectedBytes: audioDownloadExpectedBytes,
      ebookDownloadExpectedBytes: ebookDownloadExpectedBytes,
      podcastAutoDownloadEpisodes: podcastAutoDownloadEpisodes,
      podcastLastEpisodeCheck: podcastLastEpisodeCheck,
      podcastAutoDownloadSchedule: podcastAutoDownloadSchedule,
      podcastMaxEpisodesToKeep: podcastMaxEpisodesToKeep,
      podcastMaxNewEpisodesToDownload: podcastMaxNewEpisodesToDownload,
      serverUpdatedAt: serverUpdatedAt,
      podcastServerEpisodeCount: canonicalPodcastEpisodeCount,
      podcastFeedFingerprint: canonicalPodcastFeedFingerprint,
      podcastLanguage: category == .podcast ? podcastLanguage : nil,
      hasServerArtwork: hasServerArtwork,
      softDeleted: softDeleted)
  }
}
