import Foundation
import Persistence

/// Where the next page of a paged car list starts. Opaque: it comes from one page and is handed
/// back for the next.
public struct CarPlayBrowseCursor: Sendable, Hashable {
  enum Position: Sendable, Hashable {
    case audiobooks(AudiobookPageCursor)
    case entities(AudioEntityCursor)
    case entityBooks(AudioEntityBookCursor)
    case server(AudioBrowseCursor)
    /// The server's rows are exhausted; followed feeds start from their first row.
    case followedStart
    case followed(AudioBrowseCursor)
  }

  let route: CarPlayBrowseRoute
  let position: Position
}

public struct CarPlayBrowsePage: Sendable, Equatable {
  public let generation: Int
  public let route: CarPlayBrowseRoute
  public let rows: [CarPlayBrowseRow]
  /// Nil on the last page.
  public let next: CarPlayBrowseCursor?

  public init(generation: Int, route: CarPlayBrowseRoute, rows: [CarPlayBrowseRow], next: CarPlayBrowseCursor?) {
    self.generation = generation
    self.route = route
    self.rows = rows
    self.next = next
  }
}

public enum CarPlayBrowsePageRejection: Sendable, Equatable {
  /// The account graph was replaced before or during the read; its rows are dropped.
  case staleGeneration
  /// The list's order changed, or the cursor is another list's. Start again from the first page.
  case staleCursor
  /// The route is observed, not paged.
  case notPaged
  case unavailable
}

public enum CarPlayBrowsePageResult: Sendable, Equatable {
  case page(CarPlayBrowsePage)
  case rejected(CarPlayBrowsePageRejection)
}

extension CarPlayBrowseModel {
  /// One page of a paged route. `generation` is that of the snapshot, row or page that led here; a
  /// read from a replaced graph, before or while queued, is refused rather than shown under the
  /// new account. `pageSize` is what the car's item limit leaves room for
  /// (`CarPlayListLayout.pageSize`) and may differ between pages, as cursors ignore it.
  public func page(
    _ route: CarPlayBrowseRoute, after cursor: CarPlayBrowseCursor? = nil, generation: Int,
    pageSize: Int? = nil
  ) async -> CarPlayBrowsePageResult {
    let limit = min(max(1, pageSize ?? limit), Self.maximumPageSize)
    guard ownsGeneration(generation) else { return .rejected(.staleGeneration) }
    if let cursor, cursor.route != route { return .rejected(.staleCursor) }
    do {
      let page = try await read(route, after: cursor?.position, limit: limit)
      guard ownsGeneration(generation) else { return .rejected(.staleGeneration) }
      guard let page else { return .rejected(.notPaged) }
      return .page(
        CarPlayBrowsePage(
          generation: generation, route: route, rows: page.rows,
          next: page.next.map { CarPlayBrowseCursor(route: route, position: $0) }))
    } catch AudioBrowsePagingError.staleCursor {
      return .rejected(.staleCursor)
    } catch {
      return .rejected(.unavailable)
    }
  }

  private func ownsGeneration(_ generation: Int) -> Bool {
    generation == self.generation && currentGeneration() == self.generation
  }

  private typealias Rows = (rows: [CarPlayBrowseRow], next: CarPlayBrowseCursor.Position?)

