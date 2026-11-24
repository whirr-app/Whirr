import Foundation
import GRDB

/// The last listening-stats figures fetched for an account. `SyncEngine` derives it from
/// `GET /api/me/listening-stats` and trims it before storing.
public struct ListeningStatsSnapshot: Sendable, Equatable {
  /// One server calendar day: `date` is the server's `YYYY-MM-DD` key.
  public struct Day: Sendable, Equatable, Codable {
    public let date: String
    public let seconds: Double

    public init(date: String, seconds: Double) {
      self.date = date
      self.seconds = seconds
    }
  }

  public struct Title: Sendable, Equatable, Codable {
    public let serverItemId: String
    public let title: String?
    public let author: String?
    public let seconds: Double

    public init(serverItemId: String, title: String?, author: String?, seconds: Double) {
      self.serverItemId = serverItemId
      self.title = title
      self.author = author
      self.seconds = seconds
    }
  }

  public let fetchedAt: Date
  public let totalSeconds: Double
  /// Oldest first.
  public let days: [Day]
  /// Keyed by `Calendar` weekday number, Sunday = 1.
  public let weekdaySeconds: [Int: Double]
  /// Largest first.
  public let titles: [Title]

  public init(
    fetchedAt: Date, totalSeconds: Double, days: [Day], weekdaySeconds: [Int: Double], titles: [Title]
  ) {
    self.fetchedAt = fetchedAt
    self.totalSeconds = totalSeconds
    self.days = days
    self.weekdaySeconds = weekdaySeconds
    self.titles = titles
  }
}

/// One row per account in `listeningStatsSnapshot` (v88), replaced whole on each successful fetch.
public struct ListeningStatsSnapshotStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// The stored snapshot, or `nil` when there is none or its payload no longer decodes. A cache
  /// that cannot be read is treated as absent: the next fetch replaces it.
  public func snapshot(accountId: Int64) async throws -> ListeningStatsSnapshot? {
    try await database.readAsync { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT fetchedAt, totalSeconds, daysJSON, weekdaysJSON, titlesJSON
            FROM listeningStatsSnapshot WHERE accountId = ?
            """,
          arguments: [accountId])
      else { return nil }
      let decoder = JSONDecoder()
      let daysJSON: String = row["daysJSON"]
      let weekdaysJSON: String = row["weekdaysJSON"]
      let titlesJSON: String = row["titlesJSON"]
      guard
        let days = try? decoder.decode([ListeningStatsSnapshot.Day].self, from: Data(daysJSON.utf8)),
        let weekdays = try? decoder.decode([String: Double].self, from: Data(weekdaysJSON.utf8)),
        let titles = try? decoder.decode(
          [ListeningStatsSnapshot.Title].self, from: Data(titlesJSON.utf8))
      else { return nil }
      var weekdaySeconds: [Int: Double] = [:]
      for (key, seconds) in weekdays {
        guard let weekday = Int(key), (1...7).contains(weekday) else { return nil }
        weekdaySeconds[weekday] = seconds
      }
      return ListeningStatsSnapshot(
        fetchedAt: row["fetchedAt"], totalSeconds: row["totalSeconds"], days: days,
        weekdaySeconds: weekdaySeconds, titles: titles)
    }
  }

  public func replace(accountId: Int64, with snapshot: ListeningStatsSnapshot) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let daysJSON = String(decoding: try encoder.encode(snapshot.days), as: UTF8.self)
    let weekdaysJSON = String(
      decoding: try encoder.encode(
        Dictionary(uniqueKeysWithValues: snapshot.weekdaySeconds.map { (String($0.key), $0.value) })),
      as: UTF8.self)
    let titlesJSON = String(decoding: try encoder.encode(snapshot.titles), as: UTF8.self)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO listeningStatsSnapshot
            (accountId, fetchedAt, totalSeconds, daysJSON, weekdaysJSON, titlesJSON)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(accountId) DO UPDATE SET
            fetchedAt = excluded.fetchedAt,
            totalSeconds = excluded.totalSeconds,
            daysJSON = excluded.daysJSON,
            weekdaysJSON = excluded.weekdaysJSON,
            titlesJSON = excluded.titlesJSON
          """,
        arguments: [accountId, snapshot.fetchedAt, snapshot.totalSeconds, daysJSON, weekdaysJSON, titlesJSON])
    }
  }
}
