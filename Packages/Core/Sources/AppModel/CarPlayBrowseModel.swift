import Foundation
import Observation
import Persistence

/// A list the car can show. The first four are short and observed; the rest are read a page at
/// a time through `CarPlayBrowseModel.page(_:after:generation:)`.
public enum CarPlayBrowseRoute: Sendable, Hashable {
  case continueListening
  case upNext
  case recentBooks
  /// The newest episodes left to hear, across every show.
  case latestEpisodes
  case audiobooks
  case authors
  case series
  /// An author's or a series' audiobooks. Named, not numbered: the lists are built from the
  /// names on the device's own books (`AudioEntityPaging`).
  case authorBooks(name: String)
  case seriesBooks(name: String)
  case podcastShows
  case showEpisodes(itemID: String)
  case downloads
}

/// Where a row's artwork comes from, without resolving it: ABS covers are addressed by item and
/// revision, native-feed artwork by URL under its feed's credential origin. The feed case keeps
/// the item so the loader can name the feed the artwork belongs to.
public enum CarPlayArtworkReference: Sendable, Hashable {
  case none
  case item(id: String, updatedAt: Date?)
  case feed(itemID: String, url: URL, feedURL: URL?)
}

/// One small immutable row. `identity` is what a tap plays; a row whose stored identifiers do
/// not resolve to one is shown disabled and never guessed at.
public struct CarPlayBrowseRow: Sendable, Equatable, Identifiable {
  public let id: String
  public let identity: ListeningIdentity?
  /// The chapter an Up Next chapter row plays, with its row; nil for every other row.
  public let chapter: ListeningQueueRowChapter?
  public let title: String
  public let subtitle: String?
  public let artwork: CarPlayArtworkReference
  /// The list a tap opens instead of playing: a show's episodes, an author's or a series' books.
  public let child: CarPlayBrowseRoute?
  /// How much of the row has been heard, from 0 to 1; nil for a row that shows no progress.
  public let progress: Double?
  /// The row's own audio is fully on the device.
  public let isDownloaded: Bool
  /// False when the audio is neither on the device nor still offered by its origin.
  public let isAvailable: Bool

  public var isPlayable: Bool { identity != nil && isAvailable }

  public init(
    id: String, identity: ListeningIdentity?, title: String, subtitle: String?,
    artwork: CarPlayArtworkReference, child: CarPlayBrowseRoute? = nil, isDownloaded: Bool = false,
    isAvailable: Bool = true, progress: Double? = nil, chapter: ListeningQueueRowChapter? = nil
  ) {
    self.id = id
    self.identity = identity
    self.chapter = chapter
    self.title = title
    self.subtitle = subtitle
    self.artwork = artwork
    self.child = child
    self.isDownloaded = isDownloaded
    self.isAvailable = isAvailable
    self.progress = progress
  }
}

/// What one route shows right now. `generation` is the runtime generation the rows were read in;
/// a tap hands it back to `CarPlayPlaybackActions`, which refuses a row from a replaced graph.
public struct CarPlayBrowseSnapshot: Sendable, Equatable {
  public enum Content: Sendable, Equatable {
    /// Not every source has delivered yet; distinct from a list that is known to be empty.
    case loading
    case rows([CarPlayBrowseRow])
  }

  public let generation: Int
  public let route: CarPlayBrowseRoute
  public let content: Content

  public init(generation: Int, route: CarPlayBrowseRoute, content: Content) {
    self.generation = generation
    self.route = route
    self.content = content
  }
}

/// The bounded reads behind the car's lists, built per account graph.
public struct CarPlayBrowseSources: Sendable {
  public let queue: any ListeningQueuePrefixReading
  public let audiobooks: any AudioBrowsePaging
  public let entities: any AudioEntityPaging
  public let serverPodcasts: any PodcastBrowsePaging
  public let followedPodcasts: any PodcastBrowsePaging
  public let serverDownloads: any DownloadedAudioPaging
  public let followedDownloads: any DownloadedAudioPaging

  public init(
    queue: any ListeningQueuePrefixReading,
    audiobooks: any AudioBrowsePaging,
    entities: any AudioEntityPaging,
    serverPodcasts: any PodcastBrowsePaging,
    followedPodcasts: any PodcastBrowsePaging,
    serverDownloads: any DownloadedAudioPaging,
    followedDownloads: any DownloadedAudioPaging
  ) {
    self.queue = queue
    self.audiobooks = audiobooks
    self.entities = entities
    self.serverPodcasts = serverPodcasts
    self.followedPodcasts = followedPodcasts
    self.serverDownloads = serverDownloads
    self.followedDownloads = followedDownloads
  }

