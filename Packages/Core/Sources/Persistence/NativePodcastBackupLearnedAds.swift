import Foundation
import GRDB

extension NativePodcastBackupContents {
  /// A learned ad or an undone skip from the ad-skip signature store, as a backup carries it
  /// Hashes and an audio print only: never transcript text.
  public struct LearnedAd: Sendable, Equatable {
    /// An episode of the group that taught the ad, named the way the backup names any episode.
    /// Only episodes of followed RSS shows can be named; other teachers are left out.
    public struct Teacher: Sendable, Hashable {
      public var feedURL: String
      public var identityKey: String

      public init(feedURL: String, identityKey: String) {
        self.feedURL = feedURL
        self.identityKey = identityKey
      }
    }

    public var kind: AdSignatureKind
    public var lastSeen: Date
    public var startTime: Double
    public var endTime: Double
    public var hashes: Set<UInt64>
    /// Little-endian 32-bit words. Learned ads only, and optional even then: an ad without one
    /// still matches by hash.
    public var audioPrint: Data?
    public var teachers: Set<Teacher>
    /// A listener's mark taught it, so the store keeps it. Learned ads only.
    public var confirmed: Bool

    public init(
      kind: AdSignatureKind, lastSeen: Date, startTime: Double, endTime: Double, hashes: Set<UInt64>,
      audioPrint: Data?, teachers: Set<Teacher>, confirmed: Bool = false
    ) {
      self.kind = kind
      self.lastSeen = lastSeen
      self.startTime = startTime
      self.endTime = endTime
      self.hashes = hashes
      self.audioPrint = audioPrint
      self.teachers = teachers
      self.confirmed = kind == .learned && confirmed
    }
  }
}

extension AdSkipEpisodeIdentity {
  /// U+001F, which no server or feed identifier contains, so distinct identities never collide.
  private static let teacherKeySeparator = "\u{1F}"

  /// The opaque key the ad-skip pipeline and the signature store's teacher rows use. It names a
  /// local row, so it means nothing on another install: a backup carries `LearnedAd.Teacher`.
  public var teacherKey: String {
    switch source {
    case .abs:
      ["abs", String(accountId ?? 0), itemID, episodeID].joined(separator: Self.teacherKeySeparator)
    case .rss:
      ["rss", itemID, episodeID].joined(separator: Self.teacherKeySeparator)
    }
  }

  /// The feed row and episode identity an RSS teacher key names, or nil for any other key.
  static func rssTeacher(fromKey key: String) -> (feedID: Int64, identityKey: String)? {
    let parts = key.components(separatedBy: teacherKeySeparator)
    guard parts.count == 3, parts[0] == "rss", parts[1].hasPrefix(PodcastSourceIdentity.reservedPrefix),
      let feedID = Int64(parts[1].dropFirst(PodcastSourceIdentity.reservedPrefix.count)), feedID > 0
    else { return nil }
    return (feedID, parts[2])
  }

  static func rssTeacherKey(feedID: Int64, identityKey: String) -> String? {
    guard let itemID = PodcastSourceIdentity.rss(feedId: feedID)?.itemId else { return nil }
    return AdSkipEpisodeIdentity(source: .rss, accountId: nil, itemID: itemID, episodeID: identityKey).teacherKey
  }
}

extension NativePodcastBackupReader {
  /// The whole signature store, prints included. Teachers are translated to the backup's own
  /// episode naming; one that names a server episode or a show no longer followed is dropped.
  static func learnedAds(in db: Database) throws -> [NativePodcastBackupContents.LearnedAd] {
    var feedURLs: [Int64: String] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT id, feedURL FROM rssFeed") {
      feedURLs[row["id"]] = row["feedURL"]
    }
    var teachers: [Int64: Set<NativePodcastBackupContents.LearnedAd.Teacher>] = [:]
    let teacherRows = try Row.fetchCursor(db, sql: "SELECT creativeId, episodeKey FROM adSignatureTeacher")
    while let row = try teacherRows.next() {
      guard let teacher = AdSkipEpisodeIdentity.rssTeacher(fromKey: row[1] as String),
        let feedURL = feedURLs[teacher.feedID]
      else { continue }
      teachers[row[0] as Int64, default: []].insert(.init(feedURL: feedURL, identityKey: teacher.identityKey))
    }
    var hashes: [Int64: Set<UInt64>] = [:]
    let shingleRows = try Row.fetchCursor(db, sql: "SELECT creativeId, hash FROM adSignatureShingle")
    while let row = try shingleRows.next() {
      hashes[row[0] as Int64, default: []].insert(UInt64(bitPattern: row[1] as Int64))
    }
    return try Row.fetchAll(
      db,
      sql: """
        SELECT id, kind, lastSeen, startTime, endTime, audioPrint, confirmed
        FROM adSignatureCreative ORDER BY id
        """
    ).compactMap { row in
      let id: Int64 = row["id"]
      guard let own = hashes[id], own.isEmpty == false else { return nil }
      return NativePodcastBackupContents.LearnedAd(
        kind: row["kind"], lastSeen: row["lastSeen"], startTime: row["startTime"], endTime: row["endTime"],
        hashes: own, audioPrint: row["audioPrint"], teachers: teachers[id] ?? [],
        confirmed: row["confirmed"])
    }
  }
}

extension NativePodcastBackupRestorer {
  /// The most teachers a learned ad keeps: the backup file's limit, which lives in `SyncEngine`
  /// where this target cannot see it. `LearnedAdLimitsTests` holds the copies equal.
  public static let maximumLearnedAdTeachers = 256

