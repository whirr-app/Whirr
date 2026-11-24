import AppModel
import Foundation
import Persistence
import WatchProtocol

/// A browse session's frozen read: both source readers, the show and episode projection, and the
/// session `reply` pages against. `reply` owns the shared load task, so a second request joins the
/// load in flight rather than starting another.
extension WatchPhoneBrowseModel {
  func load(binding: UInt64, nativeEnabled: Bool) async throws -> BrowseSession {
    let sources = try await readSources(nativeEnabled: nativeEnabled)
    var shows = loadShows(abs: sources.abs, rss: sources.rss)

    guard browseBindingEpoch == binding, self.nativeEnabled == nativeEnabled else { throw BrowseLoadError.unavailable }
    guard shows.count <= 2_000 else { throw BrowseLoadError.unavailable }
    let episodeResults = try await loadEpisodeBatches(
      shows: shows, binding: binding, nativeEnabled: nativeEnabled)
    let built = try buildRows(shows: &shows, episodeResults: episodeResults)

    let orderedShows = shows.map(\.0).sorted { lhs, rhs in
      let left = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
      if left != .orderedSame { return left == .orderedAscending }
      return String(describing: lhs.id) < String(describing: rhs.id)
    }
    let nextGeneration = browseEpoch == UInt64.max ? 1 : browseEpoch + 1
    self.browseEpoch = nextGeneration
    let session = BrowseSession(
      shows: orderedShows, episodes: built.episodeRows, inProgress: built.inProgress,
      generation: nextGeneration)
    self.sessions[nextGeneration] = session
    if sessions.count > 3, let oldest = sessions.keys.filter({ $0 != nextGeneration }).min() {
      sessions.removeValue(forKey: oldest)
    }
    return session
  }

  /// Both source readers must answer. An empty array is complete; nil is a timed-out or
  /// unavailable reader and must not be presented as a complete catalogue.
  private func readSources(
    nativeEnabled: Bool
  ) async throws -> (abs: [ItemSummary], rss: [ItemSummary]) {
    let absValue = await first(library.observeBrowseList(category: .podcast))
    let rssValue: NativePodcastShowsSnapshot?
    if nativeEnabled {
      rssValue = await first(self.nativeShows.observeShows())
    } else {
      rssValue = NativePodcastShowsSnapshot(mode: .alphabetical, shows: [])
    }
    guard let abs = absValue, let rssSnapshot = rssValue else { throw BrowseLoadError.unavailable }
    return (abs, rssSnapshot.shows)
  }

  /// One show row per item the source reader returned, paired with the item id the episode reader
  /// is keyed by. An item whose identity does not match its source is skipped.
  private func loadShows(abs: [ItemSummary], rss: [ItemSummary]) -> [(WatchBrowseShowRow, String)] {
    var shows: [(WatchBrowseShowRow, String)] = []
    for item in abs {
      guard let identity = PodcastSourceIdentity(itemId: item.id), case .abs(let id) = identity.source,
        let show = try? WatchBrowseShowRow(
          id: .audiobookshelf(itemID: id), title: bounded(item.title, fallback: "Untitled show"),
          author: item.author.map { bounded($0, fallback: "") }.flatMap { $0.isEmpty ? nil : $0 },
          artworkRevision: WatchCatalogueWireMapper.artworkRevision(item.serverUpdatedAt))
      else { continue }
      shows.append((show, item.id))
    }
    for item in rss {
      guard let identity = PodcastSourceIdentity(itemId: item.id), case .rss(let id) = identity.source,
        let show = try? WatchBrowseShowRow(
          id: .nativeFeed(feedID: String(id)), title: bounded(item.title, fallback: "Untitled show"),
          author: item.author.map { bounded($0, fallback: "") }.flatMap { $0.isEmpty ? nil : $0 })
      else { continue }
      shows.append((show, item.id))
    }
    return shows
  }

  /// One episode read per show, bounded in flight. Each batch re-checks the binding so an account
  /// or subscription change stops the read instead of caching its rows.
  private func loadEpisodeBatches(
    shows: [(WatchBrowseShowRow, String)], binding: UInt64, nativeEnabled: Bool
  ) async throws -> [(WatchBrowseShowRow, String, [PodcastEpisodeSummary]?)] {
    var episodeResults: [(WatchBrowseShowRow, String, [PodcastEpisodeSummary]?)] = []
    // Reader observations are bounded in flight so a large account cannot create one
    // task/SQLite observation per show at once.
    for batchStart in stride(from: 0, to: shows.count, by: 8) {
      let batch = Array(shows[batchStart..<min(shows.count, batchStart + 8)])
      let values = await withTaskGroup(of: (WatchBrowseShowRow, String, [PodcastEpisodeSummary]?).self) { group in
        for (show, itemID) in batch {
          group.addTask { [podcasts] in
            (show, itemID, await self.first(podcasts.observeEpisodes(itemId: itemID)))
          }
        }
        var values: [(WatchBrowseShowRow, String, [PodcastEpisodeSummary]?)] = []
        for await value in group { values.append(value) }
        return values
      }
      episodeResults.append(contentsOf: values)
      guard browseBindingEpoch == binding, self.nativeEnabled == nativeEnabled else {
        throw BrowseLoadError.unavailable
      }
    }
    guard browseBindingEpoch == binding, self.nativeEnabled == nativeEnabled else { throw BrowseLoadError.unavailable }
    return episodeResults
  }

