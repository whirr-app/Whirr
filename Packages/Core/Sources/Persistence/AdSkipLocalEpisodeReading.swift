import Foundation
import GRDB

/// A downloaded podcast episode file the ad-skip coordinator may analyse.
public struct AdSkipLocalEpisode: Sendable, Equatable {
  public var identity: AdSkipEpisodeIdentity
  public var fileURL: URL
  /// The show's declared language tag as stored (ABS `item.podcastLanguage`, RSS
  /// `rssFeed.language`); nil when untagged.
  public var languageTag: String?
  /// The show's title as stored (ABS `item.title`, RSS `rssFeed.title`): a sponsor phrase may open
  /// with it ("The Rest Is Money is powered by…").
  public var showTitle: String?
  /// Other identities that are copies of this episode: for an RSS episode, its Audiobookshelf
  /// copies recorded in `nativeEpisodeServerSaveAttempt`. Sorted, deduplicated.
  public var linkedIdentities: [AdSkipEpisodeIdentity]
  /// The show's feed fingerprint (ABS `item.podcastFeedFingerprint`, RSS
  /// `rssFeed.podcastFeedFingerprint`), validated: one show followed through both sources is one
  /// show. Nil when absent or not a fingerprint.
  public var feedFingerprint: String?

  public init(
    identity: AdSkipEpisodeIdentity, fileURL: URL, languageTag: String?, showTitle: String?,
    linkedIdentities: [AdSkipEpisodeIdentity], feedFingerprint: String? = nil
  ) {
    self.identity = identity
    self.fileURL = fileURL
    self.languageTag = languageTag
    self.showTitle = showTitle
    self.linkedIdentities = linkedIdentities
    self.feedFingerprint = feedFingerprint
  }
}

/// Reads the set of fully downloaded, single-file podcast episodes, applying the same presence
/// rule as `DownloadStore.episodePresence` and `RSSDownloadStore.episodePresence`.
public struct AdSkipLocalEpisodeReader: Sendable {
  private let database: AppDatabase
  /// The downloads root this reader resolves rows against.
  public let downloadsRootURL: URL

  public init(database: AppDatabase, downloadsRootURL: URL) {
    self.database = database
    self.downloadsRootURL = downloadsRootURL
  }

  /// Current set, sorted by (source, accountId ?? 0, itemID, episodeID).
  public func localEpisodes() async throws -> [AdSkipLocalEpisode] {
    let root = downloadsRootURL
    return try await database.readAsync { db in try Self.fetch(db, root: root) }
  }

