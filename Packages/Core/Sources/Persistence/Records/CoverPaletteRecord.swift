import Foundation
import GRDB

/// The artwork-specific palette result for one item. A nil accent means extraction completed but
/// found no usable accent; absence of the row means extraction has not run for this item/artwork.
///
/// The accent alone cannot rebuild the page colour, which comes from the selected cluster only
/// when it covers enough of the artwork and from the area average otherwise. So a row also carries
/// the cluster's weight and the average, keeping cold and warm renders identical. The evidence
/// columns are nullable because older rows cannot be backfilled by inference: such a row is
/// stale, falls through to extraction, and is backfilled.
public struct CoverPaletteRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "coverPaletteRecord"

  public var itemId: String
  public var artworkKey: String
  public var accentHue: Double?
  public var accentSaturation: Double?
  public var accentBrightness: Double?
  /// The selected cluster's share of the analysed cover, 0...1. Nil on a pre-evidence row.
  public var clusterWeight: Double?
  /// The selected cluster's colour, stored as sRGB rather than re-derived from the accent's HSB.
  ///
  /// The accent describes the same cluster, but an HSB round trip moves the components by about
  /// 1e-16, and the page colour is compared for equality between the cold and warm paths. Storing
  /// what the policy actually consumes removes the discrepancy instead of tolerating it.
  public var clusterRed: Double?
  public var clusterGreen: Double?
  public var clusterBlue: Double?
  /// The artwork's area-average colour, the fallback source when the cluster is too small.
  public var averageRed: Double?
  public var averageGreen: Double?
  public var averageBlue: Double?
  public var extractedAt: Date

  /// Whether this row can rebuild a page without re-reading the artwork.
  ///
  /// A grey cover legitimately has no accent, so a nil accent is an answer rather than a gap. The
  /// average is what paints its page, and without that the row cannot answer anything.
  public var carriesPageEvidence: Bool {
    averageRed != nil && averageGreen != nil && averageBlue != nil
  }

  public init(
    itemId: String, artworkKey: String, accentHue: Double?, accentSaturation: Double?,
    accentBrightness: Double?, clusterWeight: Double? = nil, clusterRed: Double? = nil,
    clusterGreen: Double? = nil, clusterBlue: Double? = nil, averageRed: Double? = nil,
    averageGreen: Double? = nil, averageBlue: Double? = nil, extractedAt: Date
  ) {
    self.itemId = itemId
    self.artworkKey = artworkKey
    self.accentHue = accentHue
    self.accentSaturation = accentSaturation
    self.accentBrightness = accentBrightness
    self.clusterWeight = clusterWeight
    self.clusterRed = clusterRed
    self.clusterGreen = clusterGreen
    self.clusterBlue = clusterBlue
    self.averageRed = averageRed
    self.averageGreen = averageGreen
    self.averageBlue = averageBlue
    self.extractedAt = extractedAt
  }
}
