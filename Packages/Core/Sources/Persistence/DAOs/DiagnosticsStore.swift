import Foundation
import GRDB
import os

/// The Persistence-owned `DiagnosticsRecording` conformance (ARCHITECTURE.md D16): a bounded,
/// account-scoped, rolling store of category/timing/status-class/endpoint-template events.
/// Never records payloads, tokens, or concrete URLs: `EndpointTemplate`'s validating initialiser
/// makes that structural.
///
/// `record` is best-effort and swallows its own errors: a diagnostics write failure must never
/// surface to a caller mid sync-run/outbox-drain.
public struct DiagnosticsStore: DiagnosticsRecording {
  private let database: AppDatabase
  private let cap: Int
  private let now: @Sendable () -> Date

  /// `cap` bounds rows retained per account (oldest evicted first on every write), so the table
  /// never grows unbounded.
  public init(
    database: AppDatabase, cap: Int = 500, now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    self.cap = cap
    self.now = now
  }

  /// Every recorded event is also written to the unified log, so the current-session log in a
  /// shared problem report shows the same closed-enum facts the durable store keeps, with finer
  /// timestamps. The fields are privacy-safe by construction, which is why they can be `.public`.
  private static let log = PersistenceLogging.logger(category: "diagnostics")

  public func record(_ event: DiagnosticsEvent, accountId: Int64) async {
    Self.log.info(
      """
      \(event.category.rawValue, privacy: .public) \
      \(event.statusClass.rawValue, privacy: .public) \
      \(Int(event.durationMilliseconds.rounded()), privacy: .public)ms \
      \(event.endpointTemplate?.path ?? "-", privacy: .public)
      """)
    try? await database.writeAsync { db in
      var record = DiagnosticsEventRecord(
        accountId: accountId,
        category: event.category,
        statusClass: event.statusClass,
        durationMilliseconds: event.durationMilliseconds,
        endpointTemplate: event.endpointTemplate,
        occurredAt: now())
      try record.insert(db)
      try Self.evictBeyondCap(db, accountId: accountId, cap: cap)
    }
  }

  /// Oldest-first for the account.
  public func fetchAll(accountId: Int64) throws -> [DiagnosticsEventRecord] {
    try database.read { db in
      try DiagnosticsEventRecord
        .filter(Column("accountId") == accountId)
        .order(Column("id"))
        .fetchAll(db)
    }
  }

  /// User-initiated deletion (a future Settings action), per account.
  public func deleteAll(accountId: Int64) throws {
    try database.write { db in
      _ = try DiagnosticsEventRecord.filter(Column("accountId") == accountId).deleteAll(db)
    }
  }

  /// A text summary for a future Settings export screen.
  /// Every field is already privacy-safe by construction, so this only formats them.
  public func export(accountId: Int64) throws -> String {
    let formatter = ISO8601DateFormatter()
    return try fetchAll(accountId: accountId).map { event in
      let endpoint = event.endpointTemplate?.path ?? "-"
      let millis = Int(event.durationMilliseconds.rounded())
      return
        "\(formatter.string(from: event.occurredAt))\t\(event.category.rawValue)\t"
        + "\(event.statusClass.rawValue)\t\(millis)ms\t\(endpoint)"
    }.joined(separator: "\n")
  }

  private static func evictBeyondCap(_ db: Database, accountId: Int64, cap: Int) throws {
    let count = try DiagnosticsEventRecord.filter(Column("accountId") == accountId).fetchCount(db)
    let overflow = count - cap
    guard overflow > 0 else { return }
    let staleIds =
      try DiagnosticsEventRecord
      .filter(Column("accountId") == accountId)
      .order(Column("id"))
      .limit(overflow)
      .fetchAll(db)
      .compactMap(\.id)
    try DiagnosticsEventRecord.deleteAll(db, keys: staleIds)
  }
}