  /// Emits the current set, then again whenever it changes (deduplicated).
  public func observeLocalEpisodes() -> AsyncStream<[AdSkipLocalEpisode]> {
    let root = downloadsRootURL
    return ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in try Self.fetch(db, root: root) }
        .removeDuplicates())
  }

  /// One language tag per podcast-episode download still to arrive (`pending`, `downloading` or
  /// `interrupted`, or `failed` while waiting for an automatic retry), ABS and RSS. The overnight
  /// analysis task asks for another run the same night only while an analysable one is
  /// outstanding.
  public func outstandingDownloadLanguageTags() async throws -> [String?] {
    try await database.readAsync { db in
      let outstanding = """
        (download.state IN ('pending', 'downloading', 'interrupted')
          OR (download.state = 'failed' AND download.autoRetryNotBefore IS NOT NULL))
        """
      let abs = try String?.fetchAll(
        db,
        sql: """
          SELECT item.podcastLanguage
          FROM download
          JOIN item ON item.id = download.itemId
          WHERE download.podcastEpisodeId IS NOT NULL AND \(outstanding)
          """)
      let rss = try String?.fetchAll(
        db,
        sql: """
          SELECT feed.language
          FROM rssDownload AS download
          JOIN rssEpisode AS episode ON episode.id = download.episodeId
          JOIN rssFeed AS feed ON feed.id = episode.feedId
          WHERE \(outstanding)
          """)
      return abs + rss
    }
  }

  // MARK: - Query

  private static func fetch(_ db: Database, root: URL) throws -> [AdSkipLocalEpisode] {
    var episodes = try absEpisodes(db, root: root)
    episodes.append(contentsOf: try rssEpisodes(db, root: root))
    return episodes.sorted { isOrderedBefore($0.identity, $1.identity) }
  }

  /// Groups the non-deleting rows per episode; a group qualifies only when it is exactly one
  /// completed row (multi-file episodes are not analysed).
  private static func absEpisodes(_ db: Database, root: URL) throws -> [AdSkipLocalEpisode] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT download.accountId AS accountId,
               item.serverItemId AS serverItemId,
               podcastEpisode.serverEpisodeId AS serverEpisodeId,
               item.podcastLanguage AS language,
               item.title AS title,
               item.podcastFeedFingerprint AS feedFingerprint,
               MIN(download.destinationRelativePath) AS path
        FROM download
        JOIN item ON item.id = download.itemId
        JOIN podcastEpisode ON podcastEpisode.id = download.podcastEpisodeId
        WHERE download.podcastEpisodeId IS NOT NULL AND download.state <> 'deleting'
        GROUP BY download.accountId, download.itemId, download.podcastEpisodeId
        HAVING COUNT(*) = 1 AND MIN(download.state) = 'completed'
        """)
    return rows.map { row in
      AdSkipLocalEpisode(
        identity: AdSkipEpisodeIdentity(
          source: .abs, accountId: row["accountId"], itemID: row["serverItemId"],
          episodeID: row["serverEpisodeId"]),
        fileURL: root.appendingPathComponent(row["path"] as String),
        languageTag: row["language"], showTitle: row["title"], linkedIdentities: [],
        feedFingerprint: PodcastFeedIdentity.validatedFingerprint(row["feedFingerprint"]))
    }
  }

  private static func rssEpisodes(_ db: Database, root: URL) throws -> [AdSkipLocalEpisode] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT episode.id AS episodeRowId,
               episode.feedId AS feedId,
               episode.identityKey AS identityKey,
               download.relativePath AS path,
               feed.language AS language,
               feed.title AS title,
               feed.podcastFeedFingerprint AS feedFingerprint
        FROM rssDownload AS download
        JOIN rssEpisode AS episode ON episode.id = download.episodeId
        JOIN rssFeed AS feed ON feed.id = episode.feedId
        WHERE download.state = 'completed'
        """)
    guard rows.isEmpty == false else { return [] }

    let attempts = try Row.fetchAll(
      db,
      sql: """
        SELECT DISTINCT feedId, episodeId, accountId, serverItemId, serverEpisodeId
        FROM nativeEpisodeServerSaveAttempt
        WHERE serverItemId IS NOT NULL AND serverEpisodeId IS NOT NULL
        """)
    struct EpisodeKey: Hashable {
      var feedId: Int64
      var episodeId: Int64
    }
    var linked: [EpisodeKey: Set<AdSkipEpisodeIdentity>] = [:]
    for attempt in attempts {
      let key = EpisodeKey(feedId: attempt["feedId"], episodeId: attempt["episodeId"])
      linked[key, default: []].insert(
        AdSkipEpisodeIdentity(
          source: .abs, accountId: attempt["accountId"], itemID: attempt["serverItemId"],
          episodeID: attempt["serverEpisodeId"]))
    }

    return rows.compactMap { row -> AdSkipLocalEpisode? in
      let feedId: Int64 = row["feedId"]
      guard let itemID = PodcastSourceIdentity.rss(feedId: feedId)?.itemId else { return nil }
      let key = EpisodeKey(feedId: feedId, episodeId: row["episodeRowId"])
      return AdSkipLocalEpisode(
        identity: AdSkipEpisodeIdentity(
          source: .rss, accountId: nil, itemID: itemID, episodeID: row["identityKey"]),
        fileURL: root.appendingPathComponent(row["path"] as String),
        languageTag: row["language"], showTitle: row["title"],
        linkedIdentities: (linked[key] ?? []).sorted(by: isOrderedBefore),
        feedFingerprint: PodcastFeedIdentity.validatedFingerprint(row["feedFingerprint"]))
    }
  }

  private static func isOrderedBefore(
    _ lhs: AdSkipEpisodeIdentity, _ rhs: AdSkipEpisodeIdentity
  ) -> Bool {
    if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
    if (lhs.accountId ?? 0) != (rhs.accountId ?? 0) {
      return (lhs.accountId ?? 0) < (rhs.accountId ?? 0)
    }
    if lhs.itemID != rhs.itemID { return lhs.itemID < rhs.itemID }
    return lhs.episodeID < rhs.episodeID
  }
}