  /// Fills in the learned ads the device lacks. A learned ad is already here when a local learned
  /// ad holds every one of its hashes (the device stores each ad once, with the hashes of every
  /// copy heard), so restoring a file twice adds nothing. An undone skip is here only with exactly
  /// the same hashes. For an ad the device has, the later `lastSeen` is kept, a missing audio
  /// print is filled and the file's teachers are added; with several local matches, the lowest id.
  ///
  /// A teacher is rewritten to its show's local key when the backup's shows include it, else
  /// dropped. An ad left with no teachers matches its own teaching episode too.
  static func applyLearnedAds(
    _ ads: [NativePodcastBackupContents.LearnedAd], feedIDs: [String: Int64], in db: Database,
    outcome: inout NativePodcastRestoreOutcome
  ) throws {
    guard ads.isEmpty == false else { return }
    struct Local {
      var kind: AdSignatureKind
      var lastSeen: Date
      var hasPrint: Bool
      var confirmed: Bool
      var hashes: Set<UInt64>
      var teachers: Set<String>
    }
    var locals: [Int64: Local] = [:]
    for row in try Row.fetchAll(
      db, sql: "SELECT id, kind, lastSeen, audioPrint IS NOT NULL AS hasPrint, confirmed FROM adSignatureCreative")
    {
      locals[row["id"]] = Local(
        kind: row["kind"], lastSeen: row["lastSeen"], hasPrint: row["hasPrint"],
        confirmed: row["confirmed"], hashes: [], teachers: [])
    }
    let teacherRows = try Row.fetchCursor(db, sql: "SELECT creativeId, episodeKey FROM adSignatureTeacher")
    while let row = try teacherRows.next() {
      locals[row[0] as Int64]?.teachers.insert(row[1] as String)
    }
    // Which ads hold each hash, so an ad holding all of a file ad's hashes is found without
    // comparing it with every local ad.
    var holders: [UInt64: [Int64]] = [:]
    let shingleRows = try Row.fetchCursor(db, sql: "SELECT creativeId, hash FROM adSignatureShingle")
    while let row = try shingleRows.next() {
      let id: Int64 = row[0]
      let hash = UInt64(bitPattern: row[1] as Int64)
      locals[id]?.hashes.insert(hash)
      holders[hash, default: []].append(id)
    }

    /// The lowest id of the local ads of `ad`'s kind that already hold it.
    func holder(of ad: NativePodcastBackupContents.LearnedAd) -> Int64? {
      var fewest: [Int64]?
      for hash in ad.hashes {
        guard let ids = holders[hash] else { return nil }
        if fewest == nil || ids.count < (fewest?.count ?? 0) { fewest = ids }
      }
      return (fewest ?? []).filter { id in
        guard let local = locals[id], local.kind == ad.kind else { return false }
        return ad.kind == .learned ? local.hashes.isSuperset(of: ad.hashes) : local.hashes == ad.hashes
      }.min()
    }

    for ad in ads where ad.hashes.isEmpty == false {
      let print = ad.kind == .learned ? ad.audioPrint.flatMap { $0.isEmpty ? nil : $0 } : nil
      let keys = Set(
        ad.teachers.compactMap { teacher in
          feedIDs[teacher.feedURL].flatMap {
            AdSkipEpisodeIdentity.rssTeacherKey(feedID: $0, identityKey: teacher.identityKey)
          }
        })
      if let id = holder(of: ad), var local = locals[id] {
        if ad.lastSeen > local.lastSeen {
          try db.execute(
            sql: "UPDATE adSignatureCreative SET lastSeen = ? WHERE id = ?", arguments: [ad.lastSeen, id])
          local.lastSeen = ad.lastSeen
        }
        var changed = false
        // A confirmed ad stays confirmed wherever it is restored.
        if ad.confirmed, local.confirmed == false {
          try db.execute(sql: "UPDATE adSignatureCreative SET confirmed = 1 WHERE id = ?", arguments: [id])
          local.confirmed = true
          changed = true
        }
        if local.hasPrint == false, let print {
          try db.execute(
            sql: "UPDATE adSignatureCreative SET audioPrint = ? WHERE id = ?", arguments: [print, id])
          local.hasPrint = true
          changed = true
        }
        if ad.kind == .learned {
          for key in keys.subtracting(local.teachers).sorted()
          where local.teachers.count < maximumLearnedAdTeachers {
            try db.execute(
              sql: "INSERT INTO adSignatureTeacher (creativeId, episodeKey) VALUES (?, ?)", arguments: [id, key])
            local.teachers.insert(key)
            changed = true
          }
        }
        if changed { outcome.learnedAdsChanged += 1 }
        locals[id] = local
        continue
      }
      try db.execute(
        sql: """
          INSERT INTO adSignatureCreative (kind, lastSeen, startTime, endTime, audioPrint, confirmed)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [ad.kind, ad.lastSeen, ad.startTime, ad.endTime, print, ad.confirmed])
      let id = db.lastInsertedRowID
      for key in keys {
        try db.execute(
          sql: "INSERT INTO adSignatureTeacher (creativeId, episodeKey) VALUES (?, ?)", arguments: [id, key])
      }
      for hash in ad.hashes {
        try db.execute(
          sql: "INSERT INTO adSignatureShingle (creativeId, hash) VALUES (?, ?)",
          arguments: [id, Int64(bitPattern: hash)])
        holders[hash, default: []].append(id)
      }
      locals[id] = Local(
        kind: ad.kind, lastSeen: ad.lastSeen, hasPrint: print != nil, confirmed: ad.confirmed,
        hashes: ad.hashes, teachers: keys)
      outcome.learnedAdsAdded += 1
    }
  }
}
