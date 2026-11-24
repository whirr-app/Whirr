import ABSApi
import Foundation

/// Complete, account-fenced catalogue operations used by the Watch browse screens. The page
/// methods fetch the complete bounded result before slicing: server page order is
/// not a substitute for applying a search or sort to every page.
extension WatchLibraryClient {
  public func episodes(for itemID: String, page: Int = 0, limit: Int = 100) async throws -> [WatchEpisode] {
    guard page >= 0, page <= 10_000 else { throw WatchLibraryError.invalidPage }
    let count = min(max(1, limit), Self.maximumPageSize)
    let account = try authenticatedAccount()
    let detail = try await service.detail(account: account, itemID: itemID)
    guard case .podcast(let podcast)? = detail.media else {
      return []
    }
    return podcast.episodes.dropFirst(page * count).prefix(count).compactMap { episode in
      projectEpisode(episode, itemID: itemID)
    }
  }

  public func browseAudiobooks(
    libraryID: String,
    query: String? = nil,
    sort: WatchAudiobookSort = .title,
    startsWith: String? = nil,
    page: Int = 0,
    limit: Int = 40
  ) async throws -> WatchLibraryBrowsePage<WatchLibraryItem> {
    let books = try await allBrowseItems(
      // Local ordering is applied after the complete traversal. One title-sorted cache serves
      // title/author/recent choices and prevents a search keystroke from restarting traversal.
      libraryID: libraryID, kind: .audiobook, serverSort: "title")
    let query = normalizedQuery(query)
    let filtered = books.filter { item in
      guard !query.isEmpty else { return true }
      return [item.title, item.author, item.series].compactMap { $0?.lowercased() }
        .contains { $0.localizedCaseInsensitiveContains(query) }
    }
    let ordered: [WatchLibraryItem]
    switch sort {
    case .title:
      ordered = filtered.sorted { compare($0.sortTitle, $1.sortTitle, tie: $0.id, $1.id) }
    case .author:
      ordered = filtered.sorted {
        if $0.authorSortKey != $1.authorSortKey {
          return compare($0.authorSortKey, $1.authorSortKey, tie: "", "")
        }
        if $0.sortTitle != $1.sortTitle {
          return compare($0.sortTitle, $1.sortTitle, tie: "", "")
        }
        return $0.id < $1.id
      }
    case .recentlyAdded:
      ordered = filtered.sorted {
        if $0.addedAt != $1.addedAt { return ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        return $0.id < $1.id
      }
    }
    let prefix = normalizedQuery(startsWith)
    let prefixed =
      prefix.isEmpty
      ? ordered
      : ordered.filter {
        let key = sort == .author ? $0.authorSortKey : $0.sortTitle.lowercased()
        return key.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
          .hasPrefix(prefix.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
      }
    return slice(prefixed, page: page, limit: limit)
  }

  public func browseAuthors(
    libraryID: String, query: String? = nil, page: Int = 0, limit: Int = 40
  ) async throws -> WatchLibraryBrowsePage<WatchBrowseAuthor> {
    let entries = try await browseEntityIndex(libraryID: libraryID, query: query, authors: true)
    return slice(
      entries.map { WatchBrowseAuthor(id: $0.id, name: $0.name, bookCount: $0.count) }, page: page, limit: limit)
  }

  public func browseSeries(
    libraryID: String, query: String? = nil, page: Int = 0, limit: Int = 40
  ) async throws -> WatchLibraryBrowsePage<WatchBrowseSeries> {
    let entries = try await browseEntityIndex(libraryID: libraryID, query: query, authors: false)
    return slice(
      entries.map { WatchBrowseSeries(id: $0.id, name: $0.name, bookCount: $0.count) }, page: page, limit: limit)
  }

  public func browseSeriesBooks(
    libraryID: String, seriesID: String, page: Int = 0, limit: Int = 40
  ) async throws -> WatchLibraryBrowsePage<WatchLibraryItem> {
    guard !seriesID.isEmpty else { throw WatchLibraryError.invalidPage }
    let books = try await allBrowseItems(
      libraryID: libraryID, kind: .audiobook, serverSort: "sequence",
      filter: LibraryItemFilter(group: "series", value: seriesID))
    // ABS's sequence sort is numeric and is the authoritative value even though the minified
    // shape does not expose the sequence field. Keep response order and only use a deterministic
    // id tie-breaker where a server gives an unordered page.
    return slice(books, page: page, limit: limit)
  }

  public func browseAuthorBooks(
    libraryID: String, authorID: String, page: Int = 0, limit: Int = 40
  ) async throws -> WatchLibraryBrowsePage<WatchLibraryItem> {
    guard !authorID.isEmpty else { throw WatchLibraryError.invalidPage }
    let books = try await allBrowseItems(
      libraryID: libraryID, kind: .audiobook, serverSort: "title",
      filter: LibraryItemFilter(group: "authors", value: authorID))
    let ordered = books.sorted { compare($0.sortTitle, $1.sortTitle, tie: $0.id, $1.id) }
    return slice(ordered, page: page, limit: limit)
  }

  public func browsePodcastShows(
    libraryID: String, query: String? = nil, page: Int = 0, limit: Int = 40
  ) async throws -> WatchLibraryBrowsePage<WatchPodcastShow> {
    let shows = try await allBrowseItems(libraryID: libraryID, kind: .podcast, serverSort: "title")
      .compactMap { item -> WatchPodcastShow? in
        guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
          return nil
        }
        return WatchPodcastShow(
          id: item.id, title: title, author: item.author, episodeCount: max(0, item.episodeCount ?? 0),
          selection: item.selection)
      }
    let query = normalizedQuery(query)
    let filtered = shows.filter {
      query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
        || ($0.author?.localizedCaseInsensitiveContains(query) ?? false)
    }.sorted { compare($0.sortTitle, $1.sortTitle, tie: $0.id, $1.id) }
    return slice(filtered, page: page, limit: limit)
  }

  public func browsePodcastEpisodes(
    libraryID: String,
    showID: String,
    sort: WatchPodcastEpisodeSort = .newest,
    filter: WatchPodcastEpisodeFilter = .all,
    page: Int = 0,
    limit: Int = 40
  ) async throws -> WatchLibraryBrowsePage<WatchPodcastBrowseEpisode> {
    let account = try authenticatedAccount()
    let requestGeneration = generation
    let detail = try await service.detail(account: account, itemID: showID)
    guard case .podcast(let podcast)? = detail.media else { return slice([], page: page, limit: limit) }
    let progress = try await service.progress(account: account)
    guard requestGeneration == generation else { throw WatchLibraryError.staleRequest }
    let progressByEpisode = progress.progress.reduce(into: [String: MediaProgress]()) { result, row in
      guard row.libraryItemID == showID, let episodeID = row.episodeID else { return }
      result[progressKey(showID, episodeID)] = row
    }
    let title = podcast.title ?? "Untitled show"
    let finished = progressByEpisode.mapValues(\.isFinished)
    var episodes = podcast.episodes.filter {
      includesPodcastEpisode(progressByEpisode[progressKey(showID, $0.id)], filter: filter)
    }.compactMap {
      makePodcastEpisode($0, showID: showID, showTitle: title, finished: finished)
    }
    episodes.sort {
      if dateComesBefore($0.publishedAt, $1.publishedAt, newest: sort == .newest) { return true }
      if dateComesBefore($1.publishedAt, $0.publishedAt, newest: sort == .newest) { return false }
      return $0.id < $1.id
    }
    return slice(episodes, page: page, limit: limit)
  }

  public func browseRecentPodcastEpisodes(
    libraryID: String,
    filter: WatchPodcastEpisodeFilter = .unplayed,
    page: Int = 0,
    limit: Int = 40
  ) async throws -> WatchLibraryBrowsePage<WatchPodcastBrowseEpisode> {
    let account = try authenticatedAccount()
    let requestGeneration = generation
    let pageSize = min(max(1, Self.maximumPageSize), 100)
    let source: [RecentEpisode] = try await WatchPageCollector.collect(
      client: self, generation: requestGeneration, pageSize: pageSize,
      pageLimit: WatchPageCollectorLimits.maximumItems, requiresTotal: false,
      identity: { "\($0.libraryItemID)\u{1f}\($0.episode.id)" },
      fetch: { page in
        let rows = try await service.recentEpisodes(
          account: account, libraryID: libraryID, page: page, limit: pageSize)
        return (rows, nil)
      })
    let progress = try await service.progress(account: account)
    guard requestGeneration == generation else { throw WatchLibraryError.staleRequest }
    let progressByEpisode = progress.progress.reduce(into: [String: MediaProgress]()) { result, row in
      guard let episodeID = row.episodeID else { return }
      result[progressKey(row.libraryItemID, episodeID)] = row
    }
    let finished = progressByEpisode.mapValues(\.isFinished)
    let episodes = source.filter {
      includesPodcastEpisode(progressByEpisode[progressKey($0.libraryItemID, $0.episode.id)], filter: filter)
    }.compactMap {
      makePodcastEpisode(
        $0.episode, showID: $0.libraryItemID, showTitle: $0.showTitle ?? "Untitled show", finished: finished)
    }.sorted {
      let lhs = $0.publishedAt
      let rhs = $1.publishedAt
      if dateComesBefore(lhs, rhs, newest: true) { return true }
      if dateComesBefore(rhs, lhs, newest: true) { return false }
      return $0.id < $1.id
    }
    return slice(episodes, page: page, limit: limit)
  }

  private func includesPodcastEpisode(_ progress: MediaProgress?, filter: WatchPodcastEpisodeFilter) -> Bool {
    let finished = progress?.isFinished == true
    // An explicit zero position wins over an older fraction after a reset to unplayed.
    let position = progress?.currentTime ?? progress?.progress ?? 0
    let started = position.isFinite && position > 0
    switch filter {
    case .inProgress: return started && !finished
    case .unplayed: return !started && !finished
    case .all: return true
    }
  }
}

extension WatchLibraryClient {
  fileprivate func allBrowseItems(
    libraryID: String,
    kind: WatchMediaKind,
    serverSort: String,
    filter: LibraryItemFilter? = nil
  ) async throws -> [WatchLibraryItem] {
    let account = try authenticatedAccount()
    let requestGeneration = generation
    guard requestGeneration == generation else { throw WatchLibraryError.staleRequest }
    let cacheKey = "\(libraryID)|\(kind.rawValue)|\(serverSort)|\(filter?.queryValue ?? "all")"
    if let cached = browseCache[cacheKey] { return cached }
    let requestLimit = Self.maximumPageSize
    let raw: [LibraryItemSummary] = try await WatchPageCollector.collect(
      client: self, generation: requestGeneration, pageSize: requestLimit,
      pageLimit: WatchPageCollectorLimits.maximumPages, requiresTotal: true, identity: { $0.id },
      fetch: { page in
        let response = try await service.page(
          account: account, libraryID: libraryID, page: page, limit: requestLimit,
          sort: serverSort, filter: filter)
        return (Array(response.items.prefix(requestLimit)), response.total)
      })
    var result: [WatchLibraryItem] = []
    result.reserveCapacity(min(raw.count, WatchPageCollectorLimits.maximumItems))
    for summary in raw {
      try Task.checkCancellation()
      guard let item = try await makeBrowseItem(summary, account: account), item.kind == kind else { continue }
      result.append(item)
    }
    guard requestGeneration == generation else { throw WatchLibraryError.staleRequest }
    if browseCache[cacheKey] == nil {
      while browseCacheOrder.count >= WatchPageCollectorLimits.maximumCacheEntries
        || browseCacheRowCount + result.count > WatchPageCollectorLimits.maximumCacheRows
      {
        let evicted = browseCacheOrder.removeFirst()
        browseCacheRowCount -= browseCache[evicted]?.count ?? 0
        browseCache.removeValue(forKey: evicted)
      }
      browseCacheOrder.append(cacheKey)
      browseCacheRowCount += result.count
    } else if let previous = browseCache[cacheKey] {
      browseCacheRowCount += result.count - previous.count
    }
    browseCache[cacheKey] = result
    return result
  }