  /// The episode rows for every show, and the selections a partial listen puts in progress. The
  /// show's newest publication date is folded back in before the rows are sorted.
  private func buildRows(
    shows: inout [(WatchBrowseShowRow, String)],
    episodeResults: [(WatchBrowseShowRow, String, [PodcastEpisodeSummary]?)]
  ) throws -> (episodeRows: [WatchBrowseEpisodeRow], inProgress: Set<WatchSelection>) {
    var episodeRows: [WatchBrowseEpisodeRow] = []
    var inProgress: Set<WatchSelection> = []
    for (show, _, episodeValue) in episodeResults {
      guard let episodes = episodeValue else { throw BrowseLoadError.unavailable }
      let latest = episodes.compactMap(\.publishedAt).max()
      if let index = shows.firstIndex(where: { $0.0.id == show.id }),
        let updated = try? WatchBrowseShowRow(
          id: show.id, title: show.title, author: show.author, latestPublishedAt: latest,
          artworkRevision: show.artworkRevision)
      {
        shows[index].0 = updated
      }
      let built = projectedRows(for: show, episodes: episodes)
      episodeRows.append(contentsOf: built.rows)
      inProgress.formUnion(built.inProgress)
    }
    guard episodeRows.count <= 20_000 else { throw BrowseLoadError.unavailable }
    return (episodeRows, inProgress)
  }

  private func projectedRows(
    for show: WatchBrowseShowRow, episodes: [PodcastEpisodeSummary]
  ) -> (rows: [WatchBrowseEpisodeRow], inProgress: Set<WatchSelection>) {
    var rows: [WatchBrowseEpisodeRow] = []
    var inProgress: Set<WatchSelection> = []
    for episode in episodes {
      let title = bounded(episode.title, fallback: "Untitled episode")
      let selection: WatchSelection
      let showIdentity: WatchBrowseShowIdentity
      switch show.id {
      case .audiobookshelf(let id):
        selection = .audiobookshelf(itemID: id, episodeID: episode.id)
        showIdentity = .audiobookshelf(itemID: id)
      case .nativeFeed(let id):
        selection = .nativeFeed(feedID: id, episodeID: episode.id)
        showIdentity = .nativeFeed(feedID: id)
      }
      let playable: Bool
      let phonePlayable: Bool
      switch show.id {
      case .nativeFeed:
        playable = false
        phonePlayable = true
      case .audiobookshelf:
        playable = episode.isAvailableOnServer
        phonePlayable = episode.isAvailableOnServer || episode.downloadStatus == .completed
      }
      let duration = episode.durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
      let rawProgress = episode.progressSeconds.isFinite ? max(0, episode.progressSeconds) : 0
      let progress = duration.map { min(rawProgress, $0) } ?? rawProgress
      if let row = try? WatchBrowseEpisodeRow(
        selection: selection, show: showIdentity, showTitle: show.title, title: title,
        publishedAt: episode.publishedAt, durationSeconds: duration, progressSeconds: progress,
        isPlayed: episode.isPlayed || episode.isFinished, phonePlayable: phonePlayable, watchPlayable: playable)
      {
        rows.append(row)
        // isPlayed includes partially listened episodes; only isFinished excludes them.
        if progress > 0 && !episode.isFinished { inProgress.insert(selection) }
      }
    }
    return (rows, inProgress)
  }

  private func bounded(_ value: String, fallback: String) -> String {
    let normalized = value.components(separatedBy: .controlCharacters).joined(separator: " ")
      .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    var result = normalized.isEmpty ? fallback : normalized
    if result.contains("://") || result.lowercased().hasPrefix("file:") || result.hasPrefix("/") {
      result = fallback
    }
    while result.utf8.count > WatchProtocolVersion.maxMetadataStringBytes {
      result.removeLast()
    }
    return result.isEmpty ? fallback : result
  }

  private func first<Value: Sendable>(_ stream: AsyncStream<Value>) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
      group.addTask {
        for await value in stream { return value }
        return nil
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: self.readTimeoutNanoseconds)
        return nil
      }
      let result = await group.next() ?? nil
      group.cancelAll()
      return result
    }
  }
}