  /// Every list empty: the default for a graph with no signed-in account.
  public static let empty = CarPlayBrowseSources(
    queue: NoOpListeningQueueStore(), audiobooks: EmptyBrowsePaging(), entities: EmptyBrowsePaging(),
    serverPodcasts: EmptyBrowsePaging(), followedPodcasts: EmptyBrowsePaging(),
    serverDownloads: EmptyBrowsePaging(), followedDownloads: EmptyBrowsePaging())
}

private struct EmptyBrowsePaging: AudioBrowsePaging, AudioEntityPaging, PodcastBrowsePaging,
  DownloadedAudioPaging
{
  func entityPage(
    kind: AudioEntityKind, after cursor: AudioEntityCursor?, limit: Int
  ) async throws -> AudioBrowsePage<AudioEntityPageRow, AudioEntityCursor> { .init(rows: [], next: nil) }

  func entityBookPage(
    kind: AudioEntityKind, name: String, after cursor: AudioEntityBookCursor?, limit: Int
  ) async throws -> AudioBrowsePage<AudiobookPageRow, AudioEntityBookCursor> { .init(rows: [], next: nil) }

  func audiobookPage(
    after cursor: AudiobookPageCursor?, limit: Int
  ) async throws -> AudioBrowsePage<AudiobookPageRow, AudiobookPageCursor> { .init(rows: [], next: nil) }

  func showPage(
    after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<ItemSummary, AudioBrowseCursor> { .init(rows: [], next: nil) }

  func episodePage(
    itemID: String, after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<PodcastEpisodePageRow, AudioBrowseCursor> { .init(rows: [], next: nil) }

  func downloadedAudioPage(
    after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<DownloadedAudioPageRow, AudioBrowseCursor> { .init(rows: [], next: nil) }
}

/// The car's lists for one account graph, read through the same boundaries Home uses so the car
/// never offers a row the phone's Continue hides. It holds no phone screen model.
@MainActor
@Observable
public final class CarPlayBrowseModel {
  /// A car list is short by contract; the readers are asked for no more than this.
  public static let defaultRowLimit = 12
  /// The most rows one paged read returns, whatever the car's own limit allows.
  public static let maximumPageSize = 40
  /// New Episodes leads the Podcasts tab and shares its item slots with the shows beneath.
  public static let latestEpisodeLimit = 10

  public let generation: Int
  public private(set) var continueListening: CarPlayBrowseSnapshot
  public private(set) var upNext: CarPlayBrowseSnapshot
  public private(set) var recentBooks: CarPlayBrowseSnapshot
  public private(set) var latestEpisodes: CarPlayBrowseSnapshot

  @ObservationIgnored let currentGeneration: @MainActor () -> Int
  @ObservationIgnored let sources: CarPlayBrowseSources
  @ObservationIgnored let nativeSubscriptions: any NativePodcastSubscriptionsReading
  @ObservationIgnored let limit: Int
  @ObservationIgnored var nativeEnabled: Bool?
  @ObservationIgnored private let home: any HomeReading
  @ObservationIgnored private let nativeContinueListening: any NativeContinueListeningReading
  @ObservationIgnored private let nativeLatestEpisodes: any NativeLatestPodcastEpisodesReading
  @ObservationIgnored let now: @Sendable () -> Date
  @ObservationIgnored private var latestObservations = FilterObservationCoordinator()
  @ObservationIgnored private var latestABSEpisodes: HomeLatestPodcastEpisodesSnapshot?
  @ObservationIgnored private var latestRSSEpisodes: [HomePodcastEpisode]?
  @ObservationIgnored private var latestNativeEnabled: Bool?
  @ObservationIgnored private var continueObservations = FilterObservationCoordinator()
  @ObservationIgnored private var queueObservations = FilterObservationCoordinator()
  @ObservationIgnored private var recentObservations = FilterObservationCoordinator()
  @ObservationIgnored private var isStarted = false
  @ObservationIgnored private var latestABS: [HomeItem]?
  @ObservationIgnored private var latestRSS: [HomeItem]?

  /// `currentGeneration` is the runtime's live generation; a page read is dropped once it no
  /// longer equals `generation`.
  public init(
    generation: Int,
    currentGeneration: @escaping @MainActor () -> Int,
    home: any HomeReading,
    nativeContinueListening: any NativeContinueListeningReading,
    nativeLatestEpisodes: any NativeLatestPodcastEpisodesReading,
    nativeSubscriptions: any NativePodcastSubscriptionsReading,
    sources: CarPlayBrowseSources,
    limit: Int = CarPlayBrowseModel.defaultRowLimit,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.generation = generation
    self.currentGeneration = currentGeneration
    self.home = home
    self.nativeContinueListening = nativeContinueListening
    self.nativeLatestEpisodes = nativeLatestEpisodes
    self.now = now
    self.nativeSubscriptions = nativeSubscriptions
    self.sources = sources
    self.limit = max(0, limit)
    continueListening = .init(generation: generation, route: .continueListening, content: .loading)
    upNext = .init(generation: generation, route: .upNext, content: .loading)
    recentBooks = .init(generation: generation, route: .recentBooks, content: .loading)
    latestEpisodes = .init(generation: generation, route: .latestEpisodes, content: .loading)
  }

  /// The observed lists. A paged route has no standing snapshot and answers nil.
  public func snapshot(for route: CarPlayBrowseRoute) -> CarPlayBrowseSnapshot? {
    switch route {
    case .continueListening: continueListening
    case .upNext: upNext
    case .recentBooks: recentBooks
    case .latestEpisodes: latestEpisodes
    case .audiobooks, .authors, .series, .authorBooks, .seriesBooks, .podcastShows, .showEpisodes, .downloads:
      nil
    }
  }

  /// Begins observing. Idempotent; the observations end with the model.
  public func start() {
    guard isStarted == false else { return }
    isStarted = true

    let continuing = continueObservations.begin(sourceCount: 3)
    // `category: nil` is the one bounded stream that carries audiobooks and podcast episodes
    // together, with the finished, hidden and minimum-remaining rules applied in SQL.
    continueObservations.observe(
      home.observeContinueListening(category: nil, limit: limit), sourceID: 0, in: continuing
    ) { [weak self] items, _ in
      self?.latestABS = items
      self?.publishContinueListening()
    }
    continueObservations.observe(
      nativeContinueListening.observeContinueListening(limit: limit), sourceID: 1, in: continuing
    ) { [weak self] items, _ in
      self?.latestRSS = items
      self?.publishContinueListening()
    }
    continueObservations.observe(
      nativeSubscriptions.observeEnabledOrFalse(), sourceID: 2, in: continuing
    ) { [weak self] enabled, _ in
      self?.nativeEnabled = enabled
      self?.publishContinueListening()
    }

    // Tombstones are withdrawn rows that sync may revive; the read leaves them out before its
    // limit, so the car never loads the whole queue to show a few rows.
    let queued = queueObservations.begin(sourceCount: 1)
    queueObservations.observe(
      sources.queue.observeLiveQueue(limit: limit), sourceID: 0, in: queued
    ) { [weak self] items, _ in
      self?.set(\.upNext, route: .upNext, rows: items.map(Self.row))
    }

    let recent = recentObservations.begin(sourceCount: 1)
    recentObservations.observe(
      home.observeRecentlyAdded(category: .audiobook, limit: limit), sourceID: 0, in: recent
    ) { [weak self] snapshot, _ in
      self?.set(\.recentBooks, route: .recentBooks, rows: snapshot.all.map { Self.row($0, list: "recent") })
    }

    // The phone's Latest Episodes sources and merge: both readers leave out finished episodes
    // and ones inside their last minute before their limit, and the window moves with the clock.
    let now = now
    let cutoff: @Sendable () -> Date = { HomeRecency.cutoff(now: now()) }
    let latestLimit = min(limit, Self.latestEpisodeLimit)
    let latest = latestObservations.begin(sourceCount: 3)
    latestObservations.observe(
      home.observeNewPodcastEpisodes(cutoff: cutoff, limit: latestLimit), sourceID: 0, in: latest
    ) { [weak self] snapshot, _ in
      self?.latestABSEpisodes = snapshot
      self?.publishLatestEpisodes(limit: latestLimit)
    }
    latestObservations.observe(
      nativeLatestEpisodes.observeLatestPodcastEpisodes(cutoff: cutoff, limit: latestLimit), sourceID: 1,
      in: latest
    ) { [weak self] episodes, _ in
      self?.latestRSSEpisodes = episodes
      self?.publishLatestEpisodes(limit: latestLimit)
    }
    latestObservations.observe(
      nativeSubscriptions.observeEnabledOrFalse(), sourceID: 2, in: latest
    ) { [weak self] enabled, _ in
      self?.latestNativeEnabled = enabled
      self?.publishLatestEpisodes(limit: latestLimit)
    }
  }

  private func publishLatestEpisodes(limit: Int) {
    guard let latestABSEpisodes, let latestRSSEpisodes, let latestNativeEnabled else { return }
    let merged = LatestPodcastEpisodesMerge.merge(
      snapshot: latestABSEpisodes, rss: latestRSSEpisodes, nativeSubscriptionsEnabled: latestNativeEnabled,
      limit: limit)
    let today = now()
    set(\.latestEpisodes, route: .latestEpisodes, rows: merged.map { Self.row($0, now: today) })
  }

  private static func row(_ episode: HomePodcastEpisode, now: Date) -> CarPlayBrowseRow {
    let artwork: CarPlayArtworkReference =
      episode.artworkURL.map { .feed(itemID: episode.itemID, url: $0, feedURL: episode.artworkFeedURL) }
      ?? .item(id: episode.itemID, updatedAt: episode.showServerUpdatedAt)
    let detail = CarPlayEpisodeDetail(
      publishedAt: episode.publishedAt, durationSeconds: episode.durationSeconds,
      progressSeconds: episode.progressSeconds, isFinished: episode.isFinished, now: now)
    // Across shows the show's name is what tells two rows apart, so it leads.
    let subtitle = [episode.showTitle, detail.text].compactMap { $0?.isEmpty == false ? $0 : nil }
    return CarPlayBrowseRow(
      id: "latest|\(episode.itemID)|\(episode.episodeID)",
      identity: ListeningIdentity.resolving(itemID: episode.itemID, episodeID: episode.episodeID),
      title: episode.title, subtitle: subtitle.isEmpty ? nil : subtitle.joined(separator: " · "),
      artwork: artwork, progress: detail.progress)
  }

  private func publishContinueListening() {
    guard let latestABS, let latestRSS, let nativeEnabled else { return }
    let merged = ContinueListeningMerge.merge(
      abs: latestABS, rss: latestRSS, nativeSubscriptionsEnabled: nativeEnabled, limit: limit)
    set(\.continueListening, route: .continueListening, rows: merged.map { Self.row($0, list: "continue") })
  }

  private func set(
    _ keyPath: ReferenceWritableKeyPath<CarPlayBrowseModel, CarPlayBrowseSnapshot>,
    route: CarPlayBrowseRoute, rows: [CarPlayBrowseRow]
  ) {
    let next = CarPlayBrowseSnapshot(generation: generation, route: route, content: .rows(rows))
    if self[keyPath: keyPath] != next { self[keyPath: keyPath] = next }
  }

  private static func row(_ item: HomeItem, list: String) -> CarPlayBrowseRow {
    let artwork: CarPlayArtworkReference =
      item.artworkURL.map { .feed(itemID: item.serverItemId, url: $0, feedURL: item.artworkFeedURL) }
      ?? .item(id: item.serverItemId, updatedAt: item.serverUpdatedAt)
    return CarPlayBrowseRow(
      id: "\(list)|\(item.serverItemId)|\(item.episodeID ?? "")",
      identity: ListeningIdentity.resolving(itemID: item.serverItemId, episodeID: item.episodeID),
      title: item.episodeTitle ?? item.title,
      // An episode row is titled by its episode, so the show's name is the second line.
      subtitle: item.episodeTitle == nil ? item.author : item.title,
      artwork: artwork)
  }

  private static func row(_ item: ListeningQueueItem) -> CarPlayBrowseRow {
    let artwork: CarPlayArtworkReference =
      item.artworkURL.map { .feed(itemID: item.identity.itemID, url: $0, feedURL: item.artworkFeedURL) }
      ?? .item(id: item.identity.itemID, updatedAt: item.serverUpdatedAt)
    return CarPlayBrowseRow(
      id: "queue|\(item.id)",
      identity: item.identity,
      title: ListeningQueueRowText.primary(item),
      subtitle: ListeningQueueRowText.secondary(item),
      artwork: artwork, chapter: item.rowChapter)
  }
}
