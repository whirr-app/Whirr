import Foundation
import GRDB

/// A list member by server identity, which survives every refresh of the list.
public struct PinnedListMember: Sendable, Hashable {
  public let serverItemID: String
  public let serverEpisodeID: String?

  public init(serverItemID: String, serverEpisodeID: String?) {
    self.serverItemID = serverItemID
    self.serverEpisodeID = serverEpisodeID
  }

  var episodeKey: String { serverEpisodeID ?? "" }
}

/// A member a pinned list wants downloaded and which has no audio download row yet. `key` is the
/// earliest pin that holds it, which is the pin that claims the download.
public struct PinnedListCandidate: Sendable, Hashable {
  public let key: LibraryCollectionKey
  public let member: PinnedListMember
  public let category: ItemMediaCategory

  public init(key: LibraryCollectionKey, member: PinnedListMember, category: ItemMediaCategory) {
    self.key = key
    self.member = member
    self.category = category
  }
}

/// "This pin's request created this member's audio rows."
public struct PinnedListClaim: Sendable, Hashable {
  public let key: LibraryCollectionKey
  public let member: PinnedListMember

  public init(key: LibraryCollectionKey, member: PinnedListMember) {
    self.key = key
    self.member = member
  }
}

/// A pinned list's download state, over its held, unfinished, not-declined members. `total` counts
/// the members that have audio; ebook-only ones are `notDownloadable`.
public struct PinnedListDownloadSummary: Sendable, Equatable {
  public let total: Int
  public let completed: Int
  public let waitingForWiFi: Int
  public let failed: Int
  public let notDownloadable: Int

  public init(total: Int, completed: Int, waitingForWiFi: Int, failed: Int, notDownloadable: Int) {
    self.total = total
    self.completed = completed
    self.waitingForWiFi = waitingForWiFi
    self.failed = failed
    self.notDownloadable = notDownloadable
  }

  /// Queued, transferring, paused, or not yet requested.
  public var active: Int { total - completed - waitingForWiFi - failed }
}

/// What pinning a list would download now. `expectedBytes` is nil unless every size is known.
public struct PinnedListDownloadPreview: Sendable, Equatable {
  public let count: Int
  public let expectedBytes: Int64?

  public init(count: Int, expectedBytes: Int64?) {
    self.count = count
    self.expectedBytes = expectedBytes
  }
}

/// Durable owner of device-local pins. A pin acts only while its library is live and included and
/// its list is stored; a lossy refresh keeps the old list, so it never releases anything.
public struct PinnedListStore: Sendable {
  let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  // MARK: - Pins

  public func pinnedKeys(accountID: Int64) async -> Set<LibraryCollectionKey> {
    (try? await database.readAsync { db in try Self.pinnedKeys(db: db, accountID: accountID) }) ?? []
  }

