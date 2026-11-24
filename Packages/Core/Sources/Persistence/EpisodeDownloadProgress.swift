import Foundation

/// Owns the list-facing progress quantum. Both podcast readers project a downloading episode's
/// bytes through here, so the show and Downloads screens redraw equally often and a byte write
/// inside one quantum is suppressed by `removeDuplicates`.
public enum EpisodeDownloadProgressProjection {
  /// 2%: fifty steps across a transfer.
  public static let quantum: Double = 0.02

  /// The floored fraction for a transfer with a known total, or `nil` when the total is unknown
  /// (an unknown-length transfer draws an indeterminate control).
  public static func quantizedFraction(receivedBytes: Int64, expectedBytes: Int64) -> Double? {
    guard expectedBytes > 0 else { return nil }
    let fraction = min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
    return floor(fraction / quantum) * quantum
  }

  /// The received byte count floored to the quantum of its total, for projections that report
  /// bytes rather than a fraction. An unknown total floors to the nearest mebibyte instead, so an
  /// indeterminate transfer still settles rather than emitting on every write.
  public static func quantizedBytes(receivedBytes: Int64, expectedBytes: Int64?) -> Int64 {
    guard let expectedBytes, expectedBytes > 0 else {
      let step: Int64 = 1_048_576
      return (receivedBytes / step) * step
    }
    guard let fraction = quantizedFraction(receivedBytes: receivedBytes, expectedBytes: expectedBytes)
    else { return receivedBytes }
    return Int64((fraction * Double(expectedBytes)).rounded(.down))
  }
}