  fileprivate func makeBrowseItem(_ summary: LibraryItemSummary, account: TokenAccount) async throws
    -> WatchLibraryItem?
  {
    guard !summary.id.isEmpty else { return nil }
    if summary.mediaType?.lowercased() == "podcast" {
      return WatchLibraryItem(
        id: summary.id, libraryID: summary.libraryID ?? "", kind: .podcast, title: summary.title,
        author: summary.authorName, selection: .audiobookshelf(itemID: summary.id, episodeID: nil),
        durationSeconds: summary.durationSeconds, episodeCount: summary.podcastEpisodeCount,
        series: nil, addedAt: summary.addedAt)
    }
    guard summary.mediaType?.lowercased() == "book" else { return nil }
    let detail: BookMedia?
    if let count = summary.numAudioFiles {
      guard count > 0 else { return nil }
      detail = nil
    } else {
      // A missing minified count is unknown, not ebook-only. Inspect expanded metadata so a mixed
      // record with valid audio evidence is retained while an unknown record remains unplayable.
      guard case .book(let book)? = (try await service.detail(account: account, itemID: summary.id)).media,
        book.audioFiles.files.isEmpty == false || book.tracks.isEmpty == false
      else { return nil }
      detail = book
    }
    return WatchLibraryItem(
      id: summary.id, libraryID: summary.libraryID ?? "", kind: .audiobook,
      title: summary.title ?? detail?.title, author: summary.authorName ?? detail?.authorName,
      selection: .audiobookshelf(itemID: summary.id, episodeID: nil),
      durationSeconds: summary.durationSeconds ?? detail?.duration,
      episodeCount: nil, series: summary.seriesName ?? detail?.seriesName, addedAt: summary.addedAt)
  }