  public func observePinnedKeys(accountID: Int64) -> AsyncStream<Set<LibraryCollectionKey>> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.pinnedKeys(db: db, accountID: accountID)
    }
  }

  public func pin(accountID: Int64, key: LibraryCollectionKey, at date: Date) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO pinnedList (accountId, serverLibraryId, kind, serverId, pinnedAt)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [accountID, key.serverLibraryID, key.kind.rawValue, key.serverID, date])
    }
  }

  /// Removes the pin, its claims and its declines, and returns the members it had claimed.
  public func unpin(accountID: Int64, key: LibraryCollectionKey) async throws -> [PinnedListMember] {
    try await database.writeAsync { db in
      let members = try Row.fetchAll(
        db,
        sql: """
          SELECT serverItemId, serverEpisodeId FROM pinnedListClaim
          WHERE accountId = ? AND serverLibraryId = ? AND kind = ? AND serverId = ?
          ORDER BY recordedAt, serverItemId, serverEpisodeId
          """,
        arguments: Self.keyArguments(accountID, key)
      ).map(Self.member(from:))
      try db.execute(
        sql: "DELETE FROM pinnedList WHERE accountId = ? AND serverLibraryId = ? AND kind = ? AND serverId = ?",
        arguments: Self.keyArguments(accountID, key))
      return members
    }
  }

  /// Drops pins whose list a stored snapshot no longer contains: the server deleted it. Their
  /// downloads stay. A pin on an excluded library, or on a kind never fetched, stays.
  @discardableResult
  public func dropVanishedPins(accountID: Int64) async throws -> Int {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          DELETE FROM pinnedList
          WHERE accountId = ?
            AND EXISTS (
              SELECT 1 FROM library
              JOIN libraryCollectionSnapshot AS snapshot ON snapshot.libraryId = library.id
              WHERE library.accountId = pinnedList.accountId
                AND library.serverLibraryId = pinnedList.serverLibraryId
                AND library.softDeleted = 0 AND library.isIncluded = 1
                AND snapshot.kind = pinnedList.kind
            )
            AND NOT EXISTS (
              SELECT 1 FROM library
              JOIN libraryCollection AS list ON list.libraryId = library.id
              WHERE library.accountId = pinnedList.accountId
                AND library.serverLibraryId = pinnedList.serverLibraryId
                AND list.kind = pinnedList.kind AND list.serverId = pinnedList.serverId
            )
          """,
        arguments: [accountID])
      return db.changesCount
    }
  }

  // MARK: - Candidates and claims

  public func candidates(accountID: Int64, limit: Int) async throws -> [PinnedListCandidate] {
    try await database.readAsync { db in
      let rows = try Self.pinnedMembers(db: db, accountID: accountID, key: nil)
      let audio = try Self.audioDownloads(db: db, accountID: accountID)
      let declined = try Self.declined(db: db, accountID: accountID)
      var seen: Set<PinnedListMember> = []
      var result: [PinnedListCandidate] = []
      for row in rows where result.count < limit {
        guard row.isWanted, row.category != .ebook, audio[row.rowIdentity] == nil,
          declined.contains(row.member) == false, seen.insert(row.member).inserted
        else { continue }
        result.append(PinnedListCandidate(key: row.key, member: row.member, category: row.category))
      }
      return result
    }
  }

  /// What pinning this stored list would download now, for the confirmation.
  public func downloadPreview(
    accountID: Int64, key: LibraryCollectionKey
  ) async throws -> PinnedListDownloadPreview {
    try await database.readAsync { db in
      let audio = try Self.audioDownloads(db: db, accountID: accountID)
      var seen: Set<PinnedListMember> = []
      let wanted = try Self.members(db: db, accountID: accountID, key: key, pinnedOnly: false)
        .filter {
          $0.isWanted && $0.category != .ebook && audio[$0.rowIdentity] == nil
            && seen.insert($0.member).inserted
        }
      let sizes = wanted.compactMap(\.expectedBytes)
      return PinnedListDownloadPreview(
        count: wanted.count,
        expectedBytes: sizes.count == wanted.count ? sizes.reduce(0, +) : nil)
    }
  }

  public func recordClaim(
    accountID: Int64, key: LibraryCollectionKey, member: PinnedListMember, at date: Date
  ) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO pinnedListClaim
            (accountId, serverLibraryId, kind, serverId, serverItemId, serverEpisodeId, recordedAt)
          SELECT accountId, serverLibraryId, kind, serverId, ?, ?, ?
          FROM pinnedList
          WHERE accountId = ? AND serverLibraryId = ? AND kind = ? AND serverId = ?
          """,
        arguments: [member.serverItemID, member.episodeKey, date] + Self.keyArguments(accountID, key))
    }
  }

  public func dropClaim(accountID: Int64, claim: PinnedListClaim) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          DELETE FROM pinnedListClaim
          WHERE accountId = ? AND serverLibraryId = ? AND kind = ? AND serverId = ?
            AND serverItemId = ? AND serverEpisodeId = ?
          """,
        arguments: Self.keyArguments(accountID, claim.key) + [
          claim.member.serverItemID, claim.member.episodeKey,
        ])
    }
  }

  /// The members this pin's own requests downloaded: what unpinning may delete.
  public func claimedMembers(accountID: Int64, key: LibraryCollectionKey) async throws -> [PinnedListMember] {
    try await database.readAsync { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT serverItemId, serverEpisodeId FROM pinnedListClaim
          WHERE accountId = ? AND serverLibraryId = ? AND kind = ? AND serverId = ?
          ORDER BY recordedAt, serverItemId, serverEpisodeId
          """,
        arguments: Self.keyArguments(accountID, key)
      ).map(Self.member(from:))
    }
  }

  /// The list's wanted members whose audio download failed: what Try Again resumes.
  public func failedMembers(accountID: Int64, key: LibraryCollectionKey) async throws -> [PinnedListMember] {
    try await database.readAsync { db in
      let audio = try Self.audioDownloads(db: db, accountID: accountID)
      var seen: Set<PinnedListMember> = []
      return try Self.pinnedMembers(db: db, accountID: accountID, key: key)
        .filter { $0.isWanted && audio[$0.rowIdentity] == .failed && seen.insert($0.member).inserted }
        .map(\.member)
    }
  }

  /// Claims whose member has left a list that is still stored. A claim on a list that is not
  /// stored (deleted on the server, or its library excluded) is never releasable.
  public func releasableClaims(accountID: Int64) async throws -> [PinnedListClaim] {
    try await database.readAsync { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT claim.serverLibraryId, claim.kind, claim.serverId,
            claim.serverItemId, claim.serverEpisodeId
          FROM pinnedListClaim AS claim
          JOIN library ON library.accountId = claim.accountId
            AND library.serverLibraryId = claim.serverLibraryId
            AND library.softDeleted = 0 AND library.isIncluded = 1
          JOIN libraryCollection AS list ON list.libraryId = library.id
            AND list.kind = claim.kind AND list.serverId = claim.serverId
          WHERE claim.accountId = ?
            AND NOT EXISTS (
              SELECT 1 FROM libraryCollectionMember AS member
              WHERE member.collectionId = list.id
                AND member.serverItemId = claim.serverItemId
                AND COALESCE(member.serverEpisodeId, '') = claim.serverEpisodeId
            )
          ORDER BY claim.recordedAt, claim.serverItemId, claim.serverEpisodeId
          """,
        arguments: [accountID]
      ).compactMap { row in
        guard let key = Self.key(from: row) else { return nil }
        return PinnedListClaim(key: key, member: Self.member(from: row))
      }
    }
  }

  /// Whether anything other than a pin's own claim keeps this member's download: a stored pinned
  /// list that holds it, a smart list's claim on it, Up Next, an active playback session, Saved
  /// for Later, or a transfer in flight. `excluding` leaves one pin out, so an unpin can count
  /// what it will delete before it runs. The last four are `DownloadKeepChecks`, shared with the
  /// smart-list release.
  public func isKeptBesidesPins(
    accountID: Int64, member: PinnedListMember, excluding: LibraryCollectionKey? = nil
  ) async throws -> Bool {
    try await database.readAsync { db in
      let pinned = try Self.pinnedMembers(db: db, accountID: accountID, key: nil)
      if pinned.contains(where: { $0.member == member && $0.key != excluding }) { return true }
      if let episodeID = member.serverEpisodeID,
        try DownloadKeepChecks.isClaimedBySmartList(
          db, accountID: accountID, itemID: member.serverItemID, episodeID: episodeID)
      {
        return true
      }
      return try DownloadKeepChecks.isKeptByListening(
        db, accountID: accountID, itemID: member.serverItemID, episodeID: member.serverEpisodeID)
    }
  }

  // MARK: - Declines

  /// The listener removed this member's download by hand: every pinned list holding it stops
  /// wanting it, and their claims on it go, since there is nothing left to release.
  public func decline(accountID: Int64, member: PinnedListMember, at date: Date) async throws {
    try await database.writeAsync { db in
      let keys = try Self.pinnedMembers(db: db, accountID: accountID, key: nil)
        .filter { $0.member == member }.map(\.key)
      for key in Set(keys) {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO pinnedListDecline
              (accountId, serverLibraryId, kind, serverId, serverItemId, serverEpisodeId, recordedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: Self.keyArguments(accountID, key) + [member.serverItemID, member.episodeKey, date])
      }
      try db.execute(
        sql: "DELETE FROM pinnedListClaim WHERE accountId = ? AND serverItemId = ? AND serverEpisodeId = ?",
        arguments: [accountID, member.serverItemID, member.episodeKey])
    }
  }

  /// The listener downloaded it again by hand.
  public func clearDeclines(accountID: Int64, member: PinnedListMember) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "DELETE FROM pinnedListDecline WHERE accountId = ? AND serverItemId = ? AND serverEpisodeId = ?",
        arguments: [accountID, member.serverItemID, member.episodeKey])
    }
  }

  /// The listener removed every download: declining each pinned member keeps the pins from
  /// downloading them all again on the next pass. A list pinned afterwards starts fresh.
  public func declineAll(accountID: Int64, at date: Date) async throws {
    try await database.writeAsync { db in
      for row in try Self.pinnedMembers(db: db, accountID: accountID, key: nil) {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO pinnedListDecline
              (accountId, serverLibraryId, kind, serverId, serverItemId, serverEpisodeId, recordedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: Self.keyArguments(accountID, row.key) + [
            row.member.serverItemID, row.member.episodeKey, date,
          ])
      }
      try db.execute(sql: "DELETE FROM pinnedListClaim WHERE accountId = ?", arguments: [accountID])
    }
  }

  /// Drops declines whose member has left a stored list, so rejoining it is wanted again.
  public func pruneDeclines(accountID: Int64) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          DELETE FROM pinnedListDecline
          WHERE accountId = ?
            AND EXISTS (
              SELECT 1 FROM library
              JOIN libraryCollection AS list ON list.libraryId = library.id
              WHERE library.accountId = pinnedListDecline.accountId
                AND library.serverLibraryId = pinnedListDecline.serverLibraryId
                AND library.softDeleted = 0 AND library.isIncluded = 1
                AND list.kind = pinnedListDecline.kind AND list.serverId = pinnedListDecline.serverId
                AND NOT EXISTS (
                  SELECT 1 FROM libraryCollectionMember AS member
                  WHERE member.collectionId = list.id
                    AND member.serverItemId = pinnedListDecline.serverItemId
                    AND COALESCE(member.serverEpisodeId, '') = pinnedListDecline.serverEpisodeId
                )
            )
          """,
        arguments: [accountID])
    }
  }

  // MARK: - Summary

  /// Nil when the list is not pinned or not stored.
  public func summary(accountID: Int64, key: LibraryCollectionKey) async -> PinnedListDownloadSummary? {
    try? await database.readAsync { db in try Self.summary(db: db, accountID: accountID, key: key) }
  }

  public func observeSummary(
    accountID: Int64, key: LibraryCollectionKey
  ) -> AsyncStream<PinnedListDownloadSummary?> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.summary(db: db, accountID: accountID, key: key)
    }
  }

  // MARK: - Queries

  private struct PinnedMemberRow {
    let key: LibraryCollectionKey
    let member: PinnedListMember
    let itemRowID: Int64?
    let episodeRowID: Int64?
    let category: ItemMediaCategory
    let isFinished: Bool
    let expectedBytes: Int64?

    var isHeld: Bool { itemRowID != nil && (member.serverEpisodeID == nil || episodeRowID != nil) }
    var isWanted: Bool { isHeld && isFinished == false }
    var rowIdentity: RowIdentity { RowIdentity(itemID: itemRowID ?? -1, episodeID: episodeRowID) }
  }

  private struct RowIdentity: Hashable {
    let itemID: Int64
    let episodeID: Int64?
  }

  /// Whether any stored pinned list holds this member. A smart-list release asks before it purges.
  static func isPinned(db: Database, accountID: Int64, member: PinnedListMember) throws -> Bool {
    try pinnedMembers(db: db, accountID: accountID, key: nil).contains { $0.member == member }
  }

  /// Members of stored pinned lists in live, included libraries, in pin order then list order.
  private static func pinnedMembers(
    db: Database, accountID: Int64, key: LibraryCollectionKey?
  ) throws -> [PinnedMemberRow] {
    try members(db: db, accountID: accountID, key: key, pinnedOnly: true)
  }

  /// `pinnedOnly: false` reads one stored list whether or not it is pinned, for the preview.
  private static func members(
    db: Database, accountID: Int64, key: LibraryCollectionKey?, pinnedOnly: Bool
  ) throws -> [PinnedMemberRow] {
    let lists =
      pinnedOnly
      ? """
      FROM pinnedList AS pin
      JOIN library ON library.accountId = pin.accountId
        AND library.serverLibraryId = pin.serverLibraryId
        AND library.softDeleted = 0 AND library.isIncluded = 1
      JOIN libraryCollection AS list ON list.libraryId = library.id
        AND list.kind = pin.kind AND list.serverId = pin.serverId
      """
      : """
      FROM library
      JOIN libraryCollection AS list ON list.libraryId = library.id
      """
    var sql = """
      SELECT library.serverLibraryId, list.kind, list.serverId,
        member.serverItemId, member.serverEpisodeId,
        item.id AS itemRowId, episode.id AS episodeRowId,
        item.mediaKind, item.numAudioFiles, item.ebookFormat,
        item.audioDownloadExpectedBytes, episode.sizeBytes AS episodeBytes,
        CASE WHEN member.serverEpisodeId IS NULL THEN itemProgress.isFinished
          ELSE episodeProgress.isFinished END AS isFinished
      \(lists)
      JOIN libraryCollectionMember AS member ON member.collectionId = list.id
      \(LibraryCollectionStore.heldMemberJoin)
      LEFT JOIN mediaProgress AS itemProgress
        ON itemProgress.itemId = item.id AND itemProgress.accountId = item.accountId
        AND itemProgress.podcastEpisodeId IS NULL
      LEFT JOIN mediaProgress AS episodeProgress
        ON episodeProgress.itemId = item.id AND episodeProgress.accountId = item.accountId
        AND episodeProgress.podcastEpisodeId = episode.id
      WHERE library.accountId = ? AND library.softDeleted = 0 AND library.isIncluded = 1
      """
    var arguments: StatementArguments = [accountID]
    if let key {
      sql += " AND library.serverLibraryId = ? AND list.kind = ? AND list.serverId = ?"
      arguments += [key.serverLibraryID, key.kind.rawValue, key.serverID]
    }
    sql +=
      pinnedOnly
      ? " ORDER BY pin.pinnedAt, pin.serverLibraryId, pin.kind, pin.serverId, member.position"
      : " ORDER BY member.position"
    return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
      guard let key = Self.key(from: row) else { return nil }
      let member = PinnedListMember(
        serverItemID: row["serverItemId"], serverEpisodeID: row["serverEpisodeId"])
      let category: ItemMediaCategory =
        member.serverEpisodeID != nil
        ? .podcast
        : ItemMediaCategory.derive(
          mediaKind: row["mediaKind"] ?? "book", numAudioFiles: row["numAudioFiles"],
          ebookFormat: row["ebookFormat"])
      return PinnedMemberRow(
        key: key, member: member, itemRowID: row["itemRowId"], episodeRowID: row["episodeRowId"],
        category: category, isFinished: (row["isFinished"] as Bool?) ?? false,
        expectedBytes: member.serverEpisodeID == nil
          ? row["audioDownloadExpectedBytes"] : (row["episodeBytes"] as Int?).map(Int64.init))
    }
  }

  private enum AudioState { case completed, waitingForWiFi, failed, active }

  /// Each identity's audio rows folded into one state: any failure wins, then a Wi-Fi hold, and
  /// only all-complete counts as completed.
  private static func audioDownloads(db: Database, accountID: Int64) throws -> [RowIdentity: AudioState] {
    var result: [RowIdentity: AudioState] = [:]
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT itemId, podcastEpisodeId, state, holdReason FROM download
        WHERE accountId = ? AND mediaKind = ?
        """,
      arguments: [accountID, DownloadMediaKind.audio.rawValue])
    for row in rows {
      let identity = RowIdentity(itemID: row["itemId"], episodeID: row["podcastEpisodeId"])
      let state: DownloadState? = row["state"]
      let hold: DownloadHoldReason? = row["holdReason"]
      let rowState: AudioState =
        switch state {
        case .failed: .failed
        case .completed: .completed
        case .pending where hold == .waitingForWiFi: .waitingForWiFi
        default: .active
        }
      result[identity] = Self.fold(result[identity], rowState)
    }
    return result
  }

  private static func fold(_ current: AudioState?, _ next: AudioState) -> AudioState {
    guard let current else { return next }
    for state in [AudioState.failed, .waitingForWiFi, .active] where current == state || next == state {
      return state
    }
    return .completed
  }

  private static func declined(db: Database, accountID: Int64) throws -> Set<PinnedListMember> {
    Set(
      try Row.fetchAll(
        db, sql: "SELECT serverItemId, serverEpisodeId FROM pinnedListDecline WHERE accountId = ?",
        arguments: [accountID]
      ).map(Self.member(from:)))
  }

  private static func summary(
    db: Database, accountID: Int64, key: LibraryCollectionKey
  ) throws -> PinnedListDownloadSummary? {
    guard try pinnedKeys(db: db, accountID: accountID).contains(key),
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(SELECT 1 FROM library
            JOIN libraryCollection AS list ON list.libraryId = library.id
            WHERE library.accountId = ? AND library.serverLibraryId = ?
              AND library.softDeleted = 0 AND library.isIncluded = 1
              AND list.kind = ? AND list.serverId = ?)
          """,
        arguments: keyArguments(accountID, key)) == true
    else { return nil }
    let audio = try audioDownloads(db: db, accountID: accountID)
    let declined = try declined(db: db, accountID: accountID)
    var seen: Set<PinnedListMember> = []
    var total = 0
    var completed = 0
    var waiting = 0
    var failed = 0
    var notDownloadable = 0
    for row in try pinnedMembers(db: db, accountID: accountID, key: key)
    where row.isWanted && declined.contains(row.member) == false && seen.insert(row.member).inserted {
      guard row.category != .ebook else {
        notDownloadable += 1
        continue
      }
      total += 1
      switch audio[row.rowIdentity] {
      case .completed: completed += 1
      case .waitingForWiFi: waiting += 1
      case .failed: failed += 1
      case .active, nil: break
      }
    }
    return PinnedListDownloadSummary(
      total: total, completed: completed, waitingForWiFi: waiting, failed: failed,
      notDownloadable: notDownloadable)
  }

  private static func pinnedKeys(db: Database, accountID: Int64) throws -> Set<LibraryCollectionKey> {
    Set(
      try Row.fetchAll(
        db, sql: "SELECT serverLibraryId, kind, serverId FROM pinnedList WHERE accountId = ?",
        arguments: [accountID]
      ).compactMap(key(from:)))
  }

  private static func key(from row: Row) -> LibraryCollectionKey? {
    guard let kind = LibraryCollectionListKind(rawValue: row["kind"]) else { return nil }
    return LibraryCollectionKey(
      serverLibraryID: row["serverLibraryId"], kind: kind, serverID: row["serverId"])
  }

  private static func member(from row: Row) -> PinnedListMember {
    let episode: String? = row["serverEpisodeId"]
    return PinnedListMember(
      serverItemID: row["serverItemId"], serverEpisodeID: episode?.isEmpty == true ? nil : episode)
  }

  private static func keyArguments(_ accountID: Int64, _ key: LibraryCollectionKey) -> StatementArguments {
    [accountID, key.serverLibraryID, key.kind.rawValue, key.serverID]
  }
}
