import Foundation
import Persistence

/// The `ItemSummary` the App suites use as seed data.
///
/// The four required fields are the ones every suite sets differently; everything else keeps the
/// projection's own default unless the test passes it.
extension ItemSummary {
  nonisolated static func fixture(
    serverItemId: String = "item-1",
    mediaKind: String = "book",
    title: String = "Title",
    author: String? = nil,
    durationSeconds: Double? = 600,
    progressSeconds: Double = 0,
    category: ItemMediaCategory = .audiobook,
    hasReadableEbook: Bool = false,
    addedAt: Date? = nil,
    seriesName: String? = nil,
    narratorName: String? = nil,
    expandedMetadataFetchedAt: Date? = nil,
    itemDescription: String? = nil,
    audioDownloadExpectedBytes: Int64? = nil,
    ebookDownloadExpectedBytes: Int64? = nil,
    podcastFeedFingerprint: String? = nil,
    artworkURL: URL? = nil,
    artworkFeedURL: URL? = nil,
    serverUpdatedAt: Date? = nil
  ) -> ItemSummary {
    ItemSummary(
      serverItemId: serverItemId,
      mediaKind: mediaKind,
      title: title,
      author: author,
      durationSeconds: durationSeconds,
      progressSeconds: progressSeconds,
      category: category,
      hasReadableEbook: hasReadableEbook,
      addedAt: addedAt,
      seriesName: seriesName,
      narratorName: narratorName,
      expandedMetadataFetchedAt: expandedMetadataFetchedAt,
      itemDescription: itemDescription,
      audioDownloadExpectedBytes: audioDownloadExpectedBytes,
      ebookDownloadExpectedBytes: ebookDownloadExpectedBytes,
      podcastFeedFingerprint: podcastFeedFingerprint,
      artworkURL: artworkURL,
      artworkFeedURL: artworkFeedURL,
      serverUpdatedAt: serverUpdatedAt)
  }
}
