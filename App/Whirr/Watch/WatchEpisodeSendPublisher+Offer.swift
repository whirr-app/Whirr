import ABSApi
import Foundation
import Persistence
import WatchProtocol

/// The database-backed reader the publisher needs, composed once per process.
extension WatchEpisodeSendPublisher {
  /// Builds the publisher against the phone's own stores. Nothing here reads a downloaded file:
  /// offers name the feed's enclosure and the Watch fetches it (ADR 0020 Decision 1). A finished
  /// download's recorded size only sizes the offer.
  @MainActor
  static func production(
    database: AppDatabase, credentialStore: (any FeedCredentialStoring)?, sender: Sender
  ) -> WatchEpisodeSendPublisher {
    let episodes = RSSEpisodeStore(database: database)
    let feeds = RSSFeedStore(database: database)
    let states = RSSEpisodeStateStore(database: database)
    let chapterCache = RSSEpisodeChapterStore(database: database)
    let downloads = try? RSSDownloadStore(database: database)

    let reader = Reader(
      facts: { episodeId in
        guard let episode = try? await episodes.fetchEpisode(episodeId: episodeId) else {
          return nil
        }
        let feed = try? await feeds.fetchFeed(feedId: episode.feedId)
        let state = try? await states.fetchState(episodeId: episodeId)
        // Chapters ride the offer now that no file arrives with them attached. The cache
        // holds the chapters of a previous parse, so an episode never played sends none.
        let chapters = (try? await chapterCache.cache(episodeId: episodeId))?.chapters ?? []
        let download = try? await downloads?.fetchAsync(episodeId: episodeId)
        return WatchEpisodeOfferFacts(
          feedId: episode.feedId, identityKey: episode.identityKey,
          title: episode.title ?? feed?.title ?? "Episode",
          showTitle: feed?.title ?? episode.title ?? "Podcast",
          duration: episode.durationSeconds ?? episode.measuredDurationSeconds,
          enclosureURL: URL(string: episode.enclosureURL),
          declaredBytes: episode.declaredBytes,
          downloadedBytes: download?.isPlayable == true ? download?.actualBytes : nil,
          mimeType: mimeType(declared: episode.enclosureType),
          chapters: wireChapters(chapters),
          position: state?.position ?? 0,
          lastListenedAt: state?.updatedAt, finished: state?.finished ?? false,
          stateUpdatedAt: state?.updatedAt,
          isPrivateFeed: WatchEpisodeSendEligibility.isPrivateFeed(
            feedId: episode.feedId, credentialStore: credentialStore))
      })

    return WatchEpisodeSendPublisher(
      copies: RSSWatchCopyStore(database: database), reader: reader, sender: sender,
      removesPlayedEpisodes: { WatchEpisodeSendPreferences.removesPlayedEpisodes() })
  }

  /// The MIME the Watch is told to expect. The feed's declared type wins only when it is an audio
  /// type; otherwise the phone download path's own fallback decides.
  static func mimeType(declared: String?) -> String {
    audioMime(declared: declared) ?? "audio/mpeg"
  }

  /// The feed's declared `<enclosure type>` when it is an audio type, base-normalised.
  static func audioMime(declared: String?) -> String? {
    guard let declared else { return nil }
    let base =
      declared.split(separator: ";", maxSplits: 1).first.map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    guard base.hasPrefix("audio/"), base.count > 6,
      base.utf8.count <= WatchEpisodeSendLimits.maxMimeTypeBytes
    else { return nil }
    return base
  }

  /// The phone's cached chapters, ordered and bounded for the wire. Extraction happens on playback,
  /// not in the send path, so an episode never played contributes none.
  static func wireChapters(_ stored: [RSSStoredChapter]) -> [WatchEpisodeChapter] {
    let ordered = stored.sorted { $0.start < $1.start }
      .prefix(WatchEpisodeSendLimits.maxChapters)
    return ordered.enumerated().compactMap { index, chapter in
      guard chapter.start.isFinite, chapter.start >= 0,
        chapter.start <= WatchHandoffLimits.maxPositionSeconds,
        chapter.end.isFinite, chapter.end > chapter.start,
        chapter.end <= WatchHandoffLimits.maxPositionSeconds
      else { return nil }
      let title = chapter.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(index + 1)"
      return try? WatchEpisodeChapter(title: title, start: chapter.start, end: chapter.end)
    }
  }
}