  private func read(
    _ route: CarPlayBrowseRoute, after position: CarPlayBrowseCursor.Position?, limit: Int
  ) async throws -> Rows? {
    switch route {
    case .continueListening, .upNext, .recentBooks, .latestEpisodes:
      return nil
    case .authors:
      return try await entities(.author, after: position, limit: limit)
    case .series:
      return try await entities(.series, after: position, limit: limit)
    case .authorBooks(let name):
      return try await entityBooks(.author, name: name, after: position, limit: limit)
    case .seriesBooks(let name):
      return try await entityBooks(.series, name: name, after: position, limit: limit)
    case .audiobooks:
      let cursor: AudiobookPageCursor?
      switch position {
      case nil: cursor = nil
      case .audiobooks(let value): cursor = value
      default: throw AudioBrowsePagingError.staleCursor
      }
      let page = try await sources.audiobooks.audiobookPage(after: cursor, limit: limit)
      return (page.rows.map { Self.row($0) }, page.next.map { .audiobooks($0) })
    case .podcastShows:
      let server = sources.serverPodcasts
      let followed = sources.followedPodcasts
      return try await serverThenFollowed(
        after: position, limit: limit,
        server: { try await server.showPage(after: $0, limit: $1) },
        followed: { try await followed.showPage(after: $0, limit: $1) },
        row: Self.row)
    case .showEpisodes(let itemID):
      let isFollowed = PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil
      if isFollowed, await followedEnabled() == false { return ([], nil) }
      let reader = isFollowed ? sources.followedPodcasts : sources.serverPodcasts
      let cursor: AudioBrowseCursor?
      switch position {
      case nil: cursor = nil
      case .server(let value) where isFollowed == false: cursor = value
      case .followed(let value) where isFollowed: cursor = value
      default: throw AudioBrowsePagingError.staleCursor
      }
      let page = try await reader.episodePage(itemID: itemID, after: cursor, limit: limit)
      let today = now()
      return (
        page.rows.map { Self.row($0, now: today) }, page.next.map { isFollowed ? .followed($0) : .server($0) }
      )
    case .downloads:
      let server = sources.serverDownloads
      let followed = sources.followedDownloads
      return try await serverThenFollowed(
        after: position, limit: limit,
        server: { try await server.downloadedAudioPage(after: $0, limit: $1) },
        followed: { try await followed.downloadedAudioPage(after: $0, limit: $1) },
        row: Self.row)
    }
  }

  private func entities(
    _ kind: AudioEntityKind, after position: CarPlayBrowseCursor.Position?, limit: Int
  ) async throws -> Rows {
    let cursor: AudioEntityCursor?
    switch position {
    case nil: cursor = nil
    case .entities(let value): cursor = value
    default: throw AudioBrowsePagingError.staleCursor
    }
    let page = try await sources.entities.entityPage(kind: kind, after: cursor, limit: limit)
    return (page.rows.map(Self.row), page.next.map { .entities($0) })
  }

  private func entityBooks(
    _ kind: AudioEntityKind, name: String, after position: CarPlayBrowseCursor.Position?, limit: Int
  ) async throws -> Rows {
    let cursor: AudioEntityBookCursor?
    switch position {
    case nil: cursor = nil
    case .entityBooks(let value): cursor = value
    default: throw AudioBrowsePagingError.staleCursor
    }
    let page = try await sources.entities.entityBookPage(kind: kind, name: name, after: cursor, limit: limit)
    return (page.rows.map { Self.row($0, list: "\(kind.rawValue)|\(name)") }, page.next.map { .entityBooks($0) })
  }

  /// The server's rows in their order, then followed feeds' in theirs (the phone's per-source
  /// sections, read as one list). A page that the server ends part-way is topped up from followed
  /// feeds, so a page is short only when the whole list is ending.
  private func serverThenFollowed<Row: Sendable & Equatable>(
    after position: CarPlayBrowseCursor.Position?, limit: Int,
    server: (AudioBrowseCursor?, Int) async throws -> AudioBrowsePage<Row, AudioBrowseCursor>,
    followed: (AudioBrowseCursor?, Int) async throws -> AudioBrowsePage<Row, AudioBrowseCursor>,
    row: (Row) -> CarPlayBrowseRow
  ) async throws -> Rows {
    var rows: [CarPlayBrowseRow] = []
    var followedCursor: AudioBrowseCursor?
    switch position {
    case .audiobooks, .entities, .entityBooks:
      throw AudioBrowsePagingError.staleCursor
    case nil, .server:
      var serverCursor: AudioBrowseCursor?
      if case .server(let value) = position { serverCursor = value }
      let page = try await server(serverCursor, limit)
      rows = page.rows.map(row)
      if let next = page.next { return (rows, .server(next)) }
    case .followedStart:
      break
    case .followed(let value):
      followedCursor = value
    }

    guard await followedEnabled() else { return (rows, nil) }
    let remaining = limit - rows.count
    guard remaining > 0 else {
      // The page is full: say whether followed feeds have anything, so the car is never handed
      // a cursor to an empty page.
      return (rows, try await followed(nil, 1).rows.isEmpty ? nil : .followedStart)
    }
    let page = try await followed(followedCursor, remaining)
    return (rows + page.rows.map(row), page.next.map { .followed($0) })
  }