  private func browseEntityIndex(
    libraryID: String, query: String?, authors: Bool
  ) async throws -> [(id: String, name: String, count: Int)] {
    let requestGeneration = generation
    let books = try await allBrowseItems(libraryID: libraryID, kind: .audiobook, serverSort: "title")
    guard requestGeneration == generation else { throw WatchLibraryError.staleRequest }
    var counts: [String: Set<String>] = [:]
    for book in books {
      let names = authors ? authorNames(book.author) : seriesDescriptor(book.series).map { [$0.name] } ?? []
      for name in names { counts[canonical(name), default: []].insert(book.id) }
    }
    let data = try await service.filterData(account: try authenticatedAccount(), libraryID: libraryID)
    guard requestGeneration == generation else { throw WatchLibraryError.staleRequest }
    let index: [(id: String, name: String?)] =
      authors
      ? data.authors.map { ($0.id, $0.name) }
      : data.series.map { ($0.id, $0.name) }
    let query = normalizedQuery(query)
    return index.compactMap { entry -> (id: String, name: String, count: Int)? in
      guard !entry.id.isEmpty,
        let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
        let visible = counts[canonical(name)], !visible.isEmpty,
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
      else { return nil }
      return (entry.id, name, visible.count)
    }.sorted { compare($0.name, $1.name, tie: $0.id, $1.id) }
  }

