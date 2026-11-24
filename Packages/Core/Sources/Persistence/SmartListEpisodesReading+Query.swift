import Foundation
import GRDB

/// Compiles a list's rules into the one SQL statement every `SmartListEpisodesReading` call runs.
/// Private to the reading: nothing outside this module's reading sees SQL or its arguments.
struct SmartListQuery {
  struct AccountBinding {
    let id: Int64
    let clientUUID: String
    /// `AccountRecord.serverIdentityFingerprint`, a Swift hash the twin join compares.
    let serverIdentityFingerprint: String
  }

  enum ShowSource {
    /// The list's own `smartListShow` rows.
    case stored(listID: Int64)
    /// An unsaved editor draft.
    case draft([SmartListShowSelection])
  }

  let rules: SmartListRules
  let shows: ShowSource
  /// Hidden episodes are read for this list; nil (a draft of a new list) hides nothing.
  let hiddenListID: Int64?
  let account: AccountBinding?
  let nativeEnabled: Bool
  let now: Date
  /// A run plays only unfinished episodes, whatever the Played toggle says.
  let unfinishedOnly: Bool

  /// A native episode is still in its feed's latest fetch. Dropped episodes are kept
  /// (`retained`) for history but fail this.
  static func nativeCurrentSQL(episode: String, feed: String) -> String {
    "\(episode).lastSeenGeneration = \(feed).refreshGeneration"
  }

  // MARK: - Statements

  /// The list in order, `limit` rows. `withCount` adds `matchCount` to every row.
  func listStatement(limit: Int, withCount: Bool) -> (sql: String, arguments: StatementArguments) {
    var arguments = Arguments()
    let candidates = candidatesSQL(&arguments)
    arguments["limit"] = limit
    let count = withCount ? ", COUNT(*) OVER () AS matchCount" : ""
    let sql = """
      \(candidates)
      SELECT *\(count) FROM candidates
      ORDER BY \(orderBySQL)
      LIMIT :limit
      """
    return (sql, StatementArguments(arguments.values))
  }

  func countStatement() -> (sql: String, arguments: StatementArguments) {
    var arguments = Arguments()
    let candidates = candidatesSQL(&arguments)
    return ("\(candidates)\nSELECT COUNT(*) FROM candidates", StatementArguments(arguments.values))
  }

  /// Priority episodes first (never the anchor itself), then strictly after the anchor in list
  /// order, then the rest from the top. One statement: `phase` orders the three groups.
  func nextStatement(
    after anchor: SmartListSortKey?, excluding: [(itemID: String, episodeID: String)], count: Int
  ) -> (sql: String, arguments: StatementArguments) {
    var arguments = Arguments()
    let candidates = candidatesSQL(&arguments)
    var filters: [String] = []
    for (index, pair) in excluding.enumerated() {
      arguments["xItem\(index)"] = pair.itemID
      arguments["xEpisode\(index)"] = pair.episodeID
      filters.append("NOT (itemID = :xItem\(index) AND episodeID = :xEpisode\(index))")
    }
    var phaseTerm = ""
    if let anchor {
      arguments["aSource"] = anchor.source.rawValue
      arguments["aShow"] = anchor.showKey
      arguments["aEpisode"] = anchor.episodeID
      arguments["aPriority"] = anchor.isPriority ? 1 : 0
      let tail = """
        (source > :aSource OR (source = :aSource AND (showKey > :aShow
          OR (showKey = :aShow AND episodeID > :aEpisode))))
        """
      let valueStage: String
      if let value = anchor.value {
        arguments["aValue"] = value
        let comparison = anchor.valueDescends ? "<" : ">"
        valueStage = """
          (sortValue IS NULL OR sortValue \(comparison) :aValue
            OR (sortValue = :aValue AND \(tail)))
          """
      } else {
        valueStage = "(sortValue IS NULL AND \(tail))"
      }
      let after = "(isPriority < :aPriority OR (isPriority = :aPriority AND \(valueStage)))"
      let isAnchor = "(source = :aSource AND showKey = :aShow AND episodeID = :aEpisode)"
      phaseTerm = """
        CASE WHEN isPriority = 1 AND NOT \(isAnchor) THEN 0 WHEN \(after) THEN 1 ELSE 2 END,
        """
    }
    arguments["limit"] = count
    let whereSQL = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
    let sql = """
      \(candidates)
      SELECT * FROM candidates
      \(whereSQL)
      ORDER BY \(phaseTerm) \(orderBySQL)
      LIMIT :limit
      """
    return (sql, StatementArguments(arguments.values))
  }

