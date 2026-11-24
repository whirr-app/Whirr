import Foundation
import GRDB

/// Everything a podcast backup carries, read from the native tables. `SyncEngine` maps it to the
/// portable snapshot; this layer never sees the file format.
///
/// Only followed shows are present: `rssFeed` holds no unfollowed ones, and a backup that carried
/// them would let a restore undo an unfollow.
public struct NativePodcastBackupContents: Sendable, Equatable {
  public struct Feed: Sendable, Equatable {
    public var feedURL: String
    public var title: String?
    public var author: String?
    public var subscribedAt: Date
    public var customSortIndex: Int?
    /// `nil` when the show has no settings row, which means every setting is inherited.
    public var settings: FeedSettings?

    public init(
      feedURL: String, title: String?, author: String?, subscribedAt: Date, customSortIndex: Int?,
      settings: FeedSettings?
    ) {
      self.feedURL = feedURL
      self.title = title
      self.author = author
      self.subscribedAt = subscribedAt
      self.customSortIndex = customSortIndex
      self.settings = settings
    }
  }

  public struct FeedSettings: Sendable, Equatable {
    public var autoDownload: String
    public var keepLatest: Int?
    public var deleteAfterPlayed: Bool?
    public var rateStep: Int?
    public var includeInLatest: Bool
    public var notificationOverride: String
    public var trimSilencesOverride: String
    public var voiceBoostOverride: String

    public init(
      autoDownload: String, keepLatest: Int?, deleteAfterPlayed: Bool?, rateStep: Int?, includeInLatest: Bool,
      notificationOverride: String, trimSilencesOverride: String = TrimSilencesShowOverride.inherit.rawValue,
      voiceBoostOverride: String = VoiceBoostShowOverride.inherit.rawValue
    ) {
      self.autoDownload = autoDownload
      self.keepLatest = keepLatest
      self.deleteAfterPlayed = deleteAfterPlayed
      self.rateStep = rateStep
      self.includeInLatest = includeInLatest
      self.notificationOverride = notificationOverride
      self.trimSilencesOverride = trimSilencesOverride
      self.voiceBoostOverride = voiceBoostOverride
    }
  }

  public struct EpisodeState: Sendable, Equatable {
    public var position: Double
    public var finished: Bool
    public var dismissed: Bool
    public var updatedAt: Date

    public init(position: Double, finished: Bool, dismissed: Bool, updatedAt: Date) {
      self.position = position
      self.finished = finished
      self.dismissed = dismissed
      self.updatedAt = updatedAt
    }
  }

  public struct Episode: Sendable, Equatable {
    public var feedURL: String
    public var identityKey: String
    public var alternateIdentityKey: String?
    public var guid: String?
    public var enclosureURL: String?
    public var title: String?
    public var publishedAt: Date?
    public var duration: Double?
    /// `nil` means no state row, which is distinct from a present zero-position row.
    public var state: EpisodeState?
    public var savedAt: Date?

    public init(
      feedURL: String, identityKey: String, alternateIdentityKey: String?, guid: String?, enclosureURL: String?,
      title: String?, publishedAt: Date?, duration: Double?, state: EpisodeState?, savedAt: Date?
    ) {
      self.feedURL = feedURL
      self.identityKey = identityKey
      self.alternateIdentityKey = alternateIdentityKey
      self.guid = guid
      self.enclosureURL = enclosureURL
      self.title = title
      self.publishedAt = publishedAt
      self.duration = duration
      self.state = state
      self.savedAt = savedAt
    }
  }

  public struct Bookmark: Sendable, Equatable {
    public var feedURL: String
    public var identityKey: String
    public var updatedAt: Date

    public init(feedURL: String, identityKey: String, updatedAt: Date) {
      self.feedURL = feedURL
      self.identityKey = identityKey
      self.updatedAt = updatedAt
    }
  }

  public var globalSettings: NativePodcastSettingsRecord
  public var showOrderMode: String
  public var feeds: [Feed]
  public var episodes: [Episode]
  public var bookmark: Bookmark?
  /// Follow generations sync has registered, by lowercased subscription UUID. Empty on a device
  /// that has never synced, where every show is still in its derived initial generation.
  public var followedGenerations: [String: String]
  /// The ad-skip signature store. Not account-owned and not tied to RSS: a listener with only
  /// server podcasts has learned ads and no shows here.
  public var learnedAds: [LearnedAd]

  public init(
    globalSettings: NativePodcastSettingsRecord, showOrderMode: String, feeds: [Feed], episodes: [Episode],
    bookmark: Bookmark?, followedGenerations: [String: String], learnedAds: [LearnedAd] = []
  ) {
    self.globalSettings = globalSettings
    self.showOrderMode = showOrderMode
    self.feeds = feeds
    self.episodes = episodes
    self.bookmark = bookmark
    self.followedGenerations = followedGenerations
    self.learnedAds = learnedAds
  }
}

