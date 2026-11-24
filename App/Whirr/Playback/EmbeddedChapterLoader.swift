@preconcurrency import AVFoundation
import AppModel

/// Reads the chapters embedded in a downloaded podcast episode (ID3 `CHAP`, MP4 chapter tracks).
/// Lives in the App target because no module under `Packages/Core` imports a media framework;
/// `RSSEpisodeChapterResolver` owns caching and policy and holds this only as its loader seam.
struct AVAssetEmbeddedChapterLoader: EmbeddedChapterLoading {
  func loadChapters(from localFileURL: URL) async throws -> [EmbeddedChapter] {
    let asset = AVURLAsset(url: localFileURL)
    do {
      guard try await asset.load(.availableChapterLocales).isEmpty == false else { return [] }
      let groups = try await asset.loadChapterMetadataGroups(
        bestMatchingPreferredLanguages: Locale.preferredLanguages)
      var chapters: [EmbeddedChapter] = []
      for group in groups {
        let range = group.timeRange
        guard range.start.isValid, range.duration.isValid, range.duration.isIndefinite == false
        else { continue }
        let start = CMTimeGetSeconds(range.start)
        let end = CMTimeGetSeconds(range.end)
        guard start.isFinite, end.isFinite, end > start else { continue }
        let titleItem = AVMetadataItem.metadataItems(
          from: group.items, filteredByIdentifier: .commonIdentifierTitle
        ).first
        let title = try await titleItem?.load(.stringValue)
        chapters.append(EmbeddedChapter(start: start, end: end, title: title))
      }
      return chapters
    } catch {
      // As in `AVAssetEnclosureDurationLoader`: AVFoundation reports a cancelled load as its own
      // error, so re-checking the task separates "we gave up" from "this file has no chapters".
      try Task.checkCancellation()
      return []
    }
  }
}
