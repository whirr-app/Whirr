import Foundation
import GRDB

/// The reasons other than a list's own claim to keep a download, for both sources. A pinned
/// list's release and a smart list's release both ask here, so neither feature deletes what the
/// other keeps or what the listener has since queued, saved or started playing.
enum DownloadKeepChecks {
  /// Up Next, Saved for Later, an active playback session, or a transfer in flight. `itemID` and
  /// `episodeID` are the list's identity pair: a server item and episode id, or `rss:<feedId>`
  /// and the native episode's identity key. A book has no episode id. An identity the device
  /// does not hold is not kept.
  ///
  /// Native playback is not in the database: the active episode row ids come from the playback
  /// tracker, as the storage ceiling's exclusion does.
  static func isKeptByListening(
    _ db: Database, accountID: Int64?, itemID: String, episodeID: String?,
    activeNativeEpisodeIDs: Set<Int64> = []
  ) throws -> Bool {
    if let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId {
      return try isNativeEpisodeKept(
        db, feedID: feedID, episodeID: episodeID, activeEpisodeIDs: activeNativeEpisodeIDs)
    }
    guard let accountID else { return false }
    return try isServerIdentityKept(db, accountID: accountID, itemID: itemID, episodeID: episodeID)
  }

  /// Whether any smart list holds a claim on this server episode.
  static func isClaimedBySmartList(
    _ db: Database, accountID: Int64, itemID: String, episodeID: String
  ) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(SELECT 1 FROM smartListDownloadClaim
          WHERE accountId = ? AND itemID = ? AND episodeID = ?)
        """,
      arguments: [accountID, itemID, episodeID]) ?? false
  }

  private static func isNativeEpisodeKept(
    _ db: Database, feedID: Int64, episodeID: String?, activeEpisodeIDs: Set<Int64>
  ) throws -> Bool {
    guard let episodeID,
      let rowID = try Int64.fetchOne(
        db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
        arguments: [feedID, episodeID])
    else { return false }
    if activeEpisodeIDs.contains(rowID) { return true }
    for table in ["rssListeningQueueEntry", "rssSavedShelfEntry"] {
      if try Bool.fetchOne(
        db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE rssEpisodeId = ?)",
        arguments: [rowID]) == true
      {
        return true
      }
    }
    return try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS(SELECT 1 FROM rssDownload WHERE episodeId = ? AND state IN (?, ?))",
      arguments: [rowID, DownloadState.downloading.rawValue, DownloadState.deleting.rawValue])
      ?? false
  }

  private static func isServerIdentityKept(
    _ db: Database, accountID: Int64, itemID serverItemID: String, episodeID serverEpisodeID: String?
  ) throws -> Bool {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT item.id AS itemId, episode.id AS episodeId FROM item
          LEFT JOIN podcastEpisode AS episode ON episode.itemId = item.id
            AND episode.serverEpisodeId = ?
          WHERE item.accountId = ? AND item.serverItemId = ?
          """,
        arguments: [serverEpisodeID, accountID, serverItemID])
    else { return false }
    let itemID: Int64 = row["itemId"]
    let episodeID: Int64? = row["episodeId"]
    if serverEpisodeID != nil, episodeID == nil { return false }
    let identity = "itemId = ? AND podcastEpisodeId IS ?"
    let arguments: StatementArguments = [accountID, itemID, episodeID]
    for table in ["listeningQueueEntry", "savedShelfEntry"] {
      if try Bool.fetchOne(
        db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE accountId = ? AND \(identity))",
        arguments: arguments) == true
      {
        return true
      }
    }
    if try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS(SELECT 1 FROM playbackSession WHERE accountId = ? AND \(identity) AND state = ?)",
      arguments: arguments + [PlaybackSessionState.active.rawValue]) == true
    {
      return true
    }
    return try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(SELECT 1 FROM download WHERE accountId = ? AND \(identity)
          AND mediaKind = ? AND state IN (?, ?))
        """,
      arguments: arguments + [
        DownloadMediaKind.audio.rawValue, DownloadState.downloading.rawValue,
        DownloadState.deleting.rawValue,
      ]) == true
  }
}
