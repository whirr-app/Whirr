import ABSApi
import AppModel
import Foundation
import Persistence
import PlayerCore
import WatchProtocol

/// Stateless projection and byte-budget enforcement for phone catalogue publications.
enum WatchCatalogueWireMapper {
  /// Pure mapping used by the publisher and App-target tests. Server playback capabilities pass
  /// through; native feeds stay phone-only and Watch-local downloads require a local projection.
  nonisolated static func makeWatchSnapshot(
    from companion: CompanionCatalogueSnapshot,
    generatedAt: Date,
    playbackState: WatchPlaybackState = .idle,
    playbackRate: Double? = nil,
    skipBackwardSeconds: Int? = nil,
    skipForwardSeconds: Int? = nil,
    playbackRatePresets: [Double]? = nil,
    followedPodcastsEnabled: Bool? = nil,
    removePlayedNativeEpisodes: Bool? = nil,
    playbackProgress: (
      selection: CompanionSelection, position: Double, duration: Double, chapter: PlayerCore.PlaybackChapter?
    )? =
      nil,
    phoneLastListenedAt: Date? = nil
  ) -> WatchCatalogueSnapshot? {
    guard let stamp = watchStamp(for: companion) else { return nil }
    return encodedSnapshot(
      stamp: stamp,
      items: mappedItems(
        from: companion, playbackProgress: playbackProgress, phoneLastListenedAt: phoneLastListenedAt),
      generatedAt: generatedAt,
      playbackState: playbackState, playbackRate: playbackRate,
      skipBackwardSeconds: skipBackwardSeconds, skipForwardSeconds: skipForwardSeconds,
      playbackRatePresets: playbackRatePresets, followedPodcastsEnabled: followedPodcastsEnabled,
      removePlayedNativeEpisodes: removePlayedNativeEpisodes)
  }

  nonisolated private static func watchStamp(
    for companion: CompanionCatalogueSnapshot
  ) -> WatchAccountStamp? {
    guard let accountHash = companion.accountIdentityHash,
      let serverHash = companion.serverIdentityHash,
      let stamp = try? WatchAccountStamp(
        accountIdentityHash: accountHash, serverIdentityHash: serverHash)
    else { return nil }
    return stamp
  }

  /// Every row of every section, in section then row order. Native feeds stay phone-only and
  /// Watch-local downloads require a local projection, so neither can claim Watch playback.
  nonisolated private static func mappedItems(
    from companion: CompanionCatalogueSnapshot,
    playbackProgress: (
      selection: CompanionSelection, position: Double, duration: Double, chapter: PlayerCore.PlaybackChapter?
    )?,
    phoneLastListenedAt: Date?
  ) -> [WatchCatalogueItem] {
    let groups: [(CompanionCatalogueSection, [CompanionCatalogueItem])] = [
      (.continueListening, companion.continueListening),
      (.recentBooks, companion.recentBooks),
      (.recentEpisodes, companion.recentEpisodes),
      (.downloads, companion.downloads),
    ]
    var items: [WatchCatalogueItem] = []
    for (section, rows) in groups {
      for row in rows {
        if let item = mappedItem(
          row, section: section, playbackProgress: playbackProgress,
          phoneLastListenedAt: phoneLastListenedAt)
        {
          items.append(item)
        }
      }
    }
    return items
  }

  nonisolated private static func mappedItem(
    _ row: CompanionCatalogueItem, section: CompanionCatalogueSection,
    playbackProgress: (
      selection: CompanionSelection, position: Double, duration: Double, chapter: PlayerCore.PlaybackChapter?
    )?,
    phoneLastListenedAt: Date?
  ) -> WatchCatalogueItem? {
    guard let selection = Self.watchSelection(for: row.id) else { return nil }
    // The wire validator rejects a native feed claiming Watch playback, and the phone never
    // knows about Watch-local downloads, so only Watch playback of server items passes.
    let capabilities = WatchSelectionCapabilities(
      phonePlayable: row.capabilities.phonePlayable,
      watchPlayable: Self.allowsWatchPlayback(selection) && row.capabilities.watchPlayable,
      phoneLocalDownload: row.capabilities.phoneDownloaded,
      watchLocalDownload: false)
    let progress = row.isCurrentPlayback && row.id == playbackProgress?.selection ? playbackProgress : nil
    let chapter = progress?.chapter
    guard
      let item = try? WatchCatalogueItem(
        id: CompanionCatalogueBuilder.rowIdentifier(selection: row.id, section: section),
        selection: selection,
        title: row.title,
        subtitle: row.subtitle,
        section: Self.watchSection(section),
        progressSeconds: progress?.position ?? row.progressSeconds,
        durationSeconds: progress?.duration ?? row.durationSeconds,
        isCurrentPlayback: row.isCurrentPlayback,
        chapterTitle: chapter?.title, chapterStartSeconds: chapter?.start, chapterEndSeconds: chapter?.end,
        capabilities: capabilities,
        artworkRevision: Self.artworkRevision(row.serverUpdatedAt),
        // The listen dates the loaded title, so it rides only on the row that is loaded.
        lastListenedAt: progress == nil ? nil : phoneLastListenedAt)
    else { return nil }
    return item
  }