  // MARK: - Order

  var orderBySQL: String {
    let direction = (rules.sortOrder == .newest || rules.sortOrder == .longest) ? "DESC" : "ASC"
    return """
      isPriority DESC, sortValue IS NULL, sortValue \(direction), source, showKey, episodeID
      """
  }

  /// Publication time in whole milliseconds, or the known length, as the sort key's `value`.
  private func sortValueSQL(published: String, length: String) -> String {
    switch rules.sortOrder {
    case .newest, .oldest:
      return """
        CASE WHEN \(published) IS NULL THEN NULL
          ELSE CAST(strftime('%s', \(published)) AS INTEGER) * 1000
            + CAST(substr(strftime('%f', \(published)), 4) AS INTEGER) END
        """
    case .shortest, .longest:
      return length
    }
  }

  // MARK: - Candidates

  /// Named statement arguments. Assigning nil binds NULL: a plain dictionary would drop the key
  /// and leave the parameter unbound.
  struct Arguments {
    private(set) var values: [String: DatabaseValue] = [:]

    subscript(key: String) -> (any DatabaseValueConvertible)? {
      get { values[key] }
      set { values[key] = newValue?.databaseValue ?? .null }
    }
  }

  /// `WITH listShow, native, server, candidates`. Each half is filtered before the union, so the
  /// merged set is already the matching rows and only the sort remains.
  private func candidatesSQL(_ arguments: inout Arguments) -> String {
    arguments["nativeEnabled"] = nativeEnabled ? 1 : 0
    arguments["accountID"] = account?.id
    arguments["clientUUID"] = account?.clientUUID
    arguments["serverFingerprint"] = account?.serverIdentityFingerprint
    let rulesSQL = rulePredicateSQL(&arguments)
    return """
      WITH \(listShowSQL(&arguments)),
      native AS (
        SELECT * FROM (\(nativeHalfSQL)) AS half WHERE \(rulesSQL)
      ),
      server AS (
        SELECT * FROM (\(serverHalfSQL)) AS half WHERE \(rulesSQL)
      ),
      candidates AS (SELECT * FROM native UNION ALL SELECT * FROM server)
      """
  }

  private func listShowSQL(_ arguments: inout Arguments) -> String {
    switch shows {
    case .stored(let listID):
      arguments["showListID"] = listID
      return """
        listShow(source, showKey, role) AS (
          SELECT source, showKey, role FROM smartListShow WHERE listId = :showListID)
        """
    case .draft(let selections):
      // One row per show, the last selection winning, as the store's replace would store it.
      var byRef: [SmartListShowRef: SmartListShowRole] = [:]
      var order: [SmartListShowRef] = []
      for selection in selections {
        if byRef.updateValue(selection.role, forKey: selection.ref) == nil {
          order.append(selection.ref)
        }
      }
      guard !order.isEmpty else {
        return """
          listShow(source, showKey, role) AS (
            SELECT NULL, NULL, NULL WHERE 0)
          """
      }
      var rows: [String] = []
      for (index, ref) in order.enumerated() {
        arguments["dSource\(index)"] = ref.source.rawValue
        arguments["dKey\(index)"] = ref.showKey
        arguments["dRole\(index)"] = byRef[ref]?.rawValue
        rows.append("(:dSource\(index), :dKey\(index), :dRole\(index))")
      }
      return "listShow(source, showKey, role) AS (VALUES \(rows.joined(separator: ", ")))"
    }
  }

  /// Over the half's projected columns, identical for both halves.
  private func rulePredicateSQL(_ arguments: inout Arguments) -> String {
    var terms: [String] = []

    var statuses: [Int] = []
    if rules.includeUnplayed { statuses.append(0) }
    if rules.includeInProgress { statuses.append(1) }
    if rules.includePlayed && !unfinishedOnly { statuses.append(2) }
    if statuses.isEmpty {
      terms.append("0")
    } else if statuses.count < 3 {
      terms.append("status IN (\(statuses.map(String.init).joined(separator: ", ")))")
    }

    if rules.includeDownloaded != rules.includeNotDownloaded {
      terms.append("isDownloaded = \(rules.includeDownloaded ? 1 : 0)")
    }
    if rules.savedOnly { terms.append("isSaved = 1") }

    if let window = rules.releaseWindow {
      arguments["cutoff"] = now.addingTimeInterval(-Double(window.rawValue) * 3_600)
      terms.append("(publishedAt IS NOT NULL AND publishedAt >= :cutoff)")
    }
    if rules.durationFilter {
      arguments["longerThan"] = Double(rules.longerThanMinutes) * 60
      arguments["shorterThan"] = Double(rules.shorterThanMinutes) * 60
      terms.append(
        "(lengthSeconds IS NULL OR (lengthSeconds > :longerThan AND lengthSeconds < :shorterThan))")
    }
    switch rules.showScope {
    case .all: break
    case .allExcept: terms.append("COALESCE(role, '') <> 'excluded'")
    case .only: terms.append("role IN ('included', 'priority')")
    }
    if let hiddenListID {
      arguments["hiddenListID"] = hiddenListID
      terms.append(
        """
        NOT EXISTS (
          SELECT 1 FROM smartListHiddenEpisode AS hidden
          WHERE hidden.listId = :hiddenListID AND hidden.itemID = half.itemID
            AND hidden.episodeID = half.episodeID)
        """)
    }
    return terms.isEmpty ? "1" : terms.joined(separator: "\n AND ")
  }