public struct NativePodcastBackupReader: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// One read snapshot, so a playback tick between queries cannot make the backup disagree with
  /// itself.
  public func contents() async throws -> NativePodcastBackupContents {
    try await database.readAsync { db in try Self.contents(in: db) }
  }

  static func contents(in db: Database) throws -> NativePodcastBackupContents {
    let globals =
      try NativePodcastSettingsRecord.fetchOne(db, key: NativePodcastSettingsRecord.singletonID)
      ?? NativePodcastSettingsRecord()
    let mode =
      try String.fetchOne(db, sql: "SELECT mode FROM rssShowOrder WHERE id = 0")
      ?? NativePodcastShowSortMode.alphabetical.rawValue

    let feeds = try Row.fetchAll(
      db,
      sql: """
        SELECT feed.feedURL, feed.title, feed.author, feed.subscribedAt, feed.customSortIndex,
               settings.feedId AS settingsFeedId, settings.autoDownload, settings.keepLatest,
               settings.deleteAfterPlayed, settings.rateStep, settings.includeInLatest,
               settings.notificationOverride, settings.trimSilencesOverride, settings.voiceBoostOverride
        FROM rssFeed AS feed
        LEFT JOIN rssFeedSettings AS settings ON settings.feedId = feed.id
        ORDER BY feed.id
        """
    ).map { row in
      NativePodcastBackupContents.Feed(
        feedURL: row["feedURL"], title: row["title"], author: row["author"],
        subscribedAt: row["subscribedAt"], customSortIndex: row["customSortIndex"],
        settings: row["settingsFeedId"] == nil
          ? nil
          : NativePodcastBackupContents.FeedSettings(
            autoDownload: row["autoDownload"], keepLatest: row["keepLatest"],
            deleteAfterPlayed: row["deleteAfterPlayed"], rateStep: row["rateStep"],
            includeInLatest: row["includeInLatest"], notificationOverride: row["notificationOverride"],
            trimSilencesOverride: row["trimSilencesOverride"], voiceBoostOverride: row["voiceBoostOverride"]))
    }

    // Only episodes someone interacted with: state, a save, or the bookmark. Feed catalogue rows
    // come back with the next refresh.
    let episodes = try Row.fetchAll(
      db,
      sql: """
        SELECT feed.feedURL, episode.identityKey, episode.alternateIdentityKey, episode.guid,
               episode.enclosureURL, episode.title, episode.publishedAt,
               COALESCE(episode.durationSeconds, episode.measuredDurationSeconds) AS duration,
               state.episodeId AS stateEpisodeId, state.position, state.finished,
               state.hideFromContinueListening, state.updatedAt AS stateUpdatedAt,
               saved.savedAt
        FROM rssEpisode AS episode
        JOIN rssFeed AS feed ON feed.id = episode.feedId
        LEFT JOIN rssEpisodeState AS state ON state.episodeId = episode.id
        LEFT JOIN rssSavedShelfEntry AS saved ON saved.rssEpisodeId = episode.id
        WHERE state.episodeId IS NOT NULL OR saved.rssEpisodeId IS NOT NULL
           OR episode.id = (SELECT episodeId FROM rssPlaybackBookmark WHERE id = 0)
        ORDER BY episode.id
        """
    ).map { row in
      NativePodcastBackupContents.Episode(
        feedURL: row["feedURL"], identityKey: row["identityKey"],
        alternateIdentityKey: row["alternateIdentityKey"], guid: row["guid"],
        enclosureURL: row["enclosureURL"], title: row["title"], publishedAt: row["publishedAt"],
        duration: row["duration"],
        state: row["stateEpisodeId"] == nil
          ? nil
          : NativePodcastBackupContents.EpisodeState(
            position: row["position"], finished: row["finished"],
            dismissed: row["hideFromContinueListening"], updatedAt: row["stateUpdatedAt"]),
        savedAt: row["savedAt"])
    }

    let bookmark = try Row.fetchOne(
      db,
      sql: """
        SELECT feed.feedURL, episode.identityKey, bookmark.updatedAt
        FROM rssPlaybackBookmark AS bookmark
        JOIN rssEpisode AS episode ON episode.id = bookmark.episodeId
        JOIN rssFeed AS feed ON feed.id = episode.feedId
        WHERE bookmark.id = 0
        """
    ).map { row in
      NativePodcastBackupContents.Bookmark(
        feedURL: row["feedURL"], identityKey: row["identityKey"], updatedAt: row["updatedAt"])
    }

    let generations = try Row.fetchAll(
      db, sql: "SELECT subscriptionUUID, generationUUID FROM podcastCloudSubscriptionRegistry WHERE isFollowed = 1"
    ).reduce(into: [String: String]()) { result, row in
      result[(row["subscriptionUUID"] as String).lowercased()] = row["generationUUID"]
    }

    var contents = NativePodcastBackupContents(
      globalSettings: globals, showOrderMode: mode, feeds: feeds, episodes: episodes, bookmark: bookmark,
      followedGenerations: generations)
    contents.learnedAds = try learnedAds(in: db)
    return contents
  }
}
