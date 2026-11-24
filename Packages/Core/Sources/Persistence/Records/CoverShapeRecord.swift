import Foundation
import GRDB

/// The measured shape of one item's cover: width ÷ height, so a 2:3 book cover is 0.667.
///
/// The revision is stored with the ratio and a reader uses the ratio only for that revision. A
/// cover replaced on the server therefore stops matching by itself; nothing has to reset the row.
public struct CoverShapeRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "coverShape"

  public var itemId: String
  public var revision: String
  public var aspectRatio: Double
  /// The detail width fetched for this shape. A reader asks for the fitted cover only at this
  /// width, which is the one known to be stored.
  public var fitPixelWidth: Int
  public var measuredAt: Date

  public init(
    itemId: String, revision: String, aspectRatio: Double, fitPixelWidth: Int, measuredAt: Date
  ) {
    self.itemId = itemId
    self.revision = revision
    self.aspectRatio = aspectRatio
    self.fitPixelWidth = fitPixelWidth
    self.measuredAt = measuredAt
  }
}