  /// The unknown-length rule: missing or not positive.
  private static func knownLength(_ column: String) -> String {
    "CASE WHEN \(column) > 0 THEN \(column) END"
  }

  private func statusSQL(finished: String, progress: String, length: String) -> String {
    """
    CASE WHEN \(finished) = 1
        OR (\(progress) > 0 AND \(length) IS NOT NULL
          AND \(length) - \(progress) < \(LatestPodcastEpisodePolicy.minimumRemainingSeconds))
      THEN 2 WHEN \(progress) > 0 THEN 1 ELSE 0 END
    """
  }

  private var nativeHalfSQL: String {
    let length =
      "COALESCE(\(Self.knownLength("episode.durationSeconds")), "
      + "\(Self.knownLength("episode.measuredDurationSeconds")))"
    return """
      SELECT
        'native' AS source,
        'rss:' || feed.id AS itemID,
        episode.identityKey AS episodeID,
        feed.feedURL AS showKey,
        COALESCE(feed.title, '') AS showTitle,
        feed.author AS showAuthor,
        COALESCE(episode.title, '') AS episodeTitle,
        episode.publishedAt AS publishedAt,
        \(length) AS lengthSeconds,
        COALESCE(state.position, 0) AS progressSeconds,
        \(statusSQL(
          finished: "COALESCE(state.finished, 0)", progress: "COALESCE(state.position, 0)",
          length: length)) AS status,
        EXISTS (SELECT 1 FROM rssDownload AS download
          WHERE download.episodeId = episode.id AND download.state = 'completed') AS isDownloaded,
        EXISTS (SELECT 1 FROM rssSavedShelfEntry AS saved
          WHERE saved.rssEpisodeId = episode.id) AS isSaved,
        COALESCE(listShow.role = 'priority', 0) AS isPriority,
        listShow.role AS role,
        feed.artworkURL AS artworkURL,
        feed.feedURL AS artworkFeedURL,
        NULL AS showServerUpdatedAt,
        \(sortValueSQL(published: "episode.publishedAt", length: length)) AS sortValue
      FROM rssEpisode AS episode
      JOIN rssFeed AS feed ON feed.id = episode.feedId
      LEFT JOIN rssEpisodeState AS state ON state.episodeId = episode.id
      LEFT JOIN listShow ON listShow.source = 'native' AND listShow.showKey = feed.feedURL
      WHERE :nativeEnabled = 1
        AND \(Self.nativeCurrentSQL(episode: "episode", feed: "feed"))
      """
  }