  /// The subscriptions gate as Continue saw it, or its first value when Continue has not
  /// started.
  private func followedEnabled() async -> Bool {
    if let nativeEnabled { return nativeEnabled }
    for await enabled in nativeSubscriptions.observeEnabledOrFalse() { return enabled }
    return false
  }

  private static func row(_ book: AudiobookPageRow, list: String = "book") -> CarPlayBrowseRow {
    // In a series the book's number is what the listener is looking for, so it leads.
    let subtitle = [book.seriesSequence.map { "Book \($0)" }, book.author].compactMap { $0 }
    return CarPlayBrowseRow(
      id: "\(list)|\(book.identity.itemID)", identity: book.identity, title: book.title,
      subtitle: subtitle.isEmpty ? nil : subtitle.joined(separator: " · "),
      artwork: .item(id: book.identity.itemID, updatedAt: book.serverUpdatedAt))
  }

  /// An author or a series is opened, never played.
  private static func row(_ entity: AudioEntityPageRow) -> CarPlayBrowseRow {
    let child: CarPlayBrowseRoute =
      switch entity.kind {
      case .author: .authorBooks(name: entity.name)
      case .series: .seriesBooks(name: entity.name)
      }
    return CarPlayBrowseRow(
      id: "\(entity.kind.rawValue)|\(entity.name)", identity: nil, title: entity.name,
      subtitle: entity.bookCount == 1 ? "1 book" : "\(entity.bookCount) books", artwork: .none, child: child)
  }

  /// A show is opened, never played: a whole show is not a listening identity.
  private static func row(_ show: ItemSummary) -> CarPlayBrowseRow {
    CarPlayBrowseRow(
      id: "show|\(show.serverItemId)", identity: nil, title: show.title, subtitle: show.author,
      artwork: show.artworkURL.map { .feed(itemID: show.serverItemId, url: $0, feedURL: show.artworkFeedURL) }
        ?? .item(id: show.serverItemId, updatedAt: show.serverUpdatedAt),
      child: .showEpisodes(itemID: show.serverItemId))
  }

  private static func row(_ episode: PodcastEpisodePageRow, now: Date) -> CarPlayBrowseRow {
    let detail = CarPlayEpisodeDetail(
      publishedAt: episode.publishedAt, durationSeconds: episode.durationSeconds,
      progressSeconds: episode.progressSeconds, isFinished: episode.isFinished, now: now)
    return CarPlayBrowseRow(
      id: "episode|\(episode.identity.itemID)|\(episode.identity.episodeID ?? "")",
      identity: episode.identity, title: episode.title, subtitle: detail.text, artwork: .none,
      isDownloaded: episode.audioDownloaded,
      isAvailable: episode.audioDownloaded || episode.isAvailableOnServer, progress: detail.progress)
  }

  private static func row(_ download: DownloadedAudioPageRow) -> CarPlayBrowseRow {
    CarPlayBrowseRow(
      id: "download|\(download.identity.itemID)|\(download.identity.episodeID ?? "")",
      identity: download.identity, title: download.title, subtitle: download.subtitle,
      artwork: download.artworkURL.map {
        .feed(itemID: download.identity.itemID, url: $0, feedURL: download.artworkFeedURL)
      } ?? .item(id: download.identity.itemID, updatedAt: download.serverUpdatedAt),
      isDownloaded: true)
  }
}