  private func projectEpisode(_ episode: PodcastEpisode, itemID: String) -> WatchEpisode {
    WatchEpisode(
      id: episode.id, parentItemID: itemID, title: episode.title,
      selection: .audiobookshelf(itemID: itemID, episodeID: episode.id),
      durationSeconds: episode.duration, publishedAt: episode.publishedAt,
      audio: episode.audioFile.map {
        WatchAudioDescription(
          fileIdentity: $0.ino, expectedSize: $0.expectedSize, mimeType: $0.mimeType,
          durationSeconds: $0.duration)
      })
  }

  fileprivate func makePodcastEpisode(
    _ episode: PodcastEpisode,
    showID: String,
    showTitle: String,
    finished: [String: Bool]
  ) -> WatchPodcastBrowseEpisode? {
    guard !episode.id.isEmpty, let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines),
      !title.isEmpty
    else { return nil }
    let projection = projectEpisode(episode, itemID: showID)
    return WatchPodcastBrowseEpisode(
      // Episode ids are only unique within a show. Keep the public identity scoped so a recent
      // feed containing two shows cannot collapse equal episode ids during model pagination.
      id: progressKey(showID, episode.id), showID: showID, showTitle: showTitle, title: title,
      selection: projection.selection, durationSeconds: projection.durationSeconds,
      publishedAt: projection.publishedAt, isFinished: finished[progressKey(showID, episode.id)] ?? false,
      audio: projection.audio)
  }

  fileprivate func slice<T: Sendable & Equatable>(_ values: [T], page: Int, limit: Int) -> WatchLibraryBrowsePage<T> {
    let safePage = max(0, page)
    let safeLimit = min(max(1, limit), Self.maximumPageSize)
    // Avoid overflowing an arbitrary public page argument before clamping to the available
    // result range. A page beyond the end is simply empty and still reports the safe page.
    let start = safePage > values.count / safeLimit ? values.count : safePage * safeLimit
    let end = min(values.count, start + safeLimit)
    return WatchLibraryBrowsePage(
      items: Array(values[start..<end]), total: values.count, limit: safeLimit, page: safePage,
      hasMore: end < values.count)
  }

  fileprivate func normalizedQuery(_ value: String?) -> String {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
  }

  fileprivate func canonical(_ value: String?) -> String {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
  }

  fileprivate func progressKey(_ showID: String, _ episodeID: String) -> String { "\(showID)\u{1f}\(episodeID)" }

  fileprivate func authorNames(_ value: String?) -> [String] {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
    let components = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return components.count > 1 ? [raw] + components : [raw]
  }

  fileprivate func seriesDescriptor(_ value: String?) -> (name: String, sequence: Double?, key: String)? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    guard let hash = raw.lastIndex(of: "#") else { return (raw, nil, canonical(raw)) }
    let suffix = raw[raw.index(after: hash)...].trimmingCharacters(in: .whitespacesAndNewlines)
    let name = raw[..<hash].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let sequence = Double(suffix) else { return (raw, nil, canonical(raw)) }
    return (name, sequence, canonical(name))
  }

  fileprivate func compare(_ lhs: String, _ rhs: String, tie lhsTie: String, _ rhsTie: String) -> Bool {
    let left = lhs.localizedStandardCompare(rhs)
    if left != .orderedSame { return left == .orderedAscending }
    return lhsTie.localizedStandardCompare(rhsTie) == .orderedAscending
  }

  fileprivate func dateComesBefore(_ lhs: Date?, _ rhs: Date?, newest: Bool) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return false
    case (nil, _): return false
    case (_, nil): return true
    case (let left?, let right?): return newest ? left > right : left < right
    }
  }
}
