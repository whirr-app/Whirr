import Foundation

/// One archive entry, measured rather than read.
///
/// Both lengths come from the archive's own directory, so a publication can be judged before any
/// entry is decompressed. `expandedBytes` is absent when the archive does not report a decompressed
/// length; admission then falls back to the stored length rather than treating the entry as empty.
public struct EPUBArchiveEntry: Equatable, Sendable {
  public let expandedBytes: UInt64?
  public let storedBytes: UInt64
  public let isCompressed: Bool

  public init(expandedBytes: UInt64?, storedBytes: UInt64, isCompressed: Bool) {
    self.expandedBytes = expandedBytes
    self.storedBytes = storedBytes
    self.isCompressed = isCompressed
  }

  /// The size this entry is judged on: its reported expanded length, or its stored length when the
  /// archive reports none. Never zero-by-default, because an unknown length must not buy an
  /// unbounded entry.
  var admittedBytes: UInt64 { expandedBytes ?? storedBytes }

  /// How far this entry expands. Only meaningful for a compressed entry: a stored entry expands
  /// one-to-one by definition, and its zero or equal stored length would otherwise divide into a
  /// meaningless ratio.
  var compressionRatio: Double? {
    guard isCompressed, storedBytes > 0 else { return nil }
    return Double(admittedBytes) / Double(storedBytes)
  }
}

/// The bounds a publication must satisfy before Whirr will open it.
public struct EPUBArchiveLimits: Equatable, Sendable {
  public let maximumEntryCount: Int
  public let maximumTotalExpandedBytes: UInt64
  public let maximumEntryExpandedBytes: UInt64
  public let maximumCompressionRatio: Double

  public init(
    maximumEntryCount: Int,
    maximumTotalExpandedBytes: UInt64,
    maximumEntryExpandedBytes: UInt64,
    maximumCompressionRatio: Double
  ) {
    self.maximumEntryCount = maximumEntryCount
    self.maximumTotalExpandedBytes = maximumTotalExpandedBytes
    self.maximumEntryExpandedBytes = maximumEntryExpandedBytes
    self.maximumCompressionRatio = maximumCompressionRatio
  }

  /// The bounds the shipped app applies.
  ///
  /// Provisional until calibrated against a real library before release, and generous: refusing a
  /// legitimate book is worse than admitting a hostile one, as entries are served on demand and
  /// rendered out of process.
  public static let release = EPUBArchiveLimits(
    maximumEntryCount: 10_000,
    maximumTotalExpandedBytes: 512 * 1024 * 1024,
    maximumEntryExpandedBytes: 64 * 1024 * 1024,
    maximumCompressionRatio: 100
  )
}

/// Why a publication was refused. The value carried is the measurement that failed, so the refusal
/// can be traced without naming the entry or the book.
public enum EPUBArchiveRefusal: Equatable, Sendable {
  case entryCount(Int)
  case entryExpandedBytes(UInt64)
  case totalExpandedBytes(UInt64)
  case compressionRatio(Double)
}

/// Decides whether a publication's archive may be opened.
///
/// The expanded-resource admission control the release requires. The pinned Readium path
/// serves entries on demand and never extracts to disk, so there is no extraction root to escape;
/// expansion cost remains, bounded here from the archive directory before any entry is
/// decompressed.
public enum EPUBArchiveAdmission {
  public static func refusal(
    forEntries entries: some Sequence<EPUBArchiveEntry>,
    limits: EPUBArchiveLimits = .release
  ) -> EPUBArchiveRefusal? {
    var count = 0
    var totalExpandedBytes: UInt64 = 0

    for entry in entries {
      count += 1
      guard count <= limits.maximumEntryCount else { return .entryCount(count) }

      let entryBytes = entry.admittedBytes
      guard entryBytes <= limits.maximumEntryExpandedBytes else {
        return .entryExpandedBytes(entryBytes)
      }

      if let ratio = entry.compressionRatio, ratio > limits.maximumCompressionRatio {
        return .compressionRatio(ratio)
      }

      totalExpandedBytes &+= entryBytes
      guard totalExpandedBytes <= limits.maximumTotalExpandedBytes else {
        return .totalExpandedBytes(totalExpandedBytes)
      }
    }

    return nil
  }
}
