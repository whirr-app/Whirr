import Persistence

/// What the storage screens' bar is segmented by, in the order the segments are drawn.
public enum StorageCategory: String, Sendable, CaseIterable, Identifiable {
  case audiobooks
  case podcasts
  case documents

  public var id: String { rawValue }
}

/// The storage bar as values: one segment per kind of download that has any bytes.
///
/// Each fraction is a share of the bar's track: the larger of the limit and the total when a limit
/// is finite (so downloads under it leave the track part empty), else `capacityBytes` (what the
/// device could hold for Whirr) when given, else the total, which shows composition only.
public struct StorageBarPresentation: Sendable, Equatable {
  public struct Segment: Sendable, Equatable, Identifiable {
    public let category: StorageCategory
    public let bytes: Int64
    public let fraction: Double

    public var id: String { category.id }
  }

  public let segments: [Segment]

  /// `nil` when nothing is downloaded: an empty bar would be a meter with no reading.
  public init?(breakdown: StorageBreakdown, ceilingBytes: Int64?, capacityBytes: Int64? = nil) {
    let total = breakdown.totalBytes
    guard total > 0 else { return nil }
    let track = max(ceilingBytes ?? capacityBytes ?? total, total)
    let bytesByCategory: [(StorageCategory, Int64)] = [
      (.audiobooks, breakdown.audiobookBytes),
      (.podcasts, breakdown.podcastBytes),
      (.documents, breakdown.documentBytes),
    ]
    segments = bytesByCategory.compactMap { category, bytes in
      guard bytes > 0 else { return nil }
      return Segment(category: category, bytes: bytes, fraction: Double(bytes) / Double(track))
    }
  }
}

/// What releasing the Storage Limit slider on a given value would do to completed downloads.
public enum StorageCeilingReduction: Sendable, Equatable {
  /// The change writes at once and removes nothing.
  case none
  /// The change needs confirming and would remove about this many completed bytes.
  case bytes(Int64)
  /// The change needs confirming, and completed bytes have not loaded to say how much.
  case unknown
}