  /// The twin rule is Home's `nativePreferred` link (a save attempt for this account, naming this
  /// server episode and a native episode by either identity key, plus equal feed fingerprints),
  /// to a native episode that is still current. Latest's window, `includeInLatest` and played
  /// state are deliberately not part of it: the native copy is the one Whirr plays whether or not
  /// the list would show it. With native subscriptions off there is no native copy to prefer.
  private var serverHalfSQL: String {
    let length = Self.knownLength("episode.durationSeconds")
    return """
      SELECT
        'server' AS source,
        item.serverItemId AS itemID,
        episode.serverEpisodeId AS episodeID,
        account.serverUserId || '|' || item.serverItemId AS showKey,
        COALESCE(item.title, '') AS showTitle,
        item.author AS showAuthor,
        episode.title AS episodeTitle,
        episode.publishedAt AS publishedAt,
        \(length) AS lengthSeconds,
        COALESCE(progress.currentTime, 0) AS progressSeconds,
        \(statusSQL(
          finished: "COALESCE(progress.isFinished, 0)",
          progress: "COALESCE(progress.currentTime, 0)", length: length)) AS status,
        EXISTS (SELECT 1 FROM download
          WHERE download.podcastEpisodeId = episode.id AND download.state = 'completed')
          AS isDownloaded,
        EXISTS (SELECT 1 FROM savedShelfEntry AS saved
          WHERE saved.accountId = episode.accountId AND saved.podcastEpisodeId = episode.id)
          AS isSaved,
        COALESCE(listShow.role = 'priority', 0) AS isPriority,
        listShow.role AS role,
        NULL AS artworkURL,
        NULL AS artworkFeedURL,
        item.serverUpdatedAt AS showServerUpdatedAt,
        \(sortValueSQL(published: "episode.publishedAt", length: length)) AS sortValue
      FROM podcastEpisode AS episode
      JOIN item ON item.id = episode.itemId AND item.accountId = episode.accountId
      JOIN library ON library.id = item.libraryId AND library.accountId = item.accountId
      JOIN account ON account.id = item.accountId
      LEFT JOIN mediaProgress AS progress
        ON progress.accountId = episode.accountId
        AND progress.itemId = episode.itemId
        AND progress.podcastEpisodeId = episode.id
      LEFT JOIN listShow
        ON listShow.source = 'server'
        AND listShow.showKey = account.serverUserId || '|' || item.serverItemId
      WHERE episode.accountId = :accountID
        AND episode.softDeleted = 0
        AND item.mediaKind = 'podcast'
        AND \(ItemVisibilityPredicate.sql)
        AND NOT (:nativeEnabled = 1 AND EXISTS (
          SELECT 1
          FROM nativeEpisodeServerSaveAttempt AS attempt
          JOIN rssFeed AS nativeFeed ON nativeFeed.id = attempt.feedId
          JOIN rssEpisode AS nativeEpisode
            ON nativeEpisode.id = attempt.episodeId AND nativeEpisode.feedId = nativeFeed.id
          WHERE attempt.accountId = episode.accountId
            AND attempt.accountClientUUID = :clientUUID
            AND attempt.accountServerIdentityFingerprint = :serverFingerprint
            AND attempt.serverItemId = item.serverItemId
            AND attempt.serverEpisodeId = episode.serverEpisodeId
            AND (
              attempt.episodeIdentityKey = nativeEpisode.identityKey
              OR attempt.episodeIdentityKey = nativeEpisode.alternateIdentityKey
            )
            AND nativeFeed.podcastFeedFingerprint = item.podcastFeedFingerprint
            AND \(DefaultHomeReading.validFingerprintSQL("item.podcastFeedFingerprint"))
            AND \(DefaultHomeReading.validFingerprintSQL("nativeFeed.podcastFeedFingerprint"))
            AND \(Self.nativeCurrentSQL(episode: "nativeEpisode", feed: "nativeFeed"))
        ))
      """
  }

  // MARK: - Rows

  static func episode(from row: Row, order: SmartListSortOrder) -> SmartListEpisode? {
    guard let source = SmartListShowSource(rawValue: row["source"]) else { return nil }
    let showKey: String = row["showKey"]
    let episodeID: String = row["episodeID"]
    let isPriority = (row["isPriority"] as Int) == 1
    let status: SmartListEpisodeStatus
    switch row["status"] as Int {
    case 2: status = .played
    case 1: status = .inProgress
    default: status = .unplayed
    }
    return SmartListEpisode(
      source: source, itemID: row["itemID"], episodeID: episodeID, showKey: showKey,
      showTitle: row["showTitle"], showAuthor: row["showAuthor"],
      title: (row["episodeTitle"] as String?) ?? "", publishedAt: row["publishedAt"],
      durationSeconds: row["lengthSeconds"],
      progressSeconds: PlaybackPositionListProjection.quantizedSeconds(row["progressSeconds"]),
      status: status, isDownloaded: (row["isDownloaded"] as Int) == 1,
      isSaved: (row["isSaved"] as Int) == 1, isPriority: isPriority,
      artworkURL: (row["artworkURL"] as String?).flatMap(URL.init(string:)),
      artworkFeedURL: (row["artworkFeedURL"] as String?).flatMap(URL.init(string:)),
      showServerUpdatedAt: row["showServerUpdatedAt"],
      sortKey: SmartListSortKey(
        order: order, isPriority: isPriority, value: row["sortValue"], source: source,
        showKey: showKey, episodeID: episodeID))
  }
}