  /// Encodes the snapshot, dropping trailing rows until it fits the wire budget. Rows go in
  /// section order, so the trim never reorders what remains.
  nonisolated private static func encodedSnapshot(
    stamp: WatchAccountStamp, items: [WatchCatalogueItem], generatedAt: Date,
    playbackState: WatchPlaybackState, playbackRate: Double?,
    skipBackwardSeconds: Int?, skipForwardSeconds: Int?, playbackRatePresets: [Double]?,
    followedPodcastsEnabled: Bool?, removePlayedNativeEpisodes: Bool?
  ) -> WatchCatalogueSnapshot? {
    var trimmed = items
    while true {
      guard
        let snapshot = try? WatchCatalogueSnapshot(
          accountStamp: stamp,
          generatedAt: generatedAt,
          items: trimmed,
          playbackState: playbackState, playbackRate: playbackRate,
          skipBackwardSeconds: skipBackwardSeconds, skipForwardSeconds: skipForwardSeconds,
          playbackRatePresets: playbackRatePresets, followedPodcastsEnabled: followedPodcastsEnabled,
          removePlayedNativeEpisodes: removePlayedNativeEpisodes),
        let data = try? WatchWireCodec.encode(snapshot),
        data.count <= WatchProtocolVersion.maxSnapshotBytes
      else {
        guard trimmed.isEmpty == false else { return nil }
        trimmed.removeLast()
        continue
      }
      return snapshot
    }
  }

  nonisolated private static func allowsWatchPlayback(_ selection: WatchSelection) -> Bool {
    if case .nativeFeed = selection { return false }
    return true
  }

  /// The wire spelling of a cover revision, matching the phone's own `ArtworkRevision`. An undated
  /// row sends nothing, so the Watch keeps whatever revision it already learned for that cover.
  nonisolated static func artworkRevision(_ serverUpdatedAt: Date?) -> String? {
    serverUpdatedAt.map { ArtworkRevision(serverUpdatedAt: $0).rawValue }
  }

  nonisolated private static func watchSelection(for selection: CompanionSelection) -> WatchSelection? {
    switch selection.source.source {
    case .abs(let itemID):
      return .audiobookshelf(itemID: itemID, episodeID: selection.episodeID)
    case .rss(let feedID):
      guard let episodeID = selection.episodeID else { return nil }
      return .nativeFeed(feedID: String(feedID), episodeID: episodeID)
    }
  }

  nonisolated private static func watchSection(_ section: CompanionCatalogueSection) -> WatchCatalogueSection {
    switch section {
    case .continueListening: .continueListening
    case .recentBooks: .recentBooks
    case .recentEpisodes: .recentEpisodes
    case .downloads: .downloads
    }
  }

}

/// Everything one publication needs, captured on the main actor so the expensive half (merging
/// the shelves, building the catalogue, mapping and size-checking it for the wire) can run off it.
/// While audio plays the publisher runs twice a second, and on the main thread that work costs
/// 10-19ms each time, enough to drop a frame or two while the reader scrolls.
nonisolated struct WatchCatalogueAssembly: Sendable {
  typealias PlaybackProgress = (
    selection: CompanionSelection, position: Double, duration: Double, chapter: PlayerCore.PlaybackChapter?
  )

  let identity: AccountIdentity
  let nativeEnabled: Bool
  let absContinue: [HomeItem]
  let nativeContinueItems: [HomeItem]
  let bookmark: PlaybackBookmark?
  let recentBooks: [HomeItem]
  let absLatest: HomeLatestPodcastEpisodesSnapshot?
  let nativeLatestEpisodes: [HomePodcastEpisode]
  let absDownloads: [HomeItem]
  let nativeDownloadFeeds: [RSSDownloadedFeed]
  let generatedAt: Date
  let playbackState: WatchPlaybackState
  let playbackRate: Double?
  let skipBackwardSeconds: Int
  let skipForwardSeconds: Int
  let playbackRatePresets: [Double]
  let removePlayedNativeEpisodes: Bool
  let playbackProgress: PlaybackProgress?
  let phoneLastListenedAt: Date?

  func makeSnapshot() -> WatchCatalogueSnapshot? {
    let mergedContinue = ContinueListeningMerge.merge(
      abs: absContinue,
      rss: nativeContinueItems,
      nativeSubscriptionsEnabled: nativeEnabled,
      limit: CompanionCatalogueBuilder.maxItemsPerSection)
    let episodes: [HomePodcastEpisode]
    if let absLatest {
      episodes = LatestPodcastEpisodesMerge.merge(
        snapshot: absLatest,
        rss: nativeLatestEpisodes,
        nativeSubscriptionsEnabled: nativeEnabled,
        limit: CompanionCatalogueBuilder.maxItemsPerSection)
    } else {
      episodes =
        nativeEnabled
        ? Array(nativeLatestEpisodes.prefix(CompanionCatalogueBuilder.maxItemsPerSection))
        : []
    }
    let mergedDownloads = DownloadedShelfMerge.merge(
      abs: absDownloads,
      rss: nativeContinueItems.filter { $0.isDownloaded || $0.audioDownloaded },
      nativeSubscriptionsEnabled: nativeEnabled,
      limit: CompanionCatalogueBuilder.maxItemsPerSection)
    let companion = CompanionCatalogueBuilder.build(
      CompanionCatalogueInput(
        accountIdentity: identity,
        continueListening: mergedContinue,
        currentBookmark: bookmark,
        recentBooks: recentBooks,
        recentEpisodes: episodes,
        downloads: mergedDownloads,
        nativeDownloads: nativeEnabled ? nativeDownloadFeeds : []))
    guard companion.accountServerIdentityHash != nil else { return nil }
    return WatchCatalogueWireMapper.makeWatchSnapshot(
      from: companion,
      generatedAt: generatedAt,
      playbackState: playbackState,
      playbackRate: playbackRate,
      skipBackwardSeconds: skipBackwardSeconds, skipForwardSeconds: skipForwardSeconds,
      playbackRatePresets: playbackRatePresets, followedPodcastsEnabled: nativeEnabled,
      removePlayedNativeEpisodes: removePlayedNativeEpisodes,
      playbackProgress: playbackProgress, phoneLastListenedAt: phoneLastListenedAt)
  }
}
