import Foundation
import GRDB

/// The traversal seen-set for `item`, kept in its own table.
///
/// A traversal stamps every item it visits so the next can infer deletions. As a column on `item`
/// the stamp would rewrite every row each traversal and invalidate every `item` observation; here
/// it lands outside the region those observations track.
///
/// Absence is not generation zero: rows also reach `item` outside traversals (search's
/// non-destructive upsert, podcast refresh) and have no seen row until one visits them. Deletion
/// inference must LEFT JOIN and treat a missing row as "never seen by any traversal".
public struct ItemSeenRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "itemSeen"

  /// Primary key: one seen row per item, cascading from `item` so a hard delete takes it along.
  public var itemId: Int64
  public var generation: Int

  public init(itemId: Int64, generation: Int) {
    self.itemId = itemId
    self.generation = generation
  }
}
